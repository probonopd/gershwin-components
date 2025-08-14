#import "MenuController.h"
#import "MenuBarView.h"
#import "AppMenuWidget.h"
#import "DBusMenuImporter.h"
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

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
    NSLog(@"MenuController: Application did finish launching");
    
    // Application setup is already done in main(), just set up timers and notifications
    
    [self setupWindowMonitoring];
    
    NSLog(@"MenuController: Application setup complete");
}

- (void)processDBusMessages:(NSTimer *)timer
{
    // Process incoming DBus messages
    if (_dbusMenuImporter && [[_dbusMenuImporter valueForKey:@"_dbusConnection"] isConnected]) {
        [[_dbusMenuImporter valueForKey:@"_dbusConnection"] processMessages];
    }
}

- (void)applicationWillTerminate:(NSNotification *)notification
{
    NSLog(@"MenuController: Application will terminate");
    
    [_updateTimer invalidate];
    [_updateTimer release];
    _updateTimer = nil;
    
    [_menuScanTimer invalidate];
    [_menuScanTimer release];
    _menuScanTimer = nil;
    
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    
    [_dbusMenuImporter release];
    _dbusMenuImporter = nil;
}

- (void)setupMenuBar
{
    NSScreen *screen = [NSScreen mainScreen];
    NSRect screenRect = [screen frame];
    
    // Create menu bar window at top of screen
    NSRect menuRect = NSMakeRect(0, screenRect.size.height - 24, screenRect.size.width, 24);
    
    _menuWindow = [[NSWindow alloc] initWithContentRect:menuRect
                                              styleMask:NSBorderlessWindowMask
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    
    [_menuWindow setLevel:NSMainMenuWindowLevel + 1];
    [_menuWindow setOpaque:NO];
    [_menuWindow setHasShadow:NO];
    [_menuWindow setCanHide:NO];
    [_menuWindow setCollectionBehavior:NSWindowCollectionBehaviorCanJoinAllSpaces |
                                       NSWindowCollectionBehaviorStationary];
    
    // Create menu bar view
    _menuBarView = [[MenuBarView alloc] initWithFrame:NSMakeRect(0, 0, menuRect.size.width, 24)];
    [_menuWindow setContentView:_menuBarView];
    
    // Create app menu widget
    _appMenuWidget = [[AppMenuWidget alloc] initWithFrame:NSMakeRect(20, 0, 400, 24)];
    [_appMenuWidget setDbusMenuImporter:_dbusMenuImporter];
    [_menuBarView addSubview:_appMenuWidget];
    
    [_menuWindow makeKeyAndOrderFront:nil];
    
    NSLog(@"MenuController: Menu bar setup complete at %.0f,%.0f %.0fx%.0f", 
          menuRect.origin.x, menuRect.origin.y, menuRect.size.width, menuRect.size.height);
}

- (void)updateActiveWindow:(NSTimer *)timer
{
    // Get the currently active window and update app menu
    if (_appMenuWidget) {
        [_appMenuWidget updateForActiveWindow];
    } else {
        NSLog(@"MenuController: _appMenuWidget is nil");
    }
}

- (void)windowDidBecomeKey:(NSNotification *)notification
{
    NSLog(@"MenuController: Window did become key: %@", [[notification object] title]);
    [self updateActiveWindow:nil];
}

- (void)initializeDBusConnection
{
    NSLog(@"MenuController: Attempting to connect to DBus...");
    if (![_dbusMenuImporter connectToDBus]) {
        NSLog(@"MenuController: Failed to connect to DBus - continuing anyway");
    } else {
        NSLog(@"MenuController: DBus menu importer initialized successfully");
        
        // Set up timer to process DBus messages
        [NSTimer scheduledTimerWithTimeInterval:0.1
                                        target:self
                                      selector:@selector(processDBusMessages:)
                                      userInfo:nil
                                       repeats:YES];
    }
}

- (void)createDBusImporter
{
    NSLog(@"MenuController: Creating DBusMenuImporter...");
    _dbusMenuImporter = [[DBusMenuImporter alloc] init];
}

- (void)setupWindowMonitoring
{
    NSLog(@"MenuController: Setting up window monitoring with aggressive menu scanning");
    
    // Set up timer to monitor active window changes - start with faster polling
    _updateTimer = [NSTimer scheduledTimerWithTimeInterval:0.1
                                                    target:self
                                                  selector:@selector(updateActiveWindow:)
                                                  userInfo:nil
                                                   repeats:YES];
    
    // Add the timer to the current run loop in multiple modes to ensure it fires
    [[NSRunLoop currentRunLoop] addTimer:_updateTimer forMode:NSDefaultRunLoopMode];
    [[NSRunLoop currentRunLoop] addTimer:_updateTimer forMode:NSRunLoopCommonModes];
    
    // Set up aggressive menu scanning timer - scan for new menus frequently
    // for the first few minutes, then reduce frequency
    _menuScanTimer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                      target:self
                                                    selector:@selector(scanForNewMenus:)
                                                    userInfo:nil
                                                     repeats:YES];
    
    [[NSRunLoop currentRunLoop] addTimer:_menuScanTimer forMode:NSDefaultRunLoopMode];
    [[NSRunLoop currentRunLoop] addTimer:_menuScanTimer forMode:NSRunLoopCommonModes];
    
    NSLog(@"MenuController: Timer created: %@", _updateTimer);
    NSLog(@"MenuController: Menu scan timer created: %@", _menuScanTimer);
    
    // Test the timer by calling updateActiveWindow immediately
    NSLog(@"MenuController: Testing timer by calling updateActiveWindow immediately");
    [self updateActiveWindow:nil];
    
    // Listen for window focus changes
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(windowDidBecomeKey:)
                                                 name:NSWindowDidBecomeKeyNotification
                                               object:nil];
    
    // Reduce menu scanning frequency after 2 minutes
    [NSTimer scheduledTimerWithTimeInterval:120.0
                                     target:self
                                   selector:@selector(reduceMenuScanFrequency:)
                                   userInfo:nil
                                    repeats:NO];
    
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
    
    // Use our menu window as the supporting window
    Window menuWindow = 0;
    if (_menuWindow) {
        menuWindow = (Window)[_menuWindow windowNumber];
    }
    
    if (menuWindow) {
        XChangeProperty(display, root, supportingWmAtom, windowAtom, 32,
                       PropModeReplace, (unsigned char*)&menuWindow, 1);
        
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

- (void)scanForNewMenus:(NSTimer *)timer
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

- (void)reduceMenuScanFrequency:(NSTimer *)timer
{
    NSLog(@"MenuController: Reducing menu scan frequency after initial startup period");
    
    if (_menuScanTimer) {
        [_menuScanTimer invalidate];
        [_menuScanTimer release];
        
        // Create a new timer with reduced frequency (every 5 seconds instead of 0.5)
        _menuScanTimer = [NSTimer scheduledTimerWithTimeInterval:5.0
                                                          target:self
                                                        selector:@selector(scanForNewMenus:)
                                                        userInfo:nil
                                                         repeats:YES];
        
        [[NSRunLoop currentRunLoop] addTimer:_menuScanTimer forMode:NSDefaultRunLoopMode];
        [[NSRunLoop currentRunLoop] addTimer:_menuScanTimer forMode:NSRunLoopCommonModes];
        
        NSLog(@"MenuController: Menu scan frequency reduced to 5 second intervals");
    }
}

- (void)dealloc
{
    [_menuWindow release];
    [_menuBarView release];
    [_appMenuWidget release];
    [_dbusMenuImporter release];
    [super dealloc];
}

@end
