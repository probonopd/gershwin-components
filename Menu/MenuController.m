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
#import "MenuExtraManager.h"
#import "WindowMonitor.h"
#import "AppMenuImporter.h"
#import "MenuProfiler.h"
#import "BacklightBackend.h"
#import "BrightnessKeySource.h"
#import "SysfsBacklightBackend.h"
#import "EvdevBrightnessKeySource.h"
#import "ALSABackend.h"
#import "SystemActions.h"

@interface GSVolumeControl : NSObject
+ (void)increaseVolume;
+ (void)decreaseVolume;
+ (void)toggleMute;
+ (void)toggleMicMute;
@end

@implementation GSVolumeControl
+ (ALSABackend *)sharedBackend
{
    static ALSABackend *b = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        b = [[ALSABackend alloc] init];
    });
    return b;
}
+ (void)increaseVolume
{
    ALSABackend *b = [self sharedBackend];
    float vol = [b outputVolume];
    vol += 0.05f;
    if (vol > 1.0f) vol = 1.0f;
    [b setOutputVolume:vol];
}
+ (void)decreaseVolume
{
    ALSABackend *b = [self sharedBackend];
    float vol = [b outputVolume];
    vol -= 0.05f;
    if (vol < 0.0f) vol = 0.0f;
    [b setOutputVolume:vol];
}
+ (void)toggleMute
{
    ALSABackend *b = [self sharedBackend];
    [b setOutputMuted:![b isOutputMuted]];
}
+ (void)toggleMicMute
{
    ALSABackend *b = [self sharedBackend];
    [b setInputMuted:![b isInputMuted]];
}
@end
#import "GNUstepGUI/GSTheme.h"
#include <GNUstepGUI/GSDisplayServer.h>
#import <X11/Xlib.h>
#import <X11/XF86keysym.h>
#import <X11/Xatom.h>
#import <X11/Xutil.h>
#import <sys/select.h>
#if MENU_PROFILING
#import <sys/resource.h>
#endif
#import <errno.h>
#import <unistd.h>
#import <poll.h>
#import <fcntl.h>
#ifdef __linux__
#import <linux/input.h>
#endif
#import <dispatch/dispatch.h>

// Shared debounce timestamp for brightness adjustments.
// Both the evdev handler and XF86 key handler can fire for the same
// physical keypress; we skip if either path handled within 200 ms.
static NSTimeInterval _lastBrightnessAdjust = 0;

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
{
    id<BacklightBackend> _backlightBackend;
    id<BrightnessKeySource> _brightnessKeySource;
    NSThread *_micMuteThread;
    volatile BOOL _micMuteMonitorRunning;
    int _micMuteFDs[16];
    int _micMuteFDCount;
    NSThread *_powerKeyThread;
    volatile BOOL _powerKeyMonitorRunning;
    int _powerKeyFDs[16];
    int _powerKeyFDCount;
}
@end

@implementation MenuController

static CGFloat MenuControllerLastScaleFactor = 1.0;

/* Current GSScaleFactor (1.0 when unset or non-positive). */
static CGFloat MenuControllerScaleFactor(void)
{
  CGFloat factor = [[NSUserDefaults standardUserDefaults] floatForKey:@"GSScaleFactor"];
  return (factor > 0.0) ? factor : 1.0;
}

/* True physical screen width queried directly from X11 - GSScaleFactor is
 * never applied to it, unlike the screen size GNUstep may report. */
static CGFloat MenuControllerScreenWidth(void)
{
  Display *display = XOpenDisplay(NULL);
  if (display == NULL)
    {
      return [[[NSScreen screens] objectAtIndex:0] frame].size.width;
    }
  int width = DisplayWidth(display, DefaultScreen(display));
  XCloseDisplay(display);
  return (CGFloat)width;
}

/* Menu bar height scaled by GSScaleFactor: the bar keeps its full screen
 * width but its height grows/shrinks with the scale factor. */
static CGFloat MenuControllerMenuBarHeight(void)
{
  return [[GSTheme theme] menuBarHeight] * MenuControllerScaleFactor();
}

#if MENU_PROFILING
static NSTimeInterval MenuControllerTimevalToSeconds(struct timeval value)
{
    return (NSTimeInterval)value.tv_sec + ((NSTimeInterval)value.tv_usec / 1000000.0);
}
#endif

// Minimum delay (seconds) between DBus fd re-arms.
// Prevents CPU tight-loop when GNUstep NSFileHandle fires
// continuously because the DBus socket is always readable
// (libdbus internal buffering keeps select() returning "ready").
#define DBUS_REARM_DELAY 0.1

// Maximum throttle delay (seconds) when DBus fd fires but no messages arrive
#define DBUS_MAX_THROTTLE_DELAY 2.0

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

    // Throttle if DBus fd keeps firing with no messages
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now < self.dbusThrottleUntil) {
        // Skip processing but still schedule re-arm after throttle delay
        [NSObject cancelPreviousPerformRequestsWithTarget:self
                                                 selector:@selector(rearmDBusSource)
                                                   object:nil];
        [self performSelector:@selector(rearmDBusSource)
                   withObject:nil
                   afterDelay:(self.dbusThrottleUntil - now)];
        MENU_PROFILE_END(dbusFileDescriptorReady);
        return;
    }

    NSDebugLog(@"MenuController: DBus file descriptor reported data available");

    // Lock the menu window from redrawing during DBus processing to prevent flashing
    [self.menuBar disableFlushWindow];

    NSUInteger messageCountBefore = [[MenuProtocolManager sharedManager] pendingMessageCount];
    @try {
        [[MenuProtocolManager sharedManager] processDBusMessages];
    }
    @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"MenuController: Exception processing DBus messages: %@", exception);
    }

    // Re-enable window drawing and flush all pending updates at once
    [self.menuBar enableFlushWindow];
    [self.menuBar flushWindow];

    NSUInteger messageCountAfter = [[MenuProtocolManager sharedManager] pendingMessageCount];
    BOOL gotMessages = (messageCountAfter > messageCountBefore);

    // If fd fired but we got no messages, implement exponential backoff
    if (!gotMessages) {
        self.dbusEmptyProcessingCount++;
        if (self.dbusEmptyProcessingCount > 3) {
            // Exponential backoff: 0.1 -> 0.2 -> 0.4 -> 0.8 -> 1.6 -> 2.0 (capped)
            NSTimeInterval backoffDelay = MIN(DBUS_REARM_DELAY * (1 << (self.dbusEmptyProcessingCount - 3)), DBUS_MAX_THROTTLE_DELAY);
            self.dbusThrottleUntil = now + backoffDelay;
            NSDebugLLog(@"gwcomp", @"MenuController: DBus throttle backing off to %.1fs (empty count=%lu)",
                        backoffDelay, (unsigned long)self.dbusEmptyProcessingCount);
        }
    } else {
        // Got messages - reset throttle state
        if (self.dbusEmptyProcessingCount > 0) {
            NSDebugLLog(@"gwcomp", @"MenuController: DBus throttle reset (was %lu empty cycles)",
                        (unsigned long)self.dbusEmptyProcessingCount);
        }
        self.dbusEmptyProcessingCount = 0;
        self.dbusThrottleUntil = 0;
    }

    // Delay re-arm to prevent CPU tight-loop.  The DBus fd is almost always
    // "ready to read" on GNUstep (libdbus buffers internally), so immediate
    // re-arm would fire again on the very next run-loop iteration, spinning
    // the CPU indefinitely.  A short delay breaks the cycle while keeping
    // DBus message latency under 150 ms — more than adequate for menu updates.
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(rearmDBusSource)
                                               object:nil];
    NSTimeInterval rearmDelay = gotMessages ? DBUS_REARM_DELAY : MAX(DBUS_REARM_DELAY, self.dbusThrottleUntil - now);
    [self performSelector:@selector(rearmDBusSource)
               withObject:nil
               afterDelay:rearmDelay];

    MENU_PROFILE_END(dbusFileDescriptorReady);
}

- (void)rearmDBusSource
{
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
    const CGFloat menuBarHeight = MenuControllerMenuBarHeight();

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
            /* Transient override-redirect windows (dropdown menus, popups,
               tooltips) are never the menu bar; skip before querying them. */
            if (attrs.override_redirect) {
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
            // menuBarHeight already accounts for GSScaleFactor.
            {
                if ((CGFloat)attrs.height > (menuBarHeight * 2.0) || attrs.width < 100) {
                    continue;
                }
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

/* Resolve the menu bar's X11 window ID directly from the GNUstep display
   server.  This is far more reliable than searching root children by
   title/geometry, which can fail when GSScaleFactor causes the X11 window
   height to exceed heuristic filters.  Returns 0 when the bar does not exist
   or is not yet mapped. */
- (Window)menuBarX11Window
{
    if (!self.menuBar) {
        NSDebugLLog(@"gwcomp", @"MenuController: No menuBar window to resolve X11 window for");
        return (Window)0;
    }

    GSDisplayServer *srv = GSServerForWindow(self.menuBar);
    if (!srv)
        srv = GSCurrentServer();
    if (!srv) {
        NSDebugLLog(@"gwcomp", @"MenuController: No GSDisplayServer available for strut setup");
        return (Window)0;
    }

    int winNum = [self.menuBar windowNumber];
    if (winNum <= 0) {
        NSDebugLLog(@"gwcomp", @"MenuController: menuBar windowNumber is %d, not mapped yet", winNum);
        return (Window)0;
    }

    Window menuBarWindow = (Window)(uintptr_t)[srv windowDevice: winNum];
    if (menuBarWindow == (Window)0) {
        NSDebugLLog(@"gwcomp", @"MenuController: Could not resolve X11 window from windowNumber %d", winNum);
        return (Window)0;
    }
    return menuBarWindow;
}

/* Clear the EWMH strut properties so the window manager releases the screen
   area the menu bar reserved.  This must be done BEFORE the bar is moved or
   resized on a screen geometry or scale-factor change; the struts are only
   re-applied (applyMenuBarDockAndStrutProperties) once the bar has been
   repositioned and resized, so the WM never keeps stale reserved space. */
- (void)removeMenuBarStruts
{
    Display *display = [MenuUtils sharedDisplay];
    if (!display) {
        NSDebugLLog(@"gwcomp", @"MenuController: Cannot open X11 display to clear menu bar struts");
        return;
    }

    Window menuBarWindow = [self menuBarX11Window];
    if (menuBarWindow == (Window)0) {
        NSDebugLLog(@"gwcomp", @"MenuController: No menu bar X11 window to clear struts");
        return;
    }

    unsigned long zero[4] = {0, 0, 0, 0};
    unsigned long zeroPartial[12] = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0};
    XChangeProperty(display, menuBarWindow,
                    XInternAtom(display, "_NET_WM_STRUT", False),
                    XA_CARDINAL, 32, PropModeReplace,
                    (unsigned char *)zero, 4);
    XChangeProperty(display, menuBarWindow,
                    XInternAtom(display, "_NET_WM_STRUT_PARTIAL", False),
                    XA_CARDINAL, 32, PropModeReplace,
                    (unsigned char *)zeroPartial, 12);
    XSync(display, False);

    NSDebugLLog(@"gwcomp", @"MenuController: Cleared menu bar struts on XID 0x%lx",
                (unsigned long)menuBarWindow);
}

- (void)applyMenuBarDockAndStrutProperties
{
    Display *display = [MenuUtils sharedDisplay];
    if (!display) {
        NSDebugLLog(@"gwcomp", @"MenuController: Cannot open X11 display to apply menu bar struts");
        return;
    }

    Window menuBarWindow = [self menuBarX11Window];
    if (menuBarWindow == (Window)0) {
        NSDebugLLog(@"gwcomp", @"MenuController: No menu bar X11 window for strut setup");
        return;
    }

    XWindowAttributes attrs;
    if (XGetWindowAttributes(display, menuBarWindow, &attrs) == 0 || attrs.map_state == IsUnmapped) {
        NSDebugLLog(@"gwcomp", @"MenuController: Menu bar X11 window 0x%lx not yet mapped",
                    (unsigned long)menuBarWindow);
        return;
    }

    /* The strut must reserve the strip where the bar is SUPPOSED to be - the
     * top of the primary screen - not where the window currently happens to
     * be.  Right after a resolution change the GNUstep backend can still
     * convert coordinates using the previous screen height, briefly placing
     * the bar at a wrong Y; deriving the strut from that transient position
     * (as XTranslateCoordinates would) leaves a stale, oversized strut. */
    unsigned int width = (unsigned int)MAX((CGFloat)1.0, (CGFloat)attrs.width);
    unsigned int height = (unsigned int)MAX((CGFloat)1.0, (CGFloat)attrs.height);
    unsigned long startX = (self.screenFrame.origin.x < 0)
        ? 0 : (unsigned long)self.screenFrame.origin.x;
    unsigned long endX = startX + (unsigned long)width - 1;
    unsigned long topStrut = (self.screenFrame.origin.y < 0)
        ? (unsigned long)height
        : (unsigned long)(self.screenFrame.origin.y + (int)height);
    const CGFloat menuBarHeight = MenuControllerMenuBarHeight();
    unsigned int fallbackHeight = (unsigned int)MAX((CGFloat)1.0, menuBarHeight);
    if (topStrut == 0) {
        topStrut = fallbackHeight;
    }

    unsigned long strut[4] = {0, 0, topStrut, 0};
    unsigned long strutPartial[12] = {0, 0, topStrut, 0,
                                      0, 0, 0, 0,
                                      startX, endX, 0, 0};

    Atom strutAtom = XInternAtom(display, "_NET_WM_STRUT", False);
    Atom strutPartialAtom = XInternAtom(display, "_NET_WM_STRUT_PARTIAL", False);
    XChangeProperty(display, menuBarWindow, strutAtom, XA_CARDINAL, 32,
                    PropModeReplace, (unsigned char *)strut, 4);
    XChangeProperty(display, menuBarWindow, strutPartialAtom, XA_CARDINAL, 32,
                    PropModeReplace, (unsigned char *)strutPartial, 12);

    Atom stateAtom = XInternAtom(display, "_NET_WM_STATE", False);
    Atom stickyAtom = XInternAtom(display, "_NET_WM_STATE_STICKY", False);
    Atom skipTaskbarAtom = XInternAtom(display, "_NET_WM_STATE_SKIP_TASKBAR", False);
    Atom skipPagerAtom = XInternAtom(display, "_NET_WM_STATE_SKIP_PAGER", False);
    Atom stateAtoms[3] = {stickyAtom, skipTaskbarAtom, skipPagerAtom};
    XChangeProperty(display, menuBarWindow, stateAtom, XA_ATOM, 32,
                    PropModeReplace, (unsigned char *)stateAtoms, 3);

    // Explicitly set _NET_WM_WINDOW_TYPE_DOCK so the WM treats this
    // window as a panel/dock (reserves space, keeps above, etc.).
    Atom wmTypeAtom = XInternAtom(display, "_NET_WM_WINDOW_TYPE", False);
    Atom dockAtom = XInternAtom(display, "_NET_WM_WINDOW_TYPE_DOCK", False);
    XChangeProperty(display, menuBarWindow, wmTypeAtom, XA_ATOM, 32,
                    PropModeReplace, (unsigned char *)&dockAtom, 1);

    XSync(display, False);

    NSLog(@"MenuController: Applied strut properties to XID 0x%lx "
          @"(size=%ux%u top=%lu x-range=%lu..%lu)",
          (unsigned long)menuBarWindow, width, height,
          topStrut, startX, endX);
}

- (void)extrasEnabledSetDidChange:(NSNotification *)notification
{
    CGFloat extrasWidth = [self.menuExtraManager extrasMenuWidth];
    CGFloat menuBarW = NSWidth([self.menuBarView bounds]);
    CGFloat widgetWidth = menuBarW - extrasWidth - 8;
    [self.appMenuWidget setFrameSize:NSMakeSize(widgetWidth, NSHeight([self.appMenuWidget frame]))];
    [self.menuBarView setNeedsDisplay:YES];
}

- (void)checkScaleFactor:(NSTimer *)timer
{
    // GNUstep caches defaults per-process; synchronize re-reads the store so
    // external writes (defaults tool, Display prefPane) become visible.
    [[NSUserDefaults standardUserDefaults] synchronize];

    CGFloat factor = [[NSUserDefaults standardUserDefaults] floatForKey:@"GSScaleFactor"];
    if (factor == 0.0)
        factor = 1.0;

    if (factor == MenuControllerLastScaleFactor)
        return;

    NSDebugLLog(@"gwcomp", @"MenuController: GSScaleFactor changed from %.3f to %.3f", MenuControllerLastScaleFactor, factor);
    MenuControllerLastScaleFactor = factor;
    [self screenParametersChanged: nil];
}

- (void)screenParametersChanged:(NSNotification *)notification
{
    NSDebugLLog(@"gwcomp", @"MenuController: Screen parameters changed, repositioning menu bar");

    if (!self.menuBar) {
        NSDebugLLog(@"gwcomp", @"MenuController: Menu bar not yet created, skipping reposition");
        return;
    }

    /* First release the screen area the old struts reserved, so the window
     * manager does not keep stale space while we move and resize the bar
     * below.  The struts are re-applied at the end once the bar is in place. */
    [self removeMenuBarStruts];

    // Re-read the primary screen geometry (screens[0] is the xrandr primary;
    // mainScreen may return the menu's own window screen which is circular).
    // Use the true X11 width so GSScaleFactor cannot change the bar's width.
    NSRect sf = [[[NSScreen screens] objectAtIndex:0] frame];
    sf.size.width = MenuControllerScreenWidth();
    self.screenFrame = sf;
    self.screenSize = sf.size;
    NSDebugLLog(@"gwcomp", @"MenuController: New screen frame: %.0f,%.0f %.0fx%.0f (scale=%.1f)",
          sf.origin.x, sf.origin.y,
          sf.size.width, sf.size.height, MenuControllerScaleFactor());

    /* Content views live in the window's user coordinate space, which GNUstep
     * scales by GSScaleFactor when rendering (device = user * sf).  Size them
     * in that space so they render to the device window size; the window frame
     * itself is set to the device size below. */
    CGFloat scale = MenuControllerScaleFactor();
    CGFloat contentW = MenuControllerScreenWidth() / scale;
    CGFloat contentH = [[GSTheme theme] menuBarHeight];

    // Reposition and resize the menu bar window using the screen frame origin
    // (the origin may be non-zero if the virtual desktop geometry changed)
    [self positionMenuBarWindow];

    // Resize the background view
    [self.menuBarView setFrame:NSMakeRect(0, 0, contentW, contentH)];

    // Reposition menu extras at the right edge
    NSView *extrasMenuView = nil;
    for (NSView *subview in [self.menuBarView subviews]) {
        if ([subview isKindOfClass:[NSMenuView class]]) {
            extrasMenuView = subview;
            break;
        }
    }

    CGFloat extrasMenuWidth = [self.menuExtraManager extrasMenuWidth];
    if (extrasMenuView) {
        [extrasMenuView setFrame:NSMakeRect(contentW - extrasMenuWidth - 8, 0,
                                            extrasMenuWidth, contentH)];
    }

    // Resize app menu widget to fill remaining space
    CGFloat menuWidgetWidth = contentW - extrasMenuWidth - 8;
    [self.appMenuWidget setFrame:NSMakeRect(0, 0, menuWidgetWidth, contentH)];

    // Re-layout the menu items so they reflow to the new bar width/height
    // (fonts/images scale with GSScaleFactor, changing item widths).
    [self.appMenuWidget.menuView sizeToFit];
    [self.appMenuWidget setNeedsDisplay:YES];

    // Resize rounded corners view
    CGFloat cornerHeight = 10.0;
    [self.roundedCornersView setFrame:NSMakeRect(0, contentH - cornerHeight,
                                                  contentW, cornerHeight)];

    // Update the MenuExtraManager's cached screen width
    [self.menuExtraManager setScreenWidth:self.screenSize.width];

    // Keep EWMH dock/strut properties synchronized with current geometry.
    [self applyMenuBarDockAndStrutProperties];

    // Redraw
    [self.menuBar display];
    NSDebugLLog(@"gwcomp", @"MenuController: Menu bar repositioned successfully");

    /* The GNUstep backend may still convert GNUstep -> X11 coordinates with
     * the previous screen height right after a resolution change, misplacing
     * the bar.  Re-apply the position once the backend has settled. */
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(repositionMenuBarAfterScreenChange)
                                               object:nil];
    [self performSelector:@selector(repositionMenuBarAfterScreenChange)
               withObject:nil
               afterDelay:0.5];
}

- (void)positionMenuBarWindow
{
    const CGFloat menuBarHeight = MenuControllerMenuBarHeight();
    CGFloat originX = self.screenFrame.origin.x;
    CGFloat originY = self.screenFrame.origin.y;
    NSRect menuRect = NSMakeRect(originX,
                                 originY + self.screenSize.height - menuBarHeight,
                                 self.screenSize.width, menuBarHeight);
    [self.menuBar setFrame:menuRect display:NO];
    [self.menuBar setFrameTopLeftPoint:NSMakePoint(originX, originY + self.screenSize.height)];
}

- (void)repositionMenuBarAfterScreenChange
{
    /* Same ordering as in screenParametersChanged:: clear the struts first,
       reposition, then re-apply them. */
    [self removeMenuBarStruts];
    [self positionMenuBarWindow];
    [self applyMenuBarDockAndStrutProperties];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
    MENU_PROFILE_BEGIN(applicationDidFinishLaunching);
    
    NSDebugLLog(@"gwcomp", @"MenuController: Application did finish launching");
    
    [self.menuBar orderFront:self];
    [self setupBacklightControl];
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
        /* Track how many GNUstep windows have cached menus: this must stay
           bounded.  Growth across a long session indicates windows closing
           without unregistering (crash/no DO unregister); the importer's
           reconcileMenusWithLiveWindows: sweep purges those. */
        NSUInteger cachedMenuCount = [GNUStepMenuImporter cachedMenuCount];
        if (wallDelta > 1.5) {
            NSLog(@"[CPU] delayed sample last %.2fs total=%.2f%% user=%.2fms sys=%.2fms active=0x%lx shown=0x%lx menus=%lu",
                  wallDelta,
                  cpuPercent,
                  userDelta * 1000.0,
                  systemDelta * 1000.0,
                  activeWindowId,
                  shownWindowId,
                  (unsigned long)cachedMenuCount);
        } else {
            NSLog(@"[CPU] last %.2fs total=%.2f%% user=%.2fms sys=%.2fms active=0x%lx shown=0x%lx menus=%lu",
                  wallDelta,
                  cpuPercent,
                  userDelta * 1000.0,
                  systemDelta * 1000.0,
                  activeWindowId,
                  shownWindowId,
                  (unsigned long)cachedMenuCount);
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

- (void)setupBacklightControl
{
    NSDebugLLog(@"gwcomp", @"MenuController: Setting up backlight control...");

    _backlightBackend = [[SysfsBacklightBackend alloc] init];
    _brightnessKeySource = [[EvdevBrightnessKeySource alloc] init];

    if (![_backlightBackend respondsToSelector:@selector(current)] ||
        ![_brightnessKeySource respondsToSelector:@selector(start:)]) {
        NSDebugLLog(@"gwcomp", @"MenuController: Backlight control not available on this platform");
        _backlightBackend = nil;
        _brightnessKeySource = nil;
        return;
    }

    int maxBrightness = [_backlightBackend maximum];
    if (maxBrightness <= 0) {
        NSDebugLLog(@"gwcomp", @"MenuController: No backlight device found, disabling backlight control");
        _backlightBackend = nil;
        _brightnessKeySource = nil;
        return;
    }

    // Shared debounce: both evdev and XF86 key paths can fire for the same
    // physical keypress.  The evdev path fires first (low-level input event),
    // then XF86 fires later (X11 keysym).  We skip if either path handled the
    // same event within 200 ms.
    static dispatch_once_t debounceOnce;
    dispatch_once(&debounceOnce, ^{ _lastBrightnessAdjust = 0; });
    NSTimeInterval debounceInterval = 0.2;

    __weak id<BacklightBackend> weakBackend = _backlightBackend;
    int step = maxBrightness / 20; // 5% per step

    [_brightnessKeySource start:^(int delta) {
        id<BacklightBackend> backend = weakBackend;
        if (!backend) return;

        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        if (now - _lastBrightnessAdjust < debounceInterval) return;
        _lastBrightnessAdjust = now;

        int cur = [backend current];
        int max = [backend maximum];
        int next = cur + delta * step;

        if (next < 0) next = 0;
        if (next > max) next = max;

        [backend set:next];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"BrightnessChanged" object:nil];
    }];

    // Also register XF86 brightness keys — forwarded via notification to BrightnessExtra.
    X11ShortcutManager *mgr = [X11ShortcutManager sharedManager];
    if (mgr) {
        [mgr registerXF86Key:XF86XK_MonBrightnessUp target:self action:@selector(_xf86BrightnessUp)];
        [mgr registerXF86Key:XF86XK_MonBrightnessDown target:self action:@selector(_xf86BrightnessDown)];
    }

    NSDebugLLog(@"gwcomp", @"MenuController: Backlight control started (max=%d, step=%d)",
          maxBrightness, step);
}

#pragma mark - XF86 multimedia key forwarding

- (void)_xf86VolumeUp
{
    [[NSNotificationCenter defaultCenter] postNotificationName:@"GSMenuExtraVolumeUp" object:nil];
}

- (void)_xf86VolumeDown
{
    [[NSNotificationCenter defaultCenter] postNotificationName:@"GSMenuExtraVolumeDown" object:nil];
}

- (void)_xf86Mute
{
    [[NSNotificationCenter defaultCenter] postNotificationName:@"GSMenuExtraMute" object:nil];
}

- (void)_xf86BrightnessUp
{
    [[NSNotificationCenter defaultCenter] postNotificationName:@"GSMenuExtraBrightnessUp" object:nil];
}

- (void)_xf86BrightnessDown
{
    [[NSNotificationCenter defaultCenter] postNotificationName:@"GSMenuExtraBrightnessDown" object:nil];
}

#pragma mark - Power key (short/long press)

/* Long-press threshold for the hardware power key. */
#define POWER_KEY_LONG_PRESS 5.0

/* Power key pressed: start a long-press timer.  If the key is released
 * before the timer fires it is a short press (shutdown confirmation); if
 * the timer fires the user held the key (immediate shutdown). */
- (void)_xf86PowerKeyPressed
{
    if (self.powerKeyTimer) {
        [self.powerKeyTimer invalidate];
    }
    self.powerKeyTriggered = NO;
    self.powerKeyTimer = [NSTimer scheduledTimerWithTimeInterval:POWER_KEY_LONG_PRESS
                                                          target:self
                                                        selector:@selector(powerKeyLongPressTimerFired:)
                                                        userInfo:nil
                                                         repeats:NO];
    NSDebugLLog(@"gwcomp", @"MenuController: Power key pressed, started long-press timer (%.1fs)", POWER_KEY_LONG_PRESS);
}

/* Power key released: if the long-press timer is still active it was a
 * short press - show the shutdown confirmation.  If the long press already
 * triggered, just reset the state. */
- (void)_xf86PowerKeyReleased
{
    if (self.powerKeyTimer) {
        [self.powerKeyTimer invalidate];
        self.powerKeyTimer = nil;
        self.powerKeyTriggered = NO;
        [self showShutdownConfirmation];
    } else if (self.powerKeyTriggered) {
        self.powerKeyTriggered = NO;
    }
}

/* Long press: shut down immediately without asking. */
- (void)powerKeyLongPressTimerFired:(NSTimer *)timer
{
    self.powerKeyTimer = nil;
    self.powerKeyTriggered = YES;
    NSDebugLLog(@"gwcomp", @"MenuController: Power key long-press detected: shutting down");
    [SystemActions executeShutdown];
}

/* Confirms the shutdown with the same dialog the menu uses, then shuts
 * down. */
- (void)showShutdownConfirmation
{
    NSString *title = NSLocalizedString(@"Shut Down", nil);
    NSString *message = NSLocalizedString(@"Are you sure you want to quit\nall applications and shut down now?", nil);
    NSDebugLLog(@"gwcomp", @"MenuController: Power key short press - showing shutdown confirmation");

    /* Defer so the modal appears after any menu closes, mirroring the
     * menu path. */
    NSDictionary *info = @{
        @"title": title,
        @"message": message,
        @"action": @"shutdown"
    };
    [self performSelector:@selector(showPowerActionConfirmation:)
               withObject:info
               afterDelay:0.15];
}

/* Shows the confirmation dialog for a power action and executes it on
 * confirmation (shared with the power key path). */
- (void)showPowerActionConfirmation:(NSDictionary *)info
{
    NSString *title = [info objectForKey:@"title"];
    NSString *message = [info objectForKey:@"message"];
    NSString *actionType = [info objectForKey:@"action"];

    if (NSRunAlertPanel(title, message, title, NSLocalizedString(@"Cancel", nil), nil)) {
        NSDebugLLog(@"gwcomp", @"MenuController: User confirmed %@", actionType);
        if ([actionType isEqualToString:@"shutdown"]) {
            [SystemActions executeShutdown];
        } else if ([actionType isEqualToString:@"restart"]) {
            [SystemActions executeRestart];
        } else {
            [SystemActions executeLogout];
        }
    } else {
        NSDebugLLog(@"gwcomp", @"MenuController: User cancelled %@", actionType);
    }
}

#pragma mark - Mic mute (evdev, to preserve hardware LED)

- (void)startMicMuteMonitor
{
#ifdef __linux__
    _micMuteFDCount = 0;
    memset(_micMuteFDs, -1, sizeof(_micMuteFDs));

    // Scan /proc/bus/input/devices for devices with KEY_MICMUTE
    FILE *fp = fopen("/proc/bus/input/devices", "r");
    if (!fp) return;
    char line[512];
    BOOL hasMicMute = NO;
    int eventNum = -1;
    while (fgets(line, sizeof(line), fp)) {
        if (strncmp(line, "N: Name=", 8) == 0) {
            hasMicMute = NO;
            eventNum = -1;
        } else if (strncmp(line, "B: KEY=", 7) == 0) {
            // Check for KEY_MICMUTE (248) in the key bitmap
            unsigned long bits[8] = {0};
            char *p = line + 7;
            for (int i = 0; i < 8 && *p; i++) {
                bits[i] = strtoul(p, &p, 16);
            }
            unsigned long word = bits[248 / (sizeof(long) * 8)];
            unsigned long bit = 1UL << (248 % (sizeof(long) * 8));
            if (word & bit) {
                hasMicMute = YES;
            }
        } else if (strncmp(line, "H: Handlers=", 12) == 0) {
            char *h = line + 12;
            char *tok = strtok(h, " \t\n");
            while (tok) {
                if (strncmp(tok, "event", 5) == 0) {
                    eventNum = atoi(tok + 5);
                }
                tok = strtok(NULL, " \t\n");
            }
        } else if (line[0] == '\n' && hasMicMute && eventNum >= 0) {
            // Found a device with mic mute key
            char path[64];
            snprintf(path, sizeof(path), "/dev/input/event%d", eventNum);
            int fd = open(path, O_RDONLY);
            if (fd >= 0) {
                _micMuteFDs[_micMuteFDCount++] = fd;
            }
            hasMicMute = NO;
            eventNum = -1;
            if (_micMuteFDCount >= 16) break;
        }
    }
    fclose(fp);

    if (_micMuteFDCount == 0) return;

    _micMuteMonitorRunning = YES;
    _micMuteThread = [[NSThread alloc] initWithTarget:self
                                             selector:@selector(_micMuteMonitorThread)
                                               object:nil];
    [_micMuteThread start];
#else
    NSDebugLLog(@"gwcomp", @"MenuController: Mic mute evdev monitor not available on this platform");
#endif
}

- (void)_micMuteMonitorThread
{
#ifdef __linux__
    @autoreleasepool {
        struct pollfd fds[16];
        int nfds = 0;
        for (int i = 0; i < _micMuteFDCount; i++) {
            fds[nfds].fd = _micMuteFDs[i];
            fds[nfds].events = POLLIN;
            fds[nfds].revents = 0;
            nfds++;
        }

        while (_micMuteMonitorRunning) {
            int ret = poll(fds, nfds, 1000);
            if (ret < 0) {
                if (errno == EINTR) continue;
                break;
            }
            if (ret == 0) continue;

            for (int i = 0; i < nfds; i++) {
                if (fds[i].fd < 0) continue;
                /* A deleted/replaced input device leaves its fd permanently
                 * readable with POLLHUP/POLLERR, so poll() returns immediately
                 * and the loop busy-spins at 100% CPU.  Close the dead fd and
                 * stop polling the slot (poll() ignores entries with fd < 0). */
                if (fds[i].revents & (POLLHUP | POLLERR | POLLNVAL)) {
                    close(fds[i].fd);
                    _micMuteFDs[i] = -1;
                    fds[i].fd = -1;
                    continue;
                }
                if (fds[i].revents & POLLIN) {
                    struct input_event ev;
                    while (read(fds[i].fd, &ev, sizeof(ev)) == sizeof(ev)) {
                        if (ev.type == EV_KEY && ev.code == KEY_MICMUTE && ev.value == 1) {
                            dispatch_async(dispatch_get_main_queue(), ^{
                                [GSVolumeControl toggleMicMute];
                            });
                        }
                    }
                }
            }
        }

        // Cleanup FDs
        for (int i = 0; i < _micMuteFDCount; i++) {
            if (_micMuteFDs[i] >= 0) {
                close(_micMuteFDs[i]);
                _micMuteFDs[i] = -1;
            }
        }
    }
#endif
}

- (void)_stopMicMuteMonitor
{
    _micMuteMonitorRunning = NO;
    _micMuteThread = nil;
}

#pragma mark - Power key (evdev)

/* The X server does not reliably deliver the physical power button to the
 * root window grab (the keycode/keysym mapping differs per input device), so
 * read KEY_POWER directly from the kernel input devices instead.  This is the
 * same approach used for the mic-mute LED key. */
- (void)startPowerKeyMonitor
{
#ifdef __linux__
    _powerKeyFDCount = 0;
    memset(_powerKeyFDs, -1, sizeof(_powerKeyFDs));

    // Scan /proc/bus/input/devices for devices that report KEY_POWER (116)
    FILE *fp = fopen("/proc/bus/input/devices", "r");
    if (!fp) return;
    char line[512];
    BOOL hasPower = NO;
    int eventNum = -1;
    while (fgets(line, sizeof(line), fp)) {
        if (strncmp(line, "N: Name=", 8) == 0) {
            hasPower = NO;
            eventNum = -1;
        } else if (strncmp(line, "B: KEY=", 7) == 0) {
            // Check for KEY_POWER (116) in the key bitmap
            unsigned long bits[8] = {0};
            char *p = line + 7;
            for (int i = 0; i < 8 && *p; i++) {
                bits[i] = strtoul(p, &p, 16);
            }
            unsigned long word = bits[116 / (sizeof(long) * 8)];
            unsigned long bit = 1UL << (116 % (sizeof(long) * 8));
            if (word & bit) {
                hasPower = YES;
            }
        } else if (strncmp(line, "H: Handlers=", 12) == 0) {
            char *h = line + 12;
            char *tok = strtok(h, " \t\n");
            while (tok) {
                if (strncmp(tok, "event", 5) == 0) {
                    eventNum = atoi(tok + 5);
                }
                tok = strtok(NULL, " \t\n");
            }
        } else if (line[0] == '\n' && hasPower && eventNum >= 0) {
            // Found a device with the power key
            char path[64];
            snprintf(path, sizeof(path), "/dev/input/event%d", eventNum);
            int fd = open(path, O_RDONLY);
            if (fd >= 0) {
                _powerKeyFDs[_powerKeyFDCount++] = fd;
            }
            hasPower = NO;
            eventNum = -1;
            if (_powerKeyFDCount >= 16) break;
        }
    }
    fclose(fp);

    if (_powerKeyFDCount == 0) return;

    _powerKeyMonitorRunning = YES;
    _powerKeyThread = [[NSThread alloc] initWithTarget:self
                                              selector:@selector(_powerKeyMonitorThread)
                                                object:nil];
    [_powerKeyThread start];
#else
    NSDebugLLog(@"gwcomp", @"MenuController: Power key evdev monitor not available on this platform");
#endif
}

- (void)_powerKeyMonitorThread
{
#ifdef __linux__
    @autoreleasepool {
        struct pollfd fds[16];
        int nfds = 0;
        for (int i = 0; i < _powerKeyFDCount; i++) {
            fds[nfds].fd = _powerKeyFDs[i];
            fds[nfds].events = POLLIN;
            fds[nfds].revents = 0;
            nfds++;
        }

        while (_powerKeyMonitorRunning) {
            int ret = poll(fds, nfds, 1000);
            if (ret < 0) {
                if (errno == EINTR) continue;
                break;
            }
            if (ret == 0) continue;

            for (int i = 0; i < nfds; i++) {
                if (fds[i].fd < 0) continue;
                /* A deleted/replaced input device leaves its fd permanently
                 * readable with POLLHUP/POLLERR, so poll() returns immediately
                 * and the loop busy-spins at 100% CPU.  Close the dead fd and
                 * stop polling the slot (poll() ignores entries with fd < 0). */
                if (fds[i].revents & (POLLHUP | POLLERR | POLLNVAL)) {
                    close(fds[i].fd);
                    _powerKeyFDs[i] = -1;
                    fds[i].fd = -1;
                    continue;
                }
                if (fds[i].revents & POLLIN) {
                    struct input_event ev;
                    while (read(fds[i].fd, &ev, sizeof(ev)) == sizeof(ev)) {
                        if (ev.type == EV_KEY && ev.code == KEY_POWER && ev.value == 1) {
                            dispatch_async(dispatch_get_main_queue(), ^{
                                [self _xf86PowerKeyPressed];
                            });
                        } else if (ev.type == EV_KEY && ev.code == KEY_POWER && ev.value == 0) {
                            dispatch_async(dispatch_get_main_queue(), ^{
                                [self _xf86PowerKeyReleased];
                            });
                        }
                    }
                }
            }
        }

        // Cleanup FDs
        for (int i = 0; i < _powerKeyFDCount; i++) {
            if (_powerKeyFDs[i] >= 0) {
                close(_powerKeyFDs[i]);
                _powerKeyFDs[i] = -1;
            }
        }
    }
#endif
}

- (void)_stopPowerKeyMonitor
{
    _powerKeyMonitorRunning = NO;
    _powerKeyThread = nil;
}

- (void)applicationWillTerminate:(NSNotification *)notification
{
    NSDebugLLog(@"gwcomp", @"MenuController: Application will terminate");
#if MENU_PROFILING
    [self stopCPUUsageLogging];
#endif
    
    // Unload menu extras first
    if (self.menuExtraManager) {
        NSDebugLLog(@"gwcomp", @"MenuController: Unloading menu extras...");
        [self.menuExtraManager unloadAllMenuExtras];
        self.menuExtraManager = nil;
    }
    
    // Stop backlight control
    NSDebugLLog(@"gwcomp", @"MenuController: Stopping backlight control...");
    if ([_brightnessKeySource respondsToSelector:@selector(stop)]) {
        [_brightnessKeySource stop];
    }
    _brightnessKeySource = nil;
    _backlightBackend = nil;

    // Stop mic mute evdev monitor
    [self _stopMicMuteMonitor];

    // Stop the power key evdev monitor
    [self _stopPowerKeyMonitor];

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
    /* Raw theme height: GNUstep multiplies the window frame by the scale
     * factor at creation, so the resulting device height is 22 * sf. */
    const CGFloat menuBarHeight = [[GSTheme theme] menuBarHeight];
    NSDebugLLog(@"gwcomp", @"MenuController: Menu bar height: %.0f", menuBarHeight);
    
    NSRect rect;
    NSColor *color;
    NSFont *menuFont = [NSFont menuBarFontOfSize:0];
    NSMutableDictionary *attributes;
    
    attributes = [NSMutableDictionary new];
    [attributes setObject:menuFont forKey:NSFontAttributeName];
    
    NSRect sf = [[[NSScreen screens] objectAtIndex:0] frame];
    sf.size.width = MenuControllerScreenWidth();
    sf.size.width /= MenuControllerScaleFactor();
    self.screenFrame = sf;
    self.screenSize = sf.size;

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
    
    [self.menuBar setTitle:@"Menu"];
    [self.menuBar setBackgroundColor:[NSColor clearColor]];
    [self.menuBar setOpaque:NO];
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
    
    // Create app menu widget for displaying menus - leave space for menu extras on right
    // Menu extra width is computed dynamically from loaded bundles below.
    // First, create and load the MenuExtraManager to know the total width.
    NSDebugLLog(@"gwcomp", @"MenuController: Creating MenuExtraManager");
    self.menuExtraManager = [[MenuExtraManager alloc] initWithScreenWidth:self.screenSize.width
                                                             menuBarHeight:menuBarHeight];
    [self.menuExtraManager loadMenuExtras];
    NSDebugLLog(@"gwcomp", @"MenuController: MenuExtraManager items loaded");

    // Create the extras menu view (horizontal NSMenuView)
    NSView *extrasMenuView = [self.menuExtraManager createExtrasMenuView];
    CGFloat extrasMenuWidth = [self.menuExtraManager extrasMenuWidth];
    NSDebugLLog(@"gwcomp", @"MenuController: Extras menu view width: %.0f", extrasMenuWidth);

    // Position extras 8px from the right edge of the menu bar
    [extrasMenuView setFrame:NSMakeRect(self.screenSize.width - extrasMenuWidth - 8, 0,
                                        extrasMenuWidth, menuBarHeight)];

    // Observe extras layout changes so we can resize AppMenuWidget
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(extrasEnabledSetDidChange:)
                                                 name:@"GSMenuExtraEnabledSetDidChange"
                                               object:self.menuExtraManager];

    // Give the app menu widget the remaining space
    CGFloat menuWidgetWidth = self.screenSize.width - extrasMenuWidth - 8;
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
    
    // Add AppMenuWidget and extras menu view as children of MenuBarView (on top of the background)
    [self.menuBarView addSubview:self.appMenuWidget];
    
    // Add the extras menu view and start update timers
    [self.menuBarView addSubview:extrasMenuView];
    [self.menuExtraManager startUpdateTimers];
    NSDebugLLog(@"gwcomp", @"MenuController: Added extras menu view as child of MenuBarView");
    
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
            NSLog(@"NSAlert: Cannot register global shortcut");
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

    // Register XF86Audio volume keys — forwarded via notification to SoundExtra.
    X11ShortcutManager *volMgr = [X11ShortcutManager sharedManager];
    if (volMgr) {
        [volMgr registerXF86Key:XF86XK_AudioRaiseVolume target:self action:@selector(_xf86VolumeUp)];
        [volMgr registerXF86Key:XF86XK_AudioLowerVolume target:self action:@selector(_xf86VolumeDown)];
        [volMgr registerXF86Key:XF86XK_AudioMute target:self action:@selector(_xf86Mute)];
        NSDebugLLog(@"gwcomp", @"MenuController: Registered XF86Audio volume keys via notifications");
    }

    // Register the hardware power key (XF86PowerOff).  A short press shows the
    // shutdown confirmation; a long press (> POWER_KEY_LONG_PRESS) shuts down
    // immediately.  This used to live in the Workspace.
    X11ShortcutManager *pwrMgr = [X11ShortcutManager sharedManager];
    if (pwrMgr) {
        [pwrMgr registerXF86Key:XF86XK_PowerOff
                         target:self
                         action:@selector(_xf86PowerKeyPressed)
                  releaseTarget:self
                  releaseAction:@selector(_xf86PowerKeyReleased)];
        NSDebugLLog(@"gwcomp", @"MenuController: Registered power key (XF86PowerOff)");
    }

    // The physical power button is not reliably delivered to the X11 grab on
    // every machine, so also monitor it directly via evdev (KEY_POWER).  The
    // X11 registration above stays as a secondary path.
    [self startPowerKeyMonitor];

    // Mic mute uses evdev (not XGrabKey) so the system mic-mute LED still works.
    [self startMicMuteMonitor];

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

    // React live to GSScaleFactor changes.  GNUstep only posts
    // NSUserDefaultsDidChangeNotification for changes made in this process,
    // so instead poll: synchronize re-reads external writes, then diff
    // against the last seen value so unrelated changes are ignored.
    [NSTimer scheduledTimerWithTimeInterval:1.0
                                     target:self
                                   selector:@selector(checkScaleFactor:)
                                   userInfo:nil
                                    repeats:YES];
}

- (void)setupMenuBar
{
    /* GNUstep loads the defaults lazily; synchronize up front so the first
     * GSScaleFactor read (used when creating the menu bar below) sees the
     * externally-written value instead of a stale one. */
    [[NSUserDefaults standardUserDefaults] synchronize];
    MenuControllerLastScaleFactor = [[NSUserDefaults standardUserDefaults] floatForKey:@"GSScaleFactor"];
    if (MenuControllerLastScaleFactor == 0.0)
        MenuControllerLastScaleFactor = 1.0;

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
            self.dbusPollingTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                                      target:self
                                                                    selector:@selector(pollDBusMessages:)
                                                                    userInfo:nil
                                                                     repeats:YES];
            NSDebugLLog(@"gwcomp", @"MenuController: D-Bus polling timer set up as fallback (2s interval)");
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

    // Fallback poll for the active window.  The WindowMonitor is event-driven
    // via a dispatch source on its own X connection; that source has been
    // observed to stop firing after a while (GCD read-source on an Xlib fd),
    // which leaves the menu stuck on the previously active app.  Polling every
    // 100ms on a fresh connection keeps the menu tracking responsive (the menu
    // must follow an app switch within ~100ms).
    self.activeWindowPollTimer = [NSTimer scheduledTimerWithTimeInterval:0.1
                                                                  target:self
                                                                selector:@selector(activeWindowPollTick:)
                                                                userInfo:nil
                                                                 repeats:YES];
    
    NSDebugLLog(@"gwcomp", @"MenuController: Window monitoring setup complete");
}

- (void)activeWindowPollTick:(NSTimer *)timer
{
    @try {
        /* Read the active window live via MenuUtils' shared X connection.
           Do NOT use the WindowMonitor's cached value: its event loop is
           known to stall (see the monitor setup comment), so the cache goes
           stale and Menu would miss or lag active-app switches.  Do NOT open
           a fresh X connection per tick either - that churns ~36000 connects
           per hour and accumulated CPU on long-running sessions.  The shared
           persistent connection gives a fresh read with no per-tick cost. */
        unsigned long activeWindow = [MenuUtils getActiveWindow];

        if (activeWindow == 0 || activeWindow == self.lastProcessedWindowId) {
            return;
        }
        if (self.appMenuWidget) {
            [self.appMenuWidget updateForActiveWindowId:activeWindow];
        }
        self.lastProcessedWindowId = activeWindow;
        self.lastProcessedTime = [[NSDate date] timeIntervalSince1970];
    }
    @catch (NSException *ex) {
        NSDebugLLog(@"gwcomp", @"MenuController: Exception in activeWindowPollTick: %@", ex);
    }
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

    /* Ignore focus on Menu.app itself — but still forward to AppMenuWidget to
       cancel any stale coalesce timer left by a transient windowId==0 event.
       The widget's handleFocusChange: will return early via isSelfWindow.

       Also match windows by PID to catch NSMenuWindow popups created by our
       own process that [NSApp windowWithWindowNumber:] does not track. */
    if (windowId != 0) {
        BOOL isSelfWindow = ([NSApp windowWithWindowNumber:windowId] != nil);
        if (!isSelfWindow) {
            isSelfWindow = ((pid_t)[MenuUtils getWindowPID:windowId]
                            == [[NSProcessInfo processInfo] processIdentifier]);
        }
        if (isSelfWindow) {
            if (self.appMenuWidget) {
                [self.appMenuWidget updateForActiveWindowId:windowId];
            }
            self.lastProcessedWindowId = windowId;
            self.lastProcessedTime = [[NSDate date] timeIntervalSince1970];
            MENU_PROFILE_END(activeWindowChangedNotification);
            return;
        }
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
        if (activeWindow == 0) {
            // No active window reported.  The WM is transiently reporting 0
            // (e.g. Chromium recycling its window IDs), so the shown window
            // may be stale even though the app is still frontmost.  Clearing
            // here made every app's menu vanish a few seconds after it loaded
            // - and unregistered its shortcuts.  Keep the menu until we know
            // what is actually active.
            NSDebugLLog(@"gwcomp", @"MenuController: No active window - keeping current menu");
            MENU_PROFILE_END(windowValidationTick);
            return;
        }
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
            NSDebugLog(@"MenuController: Watchdog detected invalid/closed window 0x%lx - clearing menu", shownWindow);
            [self.appMenuWidget clearMenuAndHideView];
            self.lastClearedWindowId = shownWindow;
            self.lastClearedTime = now;
            self.lastClearSuppressUntil = 0;
            MENU_PROFILE_END(windowValidationTick);
            return;
        }

        // NOTE: no longer clear when the WM reports no active window while a
        // menu is shown.  _NET_ACTIVE_WINDOW is transiently 0 whenever the
        // focused app juggles internal/helper windows (e.g. Chromium), so this
        // cleared every app's menu - and unregistered its shortcuts - a few
        // seconds after it loaded.  The shown window is still valid and mapped
        // (checked above), so the menu must stay until a real focus change.
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
    
    // Advertise our global-menu atoms by merging them into the WM-owned
    // _NET_SUPPORTED property, never replacing it.
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
    [MenuUtils mergeNetSupportedAtoms:supportedAtoms
                                count:sizeof(supportedAtoms) / sizeof(Atom)
                                onRoot:root
                              display:display];
    
    NSDebugLLog(@"gwcomp", @"MenuController: Merged global menu atoms into _NET_SUPPORTED");
    
    // Set Unity-specific properties that Chrome looks for
    Atom atomAtom = XInternAtom(display, "ATOM", False);
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
    const CGFloat menuBarHeight = MenuControllerMenuBarHeight();
    
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
    const CGFloat menuBarHeight = MenuControllerMenuBarHeight();
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
