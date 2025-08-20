#import "MenuController.h"
#import "MenuBarView.h"
#import "AppMenuWidget.h"
#import "MenuProtocolManager.h"
#import "DBusMenuImporter.h"
#import "GTKMenuImporter.h"
#import "RoundedCornersView.h"
#import "X11ShortcutManager.h"
#import "GNUstepGUI/GSTheme.h"
#import <X11/Xlib.h>
#import <X11/Xatom.h>
#import <sys/select.h>
#import <errno.h>

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
    
    [_menuBar orderFront:self];
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
    
    [[MenuProtocolManager sharedManager] cleanup];
    
    [_protocolManager release];
    _protocolManager = nil;
    
    [_roundedCornersView release];
    _roundedCornersView = nil;
}

- (void)createMenuBar
{
    NSLog(@"MenuController: ===== CREATING MENU BAR =====");
    const CGFloat menuBarHeight = [[GSTheme theme] menuBarHeight];
    NSLog(@"MenuController: Menu bar height: %.0f", menuBarHeight);
    
    NSRect rect;
    NSColor *color;
    NSFont *menuFont = [NSFont menuBarFontOfSize:0];
    NSMutableDictionary *attributes;
    
    attributes = [NSMutableDictionary new];
    [attributes setObject:menuFont forKey:NSFontAttributeName];
    
    _screenFrame = [[NSScreen mainScreen] frame];
    _screenSize = _screenFrame.size;
    NSLog(@"MenuController: Screen frame: %.0f,%.0f %.0fx%.0f", 
          _screenFrame.origin.x, _screenFrame.origin.y, _screenSize.width, _screenSize.height);
    
    color = [self backgroundColor];
    NSLog(@"MenuController: Background color: %@", color);
        
    // Creation of the menuBar at the TOP of the screen (GNUstep coordinates: bottom-left origin)
    rect = NSMakeRect(0, _screenSize.height - menuBarHeight, _screenSize.width, menuBarHeight);
    NSLog(@"MenuController: Menu bar rect: %.0f,%.0f %.0fx%.0f", 
          rect.origin.x, rect.origin.y, rect.size.width, rect.size.height);
    
    _menuBar = [[NSWindow alloc] initWithContentRect:rect
                                          styleMask:NSBorderlessWindowMask
                                            backing:NSBackingStoreBuffered
                                              defer:NO];
    NSLog(@"MenuController: Created NSWindow: %@", _menuBar);
    
    [_menuBar setTitle:@"MenuBar"];
    [_menuBar setBackgroundColor:color];
    [_menuBar setAlphaValue:1.0];
    [_menuBar setLevel:NSFloatingWindowLevel]; // Keep higher level
    [_menuBar setCanHide:NO];
    [_menuBar setHidesOnDeactivate:NO];
    [_menuBar setCollectionBehavior:NSWindowCollectionBehaviorCanJoinAllSpaces |
                                   NSWindowCollectionBehaviorStationary];
    
    NSLog(@"MenuController: Configured window properties");
    
    // Make the window visible immediately
    [_menuBar makeKeyAndOrderFront:self];
    [_menuBar orderFront:self];
    NSLog(@"MenuController: Ordered window front");
    
    // Create the main menu bar view that draws the background
    _menuBarView = [[MenuBarView alloc] initWithFrame:NSMakeRect(0, 0, _screenSize.width, menuBarHeight)];
    NSLog(@"MenuController: Created MenuBarView: %@", _menuBarView);
    
    // Create app menu widget for displaying menus
    _appMenuWidget = [[AppMenuWidget alloc] initWithFrame:NSMakeRect(20, 0, 400, menuBarHeight)];
    [_appMenuWidget setProtocolManager:[MenuProtocolManager sharedManager]];
    NSLog(@"MenuController: Created AppMenuWidget: %@", _appMenuWidget);
    
    // Create time/date menu bar
    [self createTimeMenu];
    
    // probono: Create rounded corners view for black top corners like in old/src/mainwindow.cpp
    // Position it at the top of the menu bar, with height enough for the corner radius effect
    CGFloat cornerHeight = 10.0; // 2 * corner radius (5px)
    _roundedCornersView = [[RoundedCornersView alloc] initWithFrame:NSMakeRect(0, menuBarHeight - cornerHeight, _screenSize.width, cornerHeight)];
    
    // Add subviews in the correct order (background first, then content, then corners on top)
    [[_menuBar contentView] addSubview:_menuBarView];
    [[_menuBar contentView] addSubview:_appMenuWidget];
    [[_menuBar contentView] addSubview:_timeMenuView];
    [[_menuBar contentView] addSubview:_roundedCornersView];
    
    [attributes release];
}

- (void)setupMenuBar
{
    NSLog(@"MenuController: Setting up menu bar using createMenuBar method");
    [self createMenuBar];
    
    NSLog(@"MenuController: Menu bar setup complete at %.0f,%.0f %.0fx%.0f", 
          _screenFrame.origin.x, _screenFrame.origin.y, _screenSize.width, [[GSTheme theme] menuBarHeight]);
    
    // Set up X11 window monitoring
    NSLog(@"MenuController: Setting up X11 window monitoring");
    [self setupWindowMonitoring];
    
    // Initialize protocol scanning
    NSLog(@"MenuController: Initializing protocol scanning");
    [self initializeProtocols];
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

- (void)initializeProtocols
{
    NSLog(@"MenuController: Initializing all menu protocols...");
    
    if (![[MenuProtocolManager sharedManager] initializeAllProtocols]) {
        NSLog(@"MenuController: Failed to initialize menu protocols - continuing anyway");
        _dbusFileDescriptor = -1;
    } else {
        NSLog(@"MenuController: Menu protocols initialized successfully");
        
        // Get the DBus file descriptor for X11 event loop integration
        _dbusFileDescriptor = [[MenuProtocolManager sharedManager] getDBusFileDescriptor];
        if (_dbusFileDescriptor >= 0) {
            NSLog(@"MenuController: Got DBus file descriptor %d for event loop integration", _dbusFileDescriptor);
        } else {
            NSLog(@"MenuController: Failed to get DBus file descriptor");
        }
    }
    
    // Set the app menu widget reference
    if (_appMenuWidget) {
        [[MenuProtocolManager sharedManager] setAppMenuWidget:_appMenuWidget];
        NSLog(@"MenuController: Set up connection between MenuProtocolManager and AppMenuWidget");
    }
}

- (void)createProtocolManager
{
    NSLog(@"MenuController: Creating MenuProtocolManager...");
    _protocolManager = [[MenuProtocolManager sharedManager] retain];
    
    // Register both Canonical and GTK protocol handlers
    DBusMenuImporter *canonicalHandler = [[DBusMenuImporter alloc] init];
    GTKMenuImporter *gtkHandler = [[GTKMenuImporter alloc] init];
    
    [_protocolManager registerProtocolHandler:canonicalHandler forType:MenuProtocolTypeCanonical];
    [_protocolManager registerProtocolHandler:gtkHandler forType:MenuProtocolTypeGTK];
    
    [canonicalHandler release];
    [gtkHandler release];
    
    NSLog(@"MenuController: Registered both Canonical and GTK protocol handlers");
}

- (void)setupWindowMonitoring
{
    // Prevent setting up monitoring multiple times
    if (_x11Thread && ![_x11Thread isFinished]) {
        NSLog(@"MenuController: X11 monitoring already set up, skipping");
        return;
    }
    
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
    Atom netClientListAtom = XInternAtom(_display, "_NET_CLIENT_LIST", False);
    
    // Select PropertyNotify events on the root window to detect both active window and client list changes
    XSelectInput(_display, _rootWindow, PropertyChangeMask);
    
    // Store the client list atom for monitoring
    _netClientListAtom = netClientListAtom;
    
    NSLog(@"MenuController: X11 display opened, monitoring _NET_ACTIVE_WINDOW and _NET_CLIENT_LIST property changes");
    
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
    
    // Use our menu bar window as the supporting window
    Window menuBarWindow = 0;
    if (_menuBar) {
        menuBarWindow = (Window)[_menuBar windowNumber];
    }
    
    if (menuBarWindow) {
        XChangeProperty(display, root, supportingWmAtom, windowAtom, 32,
                       PropModeReplace, (unsigned char*)&menuBarWindow, 1);
        
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
    
    [[MenuProtocolManager sharedManager] scanForExistingMenuServices];
    
    // Force an immediate update of the current window to check if it now has a menu
    if (_appMenuWidget) {
        [_appMenuWidget updateForActiveWindow];
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
    
    // Do initial scan once when thread starts
    [[MenuProtocolManager sharedManager] scanForExistingMenuServices];
    
    // Get X11 connection file descriptor
    int x11_fd = ConnectionNumber(_display);
    NSLog(@"MenuController: X11 file descriptor: %d, DBus file descriptor: %d", x11_fd, _dbusFileDescriptor);
    
    while (!_shouldStopMonitoring) {
        // Process X11 events - simpler approach from working commit
        if (XPending(_display) > 0) {
            XEvent event;
            XNextEvent(_display, &event);
            
            // Check if this is a PropertyNotify event for _NET_ACTIVE_WINDOW
            if (event.type == PropertyNotify && 
                event.xproperty.window == _rootWindow &&
                event.xproperty.atom == _netActiveWindowAtom) {
                
                NSLog(@"MenuController: _NET_ACTIVE_WINDOW property changed - active window changed");
                
                // Update the app menu widget for the new active window
                if (_appMenuWidget) {
                    [_appMenuWidget updateForActiveWindow];
                }
            }
            // Check if this is a PropertyNotify event for _NET_CLIENT_LIST (new windows)
            else if (event.type == PropertyNotify && 
                     event.xproperty.window == _rootWindow &&
                     event.xproperty.atom == _netClientListAtom) {
                
                NSLog(@"MenuController: _NET_CLIENT_LIST property changed - new window created/destroyed");
                
                // Scan for new GTK menu services when windows are created/destroyed
                [[MenuProtocolManager sharedManager] scanForExistingMenuServices];
            }
        } else {
            // No events pending, sleep briefly to avoid busy waiting
            [NSThread sleepForTimeInterval:0.01];
        }
        
        // Process DBus messages (non-blocking check)
        if (_dbusFileDescriptor >= 0) {
            id<MenuProtocolHandler> canonicalHandler = [[MenuProtocolManager sharedManager] handlerForType:MenuProtocolTypeCanonical];
            if (canonicalHandler && [canonicalHandler respondsToSelector:@selector(processDBusMessages)]) {
                [(id)canonicalHandler processDBusMessages];
            }
        }
    }
    
    NSLog(@"MenuController: X11 monitor thread exiting");
    [pool release];
}

- (void)createTimeMenu
{
    NSLog(@"MenuController: Creating time menu");
    
    // Create formatters
    _timeFormatter = [[NSDateFormatter alloc] init];
    [_timeFormatter setDateFormat:@"HH:mm"];
    _dateFormatter = [[NSDateFormatter alloc] init];
    [_dateFormatter setDateFormat:@"EEEE, MMMM d, yyyy"];

    // Create the menu and items
    _timeMenu = [[NSMenu alloc] initWithTitle:@""];
    [_timeMenu setAutoenablesItems:NO];
    _timeMenuItem = [[NSMenuItem alloc] initWithTitle:@"00:00" action:nil keyEquivalent:@""];
    /*
    NSMenu *timeSubMenu = [[NSMenu alloc] initWithTitle:@"TimeSubMenu"];
    _dateMenuItem = [[NSMenuItem alloc] initWithTitle:@"Loading..." action:nil keyEquivalent:@""];
    [_dateMenuItem setEnabled:NO];
    [timeSubMenu addItem:_dateMenuItem];
    [_timeMenuItem setSubmenu:timeSubMenu];
    [timeSubMenu release];
    */
    [_timeMenu addItem:_timeMenuItem];
    
    // Create the menu view at the right edge
    CGFloat timeMenuWidth = 60;
    CGFloat timeMenuX = _screenSize.width - timeMenuWidth;
    const CGFloat menuBarHeight = [[GSTheme theme] menuBarHeight];
    _timeMenuView = [[NSMenuView alloc] initWithFrame:NSMakeRect(timeMenuX, 0, timeMenuWidth, menuBarHeight)];
    [_timeMenuView setMenu:_timeMenu];
    [_timeMenuView setHorizontal:YES];
    [_timeMenuView setAutoresizingMask:NSViewMinXMargin | NSViewMaxYMargin | NSViewMinYMargin];

    // Start timer to update time
    _timeUpdateTimer = [[NSTimer scheduledTimerWithTimeInterval:1.0
                                                        target:self
                                                      selector:@selector(updateTimeMenu)
                                                      userInfo:nil
                                                       repeats:YES] retain];
    [self updateTimeMenu];
}

- (void)updateTimeMenu
{
    NSDate *now = [NSDate date];
    NSString *timeString = [_timeFormatter stringFromDate:now];
    [_timeMenuItem setTitle:timeString];
    NSString *dateString = [_dateFormatter stringFromDate:now];
    [_dateMenuItem setTitle:dateString];
}

- (void)dealloc
{
    // Ensure shortcuts are cleaned up if dealloc is called
    NSLog(@"MenuController: dealloc - cleaning up global shortcuts...");
    [[X11ShortcutManager sharedManager] cleanup];
    
    // Clean up time display resources
    if (_timeUpdateTimer) {
        [_timeUpdateTimer invalidate];
        [_timeUpdateTimer release];
        _timeUpdateTimer = nil;
    }
    [_timeFormatter release];
    [_dateFormatter release];
    [_timeMenuView release];
    [_timeMenu release];
    [_timeMenuItem release];
    [_dateMenuItem release];
    
    [_menuBar release];
    [_menuBarView release];
    [_appMenuWidget release];
    [_protocolManager release];
    [super dealloc];
}

@end
