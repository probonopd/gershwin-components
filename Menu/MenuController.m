/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */


#import "MenuController.h"
#import "MenuBarView.h"
#import "AppMenuWidget.h"
#import "MenuProtocolManager.h"
#import "GNUStepMenuImporter.h"
#import "RoundedCornersView.h"
#import "X11ShortcutManager.h"
#import "ActionSearch.h"
#import "MenuUtils.h"
#import "StatusItemManager.h"
#import "StatusItemsView.h"
#import "StatusItemView.h"
#import "WindowMonitor.h"
/* AppMenuImporter and the DBus / GTK menu importers were deleted in the
 * macOS-model menu refactor. Only GNUStepMenuImporter remains; it is the
 * receive-side of pkgwrap's runtime menu-stub sidecar (and any future
 * GNUstep client). */
#import "GNUstepGUI/GSTheme.h"
#import <X11/Xlib.h>
#import <X11/Xatom.h>
#import <GNUstepGUI/GSDisplayServer.h>
#import <X11/Xatom.h>
#import <X11/Xutil.h>
#import <sys/select.h>
#import <errno.h>
#import <dispatch/dispatch.h>

@interface TimeMenuView : NSMenuView
@end

@implementation TimeMenuView

- (void)drawRect:(NSRect)dirtyRect
{
    // Clear with transparent background to let the MenuBarView background show through
    [[NSColor clearColor] set];
    NSRectFill(dirtyRect);
    
    // Draw menu items with transparent background
    [super drawRect:dirtyRect];
}

- (BOOL)isOpaque
{
    return NO;
}

@end

@implementation MenuController

// DBus file descriptor monitoring using NSFileHandle
// Minimum interval (seconds) between consecutive DBus fd notifications to prevent CPU spin
static NSTimeInterval _lastDbusNotificationTime = 0;
static NSUInteger _rapidDbusNotificationCount = 0;
#define DBUS_MIN_NOTIFICATION_INTERVAL 0.005   // 5ms minimum gap
#define DBUS_RAPID_FIRE_THRESHOLD 100          // number of rapid fires before back-off
#define DBUS_BACKOFF_INTERVAL 0.1              // 100ms cooldown after rapid fire

- (void)dbusFileDescriptorReady:(NSNotification *)notification {
    // Always handle DBus traffic on the main thread to avoid races with UI work
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self dbusFileDescriptorReady:notification];
        });
        return;
    }

    // TIGHT-LOOP GUARD: Throttle rapid fd-ready notifications
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    NSTimeInterval elapsed = now - _lastDbusNotificationTime;
    if (elapsed < DBUS_MIN_NOTIFICATION_INTERVAL) {
        _rapidDbusNotificationCount++;
        if (_rapidDbusNotificationCount > DBUS_RAPID_FIRE_THRESHOLD) {
            // Too many rapid fires - back off with a delayed re-arm instead of immediate
            NSDebugLLog(@"gwcomp", @"MenuController: DBus fd rapid-fire detected (%lu in %.3fs) - backing off %.0fms",
                  (unsigned long)_rapidDbusNotificationCount, elapsed, DBUS_BACKOFF_INTERVAL * 1000);
            _rapidDbusNotificationCount = 0;
            if (self.dbusFileHandle) {
                [NSTimer scheduledTimerWithTimeInterval:DBUS_BACKOFF_INTERVAL
                                                target:self
                                              selector:@selector(rearmDbusFileHandle:)
                                              userInfo:nil
                                               repeats:NO];
            }
            return;
        }
    } else {
        _rapidDbusNotificationCount = 0;
    }
    _lastDbusNotificationTime = now;

    NSDebugLog(@"MenuController: DBus file descriptor reported data available");
    
    // Lock the menu window from redrawing during DBus processing to prevent flashing
    [self.menuBar disableFlushWindow];
    
    @try {
        [[MenuProtocolManager sharedManager] processDBusMessages];
    }
    @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"MenuController: Exception processing DBus messages: %@", exception);
    }
    @finally {
        // Re-enable window drawing and flush all pending updates at once
        [self.menuBar enableFlushWindow];
        [self.menuBar flushWindow];
    }

    // Re-arm the watcher so we continue receiving notifications
    // Only re-arm if the file handle is still valid
    if (self.dbusFileHandle) {
        @try {
            [self.dbusFileHandle waitForDataInBackgroundAndNotify];
        }
        @catch (NSException *exception) {
            NSDebugLLog(@"gwcomp", @"MenuController: Exception re-arming DBus file handle: %@", exception);
            self.dbusFileHandle = nil;
        }
    }
}

- (void)rearmDbusFileHandle:(NSTimer *)timer
{
    (void)timer;
    if (self.dbusFileHandle) {
        // Process any accumulated messages first
        @try {
            [[MenuProtocolManager sharedManager] processDBusMessages];
        }
        @catch (NSException *exception) {
            NSDebugLLog(@"gwcomp", @"MenuController: Exception processing DBus messages during re-arm: %@", exception);
        }
        // Now re-arm
        @try {
            [self.dbusFileHandle waitForDataInBackgroundAndNotify];
        }
        @catch (NSException *exception) {
            NSDebugLLog(@"gwcomp", @"MenuController: Exception re-arming DBus file handle after backoff: %@", exception);
            self.dbusFileHandle = nil;
        }
    }
}

- (void)pollDBusMessages:(NSTimer *)timer
{
    // Always handle DBus traffic on the main thread
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self pollDBusMessages:timer];
        });
        return;
    }
    
    // Process any pending D-Bus messages
    @try {
        [[MenuProtocolManager sharedManager] processDBusMessages];
    }
    @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"MenuController: Exception polling DBus messages: %@", exception);
    }
}

- (id)init
{
    NSDebugLLog(@"gwcomp", @"MenuController: Initializing controller...");
    self = [super init];
    if (self) {
        // Initialize trailing-edge debounce properties to prevent infinite loops
        self.lastActiveWindowScanTime = 0;
        
        // Initialize window monitor
        self.windowMonitor = [WindowMonitor sharedMonitor];
        self.windowMonitor.delegate = (id<WindowMonitorDelegate>)self;
        
        NSDebugLLog(@"gwcomp", @"MenuController: Controller initialized successfully. Active window: 0x%lx", (unsigned long)[self.windowMonitor currentActiveWindow]);
    }
    return self;
}

- (NSColor *)backgroundColor
{
    /* Match Eau's slot panel fill exactly. Eau provides
     * -menuBarBackgroundColor at alpha 1.0 so the slot and our bar's
     * left/right strips render to identical pixels — no seam. */
    GSTheme *theme = [GSTheme theme];
    if ([theme respondsToSelector:@selector(menuBarBackgroundColor)]) {
        return [(id)theme menuBarBackgroundColor];
    }
    return [theme menuItemBackgroundColor];
}

- (NSColor *)transparentColor
{
    NSColor *color = [NSColor colorWithCalibratedRed:0.992 green:0.992 blue:0.992 alpha:0.0];
    return color;
}

- (void)createPersistentStrutWindow
{
    NSDebugLLog(@"gwcomp", @"MenuController: Creating persistent X11 strut window...");
    
    const CGFloat menuBarHeight = [[GSTheme theme] menuBarHeight];
    
    // Open X11 display connection that will persist for the application lifetime
    self.strutDisplay = XOpenDisplay(NULL);
    if (!self.strutDisplay) {
        NSDebugLLog(@"gwcomp", @"MenuController: Cannot open X11 display for strut window");
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
        NSDebugLLog(@"gwcomp", @"MenuController: Failed to create X11 strut window");
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
    
    NSDebugLLog(@"gwcomp", @"MenuController: Created persistent X11 strut window (XID: %lu) - invisible 1x1 window with full-width struts",
          (unsigned long)self.strutWindow);
}

- (void)screenParametersChanged:(NSNotification *)notification
{
    NSDebugLLog(@"gwcomp", @"MenuController: Screen parameters changed, repositioning menu bar");

    if (!self.menuBar) {
        NSDebugLLog(@"gwcomp", @"MenuController: Menu bar not yet created, skipping reposition");
        return;
    }

    // Re-read the primary screen geometry (screens[0] is the xrandr primary;
    // mainScreen may return the menu's own window screen which is circular)
    self.screenFrame = [[[NSScreen screens] objectAtIndex:0] frame];
    self.screenSize = self.screenFrame.size;
    NSDebugLLog(@"gwcomp", @"MenuController: New screen frame: %.0f,%.0f %.0fx%.0f",
          self.screenFrame.origin.x, self.screenFrame.origin.y,
          self.screenSize.width, self.screenSize.height);

    const CGFloat menuBarHeight = [[GSTheme theme] menuBarHeight];

    // Reposition and resize the menu bar window using the screen frame origin
    // (the origin may be non-zero if the virtual desktop geometry changed)
    CGFloat originX = self.screenFrame.origin.x;
    CGFloat originY = self.screenFrame.origin.y;
    NSRect menuRect = NSMakeRect(originX,
                                 originY + self.screenSize.height - menuBarHeight,
                                 self.screenSize.width, menuBarHeight);
    [self.menuBar setFrame:menuRect display:NO];
    [self.menuBar setFrameTopLeftPoint:NSMakePoint(originX, originY + self.screenSize.height)];

    // Resize the background view
    [self.menuBarView setFrame:NSMakeRect(0, 0, self.screenSize.width, menuBarHeight)];

    // Reposition status items at the right edge
    StatusItemsView *statusItemsView = nil;
    for (NSView *subview in [self.menuBarView subviews]) {
        if ([subview isKindOfClass:NSClassFromString(@"StatusItemsView")]) {
            statusItemsView = (StatusItemsView *)subview;
            break;
        }
    }

    CGFloat statusItemsWidth = 0;
    if (statusItemsView) {
        statusItemsWidth = [statusItemsView totalRequiredWidth];
        [statusItemsView setFrame:NSMakeRect(self.screenSize.width - statusItemsWidth, 0,
                                              statusItemsWidth, menuBarHeight)];
    }

    // Resize app menu widget to fill remaining space
    CGFloat menuWidgetWidth = self.screenSize.width - statusItemsWidth;
    [self.appMenuWidget setFrame:NSMakeRect(0, 0, menuWidgetWidth, menuBarHeight)];

    // Resize rounded corners view
    CGFloat cornerHeight = 10.0;
    [self.roundedCornersView setFrame:NSMakeRect(0, menuBarHeight - cornerHeight,
                                                  self.screenSize.width, cornerHeight)];

    // Update the StatusItemManager's cached screen width
    [self.statusItemManager setScreenWidth:self.screenSize.width];

    // Update strut properties to match new width
    if (self.strutWindow != None && self.strutDisplay) {
        unsigned int width = (unsigned int)self.screenSize.width;
        unsigned int height = (unsigned int)menuBarHeight;

        Atom strutAtom = XInternAtom(self.strutDisplay, "_NET_WM_STRUT", False);
        Atom strutPartialAtom = XInternAtom(self.strutDisplay, "_NET_WM_STRUT_PARTIAL", False);
        unsigned long strut[4] = {0, 0, height, 0};
        unsigned long strutPartial[12] = {0, 0, height, 0, 0, 0, 0, 0, 0, width - 1, 0, width - 1};

        XChangeProperty(self.strutDisplay, self.strutWindow, strutAtom, XA_CARDINAL, 32,
                       PropModeReplace, (unsigned char *)strut, 4);
        XChangeProperty(self.strutDisplay, self.strutWindow, strutPartialAtom, XA_CARDINAL, 32,
                       PropModeReplace, (unsigned char *)strutPartial, 12);
        XSync(self.strutDisplay, False);
        NSDebugLLog(@"gwcomp", @"MenuController: Updated strut properties for new screen width: %u", width);
    }

    // Redraw
    [self.menuBar display];
    NSDebugLLog(@"gwcomp", @"MenuController: Menu bar repositioned successfully");
}

/* Advertise the slot rect (in X11 screen coords, top-left origin) where
 * each GNUstep app should draw its NSMacintoshInterfaceStyle top-strip
 * menu. Eau's modifyRect:forMenu:isHorizontal: reads this property and
 * narrows libs-gui's panel frame to fit. We also lower our own bar one
 * level so the app's panel naturally appears above us inside the slot
 * region — outside the slot (left = command area, right = status items)
 * we remain visible. */
- (void)_advertiseMenuSlot
{
    NSWindow *bar = self.menuBar;
    if (!bar) return;
    GSDisplayServer *server = GSServerForWindow(bar);
    if (!server) return;
    Display *dpy = (Display *)[server serverDevice];
    if (!dpy) return;
    Window root = DefaultRootWindow(dpy);

    Atom geomAtom = XInternAtom(dpy, "_GERSHWIN_MENU_SLOT_GEOMETRY", False);

    /* Use screen rect of the bar so apps don't need to know our internal
     * layout. Slot is the middle of the bar; reserve space on left and
     * right. Coords are X11 (top-left origin). */
    NSRect barFrame = [bar frame];
    CGFloat screenH = [[NSScreen mainScreen] frame].size.height;
    /* Reserve only enough on the LEFT for the command/Apple icon; slot
     * starts immediately after it so the app's menu items appear right
     * next to the icon (macOS layout). 280 px on the RIGHT for the
     * status items / clock. */
    long reservedLeft  = 40;
    long reservedRight = 280;
    long slotWidth = (long)barFrame.size.width - reservedLeft - reservedRight;
    if (slotWidth < 200) slotWidth = 200;
    long geom[4];
    geom[0] = (long)barFrame.origin.x + reservedLeft;
    geom[1] = (long)(screenH - (barFrame.origin.y + barFrame.size.height));
    geom[2] = slotWidth;
    geom[3] = (long)barFrame.size.height;
    XChangeProperty(dpy, root, geomAtom, XA_CARDINAL, 32, PropModeReplace,
                    (unsigned char *)geom, 4);
    XFlush(dpy);
    NSLog(@"MenuController: Advertised menu slot at screen (%ld, %ld, %ld, %ld)",
          geom[0], geom[1], geom[2], geom[3]);

    /* Lower our bar one level below NSMainMenuWindowLevel so each app's
     * NSMenuPanel (created at NSMainMenuWindowLevel by libs-gui under
     * Macintosh style) naturally sits above us in the slot region. */
    [bar setLevel:NSMainMenuWindowLevel - 1];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
    NSDebugLLog(@"gwcomp", @"MenuController: Application did finish launching");

    [self.menuBar orderFront:self];
    [self _advertiseMenuSlot];
    [self setupWindowMonitoring];
    
    NSDebugLLog(@"gwcomp", @"MenuController: Application setup complete");
    
    // Register D-Bus service immediately - run loop is active
    NSDebugLLog(@"gwcomp", @"MenuController: Registering D-Bus service now...");
    
    // Call directly instead of using dispatch_async - the main queue might not process async blocks reliably
    [self registerDBusServiceWhenReady];
}

- (void)registerDBusServiceWhenReady
{
    NSDebugLLog(@"gwcomp", @"MenuController: ===== Registering D-BUS SERVICE =====");
    
    // Get the canonical handler
    id<MenuProtocolHandler> canonicalHandler = [[MenuProtocolManager sharedManager] handlerForType:MenuProtocolTypeCanonical];
    
    if (canonicalHandler && [canonicalHandler respondsToSelector:@selector(registerService)]) {
        BOOL result = [(id)canonicalHandler registerService];
        
        if (result) {
            NSDebugLLog(@"gwcomp", @"MenuController: ===== Successfully registered D-Bus service - Menu is now VISIBLE =====");
            // Advertise global menu support via X11 so applications know to register their menus
            BOOL advertised = [MenuUtils advertiseGlobalMenuSupport];
            if (advertised) {
                NSDebugLLog(@"gwcomp", @"MenuController: Advertised global menu support on X11 root window");
            } else {
                NSDebugLLog(@"gwcomp", @"MenuController: Failed to advertise global menu support on X11 root window");
            }
        } else {
            NSDebugLLog(@"gwcomp", @"MenuController: Warning - failed to register D-Bus service");
        }
    } else {
        NSDebugLLog(@"gwcomp", @"MenuController: WARNING - canonical handler not available or doesn't have registerService");
    }
}

- (void)applicationWillTerminate:(NSNotification *)notification
{
    NSDebugLLog(@"gwcomp", @"MenuController: Application will terminate");
    
    // Unload status items first
    if (self.statusItemManager) {
        NSDebugLLog(@"gwcomp", @"MenuController: Unloading status items...");
        [self.statusItemManager unloadAllStatusItems];
        self.statusItemManager = nil;
    }
    
    // Clean up global shortcuts
    NSDebugLLog(@"gwcomp", @"MenuController: Cleaning up global shortcuts...");
    [[X11ShortcutManager sharedManager] cleanup];
    
    // Stop window monitoring
    NSDebugLLog(@"gwcomp", @"MenuController: Stopping window monitoring...");
    [self.windowMonitor stopMonitoring];
    self.windowMonitor = nil;
    
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
    
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    
    [[MenuProtocolManager sharedManager] cleanup];
    
    self.protocolManager = nil;
    
    self.roundedCornersView = nil;
}

- (void)createMenuBar
{
    NSDebugLLog(@"gwcomp", @"MenuController: ===== CREATING MENU BAR =====");
    const CGFloat menuBarHeight = [[GSTheme theme] menuBarHeight];
    NSDebugLLog(@"gwcomp", @"MenuController: Menu bar height: %.0f", menuBarHeight);
    
    NSRect rect;
    NSColor *color;
    NSFont *menuFont = [NSFont menuBarFontOfSize:0];
    NSMutableDictionary *attributes;
    
    attributes = [NSMutableDictionary new];
    [attributes setObject:menuFont forKey:NSFontAttributeName];
    
    self.screenFrame = [[[NSScreen screens] objectAtIndex:0] frame];
    self.screenSize = self.screenFrame.size;
    NSDebugLLog(@"gwcomp", @"MenuController: Screen frame: %.0f,%.0f %.0fx%.0f",
          self.screenFrame.origin.x, self.screenFrame.origin.y, self.screenSize.width, self.screenSize.height);
    
    color = [self backgroundColor];
    NSDebugLLog(@"gwcomp", @"MenuController: Background color: %@", color);
        
    // Creation of the menuBar at the TOP of the screen (GNUstep coordinates: bottom-left origin)
    // Use screenFrame.origin to handle multi-monitor setups where the primary screen
    // origin may be non-zero in the virtual desktop coordinate space.
    rect = NSMakeRect(self.screenFrame.origin.x,
                      self.screenFrame.origin.y + self.screenSize.height - menuBarHeight,
                      self.screenSize.width, menuBarHeight);
    NSDebugLLog(@"gwcomp", @"MenuController: Menu bar rect: %.0f,%.0f %.0fx%.0f",
          rect.origin.x, rect.origin.y, rect.size.width, rect.size.height);
    
    self.menuBar = [[NSWindow alloc] initWithContentRect:rect
                                          styleMask:NSBorderlessWindowMask
                                            backing:NSBackingStoreBuffered
                                              defer:NO];
    NSDebugLLog(@"gwcomp", @"MenuController: Created NSWindow: %@", self.menuBar);
    
    [self.menuBar setTitle:@"MenuBar"];
    [self.menuBar setBackgroundColor:color];
    [self.menuBar setAlphaValue:1.0];
    [self.menuBar setLevel:NSMainMenuWindowLevel + 1]; // Higher than main menu, but not floating
    [self.menuBar setCanHide:NO];
    [self.menuBar setHidesOnDeactivate:NO];
    [self.menuBar setCollectionBehavior:NSWindowCollectionBehaviorCanJoinAllSpaces |
                                   NSWindowCollectionBehaviorStationary];
    
    NSDebugLLog(@"gwcomp", @"MenuController: Configured window properties");
    
    // Create and maintain a persistent X11 window for struts
    [self createPersistentStrutWindow];

    // Position the window one menu height above the screen for animation effect
    [self.menuBar setFrameTopLeftPoint:NSMakePoint(self.screenFrame.origin.x,
                                                    self.screenFrame.origin.y + self.screenSize.height + menuBarHeight)];
    NSDebugLLog(@"gwcomp", @"MenuController: Window positioned above screen for animation slide-in");
    
    // Create the main menu bar view that draws the background
    self.menuBarView = [[MenuBarView alloc] initWithFrame:NSMakeRect(0, 0, self.screenSize.width, menuBarHeight)];
    NSDebugLLog(@"gwcomp", @"MenuController: Created MenuBarView: %@", self.menuBarView);
    
    // Create app menu widget for displaying menus - leave space for status items on right
    // Status item width is computed dynamically from loaded providers below.
    // First, create and load the StatusItemManager to know the total width.
    NSDebugLLog(@"gwcomp", @"MenuController: Creating StatusItemManager");
    self.statusItemManager = [[StatusItemManager alloc] initWithScreenWidth:self.screenSize.width
                                                             menuBarHeight:menuBarHeight];
    [self.statusItemManager loadStatusItems];
    NSDebugLLog(@"gwcomp", @"MenuController: StatusItemManager items loaded");

    // Create the status items view (fixed-width cells, laid out right-to-left)
    StatusItemsView *statusItemsView = [self.statusItemManager createStatusItemsView];
    CGFloat statusItemsWidth = [statusItemsView totalRequiredWidth];
    NSDebugLLog(@"gwcomp", @"MenuController: StatusItemsView total width: %.0f", statusItemsWidth);

    // Position status items at the right edge of the menu bar
    [statusItemsView setFrame:NSMakeRect(self.screenSize.width - statusItemsWidth, 0,
                                          statusItemsWidth, menuBarHeight)];

    // Give the app menu widget the remaining space
    CGFloat menuWidgetWidth = self.screenSize.width - statusItemsWidth;
    self.appMenuWidget = [[AppMenuWidget alloc] initWithFrame:NSMakeRect(0, 0, menuWidgetWidth, menuBarHeight)];
    NSDebugLLog(@"gwcomp", @"MenuController: AppMenuWidget created successfully");
    
    NSDebugLLog(@"gwcomp", @"MenuController: Setting up protocol manager connection");
    // Set up the AppMenuWidget with the protocol manager
    [self.appMenuWidget setProtocolManager:[MenuProtocolManager sharedManager]];
    NSDebugLLog(@"gwcomp", @"MenuController: Protocol manager connected to AppMenuWidget");
    
    // Update all protocol handlers with the AppMenuWidget reference
    [[MenuProtocolManager sharedManager] updateAllHandlersWithAppMenuWidget:self.appMenuWidget];
    NSDebugLLog(@"gwcomp", @"MenuController: All protocol handlers notified of AppMenuWidget");
    
    NSDebugLLog(@"gwcomp", @"MenuController: Checking appMenuWidget before NSLog...");
    if (self.appMenuWidget) {
        NSDebugLLog(@"gwcomp", @"MenuController: appMenuWidget is valid");
    } else {
        NSDebugLLog(@"gwcomp", @"MenuController: appMenuWidget is nil!");
    }
    
    // NSLog(@"MenuController: Created AppMenuWidget with width %.0f at address %p", menuWidgetWidth, self.appMenuWidget);
    NSDebugLLog(@"gwcomp", @"MenuController: Skipping potentially problematic NSLog");
    
    // Remove the Action Search icon from the menu bar (search remains accessible via Command menu)
    
    // probono: Create rounded corners view for black top corners like in old/src/mainwindow.cpp
    // Position it at the top of the menu bar, with height enough for the corner radius effect
    CGFloat cornerHeight = 10.0; // 2 * corner radius (5px)
    self.roundedCornersView = [[RoundedCornersView alloc] initWithFrame:NSMakeRect(0, menuBarHeight - cornerHeight, self.screenSize.width, cornerHeight)];
    
    // Add MenuBarView as the background (spans full width)
    [[self.menuBar contentView] addSubview:self.menuBarView];
    
    // Add AppMenuWidget and StatusItemsView as children of MenuBarView (on top of the background)
    [self.menuBarView addSubview:self.appMenuWidget];
    
    // Add the status items view and start update timers
    [self.menuBarView addSubview:statusItemsView];
    [self.statusItemManager startUpdateTimers];
    NSDebugLLog(@"gwcomp", @"MenuController: Added StatusItemsView as child of MenuBarView");
    
    // Finally add rounded corners on top of everything
    [[self.menuBar contentView] addSubview:self.roundedCornersView];

    // Show the window and slide it in from above with animation
    [self.menuBar makeKeyAndOrderFront:self];
    [self.menuBar orderFront:self];

    // Register global Cmd-Space shortcut to toggle the Action Search panel (if available)
    // NOTE: What we call "Cmd" here is actually the "Alt" key technically but we refer to it as "Cmd" in the UI
    NSString *cmdSpaceShortcut = @"alt+space";
    X11ShortcutManager *mgr = [X11ShortcutManager sharedManager];
    if (mgr && ![mgr isShortcutAlreadyTaken:cmdSpaceShortcut]) {
        NSMenuItem *cmdSpaceItem = [[NSMenuItem alloc] initWithTitle:@"Toggle Action Search"
                                                               action:@selector(toggleSearch:)
                                                        keyEquivalent:@" "];
        [cmdSpaceItem setKeyEquivalentModifierMask:NSCommandKeyMask];
        // Register directly to call the ActionSearchController without DBus
        BOOL regOK = [mgr registerDirectShortcutForMenuItem:cmdSpaceItem
                                                     target:[ActionSearchController sharedController]
                                                     action:@selector(toggleSearch:)];
        if (regOK) {
            NSDebugLLog(@"gwcomp", @"MenuController: Registered global shortcut Cmd-Space for Action Search");
        } else {
            NSDebugLLog(@"gwcomp", @"MenuController: Failed to register Cmd-Space as global shortcut");
            // Notify user with alert so failure is visible
            NSAlert *alert = [[NSAlert alloc] init];
            [alert setMessageText:NSLocalizedString(@"Cannot register global shortcut", @"Alert title for shortcut failure")];
            [alert setInformativeText:NSLocalizedString(@"Menu.app failed to register the Cmd-Space global shortcut. Please check for conflicts or permissions.", @"Alert text for shortcut failure")];
            [alert addButtonWithTitle:NSLocalizedString(@"OK", @"OK button")];
            [alert setAlertStyle:NSWarningAlertStyle];
            // Run non-modally to avoid blocking the app startup
            [alert beginSheetModalForWindow:self.menuBar completionHandler:nil];
        }
    } else {
        if (!mgr) {
            NSDebugLLog(@"gwcomp", @"MenuController: Warning - cannot register Cmd-Space because X11ShortcutManager is unavailable");
        } else {
            NSDebugLLog(@"gwcomp", @"MenuController: Cmd-Space already taken - not registering global shortcut");
        }
    }

    // Animate menu sliding in using NSTimer instead of dispatch_async for better GNUstep/FreeBSD compatibility
    // FIXME: GCD dispatch_async may not execute reliably with GNUstep run loop on some platforms
    [NSTimer scheduledTimerWithTimeInterval:0.001  // Start almost immediately
                                     target:self
                                   selector:@selector(animateMenuSlideIn)
                                   userInfo:nil
                                    repeats:NO];
    NSDebugLLog(@"gwcomp", @"MenuController: Window shown, menu will slide in immediately (using NSTimer for compatibility)");

    // Observe screen resolution/layout changes so we can reposition the menu bar.
    // Registered here (after creation) rather than in init, to avoid interfering
    // with startup if RRScreenChangeNotify events arrive before the menu exists.
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(screenParametersChanged:)
                                                 name:NSApplicationDidChangeScreenParametersNotification
                                               object:nil];
}

- (void)setupMenuBar
{
    NSDebugLLog(@"gwcomp", @"MenuController: Setting up menu bar using createMenuBar method");
    [self createMenuBar];
    NSDebugLLog(@"gwcomp", @"MenuController: Menu bar setup complete at %.0f,%.0f %.0fx%.0f", self.screenFrame.origin.x, self.screenFrame.origin.y, self.screenSize.width, [[GSTheme theme] menuBarHeight]);
    NSDebugLLog(@"gwcomp", @"MenuController: Setting up X11 window monitoring");
    [self setupWindowMonitoring];
    NSDebugLLog(@"gwcomp", @"MenuController: Initializing protocol scanning");
    [self initializeProtocols];
}

- (void)updateActiveWindow
{
    // Get the currently active window and update app menu
    if (self.appMenuWidget) {
        [self.appMenuWidget updateForActiveWindow];
    } else {
        NSDebugLLog(@"gwcomp", @"MenuController: self.appMenuWidget is nil");
    }
}

- (void)initializeProtocols
{
    NSDebugLLog(@"gwcomp", @"MenuController: Initializing all menu protocols...");
    
    NSDebugLLog(@"gwcomp", @"MenuController: About to call initializeAllProtocols...");
    if (![[MenuProtocolManager sharedManager] initializeAllProtocols]) {
        NSDebugLLog(@"gwcomp", @"MenuController: Failed to initialize menu protocols - continuing anyway");
        self.dbusFileDescriptor = -1;
    } else {
        NSDebugLLog(@"gwcomp", @"MenuController: Menu protocols initialized successfully");
        
        // Get the DBus file descriptor for X11 event loop integration
        self.dbusFileDescriptor = [[MenuProtocolManager sharedManager] getDBusFileDescriptor];
        if (self.dbusFileDescriptor >= 0) {
            NSDebugLLog(@"gwcomp", @"MenuController: Got DBus file descriptor %d for event loop integration", self.dbusFileDescriptor);
            
            // Create NSFileHandle for DBus file descriptor monitoring
            self.dbusFileHandle = [[NSFileHandle alloc] initWithFileDescriptor:self.dbusFileDescriptor closeOnDealloc:NO];
            if (self.dbusFileHandle) {
                NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
                [center addObserver:self
                           selector:@selector(dbusFileDescriptorReady:)
                               name:NSFileHandleDataAvailableNotification
                             object:self.dbusFileHandle];
                [self.dbusFileHandle waitForDataInBackgroundAndNotify];
                NSDebugLLog(@"gwcomp", @"MenuController: DBus file descriptor integrated into notification system");
            } else {
                NSDebugLLog(@"gwcomp", @"MenuController: Failed to create NSFileHandle for DBus file descriptor");
            }
            
            NSDebugLLog(@"gwcomp", @"MenuController: Event loop integration setup complete");
        } else {
            NSDebugLLog(@"gwcomp", @"MenuController: Failed to get DBus file descriptor");
        }
        
        // Set up timer-based D-Bus polling ONLY as fallback when fd monitoring is unavailable
        if (!self.dbusFileHandle) {
            self.dbusPollingTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 // 500ms fallback
                                                                      target:self
                                                                    selector:@selector(pollDBusMessages:)
                                                                    userInfo:nil
                                                                     repeats:YES];
            NSDebugLLog(@"gwcomp", @"MenuController: D-Bus polling timer set up as fallback (500ms interval)");
        } else {
            NSDebugLLog(@"gwcomp", @"MenuController: Using fd-based monitoring, no polling timer needed");
        }
    }
    
    // Set the app menu widget reference
    if (self.appMenuWidget) {
        [[MenuProtocolManager sharedManager] setAppMenuWidget:self.appMenuWidget];
        NSDebugLLog(@"gwcomp", @"MenuController: Set up connection between MenuProtocolManager and AppMenuWidget");
    }
    
    // D-Bus will continue initializing via the file descriptor monitoring on the main thread
    // The run loop will handle D-Bus messages asynchronously without blocking the UI
    // This ensures thread safety - D-Bus is NOT thread-safe and must run on main thread only
    NSDebugLLog(@"gwcomp", @"MenuController: D-Bus initialization will continue via main thread run loop");
    NSDebugLLog(@"gwcomp", @"MenuController: File descriptor monitoring will handle D-Bus messages asynchronously");
}

- (void)createProtocolManager
{
    NSDebugLLog(@"gwcomp", @"MenuController: Creating MenuProtocolManager...");
    self.protocolManager = [MenuProtocolManager sharedManager];
    
    /* Only the GNUstep handler remains. The Canonical (com.canonical.dbusmenu)
     * and GTK (org.gtk.Menus) live-IPC paths were deleted; their bug
     * surface (stale validation, broken action dispatch, registrar wedges,
     * etc.) was the original motivation for this refactor. Apps wrapped
     * by pkgwrap continue to work via pkgwrap-menu-stub which speaks the
     * GSGNUstepMenuServer DO protocol implemented by GNUStepMenuImporter. */
    GNUStepMenuImporter *gnustepHandler = [[GNUStepMenuImporter alloc] init];
    [self.protocolManager registerProtocolHandler:gnustepHandler forType:MenuProtocolTypeGNUstep];

    NSDebugLLog(@"gwcomp", @"MenuController: Registered GNUstep protocol handler");
    NSDebugLLog(@"gwcomp", @"MenuController: createProtocolManager COMPLETED");
}

- (void)setupWindowMonitoring
{
    NSDebugLLog(@"gwcomp", @"MenuController: Setting up window monitoring");
    
    // Start GCD-based window monitoring (event-driven, zero-polling)
    if ([self.windowMonitor startMonitoring]) {
        NSDebugLLog(@"gwcomp", @"MenuController: Window monitoring started successfully (GCD-based, event-driven)");
    } else {
        NSDebugLLog(@"gwcomp", @"MenuController: ERROR - Failed to start window monitoring");
        return;
    }
    
        // Observe active window changes via notification as a robust fallback
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                                                         selector:@selector(activeWindowChangedNotification:)
                                                                                                 name:WindowMonitorActiveWindowChangedNotification
                                                                                             object:nil];

        // Announce global menu support
    [self announceGlobalMenuSupport];
    
    // Perform initial update
    [self updateActiveWindow];

    // Initialize clear/last-cleared tracking to throttle repeated clears
    self.lastClearedWindowId = 0;
    self.lastClearedTime = 0;

    // Start watchdog timer to validate active window and clear menus for closed windows
    // Use a conservative interval since event-driven WindowMonitor handles real-time changes
    self.windowValidationTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                                  target:self
                                                                selector:@selector(windowValidationTick:)
                                                                userInfo:nil
                                                                 repeats:YES];
    
    NSDebugLLog(@"gwcomp", @"MenuController: Window monitoring setup complete");
}

- (void)activeWindowChangedNotification:(NSNotification *)notification
{
    // TIGHT-LOOP GUARD: Throttle rapid window-change notifications to max once per 30ms
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if ((now - self.lastProcessedTime) < 0.03) {
        NSNumber *windowIdNum = notification.userInfo[@"windowId"];
        unsigned long windowId = windowIdNum ? [windowIdNum unsignedLongValue] : 0;
        // Allow through only if the window ID actually changed
        if (windowId == self.lastProcessedWindowId) {
            return; // Duplicate notification within 30ms - skip
        }
    }

    NSNumber *lostIdNum = notification.userInfo[@"lostWindowId"];
    if (lostIdNum) {
        unsigned long lostId = [lostIdNum unsignedLongValue];
        if (self.appMenuWidget && self.appMenuWidget.currentWindowId == lostId) {
            NSDebugLLog(@"gwcomp", @"MenuController: Currently shown window 0x%lx was explicitly lost (destroyed/unmapped) - clearing menu", lostId);
            [self.appMenuWidget clearMenuAndHideView];
        }
    }

    // NOTE: We no longer check isWindowMapped here for the currently shown window.
    // The windowValidationTick watchdog (every 2s) handles stale-window cleanup with
    // better logic (preserves menu if window IS the active window).
    // Doing it here caused a tight loop: XGetWindowAttributes failure on a shared
    // X11 Display (thread-safety issue) was misinterpreted as "unmapped", which cleared
    // the menu, which triggered a full re-import on the next notification.
    // See windowValidationTick: for the proper stale-window check.

    NSNumber *windowIdNum = notification.userInfo[@"windowId"];
    unsigned long windowId = windowIdNum ? [windowIdNum unsignedLongValue] : 0;

    // Check if the focus changed to the Menu application itself.
    // If so, we ignore the change to keep the previous application's menu visible.
    if (windowId != 0 && [NSApp windowWithWindowNumber:windowId] != nil) {
        NSDebugLLog(@"gwcomp", @"MenuController: Focus changed to Menu app window (0x%lx) - ignoring to preserve current menu", windowId);
        return;
    }

    /* Slot-bar architecture: GNUstep apps draw their menu items inside the
       advertised slot via libs-gui's NSMacintoshInterfaceStyle. Menu.app's
       bar shows only the app icon (left) and status items (right). To
       avoid drawing the same menu twice, blank AppMenuWidget's slot
       region whenever the active window is a GNUstep window. */
    if (windowId != 0 && [self.windowMonitor isGNUstepWindow:windowId]) {
        [self.appMenuWidget clearMenuAndHideView];
        self.lastProcessedWindowId = windowId;
        self.lastProcessedTime = [[NSDate date] timeIntervalSince1970];
        return;
    }

    // Similarly, ignore and preserve if the process that launched the old and new menu have the same PID.
    // This avoids flickering or clearing menus when switching between windows of the same application.
    if (windowId != 0 && self.appMenuWidget && self.appMenuWidget.currentWindowId != 0 && windowId != self.appMenuWidget.currentWindowId) {
        pid_t oldPid = [MenuUtils getWindowPID:self.appMenuWidget.currentWindowId];
        pid_t newPid = [MenuUtils getWindowPID:windowId];
        if (oldPid != 0 && oldPid == newPid) {
            NSDebugLLog(@"gwcomp", @"MenuController: Focus changed to another window (0x%lx) of the same process (PID %d) - ignoring to preserve current menu", windowId, (int)newPid);
             // We still update the window tracking in both Controller and Widget but skip the menu reload
             self.lastProcessedWindowId = windowId;
             self.lastProcessedTime = [[NSDate date] timeIntervalSince1970];
             self.appMenuWidget.currentWindowId = windowId;
             return;
        }
    }

    self.lastProcessedWindowId = windowId;
    self.lastProcessedTime = [[NSDate date] timeIntervalSince1970];

    // Always use updateForActiveWindowId - it has proper anti-flicker handling
    // including grace periods for windowId == 0 (transient no-window states)
    NSDebugLLog(@"gwcomp", @"MenuController: Active window changed (notification) to 0x%lx", windowId);

    if (self.appMenuWidget) {
        [self.appMenuWidget updateForActiveWindowId:windowId];
    }
}

- (void)windowValidationTick:(NSTimer *)timer
{
    @try {
        // Safety watchdog running on main thread to ensure menus are hidden when their windows disappear
        unsigned long activeWindow = 0;
        // Prefer asking the WindowMonitor for the active window (safe, single-threaded X11 access)
        if ([[WindowMonitor sharedMonitor] respondsToSelector:@selector(getActiveWindow)]) {
            @try {
                activeWindow = [[WindowMonitor sharedMonitor] getActiveWindow];
            }
            @catch (NSException *ex) {
                NSDebugLLog(@"gwcomp", @"MenuController: WindowMonitor getActiveWindow threw exception: %@ - treating as no active window", ex);
                activeWindow = 0;
            }
        } else {
            NSDebugLog(@"MenuController: WindowMonitor does not implement getActiveWindow - falling back to 0");
        }

        if (!self.appMenuWidget) return;

        unsigned long shownWindow = self.appMenuWidget.currentWindowId;
        if (shownWindow == 0) return; // no menu shown

        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];

        // CRITICAL FIX: Only validate the shown window if it's still the active window
        // If we've switched to a different window, don't clear the menu for the OLD window
        if (activeWindow != 0 && shownWindow != activeWindow) {
            // We've switched to a different window - the shown window ID is stale
            // Don't validate it, let the normal window change handling take care of it
            return;
        }

        // CRITICAL: If shown window IS the active window AND we have a menu for it, DON'T clear it!
        // The window manager says this is the active window, so trust that it exists
        // Only clear if we have NO menu (meaning menu failed to load/register)
        if (shownWindow == activeWindow && self.appMenuWidget.currentMenu != nil) {
            // We have a menu for the current active window - keep it!
            // Don't validate with X11 calls that might fail during WM operations
            return;
        }

        // Only validate and potentially clear if:
        // 1. Window is shown but we have no menu for it, OR
        // 2. Active window is 0 (no window focused)
        if (![MenuUtils isWindowValid:shownWindow] || ![MenuUtils isWindowMapped:shownWindow]) {
            NSDebugLog(@"MenuController: Watchdog detected invalid/closed window 0x%lx - clearing menu", shownWindow);
            [self.appMenuWidget clearMenuAndHideView];
            self.lastClearedWindowId = shownWindow;
            self.lastClearedTime = now;
            self.lastClearSuppressUntil = 0;
            return;
        }

        // If the system reports no active window, but we have a menu for one, hide it
        if (activeWindow == 0 && shownWindow != 0) {
            NSDebugLLog(@"gwcomp", @"MenuController: Active window is 0 but menu shown for 0x%lx - clearing menu", shownWindow);
            [self.appMenuWidget clearMenuAndHideView];
            self.lastClearedWindowId = shownWindow;
            self.lastClearedTime = now;
            self.lastClearSuppressUntil = 0;
            return;
        }
    }
    @catch (NSException *ex) {
        NSDebugLLog(@"gwcomp", @"MenuController: Exception in windowValidationTick: %@", ex);
    }
}

- (void)announceGlobalMenuSupport
{
    NSDebugLLog(@"gwcomp", @"MenuController: Announcing global menu support via X11 properties");
    
    // Set X11 root window properties to announce that we support global menus
    // This is essential for applications to know they should export their menus
    Display *display = [MenuUtils sharedDisplay];
    if (!display) {
        NSDebugLLog(@"gwcomp", @"MenuController: Cannot open X11 display to announce global menu support");
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
        
        NSDebugLLog(@"gwcomp", @"MenuController: Set _NET_SUPPORTING_WM property");
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
    
    NSDebugLLog(@"gwcomp", @"MenuController: Set _NET_SUPPORTED property with %lu atoms", 
          sizeof(supportedAtoms) / sizeof(Atom));
    
    // Set Unity-specific properties that Chrome looks for
    Atom unityGlobalMenuAtom = XInternAtom(display, "_UNITY_SUPPORTED", False);
    XChangeProperty(display, root, unityGlobalMenuAtom, atomAtom, 32,
                   PropModeReplace, (unsigned char*)supportedAtoms, 1);
    
    NSDebugLLog(@"gwcomp", @"MenuController: Set _UNITY_SUPPORTED property");
    
    XSync(display, False);
    
    NSDebugLLog(@"gwcomp", @"MenuController: Global menu support announcement complete");
}

- (void)scanForNewMenus
{
    NSDebugLLog(@"gwcomp", @"MenuController: Scanning for new menu services");
    
    [[MenuProtocolManager sharedManager] scanForExistingMenuServices];
    
    // Force an immediate update of the current window to check if it now has a menu
    if (self.appMenuWidget) {
        [self.appMenuWidget updateForActiveWindow];
    }
}

#pragma mark - WindowMonitorDelegate

- (void)activeWindowChanged:(unsigned long)windowId
{
    NSDebugLog(@"MenuController: Active window changed to 0x%lx", windowId);
    
    // Update app menu widget on main thread
    if (self.appMenuWidget) {
        [self.appMenuWidget updateForActiveWindowId:windowId];
        
        // After updating for active window, scan for menus (debounced)
        // Applications may register menus after window activation
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        if ((now - self.lastActiveWindowScanTime) > 3.0) { // Only scan once every 3 seconds max
            NSDebugLLog(@"gwcomp", @"MenuController: Active window changed, triggering scan to discover new menus");
            self.lastActiveWindowScanTime = now;
            [[MenuProtocolManager sharedManager] scanForExistingMenuServices];
        }
    }
}

- (void)createTimeMenu
{
    NSDebugLLog(@"gwcomp", @"MenuController: createTimeMenu - DISABLED (bundles only)");
    return;
    
    NSDebugLLog(@"gwcomp", @"MenuController: Creating time menu");
    
    NSDebugLLog(@"gwcomp", @"MenuController: Creating time formatters...");
    // Create formatters
    self.timeFormatter = [[NSDateFormatter alloc] init];
    NSDebugLLog(@"gwcomp", @"MenuController: Created timeFormatter");
    [self.timeFormatter setDateFormat:@"HH:mm"];
    NSDebugLLog(@"gwcomp", @"MenuController: Set time format");
    self.dateFormatter = [[NSDateFormatter alloc] init];
    NSDebugLLog(@"gwcomp", @"MenuController: Created dateFormatter");
    [self.dateFormatter setDateFormat:@"EEEE, MMMM d, yyyy"];
    NSDebugLLog(@"gwcomp", @"MenuController: Set date format");

    NSDebugLLog(@"gwcomp", @"MenuController: Creating menu and items...");
    // Create the menu and items
    self.timeMenu = [[NSMenu alloc] initWithTitle:@""];
    NSDebugLLog(@"gwcomp", @"MenuController: Created timeMenu");
    [self.timeMenu setAutoenablesItems:NO];
    NSDebugLLog(@"gwcomp", @"MenuController: Set autoenablesItems");
    self.timeMenuItem = [[NSMenuItem alloc] initWithTitle:@"00:00" action:nil keyEquivalent:@""];
    NSDebugLLog(@"gwcomp", @"MenuController: Created timeMenuItem");
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
    CGFloat timeMenuX = self.screenSize.width - timeMenuWidth - 7;  // Move clock 7px left
    const CGFloat menuBarHeight = [[GSTheme theme] menuBarHeight];
    self.timeMenuView = [[TimeMenuView alloc] initWithFrame:NSMakeRect(timeMenuX, 0, timeMenuWidth, menuBarHeight)];
    [self.timeMenuView setMenu:self.timeMenu];
    [self.timeMenuView setHorizontal:YES];
    [self.timeMenuView setAutoresizingMask:NSViewMinXMargin | NSViewMaxYMargin | NSViewMinYMargin];

    NSDebugLLog(@"gwcomp", @"MenuController: About to schedule time update timer");
    // Start timer to update time
    self.timeUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                        target:self
                                                      selector:@selector(updateTimeMenu)
                                                      userInfo:nil
                                                       repeats:YES];
    NSDebugLLog(@"gwcomp", @"MenuController: Timer scheduled successfully");
    [self updateTimeMenu];
    NSDebugLLog(@"gwcomp", @"MenuController: Initial time update called");
}

- (void)updateTimeMenu
{
    NSDate *now = [NSDate date];
    NSString *timeString = [self.timeFormatter stringFromDate:now];
    [self.timeMenuItem setTitle:timeString];
    NSString *dateString = [self.dateFormatter stringFromDate:now];
    [self.dateMenuItem setTitle:dateString];
}

- (void)animateMenuSlideIn
{
    const CGFloat menuBarHeight = [[GSTheme theme] menuBarHeight];
    
    // Start animation timer for smooth slide-in from above
    self.slideInStartTime = [NSDate timeIntervalSinceReferenceDate];
    self.slideInStartY = self.screenFrame.origin.y + self.screenSize.height + menuBarHeight;
    
    self.slideInAnimationTimer = [NSTimer scheduledTimerWithTimeInterval:0.016  // ~60fps
                                                                  target:self
                                                                selector:@selector(updateSlideInAnimation)
                                                                userInfo:nil
                                                                 repeats:YES];
    
    NSDebugLLog(@"gwcomp", @"MenuController: Menu slide-in animation started");
}

- (void)updateSlideInAnimation
{
    const CGFloat menuBarHeight = [[GSTheme theme] menuBarHeight];
    NSTimeInterval elapsed = [NSDate timeIntervalSinceReferenceDate] - self.slideInStartTime;
    NSTimeInterval duration = 0.3;
    
    if (elapsed >= duration) {
        // Animation complete
        [self.slideInAnimationTimer invalidate];
        self.slideInAnimationTimer = nil;
        
        // Set final position (place menu bar at very top of the screen)
        [self.menuBar setFrameTopLeftPoint:NSMakePoint(self.screenFrame.origin.x,
                                                        self.screenFrame.origin.y + self.screenSize.height)];
        [self revealAppMenuWidget];
        NSDebugLLog(@"gwcomp", @"MenuController: Menu slide-in animation completed");
    } else {
        // Calculate progress (0.0 to 1.0) using ease-out cubic for smooth deceleration
        CGFloat progress = elapsed / duration;
        progress = 1.0 - ((1.0 - progress) * (1.0 - progress) * (1.0 - progress));  // Ease-out cubic
        
        // Interpolate position from above screen to final position
        CGFloat currentY = self.slideInStartY - (progress * menuBarHeight);
        [self.menuBar setFrameTopLeftPoint:NSMakePoint(self.screenFrame.origin.x, currentY)];
    }
}

- (void)revealAppMenuWidget
{
    [self.appMenuWidget setHidden:NO];
    [self.appMenuWidget setNeedsDisplay:YES];
    NSDebugLLog(@"gwcomp", @"MenuController: AppMenuWidget revealed");
}

- (void)loadDesktopMenuIfAvailable
{
    NSDebugLLog(@"gwcomp", @"MenuController: Checking for Desktop/Workspace window to load default menu...");
    
    // Get all windows
    NSArray *windows = [MenuUtils getAllWindows];
    
    // Find the desktop window
    unsigned long desktopWindowId = 0;
    for (NSNumber *windowNum in windows) {
        unsigned long windowId = [windowNum unsignedLongValue];
        if ([MenuUtils isDesktopWindow:windowId]) {
            desktopWindowId = windowId;
            NSDebugLLog(@"gwcomp", @"MenuController: Found Desktop/Workspace window: 0x%lx", desktopWindowId);
            break;
        }
    }
    
    if (desktopWindowId == 0) {
        NSDebugLLog(@"gwcomp", @"MenuController: No Desktop/Workspace window found yet - will load when it appears");
        return;
    }
    
    // Check if this desktop window has a menu registered
    if ([[MenuProtocolManager sharedManager] hasMenuForWindow:desktopWindowId]) {
        NSDebugLLog(@"gwcomp", @"MenuController: Desktop/Workspace window has menu - loading it as default");
        // Load the desktop menu in the AppMenuWidget
        if (self.appMenuWidget) {
            [self.appMenuWidget displayMenuForWindow:desktopWindowId];
        }
    } else {
        NSDebugLLog(@"gwcomp", @"MenuController: Desktop/Workspace window found but no menu registered yet");
    }
}

@end
