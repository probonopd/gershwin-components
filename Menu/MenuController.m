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
#import <X11/Xutil.h>
#import <sys/select.h>
#import <errno.h>

@implementation MenuController

// DBus file descriptor monitoring using NSFileHandle
- (void)dbusFileDescriptorReady:(NSNotification *)notification {
    NSLog(@"MenuController: DBus file descriptor ready for reading");
    [[MenuProtocolManager sharedManager] processDBusMessages];
}

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

- (void)createPersistentStrutWindow
{
    NSLog(@"MenuController: Creating persistent X11 strut window...");
    
    const CGFloat menuBarHeight = [[GSTheme theme] menuBarHeight];
    
    // Open X11 display connection that will persist for the application lifetime
    self.strutDisplay = XOpenDisplay(NULL);
    if (!self.strutDisplay) {
        NSLog(@"MenuController: Cannot open X11 display for strut window");
        return;
    }
    
    int screen = DefaultScreen(self.strutDisplay);
    Window root = RootWindow(self.strutDisplay, screen);
    unsigned int width = (unsigned int)self.screenSize.width;
    unsigned int height = (unsigned int)menuBarHeight;
    
    // Create invisible strut window that reserves space but doesn't interfere with our menu
    XSetWindowAttributes attrs;
    attrs.override_redirect = False;
    attrs.background_pixel = BlackPixel(self.strutDisplay, screen);
    attrs.border_pixel = BlackPixel(self.strutDisplay, screen);
    
    // Create a 1x1 pixel window at the top-left corner to avoid visual interference
    self.strutWindow = XCreateWindow(self.strutDisplay, root, 0, 0, 1, 1, 0, 
                                   CopyFromParent, InputOutput, CopyFromParent, 
                                   CWOverrideRedirect | CWBackPixel | CWBorderPixel, &attrs);
    
    if (self.strutWindow == None) {
        NSLog(@"MenuController: Failed to create X11 strut window");
        XCloseDisplay(self.strutDisplay);
        self.strutDisplay = NULL;
        return;
    }
    
    // Set window type to dock
    Atom windowTypeAtom = XInternAtom(self.strutDisplay, "_NET_WM_WINDOW_TYPE", False);
    Atom dockAtom = XInternAtom(self.strutDisplay, "_NET_WM_WINDOW_TYPE_DOCK", False);
    XChangeProperty(self.strutDisplay, self.strutWindow, windowTypeAtom, XA_ATOM, 32, 
                   PropModeReplace, (unsigned char *)&dockAtom, 1);
    
    // Set WM_CLASS to "StrutPanel" to distinguish from our actual menu
    XClassHint classHint;
    classHint.res_name = "StrutPanel";
    classHint.res_class = "StrutPanel";
    XSetClassHint(self.strutDisplay, self.strutWindow, &classHint);
    
    // Set WM_NAME to "MenuBarStrut"
    XStoreName(self.strutDisplay, self.strutWindow, "MenuBarStrut");
    
    // Set struts - this reserves the space for the full menu bar height
    Atom strutAtom = XInternAtom(self.strutDisplay, "_NET_WM_STRUT", False);
    Atom strutPartialAtom = XInternAtom(self.strutDisplay, "_NET_WM_STRUT_PARTIAL", False);
    unsigned long strut[4] = {0, 0, height, 0}; // left, right, top, bottom
    unsigned long strutPartial[12] = {0, 0, height, 0, 0, 0, 0, 0, 0, width - 1, 0, width - 1};
    
    XChangeProperty(self.strutDisplay, self.strutWindow, strutAtom, XA_CARDINAL, 32, 
                   PropModeReplace, (unsigned char *)strut, 4);
    XChangeProperty(self.strutDisplay, self.strutWindow, strutPartialAtom, XA_CARDINAL, 32, 
                   PropModeReplace, (unsigned char *)strutPartial, 12);
    
    // Set window state to sticky but NOT above (we want our menu to be above it)
    Atom stateAtom = XInternAtom(self.strutDisplay, "_NET_WM_STATE", False);
    Atom stickyAtom = XInternAtom(self.strutDisplay, "_NET_WM_STATE_STICKY", False);
    XChangeProperty(self.strutDisplay, self.strutWindow, stateAtom, XA_ATOM, 32, 
                   PropModeReplace, (unsigned char *)&stickyAtom, 1);
    
    // Map the window to make the struts active
    XMapWindow(self.strutDisplay, self.strutWindow);
    XSync(self.strutDisplay, False);
    
    NSLog(@"MenuController: Created persistent X11 strut window (XID: %lu) - invisible 1x1 window with full-width struts", 
          (unsigned long)self.strutWindow);
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
    NSLog(@"MenuController: Application did finish launching");
    
    [self.menuBar orderFront:self];
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
    self.shouldStopMonitoring = YES;
    
    // Wait for the thread to finish (with timeout to avoid hanging)
    if (self.x11Thread && ![self.x11Thread isFinished]) {
        // Give the thread a chance to exit gracefully
        [NSThread sleepForTimeInterval:0.1];
        
        if (![self.x11Thread isFinished]) {
            NSLog(@"MenuController: X11 thread did not exit gracefully");
        }
    }
    
    self.x11Thread = nil;
    
    // Clean up persistent strut window
    if (self.strutWindow != None && self.strutDisplay) {
        XDestroyWindow(self.strutDisplay, self.strutWindow);
        self.strutWindow = None;
    }
    
    // Close strut X11 display
    if (self.strutDisplay) {
        XCloseDisplay(self.strutDisplay);
        self.strutDisplay = NULL;
    }
    
    // Close X11 display
    if (self.display) {
        XCloseDisplay(self.display);
        self.display = NULL;
    }
    
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    
    [[MenuProtocolManager sharedManager] cleanup];
    
    self.protocolManager = nil;
    
    self.roundedCornersView = nil;
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
    
    self.screenFrame = [[NSScreen mainScreen] frame];
    self.screenSize = self.screenFrame.size;
    NSLog(@"MenuController: Screen frame: %.0f,%.0f %.0fx%.0f", 
          self.screenFrame.origin.x, self.screenFrame.origin.y, self.screenSize.width, self.screenSize.height);
    
    color = [self backgroundColor];
    NSLog(@"MenuController: Background color: %@", color);
        
    // Creation of the menuBar at the TOP of the screen (GNUstep coordinates: bottom-left origin)
    rect = NSMakeRect(0, self.screenSize.height - menuBarHeight, self.screenSize.width, menuBarHeight);
    NSLog(@"MenuController: Menu bar rect: %.0f,%.0f %.0fx%.0f", 
          rect.origin.x, rect.origin.y, rect.size.width, rect.size.height);
    
    self.menuBar = [[NSWindow alloc] initWithContentRect:rect
                                          styleMask:NSBorderlessWindowMask
                                            backing:NSBackingStoreBuffered
                                              defer:NO];
    NSLog(@"MenuController: Created NSWindow: %@", self.menuBar);
    
    [self.menuBar setTitle:@"MenuBar"];
    [self.menuBar setBackgroundColor:color];
    [self.menuBar setAlphaValue:1.0];
    [self.menuBar setLevel:NSMainMenuWindowLevel + 1]; // Higher than main menu, but not floating
    [self.menuBar setCanHide:NO];
    [self.menuBar setHidesOnDeactivate:NO];
    [self.menuBar setCollectionBehavior:NSWindowCollectionBehaviorCanJoinAllSpaces |
                                   NSWindowCollectionBehaviorStationary];
    
    NSLog(@"MenuController: Configured window properties");
    
    // Create and maintain a persistent X11 window for struts
    [self createPersistentStrutWindow];

    // Now map the window - position it at the very top of the screen
    [self.menuBar setFrameTopLeftPoint:NSMakePoint(0, self.screenSize.height)];
    [self.menuBar makeKeyAndOrderFront:self];
    [self.menuBar orderFront:self];
    NSLog(@"MenuController: Ordered window front at top of screen");
    
    // Create the main menu bar view that draws the background
    self.menuBarView = [[MenuBarView alloc] initWithFrame:NSMakeRect(0, 0, self.screenSize.width, menuBarHeight)];
    NSLog(@"MenuController: Created MenuBarView: %@", self.menuBarView);
    
    // Create app menu widget for displaying menus - use larger width to accommodate more menu items
    CGFloat menuWidgetWidth = self.screenSize.width - 140; // Leave space for time menu and margins
    self.appMenuWidget = [[AppMenuWidget alloc] initWithFrame:NSMakeRect(20, 0, menuWidgetWidth, menuBarHeight)];
    NSLog(@"MenuController: AppMenuWidget created successfully");
    
    NSLog(@"MenuController: Setting up protocol manager connection");
    // Set up the AppMenuWidget with the protocol manager
    [self.appMenuWidget setProtocolManager:[MenuProtocolManager sharedManager]];
    NSLog(@"MenuController: Protocol manager connected to AppMenuWidget");
    
    // Update all protocol handlers with the AppMenuWidget reference
    [[MenuProtocolManager sharedManager] updateAllHandlersWithAppMenuWidget:self.appMenuWidget];
    NSLog(@"MenuController: All protocol handlers notified of AppMenuWidget");
    
    NSLog(@"MenuController: Checking appMenuWidget before NSLog...");
    if (self.appMenuWidget) {
        NSLog(@"MenuController: appMenuWidget is valid");
    } else {
        NSLog(@"MenuController: appMenuWidget is nil!");
    }
    
    // NSLog(@"MenuController: Created AppMenuWidget with width %.0f at address %p", menuWidgetWidth, self.appMenuWidget);
    NSLog(@"MenuController: Skipping potentially problematic NSLog");
    
    // Create time/date menu bar
    NSLog(@"MenuController: About to create time menu");
    [self createTimeMenu];
    NSLog(@"MenuController: Time menu created");
    
    // probono: Create rounded corners view for black top corners like in old/src/mainwindow.cpp
    // Position it at the top of the menu bar, with height enough for the corner radius effect
    CGFloat cornerHeight = 10.0; // 2 * corner radius (5px)
    self.roundedCornersView = [[RoundedCornersView alloc] initWithFrame:NSMakeRect(0, menuBarHeight - cornerHeight, self.screenSize.width, cornerHeight)];
    
    // Add subviews in the correct order (background first, then content, then corners on top)
    [[self.menuBar contentView] addSubview:self.menuBarView];
    [[self.menuBar contentView] addSubview:self.appMenuWidget];
    [[self.menuBar contentView] addSubview:self.timeMenuView];
    [[self.menuBar contentView] addSubview:self.roundedCornersView];
}

- (void)setupMenuBar
{
    NSLog(@"MenuController: Setting up menu bar using createMenuBar method");
    [self createMenuBar];
    NSLog(@"MenuController: Menu bar setup complete at %.0f,%.0f %.0fx%.0f", self.screenFrame.origin.x, self.screenFrame.origin.y, self.screenSize.width, [[GSTheme theme] menuBarHeight]);
    NSLog(@"MenuController: Setting up X11 window monitoring");
    [self setupWindowMonitoring];
    NSLog(@"MenuController: Initializing protocol scanning");
    [self initializeProtocols];
}

- (void)updateActiveWindow
{
    // Get the currently active window and update app menu
    if (self.appMenuWidget) {
        [self.appMenuWidget updateForActiveWindow];
    } else {
        NSLog(@"MenuController: self.appMenuWidget is nil");
    }
}

- (void)initializeProtocols
{
    NSLog(@"MenuController: Initializing all menu protocols...");
    
    NSLog(@"MenuController: About to call initializeAllProtocols...");
    if (![[MenuProtocolManager sharedManager] initializeAllProtocols]) {
        NSLog(@"MenuController: Failed to initialize menu protocols - continuing anyway");
        self.dbusFileDescriptor = -1;
    } else {
        NSLog(@"MenuController: Menu protocols initialized successfully");
        
        // Get the DBus file descriptor for X11 event loop integration
        self.dbusFileDescriptor = [[MenuProtocolManager sharedManager] getDBusFileDescriptor];
        if (self.dbusFileDescriptor >= 0) {
            NSLog(@"MenuController: Got DBus file descriptor %d for event loop integration", self.dbusFileDescriptor);
            
            // Create NSFileHandle for DBus file descriptor monitoring
            NSFileHandle *dbusFileHandle = [[NSFileHandle alloc] initWithFileDescriptor:self.dbusFileDescriptor];
            if (dbusFileHandle) {
                [[NSNotificationCenter defaultCenter] addObserver:self
                                                         selector:@selector(dbusFileDescriptorReady:)
                                                             name:NSFileHandleReadCompletionNotification
                                                           object:dbusFileHandle];
                [dbusFileHandle readInBackgroundAndNotify];
                NSLog(@"MenuController: DBus file descriptor integrated into notification system");
            } else {
                NSLog(@"MenuController: Failed to create NSFileHandle for DBus file descriptor");
            }
    
    // Add a small delay to ensure everything is properly settled
    [NSThread sleepForTimeInterval:0.05];
    
    NSLog(@"MenuController: Event loop integration setup complete");
        } else {
            NSLog(@"MenuController: Failed to get DBus file descriptor");
        }
    }
    
    // Set the app menu widget reference
    if (self.appMenuWidget) {
        [[MenuProtocolManager sharedManager] setAppMenuWidget:self.appMenuWidget];
        NSLog(@"MenuController: Set up connection between MenuProtocolManager and AppMenuWidget");
    }
}

- (void)createProtocolManager
{
    NSLog(@"MenuController: Creating MenuProtocolManager...");
    self.protocolManager = [MenuProtocolManager sharedManager];
    
    // Register both Canonical and GTK protocol handlers
    DBusMenuImporter *canonicalHandler = [[DBusMenuImporter alloc] init];
    GTKMenuImporter *gtkHandler = [[GTKMenuImporter alloc] init];
    
    [self.protocolManager registerProtocolHandler:canonicalHandler forType:MenuProtocolTypeCanonical];
    [self.protocolManager registerProtocolHandler:gtkHandler forType:MenuProtocolTypeGTK];
    
    NSLog(@"MenuController: Registered both Canonical and GTK protocol handlers");
    NSLog(@"MenuController: createProtocolManager COMPLETED");
}

- (void)setupWindowMonitoring
{
    // Prevent setting up monitoring multiple times
    if (self.x11Thread && ![self.x11Thread isFinished]) {
        NSLog(@"MenuController: X11 monitoring already set up, skipping");
        return;
    }
    
    NSLog(@"MenuController: Setting up X11 _NET_ACTIVE_WINDOW monitoring");
    
    // Initialize monitoring flag
    self.shouldStopMonitoring = NO;
    
    // Open X11 display connection
    self.display = XOpenDisplay(NULL);
    if (!self.display) {
        NSLog(@"MenuController: Cannot open X11 display for window monitoring");
        return;
    }
    
    self.rootWindow = DefaultRootWindow(self.display);
    self.netActiveWindowAtom = XInternAtom(self.display, "_NET_ACTIVE_WINDOW", False);
    Atom netClientListAtom = XInternAtom(self.display, "_NET_CLIENT_LIST", False);
    
    // Select PropertyNotify events on the root window to detect both active window and client list changes
    XSelectInput(self.display, self.rootWindow, PropertyChangeMask);
    
    // Store the client list atom for monitoring
    self.netClientListAtom = netClientListAtom;
    
    NSLog(@"MenuController: X11 display opened, monitoring _NET_ACTIVE_WINDOW and _NET_CLIENT_LIST property changes");
    
    // Start X11 event loop in a separate NSThread
    self.x11Thread = [[NSThread alloc] initWithTarget:self
                                         selector:@selector(x11ActiveWindowMonitor)
                                           object:nil];
    [self.x11Thread setName:@"X11ActiveWindowMonitor"];
    [self.x11Thread start];
    
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
    if (self.menuBar) {
        menuBarWindow = (Window)[self.menuBar windowNumber];
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
    if (self.appMenuWidget) {
        [self.appMenuWidget updateForActiveWindow];
    }
}

- (void)x11ActiveWindowMonitor
{
    NSLog(@"MenuController: X11 _NET_ACTIVE_WINDOW monitor thread started");
    
    @autoreleasepool {
        // Do initial scan once when thread starts
        [[MenuProtocolManager sharedManager] scanForExistingMenuServices];
        
        // Get X11 connection file descriptor
        int x11_fd = ConnectionNumber(self.display);
        NSLog(@"MenuController: X11 file descriptor: %d, DBus file descriptor: %d", x11_fd, self.dbusFileDescriptor);
        
        while (!self.shouldStopMonitoring) {
            // Process X11 events - simpler approach from working commit
            if (XPending(self.display) > 0) {
                XEvent event;
                XNextEvent(self.display, &event);
                
                // Check if this is a PropertyNotify event for _NET_ACTIVE_WINDOW
                if (event.type == PropertyNotify && 
                    event.xproperty.window == self.rootWindow &&
                    event.xproperty.atom == self.netActiveWindowAtom) {
                    
                    NSLog(@"MenuController: _NET_ACTIVE_WINDOW property changed - active window changed");
                    
                    // Update the app menu widget for the new active window - MUST be on main thread
                    // Copy the widget reference for thread-safe access
                    AppMenuWidget *widget = self.appMenuWidget;
                    if (widget) {
                        [widget performSelectorOnMainThread:@selector(updateForActiveWindow)
                                                 withObject:nil
                                              waitUntilDone:NO];
                    }
                }
                // Check if this is a PropertyNotify event for _NET_CLIENT_LIST (new windows)
                else if (event.type == PropertyNotify && 
                         event.xproperty.window == self.rootWindow &&
                         event.xproperty.atom == self.netClientListAtom) {
                    
                    NSLog(@"MenuController: _NET_CLIENT_LIST property changed - new window created/destroyed");
                    
                    // Scan for new menu services - dispatch to main thread to avoid threading issues
                    [[MenuProtocolManager sharedManager] performSelectorOnMainThread:@selector(scanForExistingMenuServices)
                                                                          withObject:nil
                                                                       waitUntilDone:NO];
                }
            } else {
                // No events pending, sleep briefly to avoid busy waiting
                [NSThread sleepForTimeInterval:0.01];
            }
            
            // Process DBus messages (non-blocking check) - must be on main thread for safety
            if (self.dbusFileDescriptor >= 0) {
                id<MenuProtocolHandler> canonicalHandler = [[MenuProtocolManager sharedManager] handlerForType:MenuProtocolTypeCanonical];
                if (canonicalHandler && [canonicalHandler respondsToSelector:@selector(processDBusMessages)]) {
                    [(id)canonicalHandler performSelectorOnMainThread:@selector(processDBusMessages)
                                                           withObject:nil
                                                        waitUntilDone:NO];
                }
            }
        }
    }
    
    NSLog(@"MenuController: X11 monitor thread exiting");
}

- (void)createTimeMenu
{
    NSLog(@"MenuController: createTimeMenu - ENTRY");
    
    NSLog(@"MenuController: Creating time menu");
    
    NSLog(@"MenuController: Creating time formatters...");
    // Create formatters
    self.timeFormatter = [[NSDateFormatter alloc] init];
    NSLog(@"MenuController: Created timeFormatter");
    [self.timeFormatter setDateFormat:@"HH:mm"];
    NSLog(@"MenuController: Set time format");
    self.dateFormatter = [[NSDateFormatter alloc] init];
    NSLog(@"MenuController: Created dateFormatter");
    [self.dateFormatter setDateFormat:@"EEEE, MMMM d, yyyy"];
    NSLog(@"MenuController: Set date format");

    NSLog(@"MenuController: Creating menu and items...");
    // Create the menu and items
    self.timeMenu = [[NSMenu alloc] initWithTitle:@""];
    NSLog(@"MenuController: Created timeMenu");
    [self.timeMenu setAutoenablesItems:NO];
    NSLog(@"MenuController: Set autoenablesItems");
    self.timeMenuItem = [[NSMenuItem alloc] initWithTitle:@"00:00" action:nil keyEquivalent:@""];
    NSLog(@"MenuController: Created timeMenuItem");
    /*
    NSMenu *timeSubMenu = [[NSMenu alloc] initWithTitle:@"TimeSubMenu"];
    self.dateMenuItem = [[NSMenuItem alloc] initWithTitle:@"Loading..." action:nil keyEquivalent:@""];
    [self.dateMenuItem setEnabled:NO];
    [timeSubMenu addItem:self.dateMenuItem];
    [self.timeMenuItem setSubmenu:timeSubMenu];
    */
    [self.timeMenu addItem:self.timeMenuItem];
    
    // Create the menu view at the right edge
    CGFloat timeMenuWidth = 60;
    CGFloat timeMenuX = self.screenSize.width - timeMenuWidth;
    const CGFloat menuBarHeight = [[GSTheme theme] menuBarHeight];
    self.timeMenuView = [[NSMenuView alloc] initWithFrame:NSMakeRect(timeMenuX, 0, timeMenuWidth, menuBarHeight)];
    [self.timeMenuView setMenu:self.timeMenu];
    [self.timeMenuView setHorizontal:YES];
    [self.timeMenuView setAutoresizingMask:NSViewMinXMargin | NSViewMaxYMargin | NSViewMinYMargin];

    NSLog(@"MenuController: About to schedule time update timer");
    // Start timer to update time
    self.timeUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                        target:self
                                                      selector:@selector(updateTimeMenu)
                                                      userInfo:nil
                                                       repeats:YES];
    NSLog(@"MenuController: Timer scheduled successfully");
    [self updateTimeMenu];
    NSLog(@"MenuController: Initial time update called");
}

- (void)updateTimeMenu
{
    NSDate *now = [NSDate date];
    NSString *timeString = [self.timeFormatter stringFromDate:now];
    [self.timeMenuItem setTitle:timeString];
    NSString *dateString = [self.dateFormatter stringFromDate:now];
    [self.dateMenuItem setTitle:dateString];
}

@end
