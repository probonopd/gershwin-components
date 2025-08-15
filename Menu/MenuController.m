#import "MenuController.h"
#import "MenuBarView.h"
#import "AppMenuWidget.h"
#import "DBusMenuImporter.h"
#import "RoundedCornersView.h"
#import "X11ShortcutManager.h"
#import "GNUstepGUI/GSTheme.h"
#import <X11/Xlib.h>
#import <X11/Xatom.h>

@implementation MenuController

- (id)init
{
    NSLog(@"MenuController: Initializing controller...");
    self = [super init];
    if (self) {
        NSLog(@"MenuController: Controller initialized successfully");
    }
    return self;
}

- (NSColor *)backgroundColor
{
    NSColor *color = [[GSTheme theme] menuItemBackgroundColor];
    return color;
}

- (NSColor *)transparentColor
{
    NSColor *color = [NSColor colorWithCalibratedRed:0.992 green:0.992 blue:0.992 alpha:0.0];
    return color;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
    NSLog(@"MenuController: Application did finish launching");
    
    [_topBar orderFront:self];
    [self setupWindowMonitoring];
    
    NSLog(@"MenuController: Application setup complete");
}

- (void)applicationWillTerminate:(NSNotification *)notification
{
    NSLog(@"MenuController: Application will terminate");
    
    // Clean up global shortcuts first
    NSLog(@"MenuController: Cleaning up global shortcuts...");
    [[X11ShortcutManager sharedManager] cleanup];
    
    // Signal the X11 monitoring thread to stop
    _shouldStopMonitoring = YES;
    
    // Wait for the thread to finish (with timeout to avoid hanging)
    if (_x11Thread && ![_x11Thread isFinished]) {
        // Give the thread a chance to exit gracefully
        [NSThread sleepForTimeInterval:0.1];
        
        if (![_x11Thread isFinished]) {
            NSLog(@"MenuController: X11 thread did not exit gracefully");
        }
    }
    
    [_x11Thread release];
    _x11Thread = nil;
    
    // Close X11 display
    if (_display) {
        XCloseDisplay(_display);
        _display = NULL;
    }
    
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    
    [_dbusMenuImporter release];
    _dbusMenuImporter = nil;
    
    [_roundedCornersView release];
    _roundedCornersView = nil;
}

- (void)createTopBar
{
    const CGFloat menuBarHeight = [[GSTheme theme] menuBarHeight];
    NSRect rect;
    NSColor *color;
    NSFont *menuFont = [NSFont menuBarFontOfSize:0];
    NSMutableDictionary *attributes;
    
    attributes = [NSMutableDictionary new];
    [attributes setObject:menuFont forKey:NSFontAttributeName];
    
    _screenFrame = [[NSScreen mainScreen] frame];
    _screenSize = _screenFrame.size;
    color = [self backgroundColor];
        
    // Creation of the topBar
    rect = NSMakeRect(0, _screenSize.height - menuBarHeight, _screenSize.width, menuBarHeight);
    _topBar = [[NSWindow alloc] initWithContentRect:rect
                                          styleMask:NSBorderlessWindowMask
                                            backing:NSBackingStoreBuffered
                                              defer:NO];
    [_topBar setTitle:@"TopBar"];
    [_topBar setBackgroundColor:color];
    [_topBar setAlphaValue:1.0];
    [_topBar setLevel:NSTornOffMenuWindowLevel-1];
    [_topBar setCanHide:NO];
    [_topBar setHidesOnDeactivate:NO];
    [_topBar setCollectionBehavior:NSWindowCollectionBehaviorCanJoinAllSpaces |
                                   NSWindowCollectionBehaviorStationary];
    
    // Create app menu widget for displaying DBus menus
    _appMenuWidget = [[AppMenuWidget alloc] initWithFrame:NSMakeRect(20, 0, 400, menuBarHeight)];
    [_appMenuWidget setDbusMenuImporter:_dbusMenuImporter];
    
    // probono: Create rounded corners view for black top corners like in old/src/mainwindow.cpp
    // Position it at the top of the menu bar, with height enough for the corner radius effect
    CGFloat cornerHeight = 10.0; // 2 * corner radius (5px)
    _roundedCornersView = [[RoundedCornersView alloc] initWithFrame:NSMakeRect(0, menuBarHeight - cornerHeight, _screenSize.width, cornerHeight)];
    
    // Add subviews (corners on top so they're drawn last)
    [[_topBar contentView] addSubview:_appMenuWidget];
    [[_topBar contentView] addSubview:_roundedCornersView];
    
    [attributes release];
}

- (void)setupMenuBar
{
    NSLog(@"MenuController: Setting up menu bar using createTopBar method");
    [self createTopBar];
    
    NSLog(@"MenuController: Menu bar setup complete at %.0f,%.0f %.0fx%.0f", 
          _screenFrame.origin.x, _screenFrame.origin.y, _screenSize.width, [[GSTheme theme] menuBarHeight]);
}

- (void)updateActiveWindow
{
    // Get the currently active window and update app menu
    if (_appMenuWidget) {
        [_appMenuWidget updateForActiveWindow];
    } else {
        NSLog(@"MenuController: _appMenuWidget is nil");
    }
}

- (void)initializeDBusConnection
{
    NSLog(@"MenuController: Attempting to connect to DBus...");
    if (![_dbusMenuImporter connectToDBus]) {
        NSLog(@"MenuController: Failed to connect to DBus - continuing anyway");
    } else {
        NSLog(@"MenuController: DBus menu importer initialized successfully");
    }
    
    // Set the reverse connection so DBusMenuImporter can trigger immediate menu display
    if (_dbusMenuImporter && _appMenuWidget) {
        [_dbusMenuImporter setAppMenuWidget:_appMenuWidget];
        NSLog(@"MenuController: Set up bidirectional connection between DBusMenuImporter and AppMenuWidget");
    }
}

- (void)createDBusImporter
{
    NSLog(@"MenuController: Creating DBusMenuImporter...");
    _dbusMenuImporter = [[DBusMenuImporter alloc] init];
}

- (void)setupWindowMonitoring
{
    NSLog(@"MenuController: Setting up X11 _NET_ACTIVE_WINDOW monitoring");
    
    // Initialize monitoring flag
    _shouldStopMonitoring = NO;
    
    // Open X11 display connection
    _display = XOpenDisplay(NULL);
    if (!_display) {
        NSLog(@"MenuController: Cannot open X11 display for window monitoring");
        return;
    }
    
    _rootWindow = DefaultRootWindow(_display);
    _netActiveWindowAtom = XInternAtom(_display, "_NET_ACTIVE_WINDOW", False);
    
    // Select PropertyNotify events on the root window to detect _NET_ACTIVE_WINDOW changes
    XSelectInput(_display, _rootWindow, PropertyChangeMask);
    
    NSLog(@"MenuController: X11 display opened, monitoring _NET_ACTIVE_WINDOW property changes");
    
    // Start X11 event loop in a separate NSThread
    _x11Thread = [[NSThread alloc] initWithTarget:self
                                         selector:@selector(x11ActiveWindowMonitor)
                                           object:nil];
    [_x11Thread setName:@"X11ActiveWindowMonitor"];
    [_x11Thread start];
    
    NSLog(@"MenuController: X11 monitoring thread started successfully");
    
    // Perform initial active window update
    [self updateActiveWindow];
    
    NSLog(@"MenuController: Window monitoring setup complete");
}

- (void)announceGlobalMenuSupport
{
    NSLog(@"MenuController: Announcing global menu support via X11 properties");
    
    // Set X11 root window properties to announce that we support global menus
    // This is essential for applications to know they should export their menus
    Display *display = XOpenDisplay(NULL);
    if (!display) {
        NSLog(@"MenuController: Cannot open X11 display to announce global menu support");
        return;
    }
    
    Window root = DefaultRootWindow(display);
    
    // Set _NET_SUPPORTING_WM property to identify ourselves as the window manager
    // that supports global menus (even though we're not actually a WM)
    Atom supportingWmAtom = XInternAtom(display, "_NET_SUPPORTING_WM", False);
    Atom windowAtom = XInternAtom(display, "WINDOW", False);
    
    // Use our top bar window as the supporting window
    Window topBarWindow = 0;
    if (_topBar) {
        topBarWindow = (Window)[_topBar windowNumber];
    }
    
    if (topBarWindow) {
        XChangeProperty(display, root, supportingWmAtom, windowAtom, 32,
                       PropModeReplace, (unsigned char*)&topBarWindow, 1);
        
        NSLog(@"MenuController: Set _NET_SUPPORTING_WM property");
    }
    
    // Set _NET_SUPPORTED property to list supported features
    Atom netSupportedAtom = XInternAtom(display, "_NET_SUPPORTED", False);
    Atom atomAtom = XInternAtom(display, "ATOM", False);
    
    // List of atoms we support for global menu functionality
    Atom supportedAtoms[] = {
        XInternAtom(display, "_NET_WM_WINDOW_TYPE", False),
        XInternAtom(display, "_NET_WM_WINDOW_TYPE_NORMAL", False),
        XInternAtom(display, "_NET_ACTIVE_WINDOW", False),
        XInternAtom(display, "_KDE_NET_WM_APPMENU_SERVICE_NAME", False),
        XInternAtom(display, "_KDE_NET_WM_APPMENU_OBJECT_PATH", False),
        XInternAtom(display, "_GTK_MENUBAR_OBJECT_PATH", False),
        XInternAtom(display, "_GTK_APPLICATION_OBJECT_PATH", False),
        XInternAtom(display, "_GTK_WINDOW_OBJECT_PATH", False),
        XInternAtom(display, "_GTK_APP_MENU_OBJECT_PATH", False)
    };
    
    XChangeProperty(display, root, netSupportedAtom, atomAtom, 32,
                   PropModeReplace, (unsigned char*)supportedAtoms, 
                   sizeof(supportedAtoms) / sizeof(Atom));
    
    NSLog(@"MenuController: Set _NET_SUPPORTED property with %lu atoms", 
          sizeof(supportedAtoms) / sizeof(Atom));
    
    // Set Unity-specific properties that Chrome looks for
    Atom unityGlobalMenuAtom = XInternAtom(display, "_UNITY_SUPPORTED", False);
    XChangeProperty(display, root, unityGlobalMenuAtom, atomAtom, 32,
                   PropModeReplace, (unsigned char*)supportedAtoms, 1);
    
    NSLog(@"MenuController: Set _UNITY_SUPPORTED property");
    
    XSync(display, False);
    XCloseDisplay(display);
    
    NSLog(@"MenuController: Global menu support announcement complete");
}

- (void)scanForNewMenus
{
    NSLog(@"MenuController: Scanning for new menu services");
    
    if (_dbusMenuImporter) {
        [_dbusMenuImporter scanForExistingMenuServices];
        
        // Force an immediate update of the current window to check if it now has a menu
        if (_appMenuWidget) {
            [_appMenuWidget updateForActiveWindow];
        }
    }
}

- (AppMenuWidget *)appMenuWidget
{
    return _appMenuWidget;
}

- (void)x11ActiveWindowMonitor
{
    NSLog(@"MenuController: X11 _NET_ACTIVE_WINDOW monitor thread started");
    
    // Create an autorelease pool for this thread
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    while (!_shouldStopMonitoring) {
        XEvent event;
        
        // Process DBus messages continuously to import menus as soon as they arrive
        if (_dbusMenuImporter && [[_dbusMenuImporter valueForKey:@"_dbusConnection"] isConnected]) {
            [[_dbusMenuImporter valueForKey:@"_dbusConnection"] processMessages];
            
            // No need for continuous scanning - menus are displayed immediately when registered
        }
        
        // Use XCheckTypedWindowEvent with a timeout to avoid blocking forever
        if (XPending(_display) > 0) {
            XNextEvent(_display, &event);
            
            // Check if this is a PropertyNotify event for _NET_ACTIVE_WINDOW
            if (event.type == PropertyNotify && 
                event.xproperty.window == _rootWindow &&
                event.xproperty.atom == _netActiveWindowAtom) {
                
                NSLog(@"MenuController: _NET_ACTIVE_WINDOW property changed - active window changed");
                
                // Update the app menu widget for the new active window
                // No need to scan - if the window has a menu, it's already registered
                if (_appMenuWidget) {
                    [_appMenuWidget updateForActiveWindow];
                }
            }
        } else {
            // No events pending, sleep briefly to avoid busy waiting
            [NSThread sleepForTimeInterval:0.01];
        }
    }
    
    NSLog(@"MenuController: X11 monitor thread exiting");
    [pool release];
}

- (void)dealloc
{
    // Ensure shortcuts are cleaned up if dealloc is called
    NSLog(@"MenuController: dealloc - cleaning up global shortcuts...");
    [[X11ShortcutManager sharedManager] cleanup];
    
    [_topBar release];
    [_menuBarView release];
    [_appMenuWidget release];
    [_dbusMenuImporter release];
    [super dealloc];
}

@end
