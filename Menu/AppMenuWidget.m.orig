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
#import "GTKActionHandler.h"
#import "DBusMenuActionHandler.h"
#import "DBusConnection.h"
#import "ActionSearch.h"
#import "MenuProfiler.h"
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
// Grace window for transient activeWindow==0 reports during close/switch churn
#define NO_ACTIVE_WINDOW_GRACE_SECS 2.0
#define MODAL_RECOVERY_FORCE_RELOAD_MIN_INTERVAL 0.35

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

- (void)dealloc
{
    // Safety net: GNUstep's NSNotificationCenter keeps unsafe (non-retaining) observer
    // pointers.  Remove all registrations now so no dangling pointer is left behind
    // to crash the next time any NSMenu posts NSMenuDidAddItemNotification.
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

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
@property (nonatomic, assign) pid_t currentWindowPID;
@property (nonatomic, assign) NSTimeInterval lastWindowSwitchTime;
@property (nonatomic, assign) BOOL preservingMenuForDialogTransition;
@property (nonatomic, assign) NSTimeInterval dialogPreserveUntil;
@property (nonatomic, assign) NSTimeInterval lastModalRecoveryForceReloadTime;
@property (nonatomic, strong) NSTimer *noMenuGracePeriodTimer;
@property (nonatomic, assign) unsigned long pendingClearWindowId;
@property (nonatomic, assign) unsigned long pendingWindowId;
@property (nonatomic, strong) NSString *pendingApplicationName;
// PIDs of processes confirmed (after grace period) to never export menus.
// Windows from these PIDs get system-only menu immediately, with no retry timer.
// Cleared when the process does eventually register a menu (handles slow starters).
@property (nonatomic, strong) NSMutableSet *knownMenulessPIDs;

- (unsigned long)findDesktopWindowId;
- (BOOL)windowLikelyWillRegisterMenuSoon:(unsigned long)windowId;
- (void)preserveCurrentMenuAndRetryWindow:(unsigned long)windowId reason:(NSString *)reason;
- (void)clearMenuAndHideView;
- (BOOL)isShowingSystemOnlyMenu;
- (BOOL)menusAreEquivalentForDisplay:(NSMenu *)firstMenu otherMenu:(NSMenu *)secondMenu;
- (void)appendMenuSignatureForMenu:(NSMenu *)menu intoString:(NSMutableString *)signature;
- (void)startupDesktopMenuLoad:(NSTimer *)timer;

@end

@implementation AppMenuWidget

- (void)preserveCurrentMenuAndRetryWindow:(unsigned long)windowId reason:(NSString *)reason
{
    if (windowId == 0) {
        return;
    }

    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (self.gracePeriodStartTime <= 0) {
        self.gracePeriodStartTime = now;
    }

    if (self.noMenuGracePeriodTimer) {
        [self.noMenuGracePeriodTimer invalidate];
        self.noMenuGracePeriodTimer = nil;
    }

    self.pendingClearWindowId = windowId;
    self.pendingWindowId = windowId;
        self.noMenuGracePeriodTimer = [NSTimer scheduledTimerWithTimeInterval:0.2
                                                                    target:self
                                                                  selector:@selector(noMenuGracePeriodExpired:)
                                                                  userInfo:[NSNumber numberWithUnsignedLong:windowId]
                                                                   repeats:NO];

    NSDebugLLog(@"gwcomp", @"AppMenuWidget: Preserving visible menu while retrying window %lu (%@)",
          windowId,
          reason ?: @"unknown");
}

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
        self.pendingWindowId = 0;
        self.pendingApplicationName = nil;
        self.fallbackTimers = [NSMutableDictionary dictionary];
        self.cachedIsWaitingForMenu = NO;
        self.cachedHasMenu = NO;
        self.needsRedraw = YES;
        
        // Tight-loop prevention initialisation
        self.isInsideDisplayMenuForWindow = NO;
        self.lastUpdateForActiveWindowTime = 0;
        self.lastUpdateForActiveWindowId = 0;
        self.gracePeriodStartTime = 0;
        self.currentWindowPID = 0;
        self.preservingMenuForDialogTransition = NO;
        self.dialogPreserveUntil = 0;
        self.lastModalRecoveryForceReloadTime = 0;
        self.knownMenulessPIDs = [NSMutableSet set];
        
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

    // Immediately try loading the Desktop window's menu; the Desktop app (GWorkspace/Finder)
    // is almost always the process that owns the desktop at startup.
    // If it hasn't registered a menu yet, retry at increasing intervals for up to ~5 seconds.
    [NSTimer scheduledTimerWithTimeInterval:0.3
                                     target:self
                                   selector:@selector(startupDesktopMenuLoad:)
                                   userInfo:@(0)   // attempt count
                                    repeats:NO];
}

// Called (repeatedly during startup) to switch the displayed menu to the Desktop window's menu.
// userInfo carries the current retry attempt count as an NSNumber.
// We stop retrying once the desktop menu is shown, or after the attempt budget is exhausted.
- (void)startupDesktopMenuLoad:(NSTimer *)timer
{
    NSUInteger attempt = [timer.userInfo unsignedIntegerValue];
    const NSUInteger maxAttempts = 50;   // 50 × ~0.2s ≈ 10 seconds budget
    const NSTimeInterval retryInterval = 0.2;

    // Abort if a real app window is already being shown (user clicked something).
    if (self.currentWindowId != 0) {
        NSLog(@"AppMenuWidget: Startup desktop-menu load cancelled — already showing menu for window 0x%lx", self.currentWindowId);
        return;
    }

    unsigned long desktopWindowId = [self findDesktopWindowId];
    if (desktopWindowId == 0) {
        if (attempt < maxAttempts) {
            [NSTimer scheduledTimerWithTimeInterval:retryInterval
                                             target:self
                                           selector:@selector(startupDesktopMenuLoad:)
                                           userInfo:@(attempt + 1)
                                            repeats:NO];
        } else {
            NSLog(@"AppMenuWidget: Startup desktop-menu load: no Desktop window found after %lu attempts", (unsigned long)maxAttempts);
        }
        return;
    }

    if (![self.protocolManager hasMenuForWindow:desktopWindowId]) {
        if (attempt < maxAttempts) {
            NSDebugLLog(@"gwcomp", @"AppMenuWidget: Startup desktop-menu load: Desktop window 0x%lx not registered yet (attempt %lu/%lu)",
                  desktopWindowId, (unsigned long)(attempt + 1), (unsigned long)maxAttempts);
            [NSTimer scheduledTimerWithTimeInterval:retryInterval
                                             target:self
                                           selector:@selector(startupDesktopMenuLoad:)
                                           userInfo:@(attempt + 1)
                                            repeats:NO];
        } else {
            NSLog(@"AppMenuWidget: Startup desktop-menu load: Desktop window 0x%lx never registered a menu after %lu attempts",
                  desktopWindowId, (unsigned long)maxAttempts);
        }
        return;
    }

    // Desktop has a menu ready — show it.
    NSLog(@"AppMenuWidget: Startup desktop-menu load: showing Desktop menu for window 0x%lx (attempt %lu)",
          desktopWindowId, (unsigned long)(attempt + 1));
    self.pendingWindowId = desktopWindowId;
    self.pendingApplicationName = [MenuUtils getApplicationNameForWindow:desktopWindowId];
    self.gracePeriodStartTime = 0;
    [self displayMenuForWindow:desktopWindowId isDifferentApp:YES];
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
    MENU_PROFILE_BEGIN(updateForActiveWindow);
    
    if (!self.protocolManager) {
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: No protocol manager available");
        MENU_PROFILE_END(updateForActiveWindow);
        return;
    }

    // Defensive validation: if the currently tracked window disappears, keep the
    // visible menu until a replacement active window is resolved. Clearing here
    // creates transient system-only stalls during close/switch churn.
    if (self.currentWindowId != 0 && ![AppMenuWidget isWindowStillValid:self.currentWindowId]) {
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Current tracked window %lu no longer valid - preserving visible menu until next active window settles", self.currentWindowId);
        if (self.lastWindowSwitchTime <= 0) {
            self.lastWindowSwitchTime = [NSDate timeIntervalSinceReferenceDate];
        }
    }

    // Get the active window using X11
    Display *display = [MenuUtils sharedDisplay];
    if (!display) {
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Cannot open X11 display");
        MENU_PROFILE_END(updateForActiveWindow);
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
    MENU_PROFILE_END(updateForActiveWindow);
}

- (void)updateForActiveWindowId:(unsigned long)windowId
{
    MENU_PROFILE_BEGIN(updateForActiveWindowId);

    if (!self.protocolManager) {
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: No protocol manager available (updateForActiveWindowId)");
        MENU_PROFILE_END(updateForActiveWindowId);
        return;
    }

    self.lastUpdateForActiveWindowTime = [NSDate timeIntervalSinceReferenceDate];
    self.lastUpdateForActiveWindowId = windowId;
    NSTimeInterval decisionNow = [NSDate timeIntervalSinceReferenceDate];

    NSDebugLog(@"AppMenuWidget: updateForActiveWindowId called with 0x%lx", windowId);

    unsigned long activeWindow = windowId;

    // Trust WindowMonitor's active-window signal even when local validity probing transiently fails.
    // During WM reparent/unmap churn, isWindowStillValid can race and produce false negatives,
    // which previously forced activeWindow=0 and caused long system-only menubar stalls.
    if (activeWindow != 0 && ![AppMenuWidget isWindowStillValid:activeWindow]) {
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Active window %lu failed local validity check - trusting monitor and continuing", activeWindow);
    }

    // Exclude the Menu application itself from triggering updates.
    // If we focus on the menu bar or its components, we want to keep the current app menu.
    if (activeWindow != 0 && [NSApp windowWithWindowNumber:activeWindow] != nil) {
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Focus is on Menu app itself (0x%lx) - ignoring update to preserve current menu", activeWindow);
        MENU_PROFILE_END(updateForActiveWindowId);
        return;
    }

    // DIALOG PRESERVATION: If a dialog/transient window becomes active
    // (About/Help/Preferences/etc), keep showing the owner application's menu.
    if (activeWindow != 0 && [MenuUtils isDialogWindow:activeWindow]) {
        BOOL hasRealAppMenuVisible = (self.currentWindowId != 0 && self.currentMenu != nil && ![self isShowingSystemOnlyMenu]);
        if (hasRealAppMenuVisible) {
            self.preservingMenuForDialogTransition = YES;
            self.dialogPreserveUntil = [NSDate timeIntervalSinceReferenceDate] + 3.0;
            // Treat this as a transition so the immediate close does not clear the menu.
            self.lastWindowSwitchTime = [NSDate timeIntervalSinceReferenceDate];
            NSDebugLLog(@"gwcomp", @"AppMenuWidget: Dialog/transient 0x%lx detected - preserving owner menu until %.3f",
                  activeWindow,
                  self.dialogPreserveUntil);
            MENU_PROFILE_END(updateForActiveWindowId);
            return;  // Keep showing the current application's menu
        }

        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Dialog/transient 0x%lx detected but no app menu is currently visible; proceeding with normal load", activeWindow);
    }

    // New anti-flicker mechanism: If no active window (0), check if within grace we might switch 
    // to a window of the same PID. If so, don't clear the menu yet.
    if (activeWindow == 0) {
        self.pendingWindowId = 0;
        self.pendingApplicationName = nil;
        self.lastModalRecoveryForceReloadTime = 0;

        NSTimeInterval currentTime = [NSDate timeIntervalSinceReferenceDate];
        NSTimeInterval timeSinceLastSwitch = currentTime - self.lastWindowSwitchTime;

        if (self.preservingMenuForDialogTransition && self.currentMenu != nil && currentTime < self.dialogPreserveUntil) {
            NSDebugLLog(@"gwcomp", @"AppMenuWidget: Dialog transition grace active - preserving menu for %.3fs",
                  (self.dialogPreserveUntil - currentTime));
            MENU_PROFILE_END(updateForActiveWindowId);
            return;
        }
        
        // ANTI-FLICKER: Preserve menu for grace period when window becomes 0
        // This handles:
        // 1. Rapid window switches (closing one window while opening another)
        // 2. Transient X11 "no active window" states during window manager operations
        // 3. Window manager delays in reporting the actual active window
        if (timeSinceLastSwitch < NO_ACTIVE_WINDOW_GRACE_SECS && self.lastWindowPID != 0) {
            NSDebugLLog(@"gwcomp", @"AppMenuWidget: No-window grace %.3fs < %.1fs - preserving menu for PID %d (menu=%@)", 
                timeSinceLastSwitch,
                NO_ACTIVE_WINDOW_GRACE_SECS,
                (int)self.lastWindowPID,
                self.currentMenu ? @"YES" : @"NO");
            MENU_PROFILE_END(updateForActiveWindowId);
            return;
        }
        
        // If we have a menu and this is the first time seeing window==0, preserve it briefly
        // This handles cases where lastWindowSwitchTime is very old or zero
        if (self.currentMenu != nil && self.currentWindowId != 0) {
            NSDebugLLog(@"gwcomp", @"AppMenuWidget: No-window grace with current menu from 0x%lx app=%@ - preserving briefly", 
                  self.currentWindowId, self.currentApplicationName ?: @"Unknown");
            // Update timestamp so subsequent calls within grace will use the check above
            self.lastWindowSwitchTime = currentTime;
            MENU_PROFILE_END(updateForActiveWindowId);
            return;
        }
        
        // Otherwise, clear the menu (past grace period and no current menu to preserve)
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: No-window past grace period (%.3fs) - clearing menu", timeSinceLastSwitch);
        self.preservingMenuForDialogTransition = NO;
        self.dialogPreserveUntil = 0;
        [self clearMenuAndHideView];
        self.lastWindowPID = 0;
        self.currentWindowPID = 0;
        self.lastWindowSwitchTime = currentTime;
        MENU_PROFILE_END(updateForActiveWindowId);
        return;
    }

    BOOL shouldUpdate = (activeWindow != self.currentWindowId);
    if (shouldUpdate && activeWindow != 0 && activeWindow == self.pendingWindowId &&
        self.currentWindowId != activeWindow &&
        self.pendingClearWindowId == activeWindow && self.noMenuGracePeriodTimer != nil) {
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Window 0x%lx is already pending during grace period - waiting for registration", activeWindow);
        MENU_PROFILE_END(updateForActiveWindowId);
        return;
    }

    if (!shouldUpdate && activeWindow != 0) {
        NSTimeInterval sinceLastSwitch = decisionNow - self.lastWindowSwitchTime;
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Decision win=0x%lx shouldUpdate=NO currentMenu=%@ hasMenu=%@ pendingClear=%lu graceTimer=%@ lastSwitchAgo=%.3f",
              activeWindow,
              self.currentMenu ? @"YES" : @"NO",
              [self.protocolManager hasMenuForWindow:activeWindow] ? @"YES" : @"NO",
              self.pendingClearWindowId,
              self.noMenuGracePeriodTimer ? @"YES" : @"NO",
              sinceLastSwitch);

        // Force a refresh if menu is missing or we don't have a current menu
        if (!self.currentMenu || ![self.protocolManager hasMenuForWindow:activeWindow]) {
            NSDebugLLog(@"gwcomp", @"AppMenuWidget: Window 0x%lx menu missing - forcing refresh", activeWindow);
            shouldUpdate = YES;
        }
        // MODAL DIALOG RECOVERY: If we previously had activeWindow=0 and now have activeWindow!=0,
        // force a refresh to ensure we're showing current state (handles About dialog close/reopen)
        else if (self.pendingClearWindowId != 0 || self.noMenuGracePeriodTimer != nil) {
            NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
            if ((now - self.lastModalRecoveryForceReloadTime) >= MODAL_RECOVERY_FORCE_RELOAD_MIN_INTERVAL) {
                NSDebugLLog(@"gwcomp", @"AppMenuWidget: Window 0x%lx recovering from modal dialog (pending=%lu timer=%@) - forcing refresh", 
                      activeWindow, self.pendingClearWindowId, self.noMenuGracePeriodTimer ? @"YES" : @"NO");
                self.lastModalRecoveryForceReloadTime = now;
                shouldUpdate = YES;
            } else {
                NSDebugLLog(@"gwcomp", @"AppMenuWidget: Skipping repeated modal-recovery force reload for 0x%lx (throttled)", activeWindow);
            }
        } else {
            NSDebugLLog(@"gwcomp", @"AppMenuWidget: Window 0x%lx unchanged and menu OK - skipping update", activeWindow);
        }
    }

    if (shouldUpdate) {
        self.preservingMenuForDialogTransition = NO;
        self.dialogPreserveUntil = 0;
        // Optimization: get PID once and reuse for both title-bar detection and anti-flicker tracking
        pid_t windowPid = (activeWindow != 0) ? [MenuUtils getWindowPID:activeWindow] : 0;
        
        // If the new active window has no PID, it may be a window manager
        // decoration (title bar).  Check if it shares a parent with the
        // current window — if so, the user clicked the same app's title
        // bar and we should keep the current menu.
        if (activeWindow != 0 && self.currentWindowId != 0 && windowPid == 0) {
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
                    MENU_PROFILE_END(updateForActiveWindowId);
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

          NSDebugLLog(@"gwcomp", @"AppMenuWidget: Window switch target=0x%lx app=%@ shown=0x%lx shownApp=%@",
              activeWindow,
              (newAppName && [newAppName length] > 0) ? newAppName : @"Unknown",
              self.currentWindowId,
              self.currentApplicationName ?: @"nil");

        BOOL isDifferentApp = !self.currentApplicationName ||
                             ![self.currentApplicationName isEqualToString:newAppName];
        self.pendingWindowId = activeWindow;
        self.pendingApplicationName = newAppName;
        
        // Reset grace period start time for new window focus
        self.gracePeriodStartTime = 0;
        
        // Track PID and timestamp for the new anti-flicker mechanism (PID already cached above)
        self.lastWindowPID = windowPid;
        self.lastWindowSwitchTime = [NSDate timeIntervalSinceReferenceDate];

        // Use @try/@catch to prevent crashes during menu setup for invalid/transitioning windows
        @try {
            MENU_PROFILE_BEGIN(updateForActiveWindowIdDisplayMenu);
            [self displayMenuForWindow:activeWindow isDifferentApp:isDifferentApp];
            MENU_PROFILE_END(updateForActiveWindowIdDisplayMenu);
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

    MENU_PROFILE_END(updateForActiveWindowId);
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
    if (self.pendingWindowId != windowId) {
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Pending window changed to %lu - discarding stale grace-period timer for %lu",
              self.pendingWindowId, windowId);
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
    // If we are still on system-only menu, try a desktop/menu-service fallback to avoid
    // getting stuck with a blank command-only menubar for extended periods.
    if ([self isShowingSystemOnlyMenu]) {
        unsigned long desktopWindowId = [self findDesktopWindowId];
        if (desktopWindowId != 0 && [self.protocolManager hasMenuForWindow:desktopWindowId]) {
            NSDebugLLog(@"gwcomp", @"AppMenuWidget: Window %lu still has no menu after %.2fs - switching to desktop menu 0x%lx",
                  windowId,
                  elapsed,
                  desktopWindowId);
            self.gracePeriodStartTime = 0;
            self.pendingWindowId = desktopWindowId;
            self.pendingApplicationName = [MenuUtils getApplicationNameForWindow:desktopWindowId];
            [self displayMenuForWindow:desktopWindowId isDifferentApp:YES];
            return;
        }

        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Window %lu still has no menu after %.2fs and no desktop menu yet - retrying poll",
              windowId,
              elapsed);
        self.pendingClearWindowId = windowId;
        self.noMenuGracePeriodTimer =
            [NSTimer scheduledTimerWithTimeInterval:MENU_WAIT_GRACE_PERIOD_POLL_INTERVAL
                                             target:self
                                           selector:@selector(noMenuGracePeriodExpired:)
                                           userInfo:[NSNumber numberWithUnsignedLong:windowId]
                                            repeats:NO];
        return;
    }

    // Grace period exhausted and the window still has no menu.
    // Record this PID as confirmed menu-less so future switches to it skip the retry wait.
    pid_t menulessPid = [MenuUtils getWindowPID:windowId];
    if (menulessPid != 0) {
        [self.knownMenulessPIDs addObject:@(menulessPid)];
        NSLog(@"AppMenuWidget: PID %d marked as menu-less after %.2fs - will show system-only for future switches",
              (int)menulessPid, elapsed);
    }
    self.gracePeriodStartTime = 0;
    // Only clear if we are truly still on the system-only state (no real menu loaded yet).
    // If currentWindowId != 0, a different window's menu was successfully loaded while we
    // were polling (e.g. by the reconcile path) — silently discard this stale timer so we
    // do not destroy the valid menu that is already on screen.
    if (self.currentWindowId == 0) {
        [self clearMenuAndHideView];
    } else {
        NSLog(@"AppMenuWidget: Stale grace timer for 0x%lx discarded (currently showing 0x%lx) - not clearing menu",
              windowId, self.currentWindowId);
    }
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
    if ([self isShowingSystemOnlyMenu] && self.menuView && ![self.menuView isHidden]) {
        return;
    }

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

    // Idempotence guard: if we already show the system-only menubar, avoid rebuilding it.
    if ([self isShowingSystemOnlyMenu] && self.menuView && ![self.menuView isHidden]) {
        self.currentWindowId = 0;
        self.currentWindowPID = 0;
        self.lastLoadedMenuWindowId = 0;
        self.needsRedraw = YES;
        return;
    }
    
    [self clearMenu:YES];
    self.currentWindowId = 0; // Ensure we stop showing menus for this window
    self.currentWindowPID = 0;
    self.lastLoadedMenuWindowId = 0; // Reset so next focus will load fresh
    self.needsRedraw = YES;
    // Always keep the system ⌘ menu visible even when there is no application menu.
    [self displaySystemOnlyMenu];

    NSDebugLLog(@"gwcomp", @"AppMenuWidget: Menubar cleared to system-only state");
}

- (BOOL)isShowingSystemOnlyMenu
{
    if (self.currentWindowId != 0 || self.currentMenu == nil) {
        return NO;
    }

    NSArray *items = [self.currentMenu itemArray];
    if ([items count] != 1) {
        return NO;
    }

    NSMenuItem *first = [items objectAtIndex:0];
    return [[first title] isEqualToString:@"⌘"];
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
    if (self.systemMenu) {
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc removeObserver:self name:NSMenuDidBeginTrackingNotification object:self.systemMenu];
        self.systemMenu = nil;
    }
    
    // Clear visual states
    self.currentMenu = nil;
    self.currentWindowId = 0;
    self.currentWindowPID = 0;
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
    MENU_PROFILE_BEGIN(displayMenuForWindow);

    // TIGHT-LOOP GUARD: Prevent re-entrance (e.g. displayMenuForWindow -> desktopFallback -> displayMenuForWindow)
    if (self.isInsideDisplayMenuForWindow) {
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Re-entrant displayMenuForWindow blocked for window %lu", windowId);
        MENU_PROFILE_END(displayMenuForWindow);
        return;
    }
    self.isInsideDisplayMenuForWindow = YES;

    @try { // @finally guarantees isInsideDisplayMenuForWindow is cleared on ALL exit paths

    // Defensive check: ensure we're initialized
    if (!self.protocolManager) {
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Protocol manager not initialized, cannot display menu for window %lu", windowId);
        MENU_PROFILE_END(displayMenuForWindow);
        return;
    }
    
    // ANTI-FLICKER: Don't clear the old menu yet - keep it visible while loading the new one
    // We'll clear it after successfully loading the new menu
    
    if (windowId == 0) {
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: displayMenuForWindow called with 0 - preserving visible menu");
        MENU_PROFILE_END(displayMenuForWindow);
        return;
    }

    // Detect cross-app transitions: when the new active window belongs to a different process
    // than the currently displayed one, we must NOT preserve the old app's menu while waiting.
    // A PID of 0 means unknown; in that case fall back to preserving (safe default).
    pid_t newWindowPid = [MenuUtils getWindowPID:windowId];
    BOOL crossAppSwitch = (self.currentWindowPID != 0 &&
                            newWindowPid != 0 &&
                            newWindowPid != self.currentWindowPID);
    if (crossAppSwitch) {
        NSLog(@"AppMenuWidget: Cross-app switch: PID %d -> %d (window 0x%lx) - clearing old menu immediately",
              (int)self.currentWindowPID, (int)newWindowPid, windowId);
    }

    // Fast path: if the incoming PID is known to never export menus, go straight to
    // system-only without scheduling any retry timer — no point waiting.
    if (newWindowPid != 0 && [self.knownMenulessPIDs containsObject:@(newWindowPid)]) {
        NSLog(@"AppMenuWidget: PID %d is known menu-less (window 0x%lx) - showing system-only immediately",
              (int)newWindowPid, windowId);
        [self clearMenuAndHideView];
        MENU_PROFILE_END(displayMenuForWindow);
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
            if (crossAppSwitch) {
                [self clearMenuAndHideView];
            }
            [self preserveCurrentMenuAndRetryWindow:windowId reason:@"window-invalid-no-menu-yet"];
            MENU_PROFILE_END(displayMenuForWindow);
            return;
        }
    }

    // pendingApplicationName is resolved once in updateForActiveWindowId; avoid duplicate
    // X11 name lookups here on the hot path.
    if (self.pendingWindowId == windowId && [self.pendingApplicationName length] > 0) {
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Window %lu belongs to application: %@",
              windowId, self.pendingApplicationName);
    }
    
    NSDebugLLog(@"gwcomp", @"AppMenuWidget: Displaying menu for window %lu", windowId);
    
    // Check if this window has a DBus menu registered
    @try {
        MENU_PROFILE_BEGIN(displayMenuForWindowHasMenuCheck);
        if (![self.protocolManager hasMenuForWindow:windowId]) {
            MENU_PROFILE_END(displayMenuForWindowHasMenuCheck);
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
                MENU_PROFILE_END(displayMenuForWindow);
                return;
            }

            // Stall-proof behavior: keep the currently visible menu and retry shortly.
            // For a cross-app switch, clear the old app's menu immediately instead.
            if (crossAppSwitch) {
                [self clearMenuAndHideView];
            }
            [self preserveCurrentMenuAndRetryWindow:windowId reason:@"not-registered-yet"];
            MENU_PROFILE_END(displayMenuForWindow);
            return;
        } else {
            MENU_PROFILE_END(displayMenuForWindowHasMenuCheck);
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
            MENU_PROFILE_END(displayMenuForWindow);
            return;
        }

#if ENABLE_FALLBACK_MENUS
        // Create fallback File->Close menu on exception
        NSMenu *fallbackMenu = [self createFileMenuWithClose:windowId];
        [self loadMenu:fallbackMenu forWindow:windowId];
#else
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Exception occurred but fallback menus disabled at compile time");
        if (crossAppSwitch) {
            [self clearMenuAndHideView];
        }
    [self preserveCurrentMenuAndRetryWindow:windowId reason:@"protocol-check-exception"];
#endif
        MENU_PROFILE_END(displayMenuForWindow);
        return;
    }
    
    NSDebugLLog(@"gwcomp", @"AppMenuWidget: ===== LOADING MENU FROM PROTOCOL MANAGER =====");
    NSDebugLLog(@"gwcomp", @"AppMenuWidget: This is where AboutToShow events should be triggered for submenus");

    // Get the menu from protocol manager for registered windows
    NSMenu *menu = nil;
    MENU_PROFILE_BEGIN(displayMenuForWindowGetMenu);
    @try {
        menu = [self.protocolManager getMenuForWindow:windowId];
    }
    @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Exception getting menu from protocol manager for window %lu: %@", windowId, exception);
        menu = nil;
    }
    MENU_PROFILE_END(displayMenuForWindowGetMenu);

    if (!menu) {
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Failed to get menu for window %lu (protocol manager)", windowId);

        // Transient DBus/parser failures happen during close/switch churn.
        // If we already have a visible menu, preserve it briefly and retry instead
        // of clearing to system-only immediately (which causes visible stalls).
        if (self.currentMenu != nil && self.currentWindowId != 0 && !crossAppSwitch) {
            NSDebugLLog(@"gwcomp", @"AppMenuWidget: Preserving current menu for window %lu while retrying menu load for %lu",
                  self.currentWindowId,
                  windowId);

            if (self.noMenuGracePeriodTimer) {
                [self.noMenuGracePeriodTimer invalidate];
                self.noMenuGracePeriodTimer = nil;
            }
            if (self.gracePeriodStartTime <= 0) {
                self.gracePeriodStartTime = [NSDate timeIntervalSinceReferenceDate];
            }
            self.pendingClearWindowId = windowId;
            self.noMenuGracePeriodTimer = [NSTimer scheduledTimerWithTimeInterval:0.2
                                                                            target:self
                                                                          selector:@selector(noMenuGracePeriodExpired:)
                                                                          userInfo:[NSNumber numberWithUnsignedLong:windowId]
                                                                           repeats:NO];
            MENU_PROFILE_END(displayMenuForWindow);
            return;
        }

        [self clearMenuAndHideView];
        MENU_PROFILE_END(displayMenuForWindow);
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
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Placeholder menu for window %lu - preserving current display and retrying", windowId);
        if (crossAppSwitch) {
            [self clearMenuAndHideView];
        }
        [self preserveCurrentMenuAndRetryWindow:windowId reason:@"placeholder-menu"];
        MENU_PROFILE_END(displayMenuForWindow);
        return;
    }

    MENU_PROFILE_BEGIN(displayMenuForWindowLoadMenu);
    [self loadMenu:menu forWindow:windowId];
    MENU_PROFILE_END(displayMenuForWindowLoadMenu);
    NSDebugLLog(@"gwcomp", @"AppMenuWidget: Imported %lu menu items for window %lu", (unsigned long)[[menu itemArray] count], windowId);

    MENU_PROFILE_END(displayMenuForWindow);

    } // @try
    @finally {
        self.isInsideDisplayMenuForWindow = NO;
    }
}

- (void)setupMenuViewWithMenu:(NSMenu *)menu
{
    MENU_PROFILE_BEGIN(setupMenuViewWithMenu);
    if (!menu) {
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Cannot setup menu view with nil menu");
        MENU_PROFILE_END(setupMenuViewWithMenu);
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
        MENU_PROFILE_BEGIN(setupMenuViewWithMenuRemoveExistingView);
        // Correctness over micro-optimization: NSMenuView can retain stale cell state when
        // hot-swapped repeatedly. Recreate it on each menu setup to guarantee a clean cell tree.
        if (self.menuView) {
            // CRITICAL: Disconnect from the menu BEFORE releasing the view.
            // GNUstep's NSNotificationCenter keeps unsafe (non-retaining) observer pointers.
            // NSMenuView registers globally (object:nil) for NSMenuDidAddItemNotification and
            // similar. If we just nil the view, its pointer becomes dangling in the notification
            // center and any subsequent addItem: call on ANY menu will crash via objc_msgSend.
            [[NSNotificationCenter defaultCenter] removeObserver:self.menuView];
            [self.menuView setMenu:nil];
            [self.menuView removeFromSuperview];
            self.menuView = nil;
        }
        MENU_PROFILE_END(setupMenuViewWithMenuRemoveExistingView);

        // Ensure we don't duplicate the "Command" system menu item
        MENU_PROFILE_BEGIN(setupMenuViewWithMenuSystemMenuPrep);
        MENU_PROFILE_BEGIN(setupMenuViewWithMenuCommandDedup);

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
        MENU_PROFILE_END(setupMenuViewWithMenuCommandDedup);

        // Add the "Command" system menu item at the beginning
        MENU_PROFILE_BEGIN(setupMenuViewWithMenuBuildSystemMenuShell);
        NSMenuItem *systemItem = [[NSMenuItem alloc] initWithTitle:@"⌘" action:nil keyEquivalent:@""];
        if (self.systemMenu) {
            NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
            [nc removeObserver:self name:NSMenuDidBeginTrackingNotification object:self.systemMenu];
            // Clear the delegate so the old systemMenu doesn't dispatch callbacks into us
            // after we've replaced it.
            [self.systemMenu setDelegate:nil];
        }

        NSMenu *systemMenu = [[NSMenu alloc] initWithTitle:@"System"];

        // Add "Search..." item to the system menu
        NSMenuItem *searchItem = [[NSMenuItem alloc] initWithTitle:@"Search..."
                                                            action:@selector(toggleSearch:)
                                                     keyEquivalent:@" "]; // Space
        [searchItem setKeyEquivalentModifierMask:NSCommandKeyMask];
        [searchItem setTarget:[ActionSearchController sharedController]];
        [systemMenu addItem:searchItem];
        [systemMenu addItem:[NSMenuItem separatorItem]];

        // Add a System Preferences entry and a separator after it
        NSMenuItem *prefsItem = [[NSMenuItem alloc] initWithTitle:@"System Preferences" action:@selector(openSystemPreferences:) keyEquivalent:@""];
        [prefsItem setTarget:self];
        [systemMenu addItem:prefsItem];
        [systemMenu addItem:[NSMenuItem separatorItem]];

        // Keep a reference to this system submenu so we can populate it dynamically.
        self.systemMenu = systemMenu;
        [systemMenu setDelegate:self];

        // Listen for tracking begin so we can populate items reliably on open.
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserver:self selector:@selector(systemMenuDidBeginTracking:) name:NSMenuDidBeginTrackingNotification object:systemMenu];

        // Ensure ActionSearchController knows about our AppMenuWidget so it can collect items
        [[ActionSearchController sharedController] setAppMenuWidget:self];
        MENU_PROFILE_END(setupMenuViewWithMenuBuildSystemMenuShell);

        // Defer System app list population to submenu open tracking to avoid
        // expensive app-switch path work on every active-window change.
        MENU_PROFILE_BEGIN(setupMenuViewWithMenuPopulateSystemMenu);
        MENU_PROFILE_END(setupMenuViewWithMenuPopulateSystemMenu);
        NSDebugLog(@"AppMenuWidget: System submenu initially has %lu items", (unsigned long)[[self.systemMenu itemArray] count]);

        [systemItem setSubmenu:systemMenu];
        
        // Insert at the beginning of the menu
        [menu insertItem:systemItem atIndex:0];
        MENU_PROFILE_END(setupMenuViewWithMenuSystemMenuPrep);

        MENU_PROFILE_BEGIN(setupMenuViewWithMenuCreateView);
        NSRect menuViewFrame = NSMakeRect(0, 0, [self bounds].size.width, [self bounds].size.height);
        AppMenuView *newMenuView = [[AppMenuView alloc] initWithFrame:menuViewFrame];
        if (!newMenuView) {
            NSDebugLLog(@"gwcomp", @"AppMenuWidget: Failed to create menu view");
            MENU_PROFILE_END(setupMenuViewWithMenuCreateView);
            MENU_PROFILE_END(setupMenuViewWithMenu);
            return;
        }
        [newMenuView setHorizontal:YES];
        [newMenuView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
        [newMenuView setMenu:menu];
        [newMenuView setHidden:NO];
        [self addSubview:newMenuView];
        self.menuView = newMenuView;
        
        [menu setDelegate:self];
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Set AppMenuWidget as delegate for main menu: %@", [menu title]);
        MENU_PROFILE_END(setupMenuViewWithMenuCreateView);
        
        // Check if this is a GNUStep menu by looking at menu items' representedObject
        MENU_PROFILE_BEGIN(setupMenuViewWithMenuWireItems);
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
        
        // DON'T override target/action for items that already have proper actions set
        for (NSUInteger i = 0; i < [items count]; i++) {
            NSMenuItem *item = [items objectAtIndex:i];
            NSDebugLog(@"AppMenuWidget: Setting up item %lu: '%@' (submenu: %@, target: %@, action: %@)", 
                  i, [item title], [item hasSubmenu] ? @"YES" : @"NO",
                  [item target], NSStringFromSelector([item action]));
            
            if (!isGNUStepMenu && ![item hasSubmenu]) {
                if (![item target]) {
                    [item setTarget:self];
                    [item setAction:@selector(menuItemClicked:)];
                    NSDebugLLog(@"gwcomp", @"AppMenuWidget: Set placeholder action for item without handler: '%@'", [item title]);
                }
            }
        }
        
        [self setNeedsDisplay:YES];
        MENU_PROFILE_END(setupMenuViewWithMenuWireItems);
        
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Menu view setup complete with %lu menu items", 
              (unsigned long)[[menu itemArray] count]);

        // Diagnostic: emit one NSLog line after every menu-bar state change so window switches
        // can be correlated with exact menu contents in /tmp/Gershwin.log.
        {
            NSArray *_fi = [menu itemArray];
            NSMutableString *_d = [NSMutableString stringWithFormat:
                @"[MENUBAR win=0x%lx app=%@] ",
                self.currentWindowId,
                self.currentApplicationName ?: @"nil"];
            for (NSUInteger _i = 0; _i < [_fi count]; _i++) {
                if (_i > 0) [_d appendString:@" | "];
                NSMenuItem *_it = [_fi objectAtIndex:_i];
                [_d appendFormat:@"'%@'%@", [_it title], [_it hasSubmenu] ? @"\u25b6" : @""];
            }
            NSLog(@"%@", _d);
        }
    }
    @finally {
        // Re-enable window drawing and flush all pending updates
        if (window) {
            [window enableFlushWindow];
            [window flushWindow];
            [[window contentView] setNeedsDisplay:YES];
        }
        MENU_PROFILE_END(setupMenuViewWithMenu);
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
            self.pendingWindowId = windowId;
            self.pendingApplicationName = [MenuUtils getApplicationNameForWindow:windowId];
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
    MENU_PROFILE_BEGIN(menuNeedsUpdateTotal);
    if (menu != self.systemMenu) {
        MENU_PROFILE_END(menuNeedsUpdateTotal);
        return;
    }

    // Prevent re-entrancy / repeated updates that can cause rapid loops
    if (self.isUpdatingSystemMenu) {
        // Already updating — silently skip to avoid log spam and re-entrancy
        MENU_PROFILE_END(menuNeedsUpdateTotal);
        return;
    }

    // Throttle frequent updates to avoid CPU / log thrashing
    NSTimeInterval now = [[NSDate date] timeIntervalSinceReferenceDate];
    if (now - self.lastSystemMenuUpdateTime < SYSTEM_MENU_UPDATE_MIN_INTERVAL) {
        // Too frequent - skip this update
        MENU_PROFILE_END(menuNeedsUpdateTotal);
        return;
    }
    // Record this attempt's timestamp
    self.lastSystemMenuUpdateTime = now;

    self.isUpdatingSystemMenu = YES;
    NSDebugLog(@"AppMenuWidget: System submenu needs update - populating System Applications list");

    @try {

    MENU_PROFILE_BEGIN(menuNeedsUpdateFindInsertion);

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
    MENU_PROFILE_END(menuNeedsUpdateFindInsertion);

    // Directories to search for .app bundles (make robust to both plural/singular and common locations)
    MENU_PROFILE_BEGIN(menuNeedsUpdateScanApplications);
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
    MENU_PROFILE_END(menuNeedsUpdateScanApplications);

    NSDebugLog(@"AppMenuWidget: Found %lu application bundles after dedupe", (unsigned long)[appsByKey count]);

    // Sort by display name
    MENU_PROFILE_BEGIN(menuNeedsUpdateSortApplications);
    NSArray *sortedApps = [[appsByKey allValues] sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSString *na = [[a[@"title"] lowercaseString] copy];
        NSString *nb = [[b[@"title"] lowercaseString] copy];
        return [na compare:nb];
    }];
    MENU_PROFILE_END(menuNeedsUpdateSortApplications);

    // Find or create an "Applications" submenu item at startIndex
    MENU_PROFILE_BEGIN(menuNeedsUpdateRebuildSubmenu);
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
    MENU_PROFILE_END(menuNeedsUpdateRebuildSubmenu);
    }
    @finally {
        // Always clear the updating flag so further updates can occur later
        self.isUpdatingSystemMenu = NO;
        MENU_PROFILE_END(menuNeedsUpdateTotal);
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
    MENU_PROFILE_BEGIN(loadMenuForWindow);
    if (!menu) {
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Cannot load nil menu for window %lu", windowId);
        MENU_PROFILE_END(loadMenuForWindow);
        return;
    }
    
    // Cancel any scheduled fallback for this window since we're loading a real menu
    MENU_PROFILE_BEGIN(loadMenuForWindowCancelFallback);
    [self cancelScheduledFallbackForWindow:windowId];
    MENU_PROFILE_END(loadMenuForWindowCancelFallback);

    // Cancel any lingering grace-period timer regardless of which window it was waiting on.
    // We have just loaded a real menu, so there is no longer any reason to keep waiting.
    // This prevents a stale timer (e.g. from a previous reconcile loop) from destroying this
    // freshly loaded menu when it fires moments later.
    if (self.noMenuGracePeriodTimer) {
        NSLog(@"AppMenuWidget: loadMenu:forWindow:0x%lx - cancelling stale grace timer for 0x%lx",
              windowId, self.pendingClearWindowId);
        [self.noMenuGracePeriodTimer invalidate];
        self.noMenuGracePeriodTimer = nil;
        self.pendingClearWindowId = 0;
        self.gracePeriodStartTime = 0;
    }
    self.pendingWindowId = windowId;

    NSDebugLLog(@"gwcomp", @"AppMenuWidget: Loading menu for window %lu", windowId);

    // Use the protocol menu directly to avoid expensive deep NSMenu copy on every switch.
    // setupMenuViewWithMenu performs idempotent Command-item dedup before inserting a new one.
    NSMenu *displayMenu = menu;

    unsigned long previousWindowId = self.currentWindowId;
    pid_t previousWindowPID = self.currentWindowPID;

    // Skip no-op menu replacements for the same window to prevent flicker and redundant work.
    if (previousWindowId == windowId && self.currentMenu != nil && self.menuView && ![self.menuView isHidden] &&
        [self.menuView menu] == self.currentMenu &&
        [self menusAreEquivalentForDisplay:self.currentMenu otherMenu:displayMenu]) {
        self.isWaitingForMenu = NO;
        if (self.pendingWindowId == windowId && [self.pendingApplicationName length] > 0) {
            self.currentApplicationName = self.pendingApplicationName;
        }
        self.lastLoadedMenuWindowId = windowId;
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Skipping menu rebuild for window %lu (incoming menu unchanged)", windowId);
        MENU_PROFILE_END(loadMenuForWindow);
        return;
    }
    
    // Clear the waiting flag - we have a new menu
    self.isWaitingForMenu = NO;
    self.currentWindowId = windowId;
    self.currentWindowPID = (windowId == self.lastUpdateForActiveWindowId) ? self.lastWindowPID : [MenuUtils getWindowPID:windowId];

    // If this PID was previously marked as menu-less (e.g., slow to register), un-mark it
    // so future windows from this process get the normal retry treatment.
    if (self.currentWindowPID != 0) {
        NSNumber *pidKey = @(self.currentWindowPID);
        if ([self.knownMenulessPIDs containsObject:pidKey]) {
            [self.knownMenulessPIDs removeObject:pidKey];
            NSLog(@"AppMenuWidget: PID %d removed from known-menu-less set (menu registered for window 0x%lx)",
                  (int)self.currentWindowPID, windowId);
        }
    }
    if (self.pendingWindowId == windowId && [self.pendingApplicationName length] > 0) {
        self.currentApplicationName = self.pendingApplicationName;
    } else {
        self.currentApplicationName = @"Unknown";
    }
    self.lastLoadedMenuWindowId = windowId;  // Track which window we loaded for (used by same-window guard)
    self.needsRedraw = YES;  // Mark that we need to redraw with new menu
    
    NSDebugLLog(@"gwcomp", @"AppMenuWidget: ===== MENU LOADED, SETTING UP VIEW =====");
    NSDebugLLog(@"gwcomp", @"AppMenuWidget: Menu has %lu top-level items", (unsigned long)[[displayMenu itemArray] count]);
    
    // Log each top-level menu item and whether it has submenus
    MENU_PROFILE_BEGIN(loadMenuForWindowLogItems);
    NSArray *items = [displayMenu itemArray];
    for (NSUInteger i = 0; i < [items count]; i++) {
        NSMenuItem *item = [items objectAtIndex:i];
        NSDebugLog(@"AppMenuWidget: Top-level item %lu: '%@' (has submenu: %@, submenu items: %lu)", 
              i, [item title], [item hasSubmenu] ? @"YES" : @"NO",
              [item hasSubmenu] ? (unsigned long)[[[item submenu] itemArray] count] : 0);
    }
    MENU_PROFILE_END(loadMenuForWindowLogItems);
    
    // ANTI-FLICKER: Clear shortcuts ONLY if switching to a different application
    // This must happen before setupMenuViewWithMenu to avoid conflicts
    MENU_PROFILE_BEGIN(loadMenuForWindowShortcutTransition);
    if (previousWindowId != windowId) {
        pid_t newPid = self.currentWindowPID;
        pid_t oldPid = (previousWindowId != 0) ? previousWindowPID : 0;
        BOOL switchingToDifferentApp = (oldPid == 0 || newPid == 0 || oldPid != newPid);
        
        if (switchingToDifferentApp) {
            NSDebugLLog(@"gwcomp", @"AppMenuWidget: Switching to different app (PID %d -> %d) - clearing non-direct shortcuts", 
                  (int)oldPid, (int)newPid);
            [[X11ShortcutManager sharedManager] unregisterNonDirectShortcuts];
        } else {
            NSDebugLLog(@"gwcomp", @"AppMenuWidget: Same app (PID %d) - keeping shortcuts registered", (int)newPid);
        }
    }
    MENU_PROFILE_END(loadMenuForWindowShortcutTransition);
    
    MENU_PROFILE_BEGIN(loadMenuForWindowSetupMenuView);
    @try {
        [self setupMenuViewWithMenu:displayMenu];
        MENU_PROFILE_END(loadMenuForWindowSetupMenuView);
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: setupMenuViewWithMenu completed successfully");
    }
    @catch (NSException *exception) {
        MENU_PROFILE_END(loadMenuForWindowSetupMenuView);
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: EXCEPTION in setupMenuViewWithMenu: %@", exception);
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Exception details - name: %@, reason: %@", [exception name], [exception reason]);
        // Hard safety guarantee: never leave the menubar empty.
        [self clearMenuAndHideView];
    }
    
    // Re-register shortcuts for this menu since we may have cleared them above
    MENU_PROFILE_BEGIN(loadMenuForWindowReregisterShortcuts);
    [self reregisterShortcutsForMenu:displayMenu];
    MENU_PROFILE_END(loadMenuForWindowReregisterShortcuts);
    
    NSDebugLLog(@"gwcomp", @"AppMenuWidget: Successfully loaded fallback menu with %lu items", (unsigned long)[[displayMenu itemArray] count]);
    MENU_PROFILE_END(loadMenuForWindow);
} 

- (BOOL)menusAreEquivalentForDisplay:(NSMenu *)firstMenu otherMenu:(NSMenu *)secondMenu
{
    if (!firstMenu || !secondMenu) {
        return NO;
    }

    NSMutableString *firstSignature = [NSMutableString string];
    NSMutableString *secondSignature = [NSMutableString string];
    [self appendMenuSignatureForMenu:firstMenu intoString:firstSignature];
    [self appendMenuSignatureForMenu:secondMenu intoString:secondSignature];

    BOOL areEqual = [firstSignature isEqualToString:secondSignature];
    NSDebugLLog(@"gwcomp", @"AppMenuWidget: MENU-DIFF equal=%@ oldItems=%lu newItems=%lu oldHash=%lu newHash=%lu",
          areEqual ? @"YES" : @"NO",
          (unsigned long)[firstMenu numberOfItems],
          (unsigned long)[secondMenu numberOfItems],
          (unsigned long)[firstSignature hash],
          (unsigned long)[secondSignature hash]);

    return areEqual;
}

- (void)appendMenuSignatureForMenu:(NSMenu *)menu intoString:(NSMutableString *)signature
{
    if (!menu || !signature) {
        return;
    }

    NSArray *items = [menu itemArray];
    NSUInteger normalizedCount = 0;
    for (NSMenuItem *item in items) {
        NSMenu *submenu = [item submenu];
        BOOL isSyntheticSystemItem = [[item title] isEqualToString:@"⌘"] &&
                                     (submenu == self.systemMenu ||
                                      [[submenu title] isEqualToString:@"System"]);
        if (!isSyntheticSystemItem) {
            normalizedCount++;
        }
    }
    [signature appendFormat:@"[%lu]", (unsigned long)normalizedCount];

    for (NSMenuItem *item in items) {
        NSMenu *submenu = [item submenu];

        // Ignore the synthetic system item we inject during setup.
        if ([[item title] isEqualToString:@"⌘"] &&
            (submenu == self.systemMenu || [[submenu title] isEqualToString:@"System"])) {
            continue;
        }

        NSString *title = [item title] ?: @"";
        NSString *keyEquivalent = [item keyEquivalent] ?: @"";
        [signature appendFormat:@"{%@|%d|%@|%lu",
                                title,
                                [item isEnabled] ? 1 : 0,
                                keyEquivalent,
                                (unsigned long)[item keyEquivalentModifierMask]];

        if (submenu) {
            [self appendMenuSignatureForMenu:submenu intoString:signature];
        }

        [signature appendString:@"}"];
    }
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
    
    // If this is our current window, preserve the visible menu and let focus/reconcile
    // select the replacement window. Hard-clearing here creates visible blank stalls.
    if (self.currentWindowId == windowId) {
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Current window disappeared - preserving current menu until active-window recovery");
        self.pendingWindowId = 0;
        self.pendingApplicationName = nil;
        self.pendingClearWindowId = 0;
        if (self.noMenuGracePeriodTimer) {
            [self.noMenuGracePeriodTimer invalidate];
            self.noMenuGracePeriodTimer = nil;
        }
        self.lastWindowSwitchTime = [NSDate timeIntervalSinceReferenceDate];
        self.needsRedraw = YES;
    }
}

@end
