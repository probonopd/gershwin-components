/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */


#import "MenuController.h"
#import "MenuBarView.h"
#import "AppMenuWidget.h"
#import "MenuProtocolManager.h"
#import "DBusMenuImporter.h"
#import "GTKMenuImporter.h"
#import "GNUStepMenuImporter.h"
#import "RoundedCornersView.h"
#import "X11ShortcutManager.h"
#import "ActionSearch.h"
#import "MenuUtils.h"
#import "StatusItemManager.h"
#import "StatusItemsView.h"
#import "StatusItemView.h"
#import "WindowMonitor.h"
#import "AppMenuImporter.h"
#import "MenuProfiler.h"
#import "GNUstepGUI/GSTheme.h"
#import <X11/Xlib.h>
#import <X11/Xatom.h>
#import <X11/Xutil.h>
#import <sys/select.h>
#if MENU_PROFILING
#import <sys/resource.h>
#endif
#import <errno.h>
#import <unistd.h>
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

@interface MenuController ()
@end

@implementation MenuController

#if MENU_PROFILING
static NSTimeInterval MenuControllerTimevalToSeconds(struct timeval value)
{
    return (NSTimeInterval)value.tv_sec + ((NSTimeInterval)value.tv_usec / 1000000.0);
}
#endif

// DBus file descriptor monitoring using NSFileHandle
// Minimum interval (seconds) between consecutive DBus fd notifications to prevent CPU spin
static NSTimeInterval _lastDbusNotificationTime = 0;
static NSUInteger _rapidDbusNotificationCount = 0;
#define DBUS_MIN_NOTIFICATION_INTERVAL 0.005   // 5ms minimum gap
#define DBUS_RAPID_FIRE_THRESHOLD 100          // number of rapid fires before back-off
#define DBUS_BACKOFF_INTERVAL 0.1              // 100ms cooldown after rapid fire

- (void)dbusFileDescriptorReady:(NSNotification *)notification {
    MENU_PROFILE_BEGIN(dbusFileDescriptorReady);

    // Always handle DBus traffic on the main thread to avoid races with UI work
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self dbusFileDescriptorReady:notification];
        });
        MENU_PROFILE_END(dbusFileDescriptorReady);
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
                        MENU_PROFILE_END(dbusFileDescriptorReady);
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

    MENU_PROFILE_END(dbusFileDescriptorReady);
}

- (void)rearmDbusFileHandle:(NSTimer *)timer
{
    MENU_PROFILE_BEGIN(rearmDbusFileHandle);

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

    MENU_PROFILE_END(rearmDbusFileHandle);
}

- (void)pollDBusMessages:(NSTimer *)timer
{
    MENU_PROFILE_BEGIN(pollDBusMessages);

    // Always handle DBus traffic on the main thread
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self pollDBusMessages:timer];
        });
        MENU_PROFILE_END(pollDBusMessages);
        return;
    }
    
    // Process any pending D-Bus messages
    @try {
        [[MenuProtocolManager sharedManager] processDBusMessages];
    }
    @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"MenuController: Exception polling DBus messages: %@", exception);
    }

    MENU_PROFILE_END(pollDBusMessages);
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
        
        NSDebugLLog(@"gwcomp", @"MenuController: Controller initialized successfully. Active window: 0x%lx", (unsigned long)[self.windowMonitor currentActiveWindow]);
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

- (NSArray *)menuBarX11Windows
{
    Display *display = [MenuUtils sharedDisplay];
    if (!display) {
        return @[];
    }

    pid_t pid = getpid();
    NSString *menuBarTitle = [self.menuBar title];
    NSArray *windows = [MenuUtils getAllWindows];
    NSMutableArray *candidates = [NSMutableArray array];
    const CGFloat menuBarHeight = [[GSTheme theme] menuBarHeight];

    // Discover directly from root children first. This catches windows even when
    // they are temporarily absent from _NET_CLIENT_LIST.
    Window root = DefaultRootWindow(display);
    Window rootRet = None;
    Window parentRet = None;
    Window *children = NULL;
    unsigned int nchildren = 0;
    if (XQueryTree(display, root, &rootRet, &parentRet, &children, &nchildren) != 0 && children) {
        unsigned int i;
        for (i = 0; i < nchildren; i++) {
            Window w = children[i];
            XWindowAttributes attrs;
            if (XGetWindowAttributes(display, w, &attrs) == 0 || attrs.map_state == IsUnmapped) {
                continue;
            }

            NSString *name = [MenuUtils getWindowProperty:(unsigned long)w atomName:@"_NET_WM_NAME"];
            if (!name || [name length] == 0) {
                name = [MenuUtils getWindowProperty:(unsigned long)w atomName:@"WM_NAME"];
            }
            if (!(menuBarTitle && [menuBarTitle length] > 0 && [name isEqualToString:menuBarTitle])) {
                continue;
            }

            // Prefer top-strip windows with bar-like geometry.
            if ((CGFloat)attrs.height > (menuBarHeight * 2.0) || attrs.width < 100) {
                continue;
            }

            NSNumber *candidate = [NSNumber numberWithUnsignedLong:(unsigned long)w];
            if (![candidates containsObject:candidate]) {
                [candidates addObject:candidate];
            }
        }
        XFree(children);
    }

    // Additional strategy: managed top-level clients titled like our menu bar.
    // Some WMs/backends do not expose _NET_WM_PID for this window.
    for (NSNumber *windowNum in windows) {
        unsigned long xid = [windowNum unsignedLongValue];
        NSString *name = [MenuUtils getWindowProperty:xid atomName:@"_NET_WM_NAME"];
        if (!name || [name length] == 0) {
            name = [MenuUtils getWindowProperty:xid atomName:@"WM_NAME"];
        }

        if (menuBarTitle && [menuBarTitle length] > 0 && [name isEqualToString:menuBarTitle]) {
            XWindowAttributes attrs;
            if (XGetWindowAttributes(display, (Window)xid, &attrs) != 0 && attrs.map_state != IsUnmapped) {
                [candidates addObject:[NSNumber numberWithUnsignedLong:xid]];
            }
        }
    }

    // Secondary strategy: include mapped dock-like windows from this process.
    Atom windowTypeAtom = XInternAtom(display, "_NET_WM_WINDOW_TYPE", False);
    Atom dockAtom = XInternAtom(display, "_NET_WM_WINDOW_TYPE_DOCK", False);
    for (NSNumber *windowNum in windows) {
        unsigned long xid = [windowNum unsignedLongValue];
        if ((pid_t)[MenuUtils getWindowPID:xid] != pid) {
            continue;
        }

        Atom actualType;
        int actualFormat;
        unsigned long nitems = 0;
        unsigned long bytesAfter = 0;
        unsigned char *prop = NULL;
        BOOL isDockType = NO;
        if (XGetWindowProperty(display, (Window)xid, windowTypeAtom, 0, 8, False, XA_ATOM,
                               &actualType, &actualFormat, &nitems, &bytesAfter, &prop) == Success && prop) {
            Atom *atoms = (Atom *)prop;
            unsigned long i;
            for (i = 0; i < nitems; i++) {
                if (atoms[i] == dockAtom) {
                    isDockType = YES;
                    break;
                }
            }
            XFree(prop);
        }

        if (isDockType) {
            XWindowAttributes attrs;
            if (XGetWindowAttributes(display, (Window)xid, &attrs) != 0 && attrs.map_state != IsUnmapped) {
                NSNumber *candidate = [NSNumber numberWithUnsignedLong:xid];
                if (![candidates containsObject:candidate]) {
                    [candidates addObject:candidate];
                }
            }
        }
    }

    // Fallback: include any visible top-level window from this process.
    for (NSNumber *windowNum in windows) {
        unsigned long xid = [windowNum unsignedLongValue];
        if ((pid_t)[MenuUtils getWindowPID:xid] != pid) {
            continue;
        }
        XWindowAttributes attrs;
        if (XGetWindowAttributes(display, (Window)xid, &attrs) != 0 && attrs.map_state != IsUnmapped) {
            NSNumber *candidate = [NSNumber numberWithUnsignedLong:xid];
            if (![candidates containsObject:candidate]) {
                [candidates addObject:candidate];
            }
        }
    }

    return candidates;
}

- (void)applyMenuBarDockAndStrutProperties
{
    const CGFloat menuBarHeight = [[GSTheme theme] menuBarHeight];
    Display *display = [MenuUtils sharedDisplay];
    if (!display) {
        NSDebugLLog(@"gwcomp", @"MenuController: Cannot open X11 display to apply menu bar struts");
        return;
    }

    if (!self.menuBar) {
        NSDebugLLog(@"gwcomp", @"MenuController: No menuBar window to apply X11 struts");
        return;
    }

    NSArray *menuBarWindows = [self menuBarX11Windows];
    if ([menuBarWindows count] == 0) {
        NSDebugLLog(@"gwcomp", @"MenuController: Could not resolve menu bar X11 window id yet");
        return;
    }

    Atom windowTypeAtom = XInternAtom(display, "_NET_WM_WINDOW_TYPE", False);
    Atom dockAtom = XInternAtom(display, "_NET_WM_WINDOW_TYPE_DOCK", False);
    Atom strutAtom = XInternAtom(display, "_NET_WM_STRUT", False);
    Atom strutPartialAtom = XInternAtom(display, "_NET_WM_STRUT_PARTIAL", False);
    Atom stateAtom = XInternAtom(display, "_NET_WM_STATE", False);
    Atom stickyAtom = XInternAtom(display, "_NET_WM_STATE_STICKY", False);
    Atom skipTaskbarAtom = XInternAtom(display, "_NET_WM_STATE_SKIP_TASKBAR", False);
    Atom skipPagerAtom = XInternAtom(display, "_NET_WM_STATE_SKIP_PAGER", False);
    Atom stateAtoms[3] = {stickyAtom, skipTaskbarAtom, skipPagerAtom};

    Window root = DefaultRootWindow(display);
    for (NSNumber *candidate in menuBarWindows) {
        Window menuBarWindow = (Window)[candidate unsignedLongValue];
        XWindowAttributes attrs;
        if (XGetWindowAttributes(display, menuBarWindow, &attrs) == 0 || attrs.map_state == IsUnmapped) {
            continue;
        }

        Window child = None;
        int rootX = 0;
        int rootY = 0;
        if (XTranslateCoordinates(display, menuBarWindow, root, 0, 0, &rootX, &rootY, &child) == False) {
            rootX = attrs.x;
            rootY = attrs.y;
        }

        unsigned int width = (unsigned int)MAX((CGFloat)1.0, (CGFloat)attrs.width);
        unsigned int height = (unsigned int)MAX((CGFloat)1.0, (CGFloat)attrs.height);
        unsigned long startX = (rootX < 0) ? 0 : (unsigned long)rootX;
        unsigned long endX = startX + (unsigned long)width - 1;
        unsigned long topStrut = (rootY < 0) ? (unsigned long)height : (unsigned long)(rootY + (int)height);
        unsigned int fallbackHeight = (unsigned int)MAX((CGFloat)1.0, menuBarHeight);
        if (topStrut == 0) {
            topStrut = fallbackHeight;
        }

        XChangeProperty(display, menuBarWindow, windowTypeAtom, XA_ATOM, 32,
                        PropModeReplace, (unsigned char *)&dockAtom, 1);

        unsigned long strut[4] = {0, 0, topStrut, 0};
        unsigned long strutPartial[12] = {0, 0, topStrut, 0,
                                          0, 0, 0, 0,
                                          startX, endX, 0, 0};
        XChangeProperty(display, menuBarWindow, strutAtom, XA_CARDINAL, 32,
                        PropModeReplace, (unsigned char *)strut, 4);
        XChangeProperty(display, menuBarWindow, strutPartialAtom, XA_CARDINAL, 32,
                        PropModeReplace, (unsigned char *)strutPartial, 12);

        XChangeProperty(display, menuBarWindow, stateAtom, XA_ATOM, 32,
                        PropModeReplace, (unsigned char *)stateAtoms, 3);

        NSDebugLLog(@"gwcomp", @"MenuController: Applied dock/strut properties to XID 0x%lx (root=(%d,%d) size=%ux%u top=%lu x-range=%lu..%lu)",
              (unsigned long)menuBarWindow, rootX, rootY, width, height, topStrut, startX, endX);
    }

    XSync(display, False);
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

    // Keep EWMH dock/strut properties synchronized with current geometry.
    [self applyMenuBarDockAndStrutProperties];

    // Redraw
    [self.menuBar display];
    NSDebugLLog(@"gwcomp", @"MenuController: Menu bar repositioned successfully");
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
    MENU_PROFILE_BEGIN(applicationDidFinishLaunching);
    
    NSDebugLLog(@"gwcomp", @"MenuController: Application did finish launching");
    
    [self.menuBar orderFront:self];
    [self setupWindowMonitoring];
    
    NSDebugLLog(@"gwcomp", @"MenuController: Application setup complete");
#if MENU_PROFILING
    [self startCPUUsageLogging];
#endif
    
    // Register D-Bus service immediately - run loop is active
    NSDebugLLog(@"gwcomp", @"MenuController: Registering D-Bus service now...");
    
    // Call directly instead of using dispatch_async - the main queue might not process async blocks reliably
    [self registerDBusServiceWhenReady];
    
    MENU_PROFILE_END(applicationDidFinishLaunching);
}

#if MENU_PROFILING
- (void)startCPUUsageLogging
{
    struct rusage usage;

    if (getrusage(RUSAGE_SELF, &usage) != 0) {
        NSDebugLLog(@"gwcomp", @"MenuController: Failed to initialize CPU usage logging");
        return;
    }

        [self stopCPUUsageLogging];
    self.lastCpuUsageSampleWallTime = [NSDate timeIntervalSinceReferenceDate];
    self.lastCpuUsageSampleUserTime = MenuControllerTimevalToSeconds(usage.ru_utime);
    self.lastCpuUsageSampleSystemTime = MenuControllerTimevalToSeconds(usage.ru_stime);
        self.cpuUsageLogTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                                                                                         target:self
                                                                                                                     selector:@selector(logCPUUsageSample:)
                                                                                                                     userInfo:nil
                                                                                                                        repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:self.cpuUsageLogTimer forMode:NSRunLoopCommonModes];
}

- (void)stopCPUUsageLogging
{
    if (self.cpuUsageLogTimer) {
        [self.cpuUsageLogTimer invalidate];
        self.cpuUsageLogTimer = nil;
    }
}

- (void)logCPUUsageSample:(NSTimer *)timer
{
    (void)timer;

    struct rusage usage;
    if (getrusage(RUSAGE_SELF, &usage) != 0) {
        return;
    }

    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    NSTimeInterval userTime = MenuControllerTimevalToSeconds(usage.ru_utime);
    NSTimeInterval systemTime = MenuControllerTimevalToSeconds(usage.ru_stime);
    NSTimeInterval wallDelta = now - self.lastCpuUsageSampleWallTime;
    NSTimeInterval userDelta = userTime - self.lastCpuUsageSampleUserTime;
    NSTimeInterval systemDelta = systemTime - self.lastCpuUsageSampleSystemTime;
    NSTimeInterval cpuDelta = userDelta + systemDelta;

    if (wallDelta > 0) {
        double cpuPercent = (cpuDelta / wallDelta) * 100.0;
        unsigned long activeWindowId = [[WindowMonitor sharedMonitor] getActiveWindow];
        unsigned long shownWindowId = self.appMenuWidget ? self.appMenuWidget.currentWindowId : 0UL;
        if (wallDelta > 1.5) {
            NSLog(@"[CPU] delayed sample last %.2fs total=%.2f%% user=%.2fms sys=%.2fms active=0x%lx shown=0x%lx",
                  wallDelta,
                  cpuPercent,
                  userDelta * 1000.0,
                  systemDelta * 1000.0,
                  activeWindowId,
                  shownWindowId);
        } else {
            NSLog(@"[CPU] last %.2fs total=%.2f%% user=%.2fms sys=%.2fms active=0x%lx shown=0x%lx",
                  wallDelta,
                  cpuPercent,
                  userDelta * 1000.0,
                  systemDelta * 1000.0,
                  activeWindowId,
                  shownWindowId);
        }
    }

    self.lastCpuUsageSampleWallTime = now;
    self.lastCpuUsageSampleUserTime = userTime;
    self.lastCpuUsageSampleSystemTime = systemTime;
}
#endif

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
#if MENU_PROFILING
    [self stopCPUUsageLogging];
#endif
    
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
    
    // Reserve top-of-screen work area directly on the actual menu bar window.
    [self applyMenuBarDockAndStrutProperties];

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
    // Re-apply several times after mapping so WMs that process struts only after
    // specific map/property transitions reliably observe the reservation.
    [self performSelector:@selector(applyMenuBarDockAndStrutProperties) withObject:nil afterDelay:0.05];
    [self performSelector:@selector(applyMenuBarDockAndStrutProperties) withObject:nil afterDelay:0.2];
    [self performSelector:@selector(applyMenuBarDockAndStrutProperties) withObject:nil afterDelay:0.5];
    [self performSelector:@selector(applyMenuBarDockAndStrutProperties) withObject:nil afterDelay:1.0];
    [self performSelector:@selector(applyMenuBarDockAndStrutProperties) withObject:nil afterDelay:2.0];

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
    MENU_PROFILE_BEGIN(updateActiveWindow);

    // Get the currently active window and update app menu
    if (self.appMenuWidget) {
        [self.appMenuWidget updateForActiveWindow];
    } else {
        NSDebugLLog(@"gwcomp", @"MenuController: self.appMenuWidget is nil");
    }

    MENU_PROFILE_END(updateActiveWindow);
}

- (void)initializeProtocols
{
    MENU_PROFILE_BEGIN(initializeProtocols);

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

    MENU_PROFILE_END(initializeProtocols);
}

- (void)createProtocolManager
{
    NSDebugLLog(@"gwcomp", @"MenuController: Creating MenuProtocolManager...");
    self.protocolManager = [MenuProtocolManager sharedManager];
    
    // Register both Canonical and GTK protocol handlers
    GNUStepMenuImporter *gnustepHandler = [[GNUStepMenuImporter alloc] init];
    DBusMenuImporter *canonicalHandler = [[DBusMenuImporter alloc] init];
    GTKMenuImporter *gtkHandler = [[GTKMenuImporter alloc] init];
    
    [self.protocolManager registerProtocolHandler:gnustepHandler forType:MenuProtocolTypeGNUstep];
    [self.protocolManager registerProtocolHandler:canonicalHandler forType:MenuProtocolTypeCanonical];
    [self.protocolManager registerProtocolHandler:gtkHandler forType:MenuProtocolTypeGTK];
    
    NSDebugLLog(@"gwcomp", @"MenuController: Registered GNUstep, Canonical, and GTK protocol handlers");
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
    self.windowValidationTimer = [NSTimer scheduledTimerWithTimeInterval:5.0
                                                                  target:self
                                                                selector:@selector(windowValidationTick:)
                                                                userInfo:nil
                                                                 repeats:YES];
    
    NSDebugLLog(@"gwcomp", @"MenuController: Window monitoring setup complete");
}

- (void)activeWindowChangedNotification:(NSNotification *)notification
{
    MENU_PROFILE_BEGIN(activeWindowChangedNotification);

    NSNumber *windowIdNum = notification.userInfo[@"windowId"];
    unsigned long windowId = windowIdNum ? [windowIdNum unsignedLongValue] : 0;

    /* Track no-window → window transitions for modal recovery. */
    if (windowId == 0) {
        self.lastWindowStateWasZero = YES;
    }
    BOOL justRecoveredFromModal = self.lastWindowStateWasZero && windowId != 0;
    if (justRecoveredFromModal) {
        self.lastWindowStateWasZero = NO;
    }

    /* Fast-path dedup: same window, menu still valid, not recovering from modal. */
    if (windowId != 0 && !justRecoveredFromModal &&
        windowId == self.lastProcessedWindowId &&
        self.appMenuWidget && self.appMenuWidget.currentWindowId == windowId &&
        self.appMenuWidget.currentMenu != nil && self.appMenuWidget.menuView != nil &&
        ![self.appMenuWidget.menuView isHidden]) {
        NSDebugLLog(@"gwcomp", @"MenuController: [DEDUP-SKIP] win=0x%lx same window & menu OK", windowId);
        MENU_PROFILE_END(activeWindowChangedNotification);
        return;
    }

    /* Ignore focus on Menu.app itself. */
    if (windowId != 0 && [NSApp windowWithWindowNumber:windowId] != nil) {
        MENU_PROFILE_END(activeWindowChangedNotification);
        return;
    }

    self.lastProcessedWindowId = windowId;
    self.lastProcessedTime = [[NSDate date] timeIntervalSince1970];

    /* Forward to AppMenuWidget's coalescing update path.
       The widget handles all timing, retry, and dedup internally. */
    if (self.appMenuWidget) {
        [self.appMenuWidget updateForActiveWindowId:windowId];
    }

    MENU_PROFILE_END(activeWindowChangedNotification);
}

- (void)windowValidationTick:(NSTimer *)timer
{
    MENU_PROFILE_BEGIN(windowValidationTick);

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

        if (!self.appMenuWidget) {
            MENU_PROFILE_END(windowValidationTick);
            return;
        }

        unsigned long shownWindow = self.appMenuWidget.currentWindowId;
        if (shownWindow == 0) {
            MENU_PROFILE_END(windowValidationTick);
            return;
        } // no menu shown

        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];

        // CRITICAL FIX: Only validate the shown window if it's still the active window
        // If we've switched to a different window, don't clear the menu for the OLD window
        if (activeWindow != 0 && shownWindow != activeWindow) {
            // We've switched to a different window - the shown window ID is stale
            // Don't validate it, let the normal window change handling take care of it
            MENU_PROFILE_END(windowValidationTick);
            return;
        }

        // CRITICAL: If shown window IS the active window AND we have a menu for it, DON'T clear it!
        // The window manager says this is the active window, so trust that it exists
        // Only clear if we have NO menu (meaning menu failed to load/register)
        if (shownWindow == activeWindow && self.appMenuWidget.currentMenu != nil) {
            // We have a menu for the current active window - keep it!
            // Don't validate with X11 calls that might fail during WM operations
            MENU_PROFILE_END(windowValidationTick);
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
            MENU_PROFILE_END(windowValidationTick);
            return;
        }

        // If the system reports no active window, but we have a menu for one, hide it
        if (activeWindow == 0 && shownWindow != 0) {
            NSDebugLLog(@"gwcomp", @"MenuController: Active window is 0 but menu shown for 0x%lx - clearing menu", shownWindow);
            [self.appMenuWidget clearMenuAndHideView];
            self.lastClearedWindowId = shownWindow;
            self.lastClearedTime = now;
            self.lastClearSuppressUntil = 0;
            MENU_PROFILE_END(windowValidationTick);
            return;
        }
    }
    @catch (NSException *ex) {
        NSDebugLLog(@"gwcomp", @"MenuController: Exception in windowValidationTick: %@", ex);
    }

    MENU_PROFILE_END(windowValidationTick);
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
    MENU_PROFILE_BEGIN(scanForNewMenus);

    NSDebugLLog(@"gwcomp", @"MenuController: Scanning for new menu services");
    
    [[MenuProtocolManager sharedManager] scanForExistingMenuServices];
    
    // Force an immediate update of the current window to check if it now has a menu
    if (self.appMenuWidget) {
        [self.appMenuWidget updateForActiveWindow];
    }

    MENU_PROFILE_END(scanForNewMenus);
}

#pragma mark - WindowMonitorDelegate

- (void)activeWindowChanged:(unsigned long)windowId
{
    MENU_PROFILE_BEGIN(activeWindowChanged);

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

    MENU_PROFILE_END(activeWindowChanged);
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
        [self applyMenuBarDockAndStrutProperties];
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
