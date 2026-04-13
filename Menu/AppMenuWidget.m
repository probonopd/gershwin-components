/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// Runtime behavior: built-in file/placeholder fallbacks removed. Desktop menus will be used as the FALLBACK when available.

#import "AppMenuWidget.h"
#import "MenuProtocolManager.h"
#import "MenuUtils.h"
#import "X11ShortcutManager.h"
#import "DBusConnection.h"
#import "ActionSearch.h"
#import <X11/Xlib.h>
#import <X11/Xutil.h>
#import <X11/Xatom.h>
#import <GNUstepGUI/GSTheme.h>

// Use libdispatch if available for background launching; otherwise fall back to performSelectorInBackground
#if defined(__has_include)
# if __has_include(<dispatch/dispatch.h>)
#  import <dispatch/dispatch.h>
#  define AMW_HAS_DISPATCH 1
# else
#  define AMW_HAS_DISPATCH 0
# endif
#else
# include <dispatch/dispatch.h>
# define AMW_HAS_DISPATCH 1
#endif

// Minimum interval (seconds) between consecutive system menu population runs to avoid thrashing
#define SYSTEM_MENU_UPDATE_MIN_INTERVAL 0.15

// Global X11 error handling for BadWindow and other errors
static BOOL x11_error_occurred = NO;
static int x11_error_code = 0;
static AppMenuWidget *currentWidget = nil;
static NSMutableSet *invalidWindows = nil;  // Track windows that have generated X11 errors

// X11 error handler to prevent crashes
static int handleX11Error(Display *display, XErrorEvent *event)
{
    (void)display;  // Suppress unused parameter warning
    
    // Initialize invalid windows set if needed
    if (!invalidWindows) {
        invalidWindows = [[NSMutableSet alloc] init];
    }
    
    x11_error_occurred = YES;
    x11_error_code = event->error_code;
    
    if (event->error_code == BadWindow) {
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: X11 BadWindow error (window disappeared) - error_code=%d, request_code=%d", 
              event->error_code, event->request_code);
        
        // Track this window as invalid to prevent future access
        if (event->resourceid != 0) {
            NSNumber *windowKey = [NSNumber numberWithUnsignedLong:event->resourceid];
            [invalidWindows addObject:windowKey];
            NSDebugLLog(@"gwcomp", @"AppMenuWidget: Marked window %lu as invalid to prevent future access", event->resourceid);
        }
              
        // If we have a current widget and the error is for our tracked window, clean up immediately
        if (currentWidget && event->resourceid != 0) {
            [currentWidget handleWindowDisappeared:event->resourceid];
        }
    } else if (event->error_code == BadDrawable) {
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: X11 BadDrawable error - error_code=%d, request_code=%d", 
              event->error_code, event->request_code);
        
        // Also track bad drawables as invalid
        if (event->resourceid != 0) {
            NSNumber *windowKey = [NSNumber numberWithUnsignedLong:event->resourceid];
            [invalidWindows addObject:windowKey];
        }
    } else {
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: X11 error - error_code=%d, request_code=%d", 
              event->error_code, event->request_code);
    }
    
    // Don't call the default error handler which would terminate the program
    return 0;
}

// Macro to safely wrap X11 calls with error handling
#define SAFE_X11_CALL(display, call, cleanup_code) do { \
    x11_error_occurred = NO; \
    x11_error_code = 0; \
    int (*oldHandler)(Display *, XErrorEvent *) = XSetErrorHandler(handleX11Error); \
    XSync(display, False); \
    \
    call; \
    \
    XSync(display, False); \
    XSetErrorHandler(oldHandler); \
    \
    if (x11_error_occurred) { \
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: X11 error occurred during call, executing cleanup"); \
        cleanup_code; \
    } \
} while(0)

@interface AppMenuView : NSMenuView
@end

@implementation AppMenuView

- (void)drawRect:(NSRect)dirtyRect
{
    // Use transparent background to allow MenuBarView gradient to show through
    [[NSColor clearColor] set];
    NSRectFill(dirtyRect);
    [super drawRect:dirtyRect];
}

- (BOOL)isOpaque
{
    return NO;
}

@end

@interface AppMenuWidget ()
@property (nonatomic, assign) pid_t lastWindowPID;
@property (nonatomic, assign) NSTimeInterval lastWindowSwitchTime;
@property (nonatomic, strong) NSTimer *noMenuGracePeriodTimer;
@property (nonatomic, assign) unsigned long pendingClearWindowId;

- (unsigned long)findDesktopWindowId;
- (BOOL)windowLikelyWillRegisterMenuSoon:(unsigned long)windowId;
- (void)clearMenuAndHideView;

@end

@implementation AppMenuWidget

// Called when the system submenu begins tracking (is about to be shown)
- (void)systemMenuDidBeginTracking:(NSNotification *)note
{
    // Populate the menu now
    NSMenu *menu = (NSMenu *)[note object];
    if (menu != self.systemMenu) return;

    NSDebugLLog(@"gwcomp", @"AppMenuWidget: systemMenuDidBeginTracking - populating apps");
    // Reuse our menuNeedsUpdate implementation for population
    [self menuNeedsUpdate:self.systemMenu];
}

+ (void)setCurrentWidget:(AppMenuWidget *)widget
{
    currentWidget = widget;
}

// Utility function to check if a window is safe to access
+ (BOOL)isWindowSafeToAccess:(Window)windowId
{
    if (windowId == 0) return NO;
    
    if (!invalidWindows) {
        invalidWindows = [[NSMutableSet alloc] init];
        return YES;  // If no tracking yet, assume safe
    }
    
    NSNumber *windowKey = [NSNumber numberWithUnsignedLong:windowId];
    BOOL isInvalid = [invalidWindows containsObject:windowKey];
    
    if (isInvalid) {
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Skipping X11 operation on invalid window %lu", windowId);
    }
    
    return !isInvalid;
}

- (id)initWithFrame:(NSRect)frameRect
{
    self = [super initWithFrame:frameRect];
    if (self) {
        self.menuView = nil;
        self.currentApplicationName = nil;
        self.currentWindowId = 0;
        self.currentMenu = nil;
        self.fallbackTimers = [NSMutableDictionary dictionary];
        self.cachedIsWaitingForMenu = NO;
        self.cachedHasMenu = NO;
        self.needsRedraw = YES;
        
        // Tight-loop prevention initialisation
        self.isInsideDisplayMenuForWindow = NO;
        self.lastUpdateForActiveWindowTime = 0;
        self.lastUpdateForActiveWindowId = 0;
        self.gracePeriodStartTime = 0;
        
        // Register this widget for X11 error handling
        [AppMenuWidget setCurrentWidget:self];
        
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Initialized with frame %.0f,%.0f %.0fx%.0f", 
              frameRect.origin.x, frameRect.origin.y, frameRect.size.width, frameRect.size.height);
        
        // Disable "waiting" state - we clear everything immediately
        self.isWaitingForMenu = NO;
        
        // Defer placeholder menu setup until after initialization completes
        // This ensures the view is fully ready before we try to set up and draw the menu
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setupPlaceholderMenu];
        });
    }
    return self;
}

- (void)setupPlaceholderMenu
{
    // Only set up if we still don't have a menu view
    if (self.menuView) {
        return;
    }
    
    NSDebugLLog(@"gwcomp", @"AppMenuWidget: Setting up initial system-only menu");
    @try {
        [self displaySystemOnlyMenu];
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Successfully set up initial system-only menu");
    }
    @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Exception during initial menu setup: %@", exception);
        self.menuView = nil;
    }
}

- (void)dealloc
{
    // Unregister from X11 error handling if we're the current widget
    if (currentWidget == self) {
        currentWidget = nil;
    }
    
    // Cancel any fallback timers
    for (NSTimer *timer in [self.fallbackTimers allValues]) {
        [timer invalidate];
    }
    [self.fallbackTimers removeAllObjects];
}

- (void)updateForActiveWindow
{
    
    if (!self.protocolManager) {
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: No protocol manager available");
        return;
    }

    // Defensive validation: if our current tracked window is gone, clear the menu immediately
    if (self.currentWindowId != 0 && ![AppMenuWidget isWindowStillValid:self.currentWindowId]) {
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Current tracked window %lu is no longer valid - clearing menu and re-evaluating active window", self.currentWindowId);
        [self clearMenuAndHideView];
        self.currentWindowId = 0;
        self.currentApplicationName = nil;
        self.currentMenu = nil;
    }

    // Get the active window using X11
    Display *display = [MenuUtils sharedDisplay];
    if (!display) {
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Cannot open X11 display");
        return;
    }
    
    Window root = DefaultRootWindow(display);
    Window activeWindow = 0;
    Atom actualType;
    int actualFormat;
    unsigned long nitems, bytesAfter;
    unsigned char *prop = NULL;
    
    // Get _NET_ACTIVE_WINDOW property
    Atom activeWindowAtom = XInternAtom(display, "_NET_ACTIVE_WINDOW", False);
    SAFE_X11_CALL(display, {
        if (XGetWindowProperty(display, root, activeWindowAtom,
                              0, 1, False, AnyPropertyType,
                              &actualType, &actualFormat, &nitems, &bytesAfter,
                              &prop) == Success && prop) {
            activeWindow = *(Window*)prop;
            XFree(prop);
        }
    }, {
        // Cleanup on error
        if (prop) {
            XFree(prop);
            prop = NULL;
        }
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Failed to get active window due to X11 error");
    });

    [self updateForActiveWindowId:activeWindow];
}

- (void)updateForActiveWindowId:(unsigned long)windowId
{
    if (!self.protocolManager) {
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: No protocol manager available (updateForActiveWindowId)");
        return;
    }

    // TIGHT-LOOP GUARD: Rate-limit calls to max once per 50ms for the same window
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (windowId == self.lastUpdateForActiveWindowId &&
        (now - self.lastUpdateForActiveWindowTime) < 0.05) {
        return; // Too frequent for the same window - silently skip
    }
    self.lastUpdateForActiveWindowTime = now;
    self.lastUpdateForActiveWindowId = windowId;

    NSDebugLog(@"AppMenuWidget: updateForActiveWindowId called with 0x%lx", windowId);

    unsigned long activeWindow = windowId;

    // Validate active window; if invalid, treat as no focused window
    if (activeWindow != 0 && ![AppMenuWidget isWindowStillValid:activeWindow]) {
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Active window %lu is invalid - treating as no focused window", activeWindow);
        activeWindow = 0;
    }

    // Exclude the Menu application itself from triggering updates.
    // If we focus on the menu bar or its components, we want to keep the current app menu.
    if (activeWindow != 0 && [NSApp windowWithWindowNumber:activeWindow] != nil) {
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Focus is on Menu app itself (0x%lx) - ignoring update to preserve current menu", activeWindow);
        return;
    }

    // Similarly, ignore and preserve if the process that launched the old and new menu have the same PID.
    // This avoids flickering or clearing menus when switching between windows of the same application.
    if (activeWindow != 0 && self.currentWindowId != 0 && activeWindow != self.currentWindowId) {
        pid_t oldPid = [MenuUtils getWindowPID:self.currentWindowId];
        pid_t newPid = [MenuUtils getWindowPID:activeWindow];
        if (oldPid != 0 && oldPid == newPid) {
            NSDebugLLog(@"gwcomp", @"AppMenuWidget: Focus changed within same PID %d (0x%lx -> 0x%lx) - preserving current menu", (int)newPid, self.currentWindowId, activeWindow);
            self.currentWindowId = activeWindow;
            return;
        }
    }

    // New anti-flicker mechanism: If no active window (0), check if within 0.2s we might switch 
    // to a window of the same PID. If so, don't clear the menu yet.
    if (activeWindow == 0) {
        NSTimeInterval currentTime = [NSDate timeIntervalSinceReferenceDate];
        NSTimeInterval timeSinceLastSwitch = currentTime - self.lastWindowSwitchTime;
        
        // ANTI-FLICKER: Preserve menu for 0.2s grace period when window becomes 0
        // This handles:
        // 1. Rapid window switches (closing one window while opening another)
        // 2. Transient X11 "no active window" states during window manager operations
        // 3. Window manager delays in reporting the actual active window
        if (timeSinceLastSwitch < 0.2 && self.lastWindowPID != 0) {
            NSDebugLLog(@"gwcomp", @"AppMenuWidget: Active window is 0 but within 0.2s grace period (%.3fs) - preserving menu for PID %d", 
                  timeSinceLastSwitch, (int)self.lastWindowPID);
            return;
        }
        
        // If we have a menu and this is the first time seeing window==0, preserve it briefly
        // This handles cases where lastWindowSwitchTime is very old or zero
        if (self.currentMenu != nil && self.currentWindowId != 0) {
            NSDebugLLog(@"gwcomp", @"AppMenuWidget: Active window is 0, have current menu from window %lu - preserving briefly", self.currentWindowId);
            // Update timestamp so subsequent calls within 0.2s will use the grace period above
            self.lastWindowSwitchTime = currentTime;
            return;
        }
        
        // Otherwise, clear the menu (past grace period and no current menu to preserve)
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Active window is 0 and past grace period (%.3fs) - clearing menu", timeSinceLastSwitch);
        [self clearMenuAndHideView];
        self.lastWindowPID = 0;
        self.lastWindowSwitchTime = currentTime;
        return;
    }

    BOOL shouldUpdate = (activeWindow != self.currentWindowId);
    if (!shouldUpdate && activeWindow != 0) {
        // Force a refresh if menu is missing or we don't have a current menu
        if (!self.currentMenu || ![self.protocolManager hasMenuForWindow:activeWindow]) {
            NSDebugLLog(@"gwcomp", @"AppMenuWidget: Active window unchanged (%lu) but menu missing - forcing refresh", activeWindow);
            shouldUpdate = YES;
        }
    }

    if (shouldUpdate) {
        // If the new active window has no PID, it may be a window manager
        // decoration (title bar).  Check if it shares a parent with the
        // current window — if so, the user clicked the same app's title
        // bar and we should keep the current menu.
        if (activeWindow != 0 && self.currentWindowId != 0 &&
            [MenuUtils getWindowPID:activeWindow] == 0) {
            Display *dpy = [MenuUtils sharedDisplay];
            if (dpy) {
                Window newParent = 0, curParent = 0;
                Window root, *children;
                unsigned int nchildren;
                if (XQueryTree(dpy, activeWindow, &root, &newParent, &children, &nchildren)) {
                    if (children) XFree(children);
                }
                if (XQueryTree(dpy, self.currentWindowId, &root, &curParent, &children, &nchildren)) {
                    if (children) XFree(children);
                }
                if (newParent != 0 && newParent == curParent) {
                    return;  // Same frame — title bar click
                }
            }
        }

        // Calculate newAppName first
        NSString *newAppName = nil;
        if (activeWindow != 0) {
            @try {
                newAppName = [MenuUtils getApplicationNameForWindow:activeWindow];
            }
            @catch (NSException *exception) {
                // Suppress excessive logging here if needed, but keeping for now as errors are important
                newAppName = nil;
            }
        }

        // Log detection only when the window ID actually changes to reduce log spam during retries
        static unsigned long lastDetectedWindowId = 0;
        if (activeWindow != lastDetectedWindowId) {
            NSDebugLLog(@"gwcomp", @"AppMenuWidget: Detected new active window: %lu (App: %@)", activeWindow, newAppName ?: @"Unknown");
            lastDetectedWindowId = activeWindow;
        }

        BOOL isDifferentApp = !self.currentApplicationName ||
                             ![self.currentApplicationName isEqualToString:newAppName];

        self.currentWindowId = activeWindow;
        
        // Reset grace period start time for new window focus
        self.gracePeriodStartTime = 0;
        
        // Track PID and timestamp for the new anti-flicker mechanism
        pid_t newPid = [MenuUtils getWindowPID:activeWindow];
        self.lastWindowPID = newPid;
        self.lastWindowSwitchTime = [NSDate timeIntervalSinceReferenceDate];

        // Use @try/@catch to prevent crashes during menu setup for invalid/transitioning windows
        @try {
            [self displayMenuForWindow:activeWindow isDifferentApp:isDifferentApp];
        }
        @catch (NSException *exception) {
            NSDebugLLog(@"gwcomp", @"AppMenuWidget: Exception displaying menu for window %lu: %@", activeWindow, exception);
            // Clear menu on exception to prevent further issues
            [self clearMenuAndHideView];
        }
    } else if (activeWindow == 0) {
        // No active window and no Desktop menu - ensure view is hidden
        [self clearMenuAndHideView];
    }
}

// Maximum time we preserve the previous app's menu while waiting for the new window to
// register its own menu.  During this window the old menu is kept visible — it will be
// replaced the moment the new menu arrives, so users rarely see it for the full duration.
#define MENU_WAIT_GRACE_PERIOD_MAX_SECS 2.0
#define MENU_WAIT_GRACE_PERIOD_POLL_INTERVAL 0.2

- (void)noMenuGracePeriodExpired:(NSTimer *)timer
{
    NSNumber *windowIdNum = [timer userInfo];
    unsigned long windowId = [windowIdNum unsignedLongValue];

    self.noMenuGracePeriodTimer = nil;
    self.pendingClearWindowId = 0;

    // CRITICAL: Ignore the timer if we have already moved on to a different window.
    if (self.currentWindowId != windowId) {
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Window changed to %lu - discarding stale grace-period timer for %lu",
              self.currentWindowId, windowId);
        self.gracePeriodStartTime = 0;
        return;
    }

    // Check if the window has registered its menu since the last poll.
    if ([self.protocolManager hasMenuForWindow:windowId]) {
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Window %lu registered its menu - loading immediately", windowId);
        self.gracePeriodStartTime = 0;
        // Reset optimisation guard so the load is not skipped.
        self.lastLoadedMenuWindowId = 0;
        [self updateForActiveWindowId:windowId];
        return;
    }

    // Decide whether to keep polling based on elapsed time.
    NSTimeInterval elapsed = (self.gracePeriodStartTime > 0)
        ? ([NSDate timeIntervalSinceReferenceDate] - self.gracePeriodStartTime)
        : MENU_WAIT_GRACE_PERIOD_MAX_SECS; // safety: if start wasn't recorded, don't loop

    if (elapsed < MENU_WAIT_GRACE_PERIOD_MAX_SECS && self.currentMenu != nil) {
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Window %lu still waiting for menu (%.2fs / %.0fs) - rescheduling poll",
              windowId, elapsed, MENU_WAIT_GRACE_PERIOD_MAX_SECS);
        self.pendingClearWindowId = windowId;
        self.noMenuGracePeriodTimer =
            [NSTimer scheduledTimerWithTimeInterval:MENU_WAIT_GRACE_PERIOD_POLL_INTERVAL
                                             target:self
                                           selector:@selector(noMenuGracePeriodExpired:)
                                           userInfo:[NSNumber numberWithUnsignedLong:windowId]
                                            repeats:NO];
        return;
    }

    // Grace period exhausted without the new window registering a menu.
    NSDebugLLog(@"gwcomp", @"AppMenuWidget: Window %lu has no menu after %.2fs grace period - clearing",
          windowId, elapsed);
    self.gracePeriodStartTime = 0;
    [self clearMenuAndHideView];
}

- (unsigned long)findDesktopWindowId
{
    return [MenuUtils findDesktopWindow];
}

- (BOOL)windowLikelyWillRegisterMenuSoon:(unsigned long)windowId
{
    if (windowId == 0) {
        return NO;
    }

    // Fast reject for windows that don't even advertise menu-related properties.
    if (![MenuUtils windowIndicatesMenuSupport:windowId]) {
        return NO;
    }

    // GNUstep windows should publish a menu via our native IPC path shortly.
    if ([MenuUtils getWindowProperty:windowId atomName:@"_GNUSTEP_WM_ATTR"] != nil) {
        return YES;
    }

    GNUDBusConnection *bus = [GNUDBusConnection sessionBus];
    if (!bus || ![bus isConnected]) {
        return NO;
    }

    // Canonical/KDE-style endpoint
    NSString *service = [MenuUtils getWindowMenuService:windowId];
    NSString *path = [MenuUtils getWindowMenuPath:windowId];
    if (service && path) {
        id intro = [bus callMethod:@"Introspect"
                         onService:service
                        objectPath:path
                         interface:@"org.freedesktop.DBus.Introspectable"
                         arguments:nil];
        if ([intro isKindOfClass:[NSString class]] &&
            [(NSString *)intro containsString:@"com.canonical.dbusmenu"]) {
            return YES;
        }
    }

    // GTK endpoint
    NSString *gtkService = [MenuUtils getWindowProperty:windowId atomName:@"_GTK_UNIQUE_BUS_NAME"];
    NSString *gtkMenuPath = [MenuUtils getWindowProperty:windowId atomName:@"_GTK_MENUBAR_OBJECT_PATH"];
    if (gtkService && gtkMenuPath) {
        id intro = [bus callMethod:@"Introspect"
                         onService:gtkService
                        objectPath:gtkMenuPath
                         interface:@"org.freedesktop.DBus.Introspectable"
                         arguments:nil];
        if ([intro isKindOfClass:[NSString class]] &&
            [(NSString *)intro containsString:@"org.gtk.Menus"]) {
            return YES;
        }
    }

    return NO;
}

// Always display a menu with at least the system ⌘ item, even when no application menu is available.
- (void)displaySystemOnlyMenu
{
    NSDebugLLog(@"gwcomp", @"AppMenuWidget: No application menu - showing system-only ⌘ menu");
    // An empty menu is enough; setupMenuViewWithMenu: will prepend the ⌘ system item automatically.
    NSMenu *emptyMenu = [[NSMenu alloc] initWithTitle:@""];
    [self setupMenuViewWithMenu:emptyMenu];
}

- (void)clearMenuAndHideView
{
    // Cancel any pending grace period timer
    if (self.noMenuGracePeriodTimer) {
        [self.noMenuGracePeriodTimer invalidate];
        self.noMenuGracePeriodTimer = nil;
        self.pendingClearWindowId = 0;
    }
    
    [self clearMenu:YES];
    self.currentWindowId = 0; // Ensure we stop showing menus for this window
    self.lastLoadedMenuWindowId = 0; // Reset so next focus will load fresh
    self.needsRedraw = YES;
    // Always keep the system ⌘ menu visible even when there is no application menu.
    [self displaySystemOnlyMenu];
}

- (void)clearMenu
{
    [self clearMenu:YES];  // Default to clearing shortcuts
}

- (void)clearMenu:(BOOL)shouldUnregisterShortcuts
{
    // ANTI-FLICKER: Shortcut management is now handled in loadMenu based on actual PID comparison
    // This parameter is kept for API compatibility but ignored
    (void)shouldUnregisterShortcuts;
    
    // Clear waiting state
    self.isWaitingForMenu = NO;
    NSDebugLLog(@"gwcomp", @"AppMenuWidget: Clearing menu state");
    
    self.currentApplicationName = nil;
    
    // Remove observer and clear any cached reference to the system submenu
    if (self.systemMenu) {
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc removeObserver:self name:NSMenuDidBeginTrackingNotification object:self.systemMenu];
        self.systemMenu = nil;
    }
    
    // Clear visual states
    self.currentMenu = nil;
    self.currentWindowId = 0;
    self.needsRedraw = YES;
    
    if (self.menuView) {
        [self.menuView setMenu:nil];
        [self.menuView setHidden:YES];
    }

    if (self.window) {
        [self setNeedsDisplay:YES];
    }
}

- (void)displayMenuForWindow:(unsigned long)windowId
{
    [self displayMenuForWindow:windowId isDifferentApp:YES];
}

- (void)displayMenuForWindow:(unsigned long)windowId isDifferentApp:(BOOL)isDifferentApp
{
    // TIGHT-LOOP GUARD: Prevent re-entrance (e.g. displayMenuForWindow -> desktopFallback -> displayMenuForWindow)
    if (self.isInsideDisplayMenuForWindow) {
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Re-entrant displayMenuForWindow blocked for window %lu", windowId);
        return;
    }
    self.isInsideDisplayMenuForWindow = YES;

    @try { // @finally guarantees isInsideDisplayMenuForWindow is cleared on ALL exit paths

    // OPTIMIZATION: If we already have a valid menu for this exact window, skip the expensive re-import.
    // GTK menus (e.g., GIMP with 600+ items) take seconds to parse via D-Bus, and brief window
    // focus changes (windowA -> transientWindow -> windowA) would trigger unnecessary full re-imports.
    // NOTE: We check lastLoadedMenuWindowId (not currentWindowId) because currentWindowId is set
    // by the caller (updateForActiveWindowId) BEFORE calling us.
    if (windowId != 0 && windowId == self.lastLoadedMenuWindowId && self.currentMenu != nil) {
        NSDebugLog(@"AppMenuWidget: Already showing menu for window %lu - skipping re-import", windowId);
        return;
    }

    // Defensive check: ensure we're initialized
    if (!self.protocolManager) {
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Protocol manager not initialized, cannot display menu for window %lu", windowId);
        return;
    }
    
    // ANTI-FLICKER: Don't clear the old menu yet - keep it visible while loading the new one
    // We'll clear it after successfully loading the new menu
    
    if (windowId == 0) {
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: displayMenuForWindow called with 0 - hiding menu");
        [self clearMenuAndHideView];
        return;
    }

    // Defensive check: ensure the window still exists (it may have been closed since the event)
    BOOL windowValid = [AppMenuWidget isWindowStillValid:windowId];
    if (!windowValid) {
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Window %lu validity check failed - may be closing or not yet mapped", windowId);

        // If a menu is registered for this window despite validation failure, attempt to load it
        if ([self.protocolManager hasMenuForWindow:windowId]) {
            NSDebugLLog(@"gwcomp", @"AppMenuWidget: Menu is registered for window %lu - attempting to load despite validation failure", windowId);
        } else {
            [self clearMenuAndHideView];
            return;
        }
    }

    // Get application name for this window
    NSString *appName = nil;
    @try {
        appName = [MenuUtils getApplicationNameForWindow:windowId];
    }
    @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Exception getting app name for window %lu in displayMenuForWindow: %@", windowId, exception);
        appName = nil;
    }

    // Verify the application still has at least one visible window before showing its menu
    if (appName && [appName length] > 0) {
        BOOL appHasWindows = NO;
        NSDictionary *windowApps = [MenuUtils getAllVisibleWindowApplications];
        for (NSString *visibleApp in [windowApps allValues]) {
            if ([visibleApp isEqualToString:appName]) {
                appHasWindows = YES;
                break;
            }
        }

        if (!appHasWindows) {
            NSDebugLLog(@"gwcomp", @"AppMenuWidget: Application %@ has no visible windows - not displaying its menu", appName);
            [self clearMenuAndHideView];
            return;
        }

        self.currentApplicationName = appName;
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Window %lu belongs to application: %@", windowId, appName);
    }
    
    NSDebugLLog(@"gwcomp", @"AppMenuWidget: Displaying menu for window %lu", windowId);
    
    // Check if this window has a DBus menu registered
    @try {
        if (![self.protocolManager hasMenuForWindow:windowId]) {
            static unsigned long lastMissingMenuWindowId = 0;
            if (lastMissingMenuWindowId != windowId) {
                NSDebugLLog(@"gwcomp", @"AppMenuWidget: No registered menu for window %lu yet", windowId);
                lastMissingMenuWindowId = windowId;
            }

            // DON'T trigger immediate scan here - it can interfere with app startup
            // The periodic scanning will pick it up safely

            // If it's the Desktop window and it has no menu, clear immediately
            if ([MenuUtils isDesktopWindow:windowId]) {
                NSDebugLLog(@"gwcomp", @"AppMenuWidget: Desktop window %lu has no menu registered yet", windowId);
                [self clearMenuAndHideView];
                return;
            }

            // ANTI-FLICKER: If we have an old menu and the new window appears to have a
            // live AppMenu endpoint, keep the old menu visible for up to 2 seconds while
            // registration catches up.  If no live endpoint is detectable, skip waiting.
            if (self.currentMenu != nil && [self windowLikelyWillRegisterMenuSoon:windowId]) {
                NSDebugLLog(@"gwcomp", @"AppMenuWidget: Window %lu has a live AppMenu endpoint but is not registered yet - preserving old menu for up to 2s", windowId);

                // Cancel any existing grace period timer
                if (self.noMenuGracePeriodTimer) {
                    [self.noMenuGracePeriodTimer invalidate];
                    self.noMenuGracePeriodTimer = nil;
                }

                // Record when we started waiting so noMenuGracePeriodExpired can enforce the cap.
                self.gracePeriodStartTime = [NSDate timeIntervalSinceReferenceDate];
                self.pendingClearWindowId = windowId;
                self.noMenuGracePeriodTimer = [NSTimer scheduledTimerWithTimeInterval:0.2
                                                                                target:self
                                                                              selector:@selector(noMenuGracePeriodExpired:)
                                                                              userInfo:[NSNumber numberWithUnsignedLong:windowId]
                                                                               repeats:NO];
                return;
            }

            // Nothing to show at all - clear immediately
            [self clearMenuAndHideView];
            return;
        } else {
            // If we already have a menu, ensure we don't have any scheduled fallback (no-op in current flow)
            [self cancelScheduledFallbackForWindow:windowId];
            
            // Cancel grace period timer if this is the window we were waiting for
            if (self.noMenuGracePeriodTimer && self.pendingClearWindowId == windowId) {
                NSDebugLLog(@"gwcomp", @"AppMenuWidget: Window %lu now has a menu - canceling grace period timer", windowId);
                [self.noMenuGracePeriodTimer invalidate];
                self.noMenuGracePeriodTimer = nil;
                self.pendingClearWindowId = 0;
            }
        }
    }
    @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Exception during menu protocol check for window %lu: %@", windowId, exception);
        // Prevent fallback menu for desktop windows
        if ([MenuUtils isDesktopWindow:windowId]) {
            NSDebugLLog(@"gwcomp", @"AppMenuWidget: Suppressing fallback menu for desktop window %lu on exception", windowId);
            [self clearMenuAndHideView];
            return;
        }

#if ENABLE_FALLBACK_MENUS
        // Create fallback File->Close menu on exception
        NSMenu *fallbackMenu = [self createFileMenuWithClose:windowId];
        [self loadMenu:fallbackMenu forWindow:windowId];
#else
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Exception occurred but fallback menus disabled at compile time");
        [self clearMenuAndHideView];
#endif
        return;
    }
    
    NSDebugLLog(@"gwcomp", @"AppMenuWidget: ===== LOADING MENU FROM PROTOCOL MANAGER =====");

    /* The DBus/Canonical and org.gtk.Menus importers are gone. The only
       remaining live path is GNUStepMenuImporter, which receives menus
       pushed via Distributed Objects from pkgwrap's runtime menu-stub
       sidecar (one per wrapped X11 app) and from any future GNUstep
       client. GNUstep apps themselves no longer go through this path —
       MenuController.activeWindowChangedNotification: short-circuits them
       so they draw their own bar. */
    NSMenu *menu = nil;
    @try {
        menu = [self.protocolManager getMenuForWindow:windowId];
    }
    @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Exception getting menu from protocol manager for window %lu: %@", windowId, exception);
        menu = nil;
    }

    if (!menu) {
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Failed to get menu for window %lu (protocol manager)", windowId);
        [self clearMenuAndHideView];
        return;
    }
    
    // Debug: Log menu details for placeholder detection
    NSDebugLLog(@"gwcomp", @"AppMenuWidget: Menu has %lu items", (unsigned long)[[menu itemArray] count]);
    if ([[menu itemArray] count] > 0) {
        NSMenuItem *firstItem = [[menu itemArray] objectAtIndex:0];
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: First menu item: '%@' (enabled: %@)", [firstItem title], [firstItem isEnabled] ? @"YES" : @"NO");
    }
    
    BOOL isPlaceholder = [self isPlaceholderMenu:menu];
    NSDebugLLog(@"gwcomp", @"AppMenuWidget: isPlaceholderMenu: %@", isPlaceholder ? @"YES" : @"NO");
    
    if (isPlaceholder) {
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Placeholder menu - clearing");
        [self clearMenuAndHideView];
        return;
    }
    
    [self loadMenu:menu forWindow:windowId];
    NSDebugLLog(@"gwcomp", @"AppMenuWidget: Imported %lu menu items for window %lu", (unsigned long)[[menu itemArray] count], windowId);

    } // @try
    @finally {
        self.isInsideDisplayMenuForWindow = NO;
    }
}

- (void)setupMenuViewWithMenu:(NSMenu *)menu
{
    if (!menu) {
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Cannot setup menu view with nil menu");
        return;
    }

    NSDebugLLog(@"gwcomp", @"AppMenuWidget: Setting up menu view with menu: %@", [menu title]);
    
    // Set the current menu so drawRect knows we have menu content
    self.currentMenu = menu;
    
    // Lock the window to prevent flashing during menu updates
    NSWindow *window = [self window];
    if (window) {
        [window disableFlushWindow];
    }
    
    @try {
        // Remove any existing menu view to prevent crashes when adding new one
        if (self.menuView) {
            [self.menuView removeFromSuperview];
            self.menuView = nil;
            NSDebugLLog(@"gwcomp", @"AppMenuWidget: Removed existing menu view before creating new one");
        }

        // Calculate text width for positioning
        CGFloat textWidth = 0;
        if (self.currentApplicationName && [self.currentApplicationName length] > 0) {
            // We no longer draw the text, so textWidth is 0
            textWidth = 0;
        }

        // Ensure we don't duplicate the "Command" system menu item
        NSMutableIndexSet *commandItemIndexes = [NSMutableIndexSet indexSet];
        NSArray *menuItems = [menu itemArray];
        for (NSUInteger i = 0; i < [menuItems count]; i++) {
            NSMenuItem *existingItem = [menuItems objectAtIndex:i];
            if ([[existingItem title] isEqualToString:@"⌘"]) {
                [commandItemIndexes addIndex:i];
            }
        }
        if ([commandItemIndexes count] > 0) {
            [commandItemIndexes enumerateIndexesWithOptions:NSEnumerationReverse
                                                  usingBlock:^(NSUInteger idx, BOOL *stop) {
                (void)stop;
                [menu removeItemAtIndex:idx];
            }];
            NSDebugLLog(@"gwcomp", @"AppMenuWidget: Removed %lu duplicate Command menu item(s)", (unsigned long)[commandItemIndexes count]);
        }

        // Add the "Command" system menu item at the beginning
        NSMenuItem *systemItem = [[NSMenuItem alloc] initWithTitle:@"⌘" action:nil keyEquivalent:@""];
        NSMenu *systemMenu = [[NSMenu alloc] initWithTitle:@"System"];
        
        // Add "Search..." item to the system menu
        NSMenuItem *searchItem = [[NSMenuItem alloc] initWithTitle:@"Search..." 
                                                            action:@selector(toggleSearch:) 
                                                     keyEquivalent:@" "]; // Space
        [searchItem setKeyEquivalentModifierMask:NSCommandKeyMask];
        [searchItem setTarget:[ActionSearchController sharedController]];
        // Ensure ActionSearchController knows about our AppMenuWidget so it can collect items
        [[ActionSearchController sharedController] setAppMenuWidget:self];
        
        [systemMenu addItem:searchItem];
        [systemMenu addItem:[NSMenuItem separatorItem]];

        // Add a System Preferences entry and a separator after it
        NSMenuItem *prefsItem = [[NSMenuItem alloc] initWithTitle:@"System Preferences" action:@selector(openSystemPreferences:) keyEquivalent:@""];
        [prefsItem setTarget:self];
        [systemMenu addItem:prefsItem];
        [systemMenu addItem:[NSMenuItem separatorItem]];

        // Keep a reference to this system submenu so we can populate it dynamically
        self.systemMenu = systemMenu;
        [systemMenu setDelegate:self];
        // Listen for tracking begin so we can populate items reliably on open
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserver:self selector:@selector(systemMenuDidBeginTracking:) name:NSMenuDidBeginTrackingNotification object:systemMenu];

        // Populate once now so items show up immediately; we'll also repopulate when opened/tracked
        [self menuNeedsUpdate:systemMenu];
        // Log what we added for debugging
        NSArray *sysItems = [self.systemMenu itemArray];
        NSMutableArray *titles = [NSMutableArray array];
        for (NSMenuItem *mi in sysItems) {
            [titles addObject:[mi title]];
        }
        NSDebugLog(@"AppMenuWidget: System submenu initially has %lu items", (unsigned long)[sysItems count]);

        
        [systemItem setSubmenu:systemMenu];
        
        // Insert at the beginning of the menu
        [menu insertItem:systemItem atIndex:0];

        // Create a new horizontal menu view that fits within our widget frame, starting after the text
        NSRect menuViewFrame = NSMakeRect(textWidth, 0, [self bounds].size.width - textWidth, [self bounds].size.height);
        self.menuView = [[AppMenuView alloc] initWithFrame:menuViewFrame];

        if (!self.menuView) {
            NSDebugLLog(@"gwcomp", @"AppMenuWidget: Failed to create menu view - aborting setup");
            return;
        }

        // Configure the menu view for horizontal display (like a menu bar)
        [self.menuView setHorizontal:YES];
        [self.menuView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

        // Set the menu for the menu view
        [self.menuView setMenu:menu];
        
        // Set ourselves as the delegate of the main menu to catch AboutToShow events
        [menu setDelegate:self];
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Set AppMenuWidget as delegate for main menu: %@", [menu title]);
        
        // Check if this is a GNUStep menu by looking at menu items' representedObject
        BOOL isGNUStepMenu = NO;
        NSArray *items = [menu itemArray];
        for (NSMenuItem *item in items) {
            if ([item hasSubmenu]) {
                // Check submenu items
                NSArray *subitems = [[item submenu] itemArray];
                for (NSMenuItem *subitem in subitems) {
                    NSDictionary *repObject = [subitem representedObject];
                    if ([repObject isKindOfClass:[NSDictionary class]] && 
                        [repObject objectForKey:@"clientName"] && 
                        [repObject objectForKey:@"windowId"]) {
                        isGNUStepMenu = YES;
                        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Detected GNUStep menu via representedObject - preserving original target/action");
                        break;
                    }
                }
                if (isGNUStepMenu) break;
            }
        }
        
        // Add comprehensive logging to each menu item
        // DON'T override target/action for items that already have proper actions set
        for (NSUInteger i = 0; i < [items count]; i++) {
            NSMenuItem *item = [items objectAtIndex:i];
            NSDebugLog(@"AppMenuWidget: Setting up item %lu: '%@' (submenu: %@, target: %@, action: %@)", 
                  i, [item title], [item hasSubmenu] ? @"YES" : @"NO",
                  [item target], NSStringFromSelector([item action]));
            
            // Skip items that already have a target (they have proper action handlers)
            // Skip items with submenus (NSMenuView handles their display)
            // Only set placeholder actions for items without handlers
            if (!isGNUStepMenu && ![item hasSubmenu]) {
                if (![item target]) {
                    // This item doesn't have an action - set our placeholder
                    NSDebugLLog(@"gwcomp", @"AppMenuWidget: Item '%@' has NO target - setting placeholder action", [item title]);
                    [item setTarget:self];
                    [item setAction:@selector(menuItemClicked:)];
                    NSDebugLLog(@"gwcomp", @"AppMenuWidget: Set placeholder action for item without handler: '%@'", [item title]);
                } else {
                    // Item already has a target - preserve it
                    NSDebugLLog(@"gwcomp", @"AppMenuWidget: Item '%@' already has target '%@' with action '%@' - PRESERVING", 
                          [item title], [item target], NSStringFromSelector([item action]));
                }
            }
        }
        
        // Add the menu view to our widget (this makes it visible)
        [self addSubview:self.menuView];
        
        [self setNeedsDisplay:YES];
        
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Menu view setup complete with %lu menu items", 
              (unsigned long)[[menu itemArray] count]);
    }
    @finally {
        // Re-enable window drawing and flush all pending updates
        if (window) {
            [window enableFlushWindow];
            [window flushWindow];
            // Ensure overlay views (e.g., RoundedCornersView) are redrawn after
            // a menu update.  RoundedCornersView is a sibling of MenuBarView in
            // the window's contentView, so AppMenuWidget's setNeedsDisplay does
            // not propagate to it.  Marking the contentView ensures all siblings
            // (including the rounded-corners overlay) are included in the next
            // display pass.
            [[window contentView] setNeedsDisplay:YES];
        }
    }
}

- (void)drawRect:(NSRect)dirtyRect
{
    // Only draw if we have menu items to display
    BOOL hasMenu = (self.currentMenu && [[self.currentMenu itemArray] count] > 0);
    
    // Core fix: simplify state. If we have a menu, show it. Otherwise hide it.
    if (!hasMenu) {
        // No menu to display - clear the background completely
        [[NSColor clearColor] set];
        NSRectFill([self bounds]);
        
        // Hide the menu view when there's no menu
        if (self.menuView) {
            [self.menuView setHidden:YES];
        }
        return;
    }
    
    // Show new menu
    if (self.menuView) {
        [self.menuView setHidden:NO];
    }
    // Don't fill background - let the MenuBarView background show through
    // The menu items themselves will be drawn by the menuView
}

- (void)checkAndDisplayMenuForNewlyRegisteredWindow:(unsigned long)windowId
{
    // If we had a scheduled fallback for this window, cancel it — a real menu is now available
    [self cancelScheduledFallbackForWindow:windowId];

    // Get the currently active window using X11
    Display *display = [MenuUtils sharedDisplay];
    if (!display) {
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Cannot open X11 display for checking active window");
        return;
    }
    
    Window root = DefaultRootWindow(display);
    Window activeWindow = 0;
    Atom actualType;
    int actualFormat;
    unsigned long nitems, bytesAfter;
    unsigned char *prop = NULL;
    
    // Get _NET_ACTIVE_WINDOW property
    Atom activeWindowAtom = XInternAtom(display, "_NET_ACTIVE_WINDOW", False);
    SAFE_X11_CALL(display, {
        if (XGetWindowProperty(display, root, activeWindowAtom,
                              0, 1, False, AnyPropertyType,
                              &actualType, &actualFormat, &nitems, &bytesAfter,
                              &prop) == Success && prop) {
            activeWindow = *(Window*)prop;
            XFree(prop);
        }
    }, {
        // Cleanup on error
        if (prop) {
            XFree(prop);
            prop = NULL;
        }
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Failed to get active window for newly registered window check due to X11 error");
    });
    
    // If the newly registered window is the currently active window, display its menu immediately
    if (activeWindow == windowId) {
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Newly registered window %lu is currently active, forcing menu load", windowId);
        @try {
            // Reset the optimisation guard so the new menu is loaded even if we
            // previously attempted (and failed/skipped) this window.
            self.lastLoadedMenuWindowId = 0;
            self.currentWindowId = windowId;
            // Call displayMenuForWindow: directly instead of updateForActiveWindowId:
            // to bypass the 50ms rate-limit guard — this is a one-shot event triggered
            // by a real menu registration and must not be throttled.
            [self displayMenuForWindow:windowId isDifferentApp:YES];
        }
        @catch (NSException *exception) {
            NSDebugLLog(@"gwcomp", @"AppMenuWidget: Exception updating menu for newly registered window %lu: %@", windowId, exception);
        }
    } else {
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Newly registered window %lu is not currently active (active: %lu)", windowId, activeWindow);
    }
}

// Debug method implementation

// MARK: - NSMenuDelegate Methods for Main Menu

- (void)menuWillOpen:(NSMenu *)menu
{
    NSDebugLog(@"AppMenuWidget: menuWillOpen: '%@' (window %lu)", [menu title] ?: @"(no title)", self.currentWindowId);
}

// menuNeedsUpdate is called to allow menus to be repopulated before they open
- (void)menuNeedsUpdate:(NSMenu *)menu
{
    if (menu != self.systemMenu) {
        return;
    }

    // Prevent re-entrancy / repeated updates that can cause rapid loops
    if (self.isUpdatingSystemMenu) {
        // Already updating — silently skip to avoid log spam and re-entrancy
        return;
    }

    // Throttle frequent updates to avoid CPU / log thrashing
    NSTimeInterval now = [[NSDate date] timeIntervalSinceReferenceDate];
    if (now - self.lastSystemMenuUpdateTime < SYSTEM_MENU_UPDATE_MIN_INTERVAL) {
        // Too frequent - skip this update
        return;
    }
    // Record this attempt's timestamp
    self.lastSystemMenuUpdateTime = now;

    self.isUpdatingSystemMenu = YES;
    NSDebugLog(@"AppMenuWidget: System submenu needs update - populating System Applications list");

    @try {


    NSArray *items = [menu itemArray];
    NSInteger prefsIndex = NSNotFound;
    for (NSUInteger i = 0; i < [items count]; i++) {
        NSMenuItem *it = [items objectAtIndex:i];
        if ([[it title] isEqualToString:@"System Preferences"]) {
            prefsIndex = (NSInteger)i;
            break;
        }
    }

    NSInteger startIndex = (prefsIndex != NSNotFound) ? (prefsIndex + 2) : 3; // where app list should begin

    // Remove any old application entries that were previously added directly after the prefs separator
    while ([menu numberOfItems] > startIndex) {
        [menu removeItemAtIndex:startIndex];
    }

    // Directories to search for .app bundles (make robust to both plural/singular and common locations)
    NSArray *dirs = @[[NSHomeDirectory() stringByAppendingPathComponent:@"Applications"],
                      @"/Local/Applications", @"/Local/Application",
                      @"/Network/Applications", @"/Network/Application",
                      @"/Applications",
                      @"/System/Applications", @"/System/Application"];
    NSFileManager *fm = [NSFileManager defaultManager];

    // Map of dedupeKey -> @{ "path": path, "title": title, "priority": @(priority) }
    NSMutableDictionary *appsByKey = [NSMutableDictionary dictionary];

    // Helper to compute a precedence score for a given path (higher wins)
    NSInteger (^priorityForPath)(NSString *) = ^NSInteger(NSString *p) {
        NSString *homePrefix = [NSHomeDirectory() stringByAppendingPathComponent:@"Applications"];
        if ([p hasPrefix:homePrefix]) return 4; // ~/Applications (best)
        if ([p hasPrefix:@"/Local/Applications"] || [p hasPrefix:@"/Local/Application"]) return 3; // /Local
        if ([p hasPrefix:@"/Applications"]) return 2; // /Applications (root)
        if ([p hasPrefix:@"/Network/Applications"] || [p hasPrefix:@"/Network/Application"]) return 1; // /Network
        if ([p hasPrefix:@"/System/Applications"] || [p hasPrefix:@"/System/Application"]) return 0; // /System (fallback)
        return 0;
    };

    for (NSString *dir in dirs) {
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:dir isDirectory:&isDir] && isDir) {
            NSArray *contents = [fm contentsOfDirectoryAtPath:dir error:nil];
            for (NSString *entry in contents) {
                if ([[entry pathExtension] isEqualToString:@"app"]) {
                    NSString *fullPath = [dir stringByAppendingPathComponent:entry];

                    // Try reading bundle identifier from Info.plist (Contents/Info.plist is common)
                    NSString *infoPath = [fullPath stringByAppendingPathComponent:@"Contents/Info.plist"];
                    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPath];
                    NSString *bundleID = info[@"CFBundleIdentifier"];

                    // Dedupe key: CFBundleIdentifier when available, otherwise lowercased bundle name
                    NSString *key = nil;
                    if (bundleID && [bundleID length] > 0) {
                        key = bundleID;
                    } else {
                        key = [[[entry stringByDeletingPathExtension] lowercaseString] copy];
                    }

                    NSInteger pri = priorityForPath(fullPath);

                    NSDictionary *existing = appsByKey[key];
                    NSString *displayName = [[fullPath lastPathComponent] stringByDeletingPathExtension];
                    if (!existing) {
                        appsByKey[key] = @{@"path": fullPath, @"title": displayName, @"priority": @(pri)};
                    } else {
                        NSInteger existingPri = [existing[@"priority"] integerValue];
                        if (pri > existingPri) {
                            // Current path has higher precedence - replace
                            appsByKey[key] = @{@"path": fullPath, @"title": displayName, @"priority": @(pri)};
                        } else {
                            // Keep the higher-precedence existing entry
                        }
                    }
                }
            }
        }
    }

    NSDebugLog(@"AppMenuWidget: Found %lu application bundles after dedupe", (unsigned long)[appsByKey count]);

    // Sort by display name
    NSArray *sortedApps = [[appsByKey allValues] sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSString *na = [[a[@"title"] lowercaseString] copy];
        NSString *nb = [[b[@"title"] lowercaseString] copy];
        return [na compare:nb];
    }];

    // Find or create an "Applications" submenu item at startIndex
    NSMenuItem *appsItem = nil;
    if ([menu numberOfItems] > startIndex && [[menu itemAtIndex:startIndex] isKindOfClass:[NSMenuItem class]] && [[[menu itemAtIndex:startIndex] title] isEqualToString:@"Applications"]) {
        appsItem = [menu itemAtIndex:startIndex];
    } else {
        // Insert an Applications submenu at this position
        NSMenu *appsSubmenu = [[NSMenu alloc] initWithTitle:@"Applications"];
        appsItem = [[NSMenuItem alloc] initWithTitle:@"Applications" action:nil keyEquivalent:@""];
        [appsItem setSubmenu:appsSubmenu];
        [menu insertItem:appsItem atIndex:startIndex];
    }

    NSMenu *appsSubmenu = [appsItem submenu];
    // Clear old submenu contents
    [appsSubmenu removeAllItems];

    for (NSDictionary *entry in sortedApps) {
        NSString *path = entry[@"path"];
        NSString *title = entry[@"title"];
        NSMenuItem *appItem = [[NSMenuItem alloc] initWithTitle:title action:@selector(openApplicationBundle:) keyEquivalent:@""];
        [appItem setTarget:self];
        [appItem setRepresentedObject:path];
        [appsSubmenu addItem:appItem];
    }

    if ([sortedApps count] == 0) {
        NSMenuItem *noneItem = [[NSMenuItem alloc] initWithTitle:@"No applications found" action:nil keyEquivalent:@""];
        [noneItem setEnabled:NO];
        [appsSubmenu addItem:noneItem];
    }
    }
    @finally {
        // Always clear the updating flag so further updates can occur later
        self.isUpdatingSystemMenu = NO;
    }
}

- (void)menuDidClose:(NSMenu *)menu
{
    NSDebugLog(@"AppMenuWidget: Main menu did close: '%@'", [menu title] ?: @"(no title)");
}

- (void)menu:(NSMenu *)menu willHighlightItem:(NSMenuItem *)item
{
    (void)menu;
    (void)item;
    // Hot path — avoid any logging or work here
}

- (BOOL)menu:(NSMenu *)menu updateItem:(NSMenuItem *)item atIndex:(NSInteger)index shouldCancel:(BOOL)shouldCancel
{
    (void)menu;
    (void)item;
    (void)index;
    (void)shouldCancel;
    // Don't re-trigger menu population from inside updateItem — this causes tight loops.
    return YES;
}

- (NSInteger)numberOfItemsInMenu:(NSMenu *)menu
{
    return [[menu itemArray] count];
}

- (NSRect)confinementRectForMenu:(NSMenu *)menu onScreen:(NSScreen *)screen
{
    (void)menu;
    return [screen frame];
}

// MARK: - Mouse Event Tracking

- (void)mouseEntered:(NSEvent *)theEvent
{
    NSDebugLog(@"AppMenuWidget: Mouse entered at location: %@", NSStringFromPoint([theEvent locationInWindow]));
    [super mouseEntered:theEvent];
}

- (void)mouseExited:(NSEvent *)theEvent
{
    NSDebugLog(@"AppMenuWidget: Mouse exited at location: %@", NSStringFromPoint([theEvent locationInWindow]));
    [super mouseExited:theEvent];
}

- (void)mouseMoved:(NSEvent *)theEvent
{
    [super mouseMoved:theEvent];
}

- (void)mouseDown:(NSEvent *)theEvent
{
    if (self.menuView && self.currentMenu) {
        NSPoint location = [theEvent locationInWindow];
        NSPoint localPoint = [self convertPoint:location fromView:nil];
        NSPoint menuViewPoint = [self.menuView convertPoint:location fromView:nil];
        NSDebugLog(@"AppMenuWidget: Mouse down at: %@ (local: %@, menuView: %@)",
              NSStringFromPoint(location), NSStringFromPoint(localPoint), NSStringFromPoint(menuViewPoint));
        
        [self.menuView mouseDown:theEvent];
    }
    
    [super mouseDown:theEvent];
}

- (void)mouseUp:(NSEvent *)theEvent
{
    if (self.menuView) {
        [self.menuView mouseUp:theEvent];
    }
}

// MARK: - Debug Methods

- (void)menuItemClicked:(NSMenuItem *)sender
{
    NSDebugLog(@"AppMenuWidget: Clicked menu item: '%@' tag:%ld", [sender title], (long)[sender tag]);
    
    // If this item has representedObject data (from protocol handler), try to trigger the action
    if ([sender representedObject]) {
        // If the item's original target is set, call its action
        if ([sender target]) {
            SEL action = [sender action];
            if (action && [sender.target respondsToSelector:action]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                [sender.target performSelector:action withObject:sender];
#pragma clang diagnostic pop
                return;
            }
        }
    }
    
    NSDebugLog(@"AppMenuWidget: No action handler found for menu item: '%@'", [sender title]);
}

- (void)debugLogCurrentMenuState
{
    NSDebugLLog(@"gwcomp", @"AppMenuWidget: ===== DEBUG MENU STATE =====");
    NSDebugLLog(@"gwcomp", @"AppMenuWidget: Current window ID: %lu", self.currentWindowId);
    NSDebugLLog(@"gwcomp", @"AppMenuWidget: Current application: %@", self.currentApplicationName ?: @"(none)");
    NSDebugLLog(@"gwcomp", @"AppMenuWidget: Current menu: %@", self.currentMenu ? [self.currentMenu title] : @"(none)");
    
    if (self.currentMenu) {
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Current menu has %lu items", (unsigned long)[[self.currentMenu itemArray] count]);
        NSArray *items = [self.currentMenu itemArray];
        for (NSUInteger i = 0; i < [items count]; i++) {
            NSMenuItem *item = [items objectAtIndex:i];
            NSDebugLLog(@"gwcomp", @"AppMenuWidget: Item %lu: '%@' (submenu: %@)", 
                  i, [item title], [item hasSubmenu] ? @"YES" : @"NO");
        }
    }
    
    NSDebugLLog(@"gwcomp", @"AppMenuWidget: Menu view: %@", self.menuView);
    NSDebugLLog(@"gwcomp", @"AppMenuWidget: Protocol manager: %@", self.protocolManager);
    NSDebugLLog(@"gwcomp", @"AppMenuWidget: ===== END DEBUG MENU STATE =====");
}

- (BOOL)isPlaceholderMenu:(NSMenu *)menu
{
    if (!menu || [[menu itemArray] count] == 0) {
        return YES;
    }
    
    // Check if this is the "GTK Application" placeholder menu
    NSArray *items = [menu itemArray];
    if ([items count] == 1) {
        NSMenuItem *firstItem = [items objectAtIndex:0];
        if ([[firstItem title] isEqualToString:@"GTK Application"]) {
            return YES;
        }
    }
    
    return NO;
}

- (NSMenu *)createFileMenuWithClose:(unsigned long)windowId
{
#if ENABLE_FALLBACK_MENUS
    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
    
    // Create Close menu item with Cmd+W
    NSMenuItem *closeItem = [[NSMenuItem alloc] initWithTitle:@"Close" action:@selector(closeWindow:) keyEquivalent:@"w"];
    [closeItem setKeyEquivalentModifierMask:NSCommandKeyMask];
    [closeItem setTarget:self];
    [closeItem setRepresentedObject:[NSNumber numberWithUnsignedLong:windowId]];
    [fileMenu addItem:closeItem];
    
    NSMenu *mainMenu = [[NSMenu alloc] initWithTitle:@"Main Menu"];
    NSMenuItem *fileMenuItem = [[NSMenuItem alloc] initWithTitle:@"File" action:nil keyEquivalent:@""];
    [fileMenuItem setSubmenu:fileMenu];
    [mainMenu addItem:fileMenuItem];
    
    return mainMenu;
#else
    (void)windowId;  // Suppress unused parameter warning
    return nil;
#endif
}

// Schedule a delayed fallback menu to avoid showing fallback immediately when an app is starting up
- (void)scheduleFallbackMenuForWindow:(unsigned long)windowId delay:(NSTimeInterval)delay
{
#if ENABLE_FALLBACK_MENUS
    NSNumber *key = [NSNumber numberWithUnsignedLong:windowId];
    if ([self.fallbackTimers objectForKey:key]) {
        // Already scheduled
        return;
    }

    NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:delay target:self selector:@selector(fallbackTimerFired:) userInfo:key repeats:NO];
    [self.fallbackTimers setObject:timer forKey:key];
#else
    (void)windowId;  // Suppress unused parameter warning
    (void)delay;     // Suppress unused parameter warning
#endif
}

- (void)cancelScheduledFallbackForWindow:(unsigned long)windowId
{
#if ENABLE_FALLBACK_MENUS
    NSNumber *key = [NSNumber numberWithUnsignedLong:windowId];
    NSTimer *timer = [self.fallbackTimers objectForKey:key];
    if (timer) {
        [timer invalidate];
        [self.fallbackTimers removeObjectForKey:key];
    }
#else
    (void)windowId;  // Suppress unused parameter warning
#endif
}

- (void)fallbackTimerFired:(NSTimer *)timer
{
#if ENABLE_FALLBACK_MENUS
    NSNumber *windowNum = (NSNumber *)[timer userInfo];
    [self.fallbackTimers removeObjectForKey:windowNum];

    unsigned long windowId = [windowNum unsignedLongValue];

    // If the user switched away, do nothing
    if (self.currentWindowId != windowId) {
        return;
    }

    // If a real menu appeared in the meantime, cancel fallback
    if ([self.protocolManager hasMenuForWindow:windowId]) {
        return;
    }

    // Prevent fallback for desktop windows
    if ([MenuUtils isDesktopWindow:windowId]) {
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Suppressing fallback menu for desktop window %lu (delayed)", windowId);
        return;
    }

    NSDebugLLog(@"gwcomp", @"AppMenuWidget: No menu received for window %lu after delay, providing fallback menu", windowId);
    NSMenu *fallbackMenu = [self createFileMenuWithClose:windowId];
    [self loadMenu:fallbackMenu forWindow:windowId];
#else
    (void)timer;  // Suppress unused parameter warning
#endif
}

- (void)closeWindow:(NSMenuItem *)sender
{
#if ENABLE_FALLBACK_MENUS
    NSNumber *windowIdNumber = [sender representedObject];
    if (!windowIdNumber) {
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: closeWindow called but no window ID in representedObject");
        return;
    }
    
    unsigned long windowId = [windowIdNumber unsignedLongValue];
    NSDebugLLog(@"gwcomp", @"AppMenuWidget: Closing window %lu", windowId);
    
    // Send Alt+F4 to close the window
    [self sendAltF4ToWindow:windowId];
#else
    (void)sender;  // Suppress unused parameter warning
#endif
}

- (void)sendAltF4ToWindow:(unsigned long)windowId
{
    Display *display = [MenuUtils sharedDisplay];
    if (!display) {
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Failed to open X11 display for window close");
        return;
    }
    
    Window window = (Window)windowId;
    Window root = DefaultRootWindow(display);
    
    // Send Alt+F4 key event to the window
    // We use the root window to ensure the window manager can intercept it
    XEvent keyEvent;
    memset(&keyEvent, 0, sizeof(keyEvent));
    
    // Make sure the target window has focus first
    XSetInputFocus(display, window, RevertToParent, CurrentTime);
    XFlush(display);
    
    // Press Alt+F4
    keyEvent.xkey.type = KeyPress;
    keyEvent.xkey.display = display;
    keyEvent.xkey.window = window;
    keyEvent.xkey.root = root;
    keyEvent.xkey.subwindow = None;
    keyEvent.xkey.time = CurrentTime;
    keyEvent.xkey.x = 1;
    keyEvent.xkey.y = 1;
    keyEvent.xkey.x_root = 1;
    keyEvent.xkey.y_root = 1;
    keyEvent.xkey.state = Mod1Mask; // Alt modifier
    keyEvent.xkey.keycode = XKeysymToKeycode(display, XK_F4);
    keyEvent.xkey.same_screen = True;
    
    // Send to both the window and root (for window manager)
    XSendEvent(display, window, True, KeyPressMask, &keyEvent);
    XSendEvent(display, root, False, KeyPressMask, &keyEvent);
    
    // Release Alt+F4
    keyEvent.xkey.type = KeyRelease;
    XSendEvent(display, window, True, KeyReleaseMask, &keyEvent);
    XSendEvent(display, root, False, KeyReleaseMask, &keyEvent);
    
    NSDebugLLog(@"gwcomp", @"AppMenuWidget: Sent Alt+F4 key event to window %lu", windowId);
    
    XFlush(display);
}

// preWarmCacheForApplication removed

- (void)loadMenu:(NSMenu *)menu forWindow:(unsigned long)windowId
{
    if (!menu) {
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Cannot load nil menu for window %lu", windowId);
        return;
    }
    
    // Cancel any scheduled fallback for this window since we're loading a real menu
    [self cancelScheduledFallbackForWindow:windowId];

    NSDebugLLog(@"gwcomp", @"AppMenuWidget: Loading menu for window %lu", windowId);
    
    // Clear the waiting flag - we have a new menu
    self.isWaitingForMenu = NO;
    self.currentMenu = menu;
    self.lastLoadedMenuWindowId = windowId;  // Track which window we loaded for (used by same-window guard)
    self.needsRedraw = YES;  // Mark that we need to redraw with new menu
    
    NSDebugLLog(@"gwcomp", @"AppMenuWidget: ===== MENU LOADED, SETTING UP VIEW =====");
    NSDebugLLog(@"gwcomp", @"AppMenuWidget: Menu has %lu top-level items", (unsigned long)[[menu itemArray] count]);
    
    // Log each top-level menu item and whether it has submenus
    NSArray *items = [menu itemArray];
    for (NSUInteger i = 0; i < [items count]; i++) {
        NSMenuItem *item = [items objectAtIndex:i];
        NSDebugLog(@"AppMenuWidget: Top-level item %lu: '%@' (has submenu: %@, submenu items: %lu)", 
              i, [item title], [item hasSubmenu] ? @"YES" : @"NO",
              [item hasSubmenu] ? (unsigned long)[[[item submenu] itemArray] count] : 0);
    }
    
    // ANTI-FLICKER: Clear shortcuts ONLY if switching to a different application
    // This must happen before setupMenuViewWithMenu to avoid conflicts
    if (self.currentWindowId != windowId) {
        pid_t oldPid = (self.currentWindowId != 0) ? [MenuUtils getWindowPID:self.currentWindowId] : 0;
        pid_t newPid = [MenuUtils getWindowPID:windowId];
        BOOL switchingToDifferentApp = (oldPid == 0 || newPid == 0 || oldPid != newPid);
        
        if (switchingToDifferentApp) {
            NSDebugLLog(@"gwcomp", @"AppMenuWidget: Switching to different app (PID %d -> %d) - clearing non-direct shortcuts", 
                  (int)oldPid, (int)newPid);
            [[X11ShortcutManager sharedManager] unregisterNonDirectShortcuts];
        } else {
            NSDebugLLog(@"gwcomp", @"AppMenuWidget: Same app (PID %d) - keeping shortcuts registered", (int)newPid);
        }
    }
    
    @try {
        [self setupMenuViewWithMenu:menu];
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: setupMenuViewWithMenu completed successfully");
    }
    @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: EXCEPTION in setupMenuViewWithMenu: %@", exception);
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Exception details - name: %@, reason: %@", [exception name], [exception reason]);
    }
    
    // Re-register shortcuts for this menu since we may have cleared them above
    [self reregisterShortcutsForMenu:menu];
    
    NSDebugLLog(@"gwcomp", @"AppMenuWidget: Successfully loaded fallback menu with %lu items", (unsigned long)[[menu itemArray] count]);
} 



// Background-run helpers: use libdispatch when available, otherwise fall back to performSelectorInBackground
- (void)appMenuBackgroundRunner:(id)blockObj
{
    void (^block)(void) = blockObj;
    @autoreleasepool {
        if (block) block();
    }
}

- (void)runBlockInBackground:(void (^)(void))block
{
#if AMW_HAS_DISPATCH
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), block);
#else
    if (block) {
        [self performSelectorInBackground:@selector(appMenuBackgroundRunner:) withObject:[block copy]];
    }
#endif
} 

- (void)openSystemPreferences:(NSMenuItem *)sender
{
    (void)sender;

    // Close the menu immediately to keep the UI responsive
    NSMenu *parentMenu = [sender menu];
    if (parentMenu && [parentMenu respondsToSelector:@selector(cancelTracking)]) {
        [parentMenu performSelector:@selector(cancelTracking)];
    }

    // Perform the heavy path scanning and launch attempts on a background queue
    [self runBlockInBackground:^{
        // Try a few ways to launch System Preferences. Some installs use 'System Preferences' while
        // others may have 'SystemPreferences' or a different bundle name. Try matching the bundle name
        // and finally fall back to opening the bundle path.

        NSArray *candidatePaths = @[@"/System/Applications/System Preferences.app",
                                    @"/System/Applications/SystemPreferences.app",
                                    @"/Applications/System Preferences.app",
                                    @"/Applications/SystemPreferences.app",
                                    [NSHomeDirectory() stringByAppendingPathComponent:@"Applications/System Preferences.app"],
                                    [NSHomeDirectory() stringByAppendingPathComponent:@"Applications/SystemPreferences.app"],
                                    @"/Local/Applications/System Preferences.app",
                                    @"/Local/Applications/SystemPreferences.app"];

        // First try launching by common application names
        NSArray *commonNames = @[@"System Preferences", @"SystemPreferences", @"System-Preferences"];
        for (NSString *name in commonNames) {
            if ([[NSWorkspace sharedWorkspace] launchApplication:name]) {
                NSDebugLLog(@"gwcomp", @"AppMenuWidget: Launched System Preferences by name: %@", name);
                return;
            }
        }

        NSFileManager *fm = [NSFileManager defaultManager];

        // Try exact candidate paths first and log checks
        for (NSString *p in candidatePaths) {
            BOOL exists = [fm fileExistsAtPath:p];
            NSDebugLLog(@"gwcomp", @"AppMenuWidget: Checking candidate path for prefs: %@ (exists=%@)", p, exists ? @"YES" : @"NO");
            if (exists) {
                NSURL *url = [NSURL fileURLWithPath:p];
                NSString *bundleName = [[p lastPathComponent] stringByDeletingPathExtension];
                if (bundleName && [bundleName length] > 0) {
                    if ([[NSWorkspace sharedWorkspace] launchApplication:bundleName]) {
                        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Launched System Preferences using bundle name: %@", bundleName);
                        return;
                    }
                    NSDebugLLog(@"gwcomp", @"AppMenuWidget: launchApplication: failed for %@", bundleName);
                }

                BOOL ok = [[NSWorkspace sharedWorkspace] openURL:url];
                if (ok) {
                    NSDebugLLog(@"gwcomp", @"AppMenuWidget: Opened System Preferences bundle at %@", p);
                } else {
                    NSDebugLLog(@"gwcomp", @"AppMenuWidget: Failed to open System Preferences at %@", p);
                }
                return;
            }
        }

        // Fallback: scan /System/Applications and /Applications for likely candidates (case-insensitive matching)
        NSArray *scanDirs = @[@"/System/Applications", @"/Applications", [NSHomeDirectory() stringByAppendingPathComponent:@"Applications"]];
        for (NSString *dir in scanDirs) {
            BOOL isDir = NO;
            if ([fm fileExistsAtPath:dir isDirectory:&isDir] && isDir) {
                NSArray *contents = [fm contentsOfDirectoryAtPath:dir error:nil];
                for (NSString *entry in contents) {
                    if ([[entry pathExtension] isEqualToString:@"app"]) {
                        NSString *name = [[entry stringByDeletingPathExtension] lowercaseString];
                        if ([name containsString:@"system"] && ([name containsString:@"pref"] || [name containsString:@"setting"])) {
                            NSString *fullPath = [dir stringByAppendingPathComponent:entry];
                            NSDebugLLog(@"gwcomp", @"AppMenuWidget: Found probable System Preferences at %@", fullPath);
                            NSURL *url = [NSURL fileURLWithPath:fullPath];
                            NSString *bundleName = [entry stringByDeletingPathExtension];
                            if ([[NSWorkspace sharedWorkspace] launchApplication:bundleName]) {
                                NSDebugLLog(@"gwcomp", @"AppMenuWidget: Launched System Preferences via bundle name: %@", bundleName);
                                return;
                            }
                            if ([[NSWorkspace sharedWorkspace] openURL:url]) {
                                NSDebugLLog(@"gwcomp", @"AppMenuWidget: Opened System Preferences bundle at %@", fullPath);
                                return;
                            }
                        }
                    }
                }
            }
        }

        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Could not find System Preferences to launch");
    }];
}

- (void)openApplicationBundle:(NSMenuItem *)sender
{
    NSString *path = [sender representedObject];
    if (!path) return;

    // Close the menu immediately to keep the UI responsive (works on GNUstep and Cocoa variants)
    NSMenu *parentMenu = [sender menu];
    if (parentMenu && [parentMenu respondsToSelector:@selector(cancelTracking)]) {
        [parentMenu performSelector:@selector(cancelTracking)];
    }

    // Launch asynchronously so the UI thread doesn't block
    [self runBlockInBackground:^{
        NSWorkspace *ws = [NSWorkspace sharedWorkspace];

        // Try launching by bundle name first (e.g., 'Visual Studio Code')
        NSString *bundleName = [[path lastPathComponent] stringByDeletingPathExtension];
        if (bundleName && [bundleName length] > 0) {
            if ([ws launchApplication:bundleName]) {
                NSDebugLLog(@"gwcomp", @"AppMenuWidget: Launched application by name: %@", bundleName);
                return;
            }
            NSDebugLLog(@"gwcomp", @"AppMenuWidget: launchApplication: failed for %@", bundleName);
        }

        // Try reading Info.plist to find a bundle identifier or executable
        NSString *infoPath = [path stringByAppendingPathComponent:@"Contents/Info.plist"];
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPath];
        if (info) {
            NSString *bundleID = info[@"CFBundleIdentifier"];
            if (bundleID && [bundleID length] > 0) {
                if ([ws launchApplication:bundleID]) {
                    NSDebugLLog(@"gwcomp", @"AppMenuWidget: Launched application using bundle identifier: %@", bundleID);
                    return;
                }
                NSDebugLLog(@"gwcomp", @"AppMenuWidget: launchApplication: failed for bundle identifier %@", bundleID);
            }
        }

        // Fallback: open the bundle URL (best-effort)
        NSURL *url = [NSURL fileURLWithPath:path];
        if ([ws openURL:url]) {
            NSDebugLLog(@"gwcomp", @"AppMenuWidget: Opened application bundle at %@", path);
            return;
        }

        // Final fallback: try openFile which some environments handle specially
        if ([ws openFile:path]) {
            NSDebugLLog(@"gwcomp", @"AppMenuWidget: Opened application bundle via openFile: %@", path);
            return;
        }

        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Failed to launch application at %@", path);
    }];
}

- (void)closeActiveWindow:(NSMenuItem *)sender
{
    // Get the currently active window using X11
    Display *display = [MenuUtils sharedDisplay];
    if (!display) {
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Cannot open X11 display for active window detection");
        return;
    }
    
    Window root = DefaultRootWindow(display);
    Window activeWindow = 0;
    Atom actualType;
    int actualFormat;
    unsigned long nitems, bytesAfter;
    unsigned char *prop = NULL;
    
    // Get _NET_ACTIVE_WINDOW property
    Atom activeWindowAtom = XInternAtom(display, "_NET_ACTIVE_WINDOW", False);
    SAFE_X11_CALL(display, {
        if (XGetWindowProperty(display, root, activeWindowAtom,
                              0, 1, False, AnyPropertyType,
                              &actualType, &actualFormat, &nitems, &bytesAfter,
                              &prop) == Success && prop) {
            activeWindow = *(Window*)prop;
            XFree(prop);
        }
    }, {
        // Cleanup on error
        if (prop) {
            XFree(prop);
            prop = NULL;
        }
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Failed to get active window for close operation due to X11 error");
    });
    
    if (activeWindow == 0) {
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Could not determine active window for Alt+W close");
        return;
    }
    
    NSDebugLLog(@"gwcomp", @"AppMenuWidget: Alt+W triggered - closing currently active window %lu", activeWindow);
    
    // Send Alt+F4 to close the currently active window
    [self sendAltF4ToWindow:activeWindow];
}

- (void)reregisterShortcutsForMenu:(NSMenu *)menu
{
    // This method is now handled by the protocol managers when they return cached menus
    // GTKMenuImporter and DBusMenuImporter will re-register shortcuts automatically
    NSDebugLLog(@"gwcomp", @"AppMenuWidget: Shortcut re-registration handled by protocol managers");
}

- (void)reregisterGTKShortcut:(NSMenuItem *)item
{
    // For GTK shortcuts, we need to get the stored action data and re-register
    // We would need access to GTKActionHandler's static data, but for now
    // let's register it as a basic shortcut that will trigger the existing action
    NSDebugLLog(@"gwcomp", @"AppMenuWidget: Re-registering GTK shortcut for item: %@", [item title]);
    
    [[X11ShortcutManager sharedManager] registerShortcutForMenuItem:item
                                                        serviceName:nil
                                                         objectPath:nil 
                                                     dbusConnection:nil];
}

- (void)reregisterDBusShortcut:(NSMenuItem *)item
{
    // For DBus shortcuts, similar approach
    NSDebugLLog(@"gwcomp", @"AppMenuWidget: Re-registering DBus shortcut for item: %@", [item title]);
    
    [[X11ShortcutManager sharedManager] registerShortcutForMenuItem:item
                                                        serviceName:nil
                                                         objectPath:nil
                                                     dbusConnection:nil];
}

#pragma mark - Window Validity Checks

+ (BOOL)isWindowStillValid:(Window)windowId
{
    if (windowId == 0) {
        return NO;
    }
    
    Display *display = [MenuUtils sharedDisplay];
    if (!display) {
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Cannot open X11 display for window validation");
        return NO;
    }
    
    BOOL isValid = NO;
    
    // Try to get window attributes to check if window still exists and is mapped
    SAFE_X11_CALL(display, {
        XWindowAttributes attrs;
        // XGetWindowAttributes returns non-zero on success
        if (XGetWindowAttributes(display, windowId, &attrs)) {
            if (attrs.map_state == IsViewable) {
                isValid = YES;
            } else {
                NSDebugLog(@"AppMenuWidget: Window %lu is valid but not mapped (map_state: %d)", windowId, attrs.map_state);
            }
        }
    }, {
        // Error occurred - window is invalid
        isValid = NO;
    });
    
    return isValid;
}

+ (BOOL)safelyCheckWindow:(Window)windowId withDisplay:(Display *)display
{
    if (windowId == 0 || !display) {
        return NO;
    }
    
    BOOL isValid = NO;
    
    SAFE_X11_CALL(display, {
        XWindowAttributes attrs;
        if (XGetWindowAttributes(display, windowId, &attrs) != BadWindow) {
            isValid = YES;
        }
    }, {
        // Error occurred - window is invalid
        isValid = NO;
    });
    
    return isValid;
}

- (void)handleWindowDisappeared:(Window)windowId
{
    NSDebugLLog(@"gwcomp", @"AppMenuWidget: Window %lu disappeared, performing emergency cleanup", windowId);
    
    // If this is our current window, clear everything immediately
    if (self.currentWindowId == windowId) {
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Current window disappeared, clearing all state");
        
        // Clear all state immediately
        self.currentWindowId = 0;
        self.currentApplicationName = nil;
        self.currentMenu = nil;
        
        // Remove system menu observer if present
        if (self.systemMenu) {
            NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
            [nc removeObserver:self name:NSMenuDidBeginTrackingNotification object:self.systemMenu];
            self.systemMenu = nil;
        }
        
        // Hide menu view and force redraw
        if (self.menuView) {
            self.menuView.hidden = YES;
        }
        self.needsRedraw = YES;
        self.currentMenu = nil;

    }
}

@end
