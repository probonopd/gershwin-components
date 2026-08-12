/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * AppMenuWidget — Displays the active application's menu in the global
 * menu bar.  Optimized single-pass update path with coalescing.
 */

#import "AppMenuWidget.h"
#import "MenuProtocolManager.h"
#import "WindowSwitchContext.h"
#import "MenuUtils.h"
#import "X11ShortcutManager.h"
#import "GTKActionHandler.h"
#import "DBusMenuActionHandler.h"
#import "DBusConnection.h"
#import "ActionSearch.h"
#import "SystemActions.h"
#import "MenuProfiler.h"
#import <X11/Xlib.h>
#import <X11/Xutil.h>
#import <X11/Xatom.h>
#import <GNUstepGUI/GSTheme.h>
#import <dispatch/dispatch.h>

/* ── Tuning constants ────────────────────────────────────────────── */

/* Coalescing delay for window focus changes.  Multiple rapid notifications
   within this window are collapsed into a single update. */
#define COALESCE_DELAY_SECS     0.03

/* When a newly focused window has no menu registered yet, we retry up
   to MENU_RETRY_MAX times at MENU_RETRY_INTERVAL intervals. */
#define MENU_RETRY_INTERVAL     0.25
#define MENU_RETRY_MAX          12       /* 12 × 0.25 = 3 seconds budget */

/* After a state pull/push, treat enabled/checkmark states as current for this
   long, so repeat menu opens skip the synchronous DO pull and stay lag-free. */
#define STATE_REFRESH_TTL       2.0

/* Minimum interval between system menu (⌘) app-list rebuilds. */
#define SYSTEM_MENU_CACHE_TTL   30.0

/* Delay after the dropdown menu is dismissed before the modal power-action
   confirmation appears, so the dialog is not shown on top of the menu that
   is still closing. */
#define POWER_CONFIRM_DELAY_SECS  0.3

/* Startup desktop menu retry budget */
#define STARTUP_RETRY_INTERVAL  0.5
#define STARTUP_RETRY_MAX       15       /* 15 × 0.5 = 7.5 seconds budget */

/* ── X11 error handling ──────────────────────────────────────────── */

static BOOL x11_error_occurred = NO;
static int x11_error_code = 0;
static AppMenuWidget *currentWidget = nil;
static NSMutableSet *invalidWindows = nil;

static int handleX11Error(Display *display, XErrorEvent *event)
{
    (void)display;
    if (!invalidWindows) {
        invalidWindows = [[NSMutableSet alloc] init];
    }

    x11_error_occurred = YES;
    x11_error_code = event->error_code;

    if (event->error_code == BadWindow || event->error_code == BadDrawable) {
        if (event->resourceid != 0) {
            [invalidWindows addObject:[NSNumber numberWithUnsignedLong:event->resourceid]];
        }
        if (currentWidget && event->resourceid != 0) {
            [currentWidget handleWindowDisappeared:event->resourceid];
        }
    }
    return 0;
}

#define SAFE_X11_CALL(display, call, cleanup_code) do { \
    x11_error_occurred = NO; \
    x11_error_code = 0; \
    int (*oldHandler)(Display *, XErrorEvent *) = XSetErrorHandler(handleX11Error); \
    XSync(display, False); \
    call; \
    XSync(display, False); \
    XSetErrorHandler(oldHandler); \
    if (x11_error_occurred) { cleanup_code; } \
} while(0)

/* ── AppMenuView (transparent NSMenuView subclass) ───────────────── */

@interface AppMenuView : NSMenuView
@end

@implementation AppMenuView

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)drawRect:(NSRect)dirtyRect
{
    [[NSColor clearColor] set];
    NSRectFill(dirtyRect);
    [super drawRect:dirtyRect];
}

- (BOOL)isOpaque
{
    return NO;
}

/* Override mouseUp: as a no-op to break the responder chain.  Without this,
 * [super mouseUp:theEvent] in NSView forwards the event up the responder
 * chain back to AppMenuWidget, causing infinite recursion. */
- (void)mouseUp:(NSEvent *)theEvent
{
    (void)theEvent;
}

@end

/* ── NSMenuItem swizzle: preserve custom action after setSubmenu: ── */

/*
 * GNUstep's -[NSMenuItem setSubmenu:] calls [self setAction:@selector(submenuAction:)]
 * (NSMenuItem.m:244), overwriting any action set before it.  submenuAction: is a
 * no-op (NSMenu.m:851), so our openFolderInWorkspace: was silently lost.
 *
 * We swizzle setSubmenu: to save the action/target before the call and restore
 * them afterwards — but only when a non-nil, non-submenuAction: action was
 * already set.  This allows items with both a submenu and a custom action to
 * work: the submenu opens on hover (handled by NSMenuView's tracking loop,
 * which checks [item submenu], not the action), and the custom action fires
 * on click.
 */

#import <objc/runtime.h>

@interface NSMenuItem (GWSwizzle)
@end

@implementation NSMenuItem (GWSwizzle)

+ (void)load
{
    static BOOL swizzled = NO;
    if (swizzled) return;
    swizzled = YES;

    Method original = class_getInstanceMethod(self, @selector(setSubmenu:));
    Method swizzledM = class_getInstanceMethod(self, @selector(gw_setSubmenu:));
    method_exchangeImplementations(original, swizzledM);
}

- (void)gw_setSubmenu:(NSMenu *)submenu
{
    SEL savedAction = [self action];
    id savedTarget = [self target];

    /* Call the original setSubmenu: (now gw_setSubmenu: after swizzle). */
    [self gw_setSubmenu:submenu];

    /* Restore action/target only if a custom action was explicitly set. */
    if (savedAction && savedAction != @selector(submenuAction:))
    {
        [self setAction:savedAction];
        [self setTarget:savedTarget];
    }
}

@end

/* ── Private interface ───────────────────────────────────────────── */

@interface AppMenuWidget ()

/* PID of the window whose menu is currently displayed */
@property (nonatomic, assign) pid_t lastDisplayedPID;
/* Timestamp of the last window switch (used for brief no-window grace) */
@property (nonatomic, assign) NSTimeInterval lastSwitchTime;

- (void)handleFocusChange:(WindowSwitchContext *)ctx;
- (void)coalesceTimerFired:(NSTimer *)timer;
- (void)menuRetryTimerFired:(NSTimer *)timer;
- (void)clearToSystemOnly;
- (BOOL)isShowingSystemOnlyMenu;
- (void)displaySystemOnlyMenu;
- (BOOL)topLevelMenusMatch:(NSMenu *)a with:(NSMenu *)b;
- (unsigned long)readActiveWindowFromX11;
- (void)startupDesktopMenuLoad:(NSTimer *)timer;
- (void)closeOpenMenuTracking;
- (void)mainMenuDidEndTracking:(NSNotification *)note;

@end

/* ── Implementation ──────────────────────────────────────────────── */

@implementation AppMenuWidget

#pragma mark - Lifecycle

+ (void)setCurrentWidget:(AppMenuWidget *)widget
{
    currentWidget = widget;
}

- (id)initWithFrame:(NSRect)frameRect
{
    self = [super initWithFrame:frameRect];
    if (self) {
        self.currentWindowId = 0;
        self.currentWindowPID = 0;
        self.lastDisplayedPID = 0;
        self.lastSwitchTime = 0;
        self.needsRedraw = YES;
        self.isInsideHandleFocusChange = NO;
        self.menuRetryCount = 0;
        self.cachedAppBundleTreeTime = 0;
        self.windowsWithoutMenus = [NSMutableDictionary dictionary];

        [AppMenuWidget setCurrentWidget:self];

        /* Defer initial system-only menu until the run loop is live. */
        [self performSelectorOnMainThread: @selector(setupInitialMenu)
                               withObject: nil waitUntilDone: NO];
    }
    return self;
}

- (void)setupInitialMenu
{
    if (self.menuView) return;

    @try {
        [self displaySystemOnlyMenu];
    } @catch (NSException *exception) {
        NSLog(@"AppMenuWidget: Exception during initial menu setup: %@", exception);
    }

    /* Kick off startup desktop-menu detection. */
    [NSTimer scheduledTimerWithTimeInterval:0.3
                                     target:self
                                   selector:@selector(startupDesktopMenuLoad:)
                                   userInfo:@(0)
                                    repeats:NO];
}

- (void)startupDesktopMenuLoad:(NSTimer *)timer
{
    NSUInteger attempt = [timer.userInfo unsignedIntegerValue];

    if (self.currentWindowId != 0) {
        NSLog(@"AppMenuWidget: Startup desktop-menu load cancelled — already showing menu for window 0x%lx", self.currentWindowId);
        return;
    }

    unsigned long desktopWindowId = [MenuUtils findDesktopWindow];
    if (desktopWindowId == 0 || ![self.protocolManager hasMenuForWindow:desktopWindowId]) {
        if (attempt < STARTUP_RETRY_MAX) {
            [NSTimer scheduledTimerWithTimeInterval:STARTUP_RETRY_INTERVAL
                                             target:self
                                           selector:@selector(startupDesktopMenuLoad:)
                                           userInfo:@(attempt + 1)
                                            repeats:NO];
        } else {
            NSLog(@"AppMenuWidget: Startup desktop-menu load: no Desktop menu after %lu attempts",
                  (unsigned long)STARTUP_RETRY_MAX);
        }
        return;
    }

    NSLog(@"AppMenuWidget: Startup desktop-menu load: showing Desktop menu for 0x%lx (attempt %lu)",
          desktopWindowId, (unsigned long)(attempt + 1));
    WindowSwitchContext *ctx = [WindowSwitchContext contextForWindow:desktopWindowId
                                                    protocolManager:self.protocolManager];
    if (ctx) {
        [self handleFocusChange:ctx];
    }
}

- (void)dealloc
{
    if (currentWidget == self) currentWidget = nil;
    [self.coalesceTimer invalidate];
    [self.menuRetryTimer invalidate];
}

#pragma mark - Public API (called from MenuController and importers)

- (void)updateForActiveWindow
{
    unsigned long windowId = [self readActiveWindowFromX11];
    [self updateForActiveWindowId:windowId];
}

- (void)updateForActiveWindowId:(unsigned long)windowId
{

    if (!self.protocolManager) return;

    /* Cancel any existing coalesce timer; the new event supersedes it. */
    if (self.coalesceTimer) {
        [self.coalesceTimer invalidate];
        self.coalesceTimer = nil;
    }

    self.pendingCoalesceWindowId = windowId;

    /* Fire after COALESCE_DELAY_SECS so rapid-fire notifications collapse. */
    self.coalesceTimer = [NSTimer scheduledTimerWithTimeInterval:COALESCE_DELAY_SECS
                                                          target:self
                                                        selector:@selector(coalesceTimerFired:)
                                                        userInfo:nil
                                                         repeats:NO];
}

- (void)coalesceTimerFired:(NSTimer *)timer
{
    (void)timer;
    self.coalesceTimer = nil;

    unsigned long windowId = self.pendingCoalesceWindowId;

    if (windowId == 0) {
        /* No active window reported.  If we are showing an app's menu, keep
         * it: the window manager can momentarily report 0 while the app still
         * has focus (e.g. Chromium juggling its internal windows), and
         * clearing to system-only here is what made every app's menu vanish a
         * few seconds after it loaded - wiping its shortcuts with it.  Only go
         * system-only when there really is nothing to show. */
        if (self.currentMenu && self.currentWindowId != 0) {
            NSDebugLLog(@"gwcomp", @"AppMenuWidget: No active window - keeping current menu (0x%lx)", self.currentWindowId);
            return;
        }
        [self clearToSystemOnly];
        return;
    }

    WindowSwitchContext *ctx = [WindowSwitchContext contextForWindow:windowId
                                                    protocolManager:self.protocolManager];
    if (!ctx) {
        [self clearToSystemOnly];
        return;
    }

    [self handleFocusChange:ctx];
}

- (void)checkAndDisplayMenuForNewlyRegisteredWindow:(unsigned long)windowId
{
    /* Cancel any pending menu retry for this window — a real menu is now available. */
    if (self.menuRetryTimer && self.menuRetryWindowId == windowId) {
        [self.menuRetryTimer invalidate];
        self.menuRetryTimer = nil;
        self.menuRetryCount = 0;
    }

    unsigned long activeWindow = [self readActiveWindowFromX11];
    if (activeWindow != windowId) {
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Newly registered window 0x%lx is not active (active=0x%lx)",
              windowId, activeWindow);
        return;
    }

    NSLog(@"AppMenuWidget: Newly registered window 0x%lx is active - forcing menu load", windowId);
    WindowSwitchContext *ctx = [WindowSwitchContext contextForWindow:windowId
                                                    protocolManager:self.protocolManager];
    if (ctx) {
        ctx.hasRegisteredMenu = YES; /* we just received registration */
        [self handleFocusChange:ctx];
    }
}

- (void)clearMenu
{
    self.currentApplicationName = nil;
    if (self.systemMenu) {
        [[NSNotificationCenter defaultCenter] removeObserver:self
                                                        name:NSMenuDidBeginTrackingNotification
                                                      object:self.systemMenu];
        self.systemMenu = nil;
    }
    self.currentMenu = nil;
    self.currentWindowId = 0;
    self.currentWindowPID = 0;
    self.needsRedraw = YES;
    [self closeOpenMenuTracking];
    if (self.menuView) {
        [self.menuView setMenu:nil];
        [self.menuView setHidden:YES];
    }
    if (self.window) [self setNeedsDisplay:YES];
}

- (void)clearMenuAndHideView
{
    [self clearToSystemOnly];
}

- (void)displayMenuForWindow:(unsigned long)windowId
{
    WindowSwitchContext *ctx = [WindowSwitchContext contextForWindow:windowId
                                                    protocolManager:self.protocolManager];
    if (ctx) {
        /* Refresh hasRegisteredMenu since caller expects an immediate load attempt. */
        ctx.hasRegisteredMenu = [self.protocolManager hasMenuForWindow:windowId];
        [self handleFocusChange:ctx];
    }
}

#pragma mark - Core update path (single entry point)

- (void)handleFocusChange:(WindowSwitchContext *)ctx
{
    if (!ctx || self.isInsideHandleFocusChange) return;
    self.isInsideHandleFocusChange = YES;

    @try {

    unsigned long windowId = ctx.windowId;

    /* Ignore focus on Menu.app itself. */
    if (ctx.isSelfWindow) {
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Focus on self (0x%lx) — keeping current menu", windowId);
        self.lastSwitchTime = [NSDate timeIntervalSinceReferenceDate];
        return;
    }

    /* Dialog/transient of the same app: keep the owner's menu. */
    if (ctx.isDialog && self.currentMenu && self.currentWindowId != 0) {
        if (ctx.pid != 0 && ctx.pid == self.currentWindowPID) {
            NSDebugLLog(@"gwcomp", @"AppMenuWidget: Dialog 0x%lx of same app (PID %d) — preserving menu",
                  windowId, (int)ctx.pid);
            self.lastSwitchTime = [NSDate timeIntervalSinceReferenceDate];
            return;
        }
    }

    self.lastSwitchTime = [NSDate timeIntervalSinceReferenceDate];

    /* Same window already showing a menu.  Rebuild only when PID changes
       (process restart) to avoid stale DBus service names.  Skip when the
       structure is unchanged to prevent infinite retry loops when the menu
       load transiently returns nil (e.g. slow DBus response). */
    if (windowId == self.currentWindowId && self.currentMenu && self.menuView && ![self.menuView isHidden]) {
        if (![self.protocolManager hasMenuForWindow:windowId]) {
            return;
        }
        pid_t newPID = [MenuUtils getWindowPID:windowId];
        if (newPID != 0 && newPID == self.currentWindowPID) {
            NSDebugLLog(@"gwcomp", @"AppMenuWidget: Same PID %d — assuming menu unchanged", (int)newPID);
            return;
        }
    }

    /* If the window has no registered menu yet, check if we're switching windows. */
    if (!ctx.hasRegisteredMenu) {
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Window 0x%lx has no menu yet (PID %d)", windowId, (int)ctx.pid);

        /* Desktop window with no menu — just show system-only immediately. */
        if (ctx.isDesktop) {
            [self clearToSystemOnly];
            return;
        }

        /* If switching to a DIFFERENT window (including from system-only state):
           clear immediately to avoid showing stale menu from the previous app.
           Exception: if the new window has no identifying properties at all
           (pid==0, no app name) it is likely a transient/popup belonging to the
           current app (e.g. Chrome's "Restore pages?" dialog).  In that case,
           keep the current menu during the retry period. */
        if (windowId != self.currentWindowId) {
            BOOL sameApp = (ctx.pid != 0 && ctx.pid == self.currentWindowPID);
            BOOL unidentifiable = (ctx.pid == 0 &&
                                   (ctx.appName == nil || [ctx.appName length] == 0));
            if (!sameApp && !unidentifiable) {
                NSLog(@"AppMenuWidget: CLEARING on window change 0x%lx → 0x%lx",
                      self.currentWindowId, windowId);
                [self clearToSystemOnly];
            } else {
                NSLog(@"AppMenuWidget: KEEPING menu — transient/same-app window 0x%lx (pid=%d unidentifiable=%d)",
                      windowId, (int)ctx.pid, (int)unidentifiable);
            }
        }

        /* Schedule discovery retry. This will check all protocols (DO, GTK, D-Bus)
           and load a menu if one exists. D-Bus properties often have a brief
           async delay (~100-500ms) before appearing. */
        [self scheduleMenuRetryForWindow:windowId];
        return;
    }

    /* Cancel any pending retry — we have a menu now. */
    [self cancelMenuRetry];

    /* Fetch the menu from the protocol manager. */
    NSMenu *menu = nil;
    @try {
        menu = [self.protocolManager getMenuForWindow:windowId];
    } @catch (NSException *exception) {
        NSLog(@"AppMenuWidget: Exception getting menu for 0x%lx: %@", windowId, exception);
    }

    NSLog(@"AppMenuWidget: HAS_REGISTERED_MENU - windowId=0x%lx got menu=%p", windowId, menu);
    if (!menu || [self isPlaceholderMenu:menu]) {
        NSLog(@"AppMenuWidget: NIL/PLACEHOLDER menu for 0x%lx — clearing and scheduling retry", windowId);
        /* When switching to a different window and fetching its menu returns nil/placeholder,
           clear the old menu immediately. Then retry to discover if the menu loads. */
        if (windowId != self.currentWindowId && self.currentWindowId != 0) {
            [self clearToSystemOnly];
        }
        [self scheduleMenuRetryForWindow:windowId];
        return;
    }

    /* ── We have a real menu — load it. ────────────────────────── */
    [self loadMenu:menu forWindow:windowId];

    /* Pre-warm enabled/checkmark states on window switch so the user's first
       click on a title is already fresh and the tracking handler does not have
       to block on the synchronous DO pull.  Runs on the main queue after the
       current event so the switch itself is not delayed; the freshness gate in
       mainMenuDidBeginTracking: makes the click path lag-free. */
    if (![self.protocolManager menuStatesAreFreshForWindow:windowId
                                                withinTTL:STATE_REFRESH_TTL]) {
        [self performSelectorOnMainThread: @selector(refreshMenuStateOnMain:)
                               withObject: @(windowId) waitUntilDone: NO];
    }

    /* Update application name from context. */
    if ([ctx.appName length] > 0) {
        self.currentApplicationName = ctx.appName;
    } else {
        self.currentApplicationName = @"Unknown";
    }

    } @finally {
        self.isInsideHandleFocusChange = NO;
    }
}

/* Deferred to the main run loop (performSelectorOnMainThread:).  Runs the
   synchronous DO state refresh after the current event so the window switch
   itself is not delayed; the freshness gate in mainMenuDidBeginTracking:
   makes the click path lag-free. */
- (void)refreshMenuStateOnMain:(NSNumber *)windowIdNum
{
    unsigned long windowId = [windowIdNum unsignedLongValue];
    [self.protocolManager refreshMenuStateForWindow:windowId];
}

#pragma mark - Menu retry

- (void)scheduleMenuRetryForWindow:(unsigned long)windowId
{
    /* Check if we've already determined this window has no menu (within TTL). */
    NSNumber *windowKey = [NSNumber numberWithUnsignedLong:windowId];
    NSDate *failTime = [self.windowsWithoutMenus objectForKey:windowKey];
    if (failTime) {
        NSTimeInterval age = -[failTime timeIntervalSinceNow];
        if (age < 30.0) {  /* 30 second TTL: skip retry for recently confirmed no-menu windows */
            NSDebugLLog(@"gwcomp", @"AppMenuWidget: Window 0x%lx recently confirmed to have no menu — skipping retry", windowId);
            return;
        }
        /* TTL expired — allow retry in case properties now exist */
        [self.windowsWithoutMenus removeObjectForKey:windowKey];
    }

    /* If already retrying this window, let the timer run. */
    if (self.menuRetryTimer && self.menuRetryWindowId == windowId) return;

    /* New window — reset retry count. */
    [self cancelMenuRetry];
    self.menuRetryWindowId = windowId;
    self.menuRetryCount = 0;
    self.menuRetryTimer = [NSTimer scheduledTimerWithTimeInterval:MENU_RETRY_INTERVAL
                                                           target:self
                                                         selector:@selector(menuRetryTimerFired:)
                                                         userInfo:nil
                                                          repeats:NO];
    NSDebugLLog(@"gwcomp", @"AppMenuWidget: Scheduled menu retry for 0x%lx (attempt 1/%d)", windowId, MENU_RETRY_MAX);
}

- (void)cancelMenuRetry
{
    if (self.menuRetryTimer) {
        [self.menuRetryTimer invalidate];
        self.menuRetryTimer = nil;
    }
    self.menuRetryCount = 0;
    self.menuRetryWindowId = 0;
}

- (void)menuRetryTimerFired:(NSTimer *)timer
{
    (void)timer;
    self.menuRetryTimer = nil;
    self.menuRetryCount++;

    unsigned long windowId = self.menuRetryWindowId;

    /* Check if we've moved on to a different window. */
    unsigned long activeWindow = [self readActiveWindowFromX11];
    if (activeWindow != windowId && activeWindow != 0) {
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Retry for 0x%lx cancelled — active window is now 0x%lx", windowId, activeWindow);
        [self cancelMenuRetry];
        return;
    }

    /* Check if the menu is now available. */
    if ([self.protocolManager hasMenuForWindow:windowId]) {
        NSLog(@"AppMenuWidget: Menu appeared for 0x%lx on retry %lu", windowId, (unsigned long)self.menuRetryCount);
        WindowSwitchContext *ctx = [WindowSwitchContext contextForWindow:windowId
                                                        protocolManager:self.protocolManager];
        if (ctx) {
            ctx.hasRegisteredMenu = YES;
            [self handleFocusChange:ctx];
        }
        return;
    }

    /* Budget exhausted? */
    if (self.menuRetryCount >= MENU_RETRY_MAX) {
        NSLog(@"AppMenuWidget: Window 0x%lx still has no menu after %d retries — caching as no-menu window",
              windowId, MENU_RETRY_MAX);
        /* Mark this window as confirmed to have no menu (30s TTL) to avoid retrying it again soon. */
        NSNumber *windowKey = [NSNumber numberWithUnsignedLong:windowId];
        [self.windowsWithoutMenus setObject:[NSDate date] forKey:windowKey];
        
        /* This retry is for a window that is no longer the one whose menu we
         * are showing (e.g. the user switched to another app/window while the
         * retry was running).  A stale retry must NEVER clear the current
         * app's menu - doing so also unregisters its global shortcuts, so
         * Alt+T stops working after switching away and back. */
        if (self.currentWindowId != 0 && self.currentWindowId != windowId) {
            NSLog(@"AppMenuWidget: Retry for stale window 0x%lx - keeping current menu (0x%lx)",
                  windowId, self.currentWindowId);
            [self cancelMenuRetry];
            return;
        }
        
        /* A window of the SAME app as the currently displayed menu (e.g. one of
         * Chrome's internal/helper windows that has no menu of its own) must not
         * clear the app menu either. */
        pid_t windowPID = [MenuUtils getWindowPID: windowId];
        if (self.currentWindowId != 0 && windowPID != 0
            && windowPID == self.currentWindowPID) {
            NSLog(@"AppMenuWidget: Keeping current menu - no-menu window 0x%lx is same app (pid %d)",
                  windowId, (int)windowPID);
            [self cancelMenuRetry];
            return;
        }
        
        /* Stay on system-only menu. */
        if (![self isShowingSystemOnlyMenu]) {
            [self clearToSystemOnly];
        }
        [self cancelMenuRetry];
        return;
    }

    /* Schedule next retry. */
    self.menuRetryTimer = [NSTimer scheduledTimerWithTimeInterval:MENU_RETRY_INTERVAL
                                                           target:self
                                                         selector:@selector(menuRetryTimerFired:)
                                                         userInfo:nil
                                                          repeats:NO];
    NSDebugLLog(@"gwcomp", @"AppMenuWidget: Retry %lu/%d for 0x%lx",
          (unsigned long)self.menuRetryCount, MENU_RETRY_MAX, windowId);
}

#pragma mark - Menu loading & display

- (void)loadMenu:(NSMenu *)menu forWindow:(unsigned long)windowId
{
    MENU_PROFILE_BEGIN(loadMenuForWindow);
    if (!menu) {
        MENU_PROFILE_END(loadMenuForWindow);
        return;
    }

    [self cancelMenuRetry];

    pid_t newPID = [MenuUtils getWindowPID:windowId];

    /* Skip rebuild when same window AND same PID — safe because only
       process restarts (which change PID) can leave stale DBus service
       names embedded in menu items.  Window-ID reuse across restarts
       is rare but would also be caught by the PID change. */
    if (newPID != 0 && self.currentWindowPID == newPID &&
        self.currentWindowId == windowId && self.currentMenu && self.menuView &&
        ![self.menuView isHidden] && [self.menuView menu] == self.currentMenu &&
        [self topLevelMenusMatch:self.currentMenu with:menu]) {
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Skipping menu rebuild for 0x%lx (same PID %d, unchanged)", windowId, newPID);
        MENU_PROFILE_END(loadMenuForWindow);
        return;
    }
    if (newPID == 0) {
        NSLog(@"AppMenuWidget: _NET_WM_PID not set on window 0x%lx — falling back to full rebuild", windowId);
    }

    unsigned long previousWindowId = self.currentWindowId;
    pid_t previousPID = self.currentWindowPID;
    self.currentWindowId = windowId;
    self.currentWindowPID = newPID;
    self.lastDisplayedPID = self.currentWindowPID;
    self.needsRedraw = YES;

    /* Clear shortcuts only on cross-app switch.
     
       Primary heuristic: PID comparison.  When both the previous and the new
       window have a valid PID and they differ, we are clearly switching apps.
     
       Fallback (window-ID change + unknown PID): many GNUstep applications do
       not set _NET_WM_PID on their X11 windows, causing getWindowPID: to
       return 0.  In that case the primary heuristic cannot fire, and the old
       application's shortcuts (e.g. Chrome's Cmd+W) stay registered in X11
       even after the user has switched to a different process.  To catch this,
       we also clean up when the window ID has changed AND the new PID is 0
       (unknown).  This is safe because the same-app-same-PID case still works:
       when two windows of the same app have valid PIDs, the primary heuristic
       correctly returns NO and we keep the shortcuts. */
    BOOL switchingApp = (previousPID != 0 && self.currentWindowPID != 0 && previousPID != self.currentWindowPID);
    if (!switchingApp && self.currentWindowPID == 0 && previousWindowId != 0 && previousWindowId != windowId) {
        switchingApp = YES;
    }
    if (switchingApp) {
        [[X11ShortcutManager sharedManager] unregisterNonDirectShortcuts];
    }

    @try {
        [self setupMenuViewWithMenu:menu];
    } @catch (NSException *exception) {
        NSLog(@"AppMenuWidget: Exception in setupMenuViewWithMenu: %@", exception);
        [self clearToSystemOnly];
        MENU_PROFILE_END(loadMenuForWindow);
        return;
    }

    /* Re-register shortcuts for this menu. */
    [self reregisterShortcutsForMenu:menu windowId:windowId];
    MENU_PROFILE_END(loadMenuForWindow);
}

/* Close any open dropdown menu (attached submenu panel) attached to the
   current menu view, and clear the highlighted item.

   GNUstep's NSMenuView embeds each open dropdown submenu as an "attached"
   NSMenuPanel that is created and torn down while its tracking loop runs.  If
   the menu view is destroyed or its menu replaced while such a panel is open,
   the panel is orphaned - it stays in the window list, is never unmapped, and
   keeps consuming pointer input (the "wedged" menu bar that no longer reacts
   to clicks).  This routine walks the attached-menu chain and detaches/clears
   it, so a menu-view rebuild always starts from a clean, non-tracking state.

   It only acts on the transient panels opened by the menu bar - it does not
   and cannot affect the normal application windows. */
- (void)closeOpenMenuTracking
{
    if (!self.menuView) return;

    NSView *view = self.menuView;
    if (![view isKindOfClass:[NSMenuView class]]) return;
    NSMenuView *menuView = (NSMenuView *)view;

    @try {
        /* Close the first-level dropdown (its NSMenuPanel window) by ordering
           the panel out, and clear the highlighted item.

           The attached menu must NOT be messaged directly: when a dropdown
           has been wedged (the menu view torn down while its panel was still
           open), menuView.attachedMenu still points at an NSMenu that has
           already been released, and sending it a message segfaults.  Menu
           windows are retained by NSApp, so closing them by window is always
           safe; ordering them out is exactly what un-wedges the menu bar
           (an orphaned, still-mapped panel is what swallowed pointer input).
           This app owns only its menu-bar dropdowns and the search results
           menu as NSMenuPanels, so closing all visible ones matches the
           original intent of tearing down any open menu tracking. */
        NSArray *windows = [[NSApp windows] copy];
        for (NSWindow *win in windows) {
            NSString *cls = NSStringFromClass([win class]);
            if ([cls hasPrefix:@"NSMenu"] && [win isVisible]) {
                [win orderOut:nil];
            }
        }

        [menuView setHighlightedItemIndex:-1];
    } @catch (NSException *e) {
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: closeOpenMenuTracking: %@", e);
    }
}

- (void)setupMenuViewWithMenu:(NSMenu *)menu
{
    MENU_PROFILE_BEGIN(setupMenuViewWithMenu);
    if (!menu) {
        MENU_PROFILE_END(setupMenuViewWithMenu);
        return;
    }

    /* Close any open dropdown submenu BEFORE destroying the menu view.
       A dropdown (NSMenuPanel) is an attached submenu created by GNUstep's
       NSMenuView tracking loop.  If we tear the menu view down while one is
       open, detachSubmenu never runs, the panel is orphaned but stays in the
       window list and keeps swallowing pointer input - the menu bar goes
       "wedged" and stops responding to clicks.  Force the detach up front so
       a rebuild can never orphan an open panel. */
    [self closeOpenMenuTracking];

    self.currentMenu = menu;

    NSWindow *window = [self window];
    if (window) [window disableFlushWindow];

    @try {
        /* Tear down old menu view. */
        if (self.menuView) {
            [[NSNotificationCenter defaultCenter] removeObserver:self.menuView];
            [self.menuView setMenu:nil];
            [self.menuView removeFromSuperview];
            self.menuView = nil;
        }

        /* Remove any pre-existing ⌘ items so we don't duplicate. */
        NSMutableIndexSet *commandIndexes = [NSMutableIndexSet indexSet];
        NSArray *menuItems = [menu itemArray];
        for (NSUInteger i = 0; i < [menuItems count]; i++) {
            if ([[[menuItems objectAtIndex:i] title] isEqualToString:@"⌘"]) {
                [commandIndexes addIndex:i];
            }
        }
        [commandIndexes enumerateIndexesWithOptions:NSEnumerationReverse usingBlock:^(NSUInteger idx, BOOL *stop) {
            (void)stop;
            [menu removeItemAtIndex:idx];
        }];

        /* Build the system ⌘ submenu. */
        if (self.systemMenu) {
            [[NSNotificationCenter defaultCenter] removeObserver:self
                                                            name:NSMenuDidBeginTrackingNotification
                                                          object:self.systemMenu];
            [self.systemMenu setDelegate:nil];
        }
        NSMenu *sysMenu = [[NSMenu alloc] initWithTitle:@"System"];

        NSMenuItem *searchItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Search...", nil)
                                                            action:@selector(toggleSearch:)
                                                     keyEquivalent:@" "];
        [searchItem setKeyEquivalentModifierMask:NSCommandKeyMask];
        [searchItem setTarget:[ActionSearchController sharedController]];
        [sysMenu addItem:searchItem];
        [sysMenu addItem:[NSMenuItem separatorItem]];

        NSMenu *prefsSubmenu = [[NSMenu alloc] initWithTitle:NSLocalizedString(@"System Preferences", nil)];
        self.systemPrefsSubmenu = prefsSubmenu;
        self.systemPrefsSubmenuPopulated = NO;
        /* Populate eagerly so the submenu is never empty: GNUstep's
           auto-enabling greys out an item whose submenu has no items, which
           would make "System Preferences" unclickable. */
        [self populatePrefPanesSubmenu];
        NSMenuItem *prefsItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"System Preferences", nil)
                                                           action:@selector(openSystemPreferences:)
                                                    keyEquivalent:@""];
        [prefsItem setTarget:self];
        [sysMenu addItem:prefsItem];
        [prefsItem setSubmenu:prefsSubmenu];
        [sysMenu addItem:[NSMenuItem separatorItem]];

        /* Power actions: shut down, restart and log out, ported from the
         * Workspace main menu into the Command menu. */
        NSMenuItem *restartItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Restart...", nil)
                                                             action:@selector(restart:)
                                                      keyEquivalent:@""];
        [restartItem setTarget:self];
        [sysMenu addItem:restartItem];

        NSMenuItem *shutDownItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Shut Down...", nil)
                                                              action:@selector(shutDown:)
                                                       keyEquivalent:@""];
        [shutDownItem setTarget:self];
        [sysMenu addItem:shutDownItem];

        NSMenuItem *logOutItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Log Out...", nil)
                                                            action:@selector(logOut:)
                                                     keyEquivalent:@""];
        [logOutItem setTarget:self];
        [sysMenu addItem:logOutItem];
        NSLog(@"AppMenuWidget: System menu built with %ld items: %@", (long)[sysMenu numberOfItems], [sysMenu itemArray]);

        self.systemMenu = sysMenu;
        self.systemMenuPopulatedFromCache = NO;
        [sysMenu setDelegate:self];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(systemMenuDidBeginTracking:)
                                                     name:NSMenuDidBeginTrackingNotification
                                                   object:sysMenu];
        [[ActionSearchController sharedController] setAppMenuWidget:self];

        NSMenuItem *sysItem = [[NSMenuItem alloc] initWithTitle:@"⌘" action:nil keyEquivalent:@""];
        [sysItem setSubmenu:sysMenu];
        [menu insertItem:sysItem atIndex:0];

        /* Create the new menu view. */
        NSRect mvFrame = NSMakeRect(0, 0, [self bounds].size.width, [self bounds].size.height);
        AppMenuView *newView = [[AppMenuView alloc] initWithFrame:mvFrame];
        [newView setHorizontal:YES];
        [newView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
        [newView setMenu:menu];
        [newView setHidden:NO];
        [self addSubview:newView];
        self.menuView = newView;

        [menu setDelegate:self];
        /* GNUstep's NSMenuView posts NSMenuDidBeginTrackingNotification only
           for the top-level trackWithEvent: call (the main menu bar view).
           Submenu views use _trackWithEvent: which does NOT post notifications.
           Therefore we observe the notification on the main menu itself, and
           call refreshMenuStateForWindow: whenever the user begins interacting
           with the menu bar.  This ensures enabled/disabled states (e.g. Copy
           after Select All) are pulled from the app before the user opens any
           submenu. */
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(mainMenuDidBeginTracking:)
                                                     name:NSMenuDidBeginTrackingNotification
                                                   object:menu];

        /* Observe the end of tracking too.  GNUstep only closes a menu bar's
           first-level dropdown panel itself when the interface style is
           Windows95 (NSMenuView.m line 1919 guards on mainWindowMenuView being
           non-nil, which is only set for that style).  With any other style the
           dropdown window stays mapped after every interaction, sitting over
           the menu bar and swallowing clicks - the "wedged" menu.  Close it
           right after tracking ends so it can never stick. */
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(mainMenuDidEndTracking:)
                                                     name:NSMenuDidEndTrackingNotification
                                                   object:menu];


        /* Wire up items without a target. */
        BOOL isGNUStepMenu = NO;
        NSArray *items = [menu itemArray];
        for (NSMenuItem *item in items) {
            if ([item hasSubmenu]) {
                for (NSMenuItem *sub in [[item submenu] itemArray]) {
                    NSDictionary *rep = [sub representedObject];
                    if ([rep isKindOfClass:[NSDictionary class]] &&
                        [rep objectForKey:@"clientName"] && [rep objectForKey:@"windowId"]) {
                        isGNUStepMenu = YES;
                        break;
                    }
                }
                if (isGNUStepMenu) break;
            }
        }
        if (!isGNUStepMenu) {
            for (NSMenuItem *item in items) {
                if (![item hasSubmenu] && ![item target]) {
                    [item setTarget:self];
                    [item setAction:@selector(menuItemClicked:)];
                }
            }
        }

        [self setNeedsDisplay:YES];

        /* Diagnostic log. */
        {
            NSMutableString *desc = [NSMutableString stringWithFormat:@"[MENUBAR win=0x%lx app=%@] ",
                                     self.currentWindowId, self.currentApplicationName ?: @"nil"];
            for (NSUInteger i = 0; i < [items count]; i++) {
                if (i > 0) [desc appendString:@" | "];
                NSMenuItem *it = [items objectAtIndex:i];
                [desc appendFormat:@"'%@'%@", [it title], [it hasSubmenu] ? @"\u25b6" : @""];
            }
            NSLog(@"%@", desc);
        }
    } @finally {
        if (window) {
            [window enableFlushWindow];
            [window flushWindow];
            [[window contentView] setNeedsDisplay:YES];
        }
        MENU_PROFILE_END(setupMenuViewWithMenu);
    }
}

#pragma mark - Menu comparison (lightweight, top-level only)

- (BOOL)topLevelMenusMatch:(NSMenu *)a with:(NSMenu *)b
{
    if (!a || !b) return NO;

    NSArray *itemsA = [a itemArray];
    NSArray *itemsB = [b itemArray];

    /* Filter out the synthetic ⌘ item for comparison. */
    NSMutableArray *filteredA = [NSMutableArray arrayWithCapacity:[itemsA count]];
    NSMutableArray *filteredB = [NSMutableArray arrayWithCapacity:[itemsB count]];
    for (NSMenuItem *it in itemsA) {
        if (![[it title] isEqualToString:@"⌘"]) [filteredA addObject:it];
    }
    for (NSMenuItem *it in itemsB) {
        if (![[it title] isEqualToString:@"⌘"]) [filteredB addObject:it];
    }

    if ([filteredA count] != [filteredB count]) return NO;

    for (NSUInteger i = 0; i < [filteredA count]; i++) {
        NSMenuItem *ia = [filteredA objectAtIndex:i];
        NSMenuItem *ib = [filteredB objectAtIndex:i];
        if (![[ia title] isEqualToString:[ib title]]) return NO;
        if ([ia isEnabled] != [ib isEnabled]) return NO;
        if ([ia hasSubmenu] != [ib hasSubmenu]) return NO;
    }
    return YES;
}

#pragma mark - System-only menu state

- (void)clearToSystemOnly
{
    /* Don't clear while the search panel is visible — it needs the
       current app menu items to search through. */
    if ([[ActionSearchController sharedController] isSearchVisible]) {
        return;
    }

    // CRITICAL: Always unregister non-direct (app-registered) shortcuts when the menu is
    // cleared to system-only state.  Without this, shortcuts from a previously-focused
    // application (e.g. Chrome's Cmd+W) remain live in X11 after the user has switched to
    // a process that doesn't trigger the loadMenu:forWindow: cleanup path (e.g. when the
    // new window has no registered menu, or when the retry budget is exhausted).
    [[X11ShortcutManager sharedManager] unregisterNonDirectShortcuts];

    [self cancelMenuRetry];

    /* If already in system-only state, just reset IDs. */
    if ([self isShowingSystemOnlyMenu] && self.menuView && ![self.menuView isHidden]) {
        self.currentWindowId = 0;
        self.currentWindowPID = 0;
        self.needsRedraw = YES;
        return;
    }

    [self clearMenu];
    self.currentWindowId = 0;
    self.currentWindowPID = 0;
    self.needsRedraw = YES;
    [self displaySystemOnlyMenu];
}

- (void)displaySystemOnlyMenu
{
    if ([self isShowingSystemOnlyMenu] && self.menuView && ![self.menuView isHidden]) return;
    NSMenu *empty = [[NSMenu alloc] initWithTitle:@""];
    [self setupMenuViewWithMenu:empty];
}

- (BOOL)isShowingSystemOnlyMenu
{
    if (self.currentWindowId != 0 || self.currentMenu == nil) return NO;
    NSArray *items = [self.currentMenu itemArray];
    return ([items count] == 1 && [[[items objectAtIndex:0] title] isEqualToString:@"⌘"]);
}

- (BOOL)isPlaceholderMenu:(NSMenu *)menu
{
    if (!menu || [[menu itemArray] count] == 0) return YES;
    NSArray *items = [menu itemArray];
    if ([items count] == 1 && [[[items objectAtIndex:0] title] isEqualToString:@"GTK Application"]) return YES;
    return NO;
}

#pragma mark - X11 helpers

- (unsigned long)readActiveWindowFromX11
{
    Display *display = [MenuUtils sharedDisplay];
    if (!display) return 0;

    Window root = DefaultRootWindow(display);
    Window activeWindow = 0;
    Atom actualType;
    int actualFormat;
    unsigned long nitems, bytesAfter;
    unsigned char *prop = NULL;

    Atom atom = XInternAtom(display, "_NET_ACTIVE_WINDOW", False);
    SAFE_X11_CALL(display, {
        if (XGetWindowProperty(display, root, atom, 0, 1, False, AnyPropertyType,
                               &actualType, &actualFormat, &nitems, &bytesAfter, &prop) == Success && prop) {
            activeWindow = *(Window *)prop;
            XFree(prop);
        }
    }, {
        if (prop) { XFree(prop); prop = NULL; }
    });

    return activeWindow;
}

+ (BOOL)isWindowStillValid:(Window)windowId
{
    if (windowId == 0) return NO;
    Display *display = [MenuUtils sharedDisplay];
    if (!display) return NO;

    BOOL isValid = NO;
    SAFE_X11_CALL(display, {
        XWindowAttributes attrs;
        if (XGetWindowAttributes(display, windowId, &attrs)) {
            if (attrs.map_state == IsViewable) isValid = YES;
        }
    }, {
        isValid = NO;
    });
    return isValid;
}

+ (BOOL)safelyCheckWindow:(Window)windowId withDisplay:(Display *)display
{
    if (windowId == 0 || !display) return NO;
    BOOL isValid = NO;
    SAFE_X11_CALL(display, {
        XWindowAttributes attrs;
        if (XGetWindowAttributes(display, windowId, &attrs) != BadWindow) isValid = YES;
    }, {
        isValid = NO;
    });
    return isValid;
}

- (void)handleWindowDisappeared:(Window)windowId
{
    NSDebugLLog(@"gwcomp", @"AppMenuWidget: Window %lu disappeared", windowId);
    if (self.currentWindowId == windowId) {
        /* Preserve the visible menu; focus/reconcile will select the replacement. */
        self.lastSwitchTime = [NSDate timeIntervalSinceReferenceDate];
        self.needsRedraw = YES;
    }
}

#pragma mark - NSMenuDelegate (system menu population)

- (void)systemMenuDidBeginTracking:(NSNotification *)note
{
    NSMenu *menu = (NSMenu *)[note object];
    if (menu != self.systemMenu) return;
    NSDebugLog(@"AppMenuWidget: systemMenuDidBeginTracking - populating apps");
    [self populateSystemMenu];
}

- (void)menuWillOpen:(NSMenu *)menu
{
    (void)menu;
}

/* Called via NSMenuDidBeginTrackingNotification for the main menu.
   GNUstep's NSMenuView does not call the menuWillOpen: delegate method and
   does not post NSMenuDidBeginTrackingNotification for submenus (they use
   _trackWithEvent: internally).  So we observe the notification on the main
   menu itself and refresh when the user begins interacting with the menu bar.

   The notification is posted at the top of NSMenuView -trackWithEvent:,
   before the first tracking iteration attaches the dropdown submenu.  We must
   make enabled/checkmark states current synchronously here: an asynchronous
   refresh lands after the dropdown has been drawn, so the first open always
   shows the stale states and the user has to open the menu twice to see them
   update.

   refreshMenuStateForWindow: makes a synchronous DO call to the client (Eau),
   which blocks the main thread until the remote returns.  That is intentional
   and bounded (the connection request timeout is 0.3 s; a responsive client
   answers in a few ms).  Blocking here is safe because the dropdown has not
   been drawn yet - the states we apply now are exactly the ones the user sees
   on the first open.

   To avoid this small block on every single click we skip the pull while the
   window's states are still fresh (STATE_REFRESH_TTL) - handleFocusChange:
   pre-warms them on window switch, and the client pushes state changes
   directly via updateMenuEnabledStatesForWindow:. */
- (void)mainMenuDidBeginTracking:(NSNotification *)note
{
    (void)note;
    unsigned long windowId = self.currentWindowId;

    if (windowId == 0) return;
    if (![self.protocolManager hasMenuForWindow:windowId]) return;

    if ([self.protocolManager menuStatesAreFreshForWindow:windowId
                                               withinTTL:STATE_REFRESH_TTL]) {
        return;
    }

    [self.protocolManager refreshMenuStateForWindow:windowId];
}

/* Close the first-level dropdown right after the menu bar finishes tracking.
   See the observer registration in setupMenuViewWithMenu: for why GNUstep
   leaves the panel mapped; closing it here prevents the wedge from ever
   forming.  Uses a delayed perform so the dropdown's own teardown (posted
   inside trackWithEvent:) has finished first. */
- (void)mainMenuDidEndTracking:(NSNotification *)note
{
    (void)note;
    [self performSelector:@selector(closeOpenMenuTracking)
               withObject:nil
               afterDelay:0.0];
}

- (void)menuNeedsUpdate:(NSMenu *)menu
{
    /* The System Preferences submenu is populated at build time; this guard
       catches a stale cache so the submenu stays current without re-scanning
       on every open. */
    if (menu == self.systemPrefsSubmenu) {
        if (!self.systemPrefsSubmenuPopulated) {
            [self populatePrefPanesSubmenu];
        }
        return;
    }

    /* Populate system menu but with throttling to avoid CPU thrashing from
       GNUstep calling menuNeedsUpdate: on every run-loop cycle for every
       submenu that has a delegate. */
    if (menu != self.systemMenu) {
        return;
    }

    NSDebugLog(@"AppMenuWidget: menuNeedsUpdate called for system menu");

    /* Throttle updates to avoid repeated app tree scanning. */
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - self.lastSystemMenuUpdateTime < 0.5) {
        /* Throttled — skip. */
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: menuNeedsUpdate throttled");
        return;
    }
    self.lastSystemMenuUpdateTime = now;

    [self populateSystemMenu];
}

- (void)populateSystemMenu
{
    NSMenu *menu = self.systemMenu;
    if (!menu) {
        NSLog(@"AppMenuWidget: populateSystemMenu - no systemMenu");
        return;
    }

    NSLog(@"AppMenuWidget: populateSystemMenu called");

    /* Use cached app tree if fresh enough. */
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    BOOL cacheValid = (self.cachedAppBundleTree && (now - self.cachedAppBundleTreeTime) < SYSTEM_MENU_CACHE_TTL);

    /* Already populated with current cache — skip. */
    if (cacheValid && self.systemMenuPopulatedFromCache) {
        NSLog(@"AppMenuWidget: populateSystemMenu skipped (cached), has %ld items", (long)[menu numberOfItems]);
        return;
    }

    NSLog(@"AppMenuWidget: populateSystemMenu proceeding (cacheValid=%d, populated=%d)", cacheValid, self.systemMenuPopulatedFromCache);

    /* The dynamic "Applications" submenu lives above System Preferences: it is
       inserted there on first population and replaced on refresh.  The power
       actions (Restart.../Shut Down.../Log Out...) are permanent and survive. */
    NSArray *items = [menu itemArray];
    NSInteger startIndex = 1;
    NSInteger appsIndex = NSNotFound;
    for (NSUInteger i = 0; i < [items count]; i++) {
        NSString *title = [[items objectAtIndex:i] title];
        if ([title isEqualToString:NSLocalizedString(@"System Preferences", nil)]) {
            startIndex = (NSInteger)i;
        } else if ([title isEqualToString:NSLocalizedString(@"Applications", nil)]) {
            appsIndex = (NSInteger)i;
        }
    }
    if (appsIndex != NSNotFound) {
        [menu removeItemAtIndex:appsIndex];
        if (appsIndex < startIndex) startIndex--;
    }

    NSDictionary *appTree;
    if (cacheValid) {
        appTree = self.cachedAppBundleTree;
    } else {
        appTree = [self scanApplicationBundleTree];
        self.cachedAppBundleTree = appTree;
        self.cachedAppBundleTreeTime = now;
    }

    /* Build the "Applications" submenu from the tree. */
    NSMenu *appsSubmenu = [[NSMenu alloc] initWithTitle:NSLocalizedString(@"Applications", nil)];
    NSLog(@"AppMenuWidget: Scanning app tree with %ld root keys", (long)[[appTree allKeys] count]);
    [self addMenuItemsFromTree:appTree toMenu:appsSubmenu];

    NSLog(@"AppMenuWidget: Built apps submenu with %ld items", (long)[appsSubmenu numberOfItems]);
    if ([appsSubmenu numberOfItems] == 0) {
        NSMenuItem *none = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"No applications found", nil)
                                                      action:nil keyEquivalent:@""];
        [none setEnabled:NO];
        [appsSubmenu addItem:none];
    }

    [self addLauncherItemWithTitle:NSLocalizedString(@"Applications", nil)
                            action:nil
                 representedObject:nil
                           submenu:appsSubmenu
                            toMenu:menu
                            atIndex:startIndex];
    NSLog(@"AppMenuWidget: Inserted Applications submenu at index %ld, menu has %ld items", (long)startIndex, (long)[menu numberOfItems]);

    self.systemMenuPopulatedFromCache = YES;
}

- (void)ensureSystemMenuPopulated
{
    [self populateSystemMenu];
}

#pragma mark - Application bundle scanning (recursive with subdirectory submenus)

- (NSDictionary *)scanApplicationBundleTree
{
    NSLog(@"AppMenuWidget: scanApplicationBundleTree starting");
    NSArray *roots = @[[NSHomeDirectory() stringByAppendingPathComponent:@"Applications"],
                       @"/Local/Applications", @"/Local/Application",
                       @"/Network/Applications", @"/Network/Application",
                       @"/Applications",
                       @"/System/Applications", @"/System/Application"];

    NSInteger (^priorityForRoot)(NSString *) = ^NSInteger(NSString *root) {
        NSString *home = [NSHomeDirectory() stringByAppendingPathComponent:@"Applications"];
        if ([root isEqualToString:home]) return 4;
        if ([root hasPrefix:@"/Local/"]) return 3;
        if ([root isEqualToString:@"/Applications"]) return 2;
        if ([root hasPrefix:@"/Network/"]) return 1;
        return 0;
    };

    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableDictionary *appsByKey = [NSMutableDictionary dictionary];

    for (NSString *root in roots) {
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:root isDirectory:&isDir] || !isDir) continue;
        NSInteger rootPri = priorityForRoot(root);
        NSLog(@"AppMenuWidget: Scanning root %@ (priority %ld)", root, (long)rootPri);
        [self scanDirectory:root relativeTo:root priority:rootPri into:appsByKey fileManager:fm];
    }

    NSLog(@"AppMenuWidget: Found %ld applications total", (long)[appsByKey count]);

    /* Build a tree from the flat deduplicated entries.
       Tree structure: NSDictionary where:
         @"_apps" → NSMutableArray of @{@"title":…, @"path":…} for apps at this level
         any other key → child NSDictionary (subdirectory submenu) */
    NSMutableDictionary *tree = [NSMutableDictionary dictionary];
    for (NSDictionary *entry in [appsByKey allValues]) {
        NSArray *relPath = entry[@"relPath"];
        NSString *appPath = entry[@"path"];
        NSMutableDictionary *node = tree;
        /* Compute the absolute root path for this app entry. */
        NSString *dirPath = [appPath stringByDeletingLastPathComponent];
        for (NSUInteger i = 0; i < [relPath count]; i++) {
            dirPath = [dirPath stringByDeletingLastPathComponent];
        }
        for (NSString *component in relPath) {
            dirPath = [dirPath stringByAppendingPathComponent:component];
            NSMutableDictionary *child = node[component];
            if (!child) {
                child = [NSMutableDictionary dictionary];
                child[@"_path"] = dirPath;
                node[component] = child;
            }
            node = child;
        }
        NSMutableArray *apps = node[@"_apps"];
        if (!apps) {
            apps = [NSMutableArray array];
            node[@"_apps"] = apps;
        }
        [apps addObject:@{@"title": entry[@"title"], @"path": entry[@"path"]}];
    }

    [self sortTreeApps:tree];
    return [tree copy];
}

- (void)scanDirectory:(NSString *)dir
           relativeTo:(NSString *)root
             priority:(NSInteger)pri
                 into:(NSMutableDictionary *)appsByKey
          fileManager:(NSFileManager *)fm
{
    NSArray *contents = [fm contentsOfDirectoryAtPath:dir error:nil];
    if (!contents) return;

    /* Compute relative path components from root to this directory. */
    NSArray *relPath;
    if ([dir length] <= [root length]) {
        relPath = @[];
    } else {
        NSString *relDir = [dir substringFromIndex:[root length]];
        if ([relDir hasPrefix:@"/"]) relDir = [relDir substringFromIndex:1];
        relPath = [relDir pathComponents];
    }

    for (NSString *entry in contents) {
        NSString *fullPath = [dir stringByAppendingPathComponent:entry];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:fullPath isDirectory:&isDir]) continue;

        if ([[entry pathExtension] isEqualToString:@"app"]) {
            /* .app bundle — deduplicate by bundle ID */
            NSString *infoPath = [fullPath stringByAppendingPathComponent:@"Contents/Info.plist"];
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPath];
            NSString *bundleID = info[@"CFBundleIdentifier"];
            NSString *key = (bundleID && [bundleID length] > 0) ? bundleID
                            : [[[entry stringByDeletingPathExtension] lowercaseString] copy];
            NSDictionary *existing = appsByKey[key];
            NSString *displayName = [[entry stringByDeletingPathExtension] copy];
            if (!existing || pri > [existing[@"priority"] integerValue]) {
                appsByKey[key] = @{@"path": fullPath, @"title": displayName,
                                   @"priority": @(pri), @"relPath": relPath};
            }
        } else if (isDir) {
            /* Subdirectory — recurse (skip hidden directories) */
            if (![entry hasPrefix:@"."]) {
                [self scanDirectory:fullPath relativeTo:root priority:pri into:appsByKey fileManager:fm];
            }
        }
    }
}

- (void)sortTreeApps:(NSMutableDictionary *)tree
{
    NSMutableArray *apps = tree[@"_apps"];
    if (apps) {
        [apps sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [[a[@"title"] lowercaseString] compare:[b[@"title"] lowercaseString]];
        }];
    }
    for (NSString *key in [tree allKeys]) {
        if ([key isEqualToString:@"_apps"]) continue;
        id child = tree[key];
        if ([child isKindOfClass:[NSMutableDictionary class]]) {
            [self sortTreeApps:child];
        }
    }
}

/* Build a launcher menu item that also carries a submenu: clicking the item
   performs `action` (targeted at self) and its representedObject is `object`;
   the item's submenu (may be nil) opens on hover/arrow.  This is the shared
   shape of the Applications folder items and the System Preferences item. */
- (NSMenuItem *)addLauncherItemWithTitle:(NSString *)title
                                  action:(SEL)action
                       representedObject:(id)object
                                 submenu:(NSMenu *)submenu
                                  toMenu:(NSMenu *)menu
{
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title
                                                  action:action
                                           keyEquivalent:@""];
    [item setTarget:self];
    if (object) {
        [item setRepresentedObject:object];
    }
    /* Add the item first, then attach the submenu: GNUstep's swizzled
       setSubmenu: preserves a custom action, and auto-enabling evaluates the
       item correctly only once it belongs to a menu. */
    [menu addItem:item];
    if (submenu) {
        [item setSubmenu:submenu];
    }
    return item;
}

- (NSMenuItem *)addLauncherItemWithTitle:(NSString *)title
                                  action:(SEL)action
                       representedObject:(id)object
                                 submenu:(NSMenu *)submenu
                                  toMenu:(NSMenu *)menu
                                 atIndex:(NSInteger)index
{
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title
                                                  action:action
                                           keyEquivalent:@""];
    [item setTarget:self];
    if (object) {
        [item setRepresentedObject:object];
    }
    if (index >= 0 && index <= (NSInteger)[menu numberOfItems]) {
        [menu insertItem:item atIndex:index];
    } else {
        [menu addItem:item];
    }
    if (submenu) {
        [item setSubmenu:submenu];
    }
    return item;
}

- (void)addMenuItemsFromTree:(NSDictionary *)tree toMenu:(NSMenu *)menu
{
    /* Collect both subdirectory submenus and app items, then interleave
       them alphabetically so the list feels natural. */
    NSMutableArray *entries = [NSMutableArray array];

    for (NSString *key in [tree allKeys]) {
        if ([key isEqualToString:@"_apps"]) continue;
        if ([key isEqualToString:@"_path"]) continue;
        [entries addObject:@{@"_type": @"dir", @"_name": key, @"_tree": tree[key]}];
    }

    NSArray *apps = tree[@"_apps"];
    if (apps) {
        for (NSDictionary *app in apps) {
            [entries addObject:@{@"_type": @"app", @"_name": app[@"title"], @"_path": app[@"path"]}];
        }
    }

    [entries sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [[a[@"_name"] lowercaseString] compare:[b[@"_name"] lowercaseString]];
    }];

    for (NSDictionary *entry in entries) {
        if ([entry[@"_type"] isEqualToString:@"dir"]) {
            NSDictionary *subtree = entry[@"_tree"];
            NSString *dirPath = subtree[@"_path"];
            NSMenu *submenu = [[NSMenu alloc] initWithTitle:entry[@"_name"]];
            [self addMenuItemsFromTree:subtree toMenu:submenu];
            if ([submenu numberOfItems] > 0) {
                NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:entry[@"_name"]
                                                              action:@selector(openFolderInWorkspace:)
                                                       keyEquivalent:@""];
                [item setTarget:self];
                [item setRepresentedObject:dirPath];
                [menu addItem:item];
                [item setSubmenu:submenu];
            }
        } else {
            NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:entry[@"_name"]
                                                          action:@selector(openApplicationBundle:)
                                                   keyEquivalent:@""];
            [item setTarget:self];
            [item setRepresentedObject:entry[@"_path"]];
            [menu addItem:item];
        }
    }
}

- (void)menuDidClose:(NSMenu *)menu
{
    NSDebugLog(@"AppMenuWidget: menuDidClose: '%@'", [menu title] ?: @"(no title)");
}

- (void)menu:(NSMenu *)menu willHighlightItem:(NSMenuItem *)item
{
    (void)menu; (void)item;
}

- (BOOL)menu:(NSMenu *)menu updateItem:(NSMenuItem *)item atIndex:(NSInteger)index shouldCancel:(BOOL)shouldCancel
{
    (void)menu; (void)item; (void)index; (void)shouldCancel;
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

#pragma mark - Drawing

- (void)drawRect:(NSRect)dirtyRect
{
    BOOL hasMenu = (self.currentMenu && [[self.currentMenu itemArray] count] > 0);
    if (!hasMenu) {
        [[NSColor clearColor] set];
        NSRectFill([self bounds]);
        if (self.menuView) [self.menuView setHidden:YES];
        return;
    }
    if (self.menuView) [self.menuView setHidden:NO];
}

#pragma mark - Mouse events

- (void)mouseDown:(NSEvent *)theEvent
{
    if (self.menuView && self.currentMenu) {
        [self.menuView mouseDown:theEvent];
    }
    [super mouseDown:theEvent];
}

- (void)mouseUp:(NSEvent *)theEvent
{
    if (self.menuView) [self.menuView mouseUp:theEvent];
    [super mouseUp:theEvent];
}

#pragma mark - Actions

- (void)menuItemClicked:(NSMenuItem *)sender
{
    if ([sender representedObject] && [sender target]) {
        SEL action = [sender action];
        if (action && [[sender target] respondsToSelector:action]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [[sender target] performSelector:action withObject:sender];
#pragma clang diagnostic pop
            return;
        }
    }
    NSDebugLog(@"AppMenuWidget: No action handler for '%@'", [sender title]);
}

- (void)openSystemPreferences:(NSMenuItem *)sender
{
    (void)sender;
    NSMenu *parentMenu = [sender menu];
    if (parentMenu && [parentMenu respondsToSelector:@selector(cancelTracking)]) {
        [parentMenu performSelector:@selector(cancelTracking)];
    }

    [NSThread detachNewThreadWithBlock: ^{
        /* Prefer the System-domain app bundle over any stale Local-domain
           leftover, then fall back to name lookup.  Launch the app's
           executable directly: GNUstep's NSWorkspace openURL: on a bundle
           directory opens it as a *file* (TextEdit becomes the handler),
           which never starts the app. */
        NSArray *paths = @[@"/System/Applications/System Preferences.app",
                           @"/System/Applications/SystemPreferences.app",
                           @"/Applications/System Preferences.app",
                           @"/Applications/SystemPreferences.app"];
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *execPath = nil;
        for (NSString *p in paths) {
            if ([fm fileExistsAtPath:p]) { execPath = p; break; }
        }
        if (!execPath) {
            for (NSString *name in @[@"System Preferences", @"SystemPreferences", @"System-Preferences"]) {
                NSString *p = [[NSWorkspace sharedWorkspace] fullPathForApplication:name];
                if (p) { execPath = p; break; }
            }
        }
        if (!execPath) {
            NSLog(@"AppMenuWidget: Could not find System Preferences to launch");
            return;
        }

        NSString *infoPath = [execPath stringByAppendingPathComponent:@"Resources/Info-gnustep.plist"];
        if (![fm fileExistsAtPath:infoPath]) {
            infoPath = [execPath stringByAppendingPathComponent:@"Contents/Info.plist"];
        }
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPath];
        NSString *execName = [info objectForKey:@"NSExecutable"];
        if (execName) {
            NSString *exe = [execPath stringByAppendingPathComponent:execName];
            if ([fm isExecutableFileAtPath:exe]) {
                [NSTask launchedTaskWithLaunchPath:exe arguments:@[]];
                return;
            }
        }
        NSString *exe = [execPath stringByAppendingPathComponent:
                         [[execPath lastPathComponent] stringByDeletingPathExtension]];
        if ([fm isExecutableFileAtPath:exe]) {
            [NSTask launchedTaskWithLaunchPath:exe arguments:@[]];
            return;
        }
        NSLog(@"AppMenuWidget: Could not find System Preferences executable to launch");
    }];
}

/* Populate the System Preferences submenu with one item per installed
   prefPane, taken from the same bundle directories SystemPreferences scans
   (User, Local and System Library/Bundles).  Called lazily the first time the
   submenu is about to open; each item launches SystemPreferences with the
   pane name as a command-line argument so the pane opens directly. */
- (void)populatePrefPanesSubmenu
{
    NSMenu *submenu = self.systemPrefsSubmenu;
    if (!submenu) return;

    self.systemPrefsSubmenuPopulated = YES;

    NSArray *bundleDirs = @[
        [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) lastObject],
        [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSLocalDomainMask, YES) lastObject],
        [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSSystemDomainMask, YES) lastObject]
    ];

    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableDictionary *panesByName = [NSMutableDictionary dictionary];
    NSMutableArray *labels = [NSMutableArray array];

    for (NSString *bundlesDir in bundleDirs) {
        NSString *dir = [bundlesDir stringByAppendingPathComponent:@"Bundles"];
        NSArray *contents = [fm contentsOfDirectoryAtPath:dir error:nil];
        if (!contents) continue;

        for (NSString *entry in contents) {
            if (![[entry pathExtension] isEqualToString:@"prefPane"]) continue;
            NSString *panePath = [dir stringByAppendingPathComponent:entry];

            /* GNUstep prefPane bundles keep their metadata in
               Resources/Info-gnustep.plist; fall back to the standard
               Contents/Info.plist location. */
            NSString *infoPath = [panePath stringByAppendingPathComponent:@"Resources/Info-gnustep.plist"];
            if (![fm fileExistsAtPath:infoPath]) {
                infoPath = [panePath stringByAppendingPathComponent:@"Contents/Info.plist"];
            }
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPath];
            if (!info) continue;

            NSString *label = [info objectForKey:@"NSPrefPaneIconLabel"];
            if (!label || [label length] == 0) {
                label = [entry stringByDeletingPathExtension];
            }
            if (panesByName[label]) continue;   /* first occurrence wins */

            panesByName[label] = @{ @"path": panePath, @"name": [entry stringByDeletingPathExtension] };
            [labels addObject:label];
        }
    }

    [labels sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];

    for (NSString *label in labels) {
        NSDictionary *pane = panesByName[label];
        [self addLauncherItemWithTitle:label
                                action:@selector(openPrefPane:)
                     representedObject:pane[@"name"]
                               submenu:nil
                                toMenu:submenu];
    }

    if ([submenu numberOfItems] == 0) {
        NSMenuItem *none = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"No preference panes found", nil)
                                                      action:nil keyEquivalent:@""];
        [none setEnabled:NO];
        [submenu addItem:none];
    }
}

/* Launch SystemPreferences and pass the pane name as a command-line argument;
   SystemPreferences opens the named pane directly (its
   openPaneFromCommandLineArguments matches bundle name or identifier). */
- (void)openPrefPane:(NSMenuItem *)sender
{
    NSString *paneName = [sender representedObject];
    if (!paneName || [paneName length] == 0) return;

    NSMenu *parentMenu = [sender menu];
    if (parentMenu && [parentMenu respondsToSelector:@selector(cancelTracking)]) {
        [parentMenu performSelector:@selector(cancelTracking)];
    }

    [NSThread detachNewThreadWithBlock: ^{
        /* Resolve the System Preferences app bundle, preferring the System
           domain over any stale Local-domain leftover, then launch its
           executable with the pane name as the argument. */
        NSArray *paths = @[@"/System/Applications/System Preferences.app",
                           @"/System/Applications/SystemPreferences.app",
                           @"/Applications/System Preferences.app",
                           @"/Applications/SystemPreferences.app"];
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *execPath = nil;
        for (NSString *p in paths) {
            if ([fm fileExistsAtPath:p]) { execPath = p; break; }
        }
        if (!execPath) {
            for (NSString *name in @[@"SystemPreferences", @"System Preferences", @"System-Preferences"]) {
                NSString *p = [[NSWorkspace sharedWorkspace] fullPathForApplication:name];
                if (p) { execPath = p; break; }
            }
        }
        if (!execPath) {
            NSLog(@"AppMenuWidget: Could not find System Preferences to open pane '%@'", paneName);
            return;
        }

        /* GNUstep app bundles carry the executable in the bundle root (or in
           Contents/MacOS); openPaneFromCommandLineArguments reads the pane
           from the arguments. */
        NSString *infoPath = [execPath stringByAppendingPathComponent:@"Resources/Info-gnustep.plist"];
        if (![fm fileExistsAtPath:infoPath]) {
            infoPath = [execPath stringByAppendingPathComponent:@"Contents/Info.plist"];
        }
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPath];
        NSString *execName = [info objectForKey:@"NSExecutable"];
        if (execName) {
            NSString *exe = [execPath stringByAppendingPathComponent:execName];
            if ([fm isExecutableFileAtPath:exe]) {
                [NSTask launchedTaskWithLaunchPath:exe arguments:@[paneName]];
                return;
            }
        }
        /* Fall back to the bundle-root executable name matching the app name. */
        NSString *exe = [execPath stringByAppendingPathComponent:
                         [[execPath lastPathComponent] stringByDeletingPathExtension]];
        if ([fm isExecutableFileAtPath:exe]) {
            [NSTask launchedTaskWithLaunchPath:exe arguments:@[paneName]];
            return;
        }
        NSLog(@"AppMenuWidget: Could not find System Preferences executable to open pane '%@'", paneName);
    }];
}

#pragma mark - Power actions (Command menu)

/* Confirms the action with the same dialog the Workspace uses, then hands the
 * actual command execution over to SystemActions (a single command chosen for
 * the operating system at hand). */
- (void)confirmSystemAction:(NSMenuItem *)sender
                      title:(NSString *)title
                    message:(NSString *)message
                 actionType:(NSString *)actionType
{
    NSMenu *parentMenu = [sender menu];
    if (parentMenu && [parentMenu respondsToSelector:@selector(cancelTracking)]) {
        [parentMenu performSelector:@selector(cancelTracking)];
    }

    NSLog(@"AppMenuWidget: Power action '%@' invoked, showing confirmation", actionType);

    /* Let the dropdown menu finish closing before the modal confirmation
       appears, so the dialog is not shown on top of the still-open menu. */
    NSDictionary *info = @{
        @"title": title ?: @"",
        @"message": message ?: @"",
        @"action": actionType ?: @""
    };
    [self performSelector:@selector(showPowerActionConfirmation:)
               withObject:info
               afterDelay:POWER_CONFIRM_DELAY_SECS];
}

- (void)showPowerActionConfirmation:(NSDictionary *)info
{
    NSString *title = [info objectForKey:@"title"];
    NSString *message = [info objectForKey:@"message"];
    NSString *actionType = [info objectForKey:@"action"];

    if (NSRunAlertPanel(title, message, title, NSLocalizedString(@"Cancel", nil), nil)) {
        NSLog(@"AppMenuWidget: User confirmed %@", actionType);
        if ([actionType isEqualToString:@"shutdown"]) {
            [SystemActions executeShutdown];
        } else if ([actionType isEqualToString:@"restart"]) {
            [SystemActions executeRestart];
        } else {
            [SystemActions executeLogout];
        }
    } else {
        NSLog(@"AppMenuWidget: User cancelled %@", actionType);
    }
}

- (void)restart:(NSMenuItem *)sender
{
    [self confirmSystemAction:sender
                        title:NSLocalizedString(@"Restart", nil)
                      message:NSLocalizedString(@"Are you sure you want to quit\nall applications and restart now?", nil)
                   actionType:@"restart"];
}

- (void)shutDown:(NSMenuItem *)sender
{
    [self confirmSystemAction:sender
                        title:NSLocalizedString(@"Shut Down", nil)
                      message:NSLocalizedString(@"Are you sure you want to quit\nall applications and shut down now?", nil)
                   actionType:@"shutdown"];
}

- (void)logOut:(NSMenuItem *)sender
{
    [self confirmSystemAction:sender
                        title:NSLocalizedString(@"Log Out", nil)
                      message:NSLocalizedString(@"Are you sure you want to quit\nall applications and log out now?", nil)
                   actionType:@"logout"];
}

- (void)openApplicationBundle:(NSMenuItem *)sender
{
    NSString *path = [sender representedObject];
    if (!path) return;

    NSLog(@"AppMenuWidget: Launching application at %@", path);

    NSMenu *parentMenu = [sender menu];
    if (parentMenu && [parentMenu respondsToSelector:@selector(cancelTracking)]) {
        [parentMenu performSelector:@selector(cancelTracking)];
    }

    [NSThread detachNewThreadWithBlock: ^{
        NSWorkspace *ws = [NSWorkspace sharedWorkspace];
        NSString *bundleName = [[path lastPathComponent] stringByDeletingPathExtension];

        /* Try name-based lookup (works for apps in standard directories). */
        BOOL launched = NO;
        if (bundleName && [ws launchApplication:bundleName]) launched = YES;

        /* Try full path (handles apps in subdirectories like Utilities/). */
        if (!launched && [ws launchApplication:path]) launched = YES;

        NSString *infoPath = [path stringByAppendingPathComponent:@"Contents/Info.plist"];
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPath];
        NSString *bundleID = info[@"CFBundleIdentifier"];
        if (!launched && bundleID && [ws launchApplication:bundleID]) launched = YES;

        /* Launch directly via the executable inside the bundle. */
        if (!launched) {
            NSString *execName = info[@"CFBundleExecutable"];
            if (execName)
              {
                NSString *execPath = [path stringByAppendingPathComponent:
                  [@"Contents/MacOS/" stringByAppendingString: execName]];
                if ([[NSFileManager defaultManager] isExecutableFileAtPath: execPath])
                  {
                    [NSTask launchedTaskWithLaunchPath: execPath arguments: @[]];
                    launched = YES;
                  }
              }
        }

        if (!launched) {
            NSLog(@"AppMenuWidget: Failed to launch application at %@", path);
        }
    }];
}

- (void)openFolderInWorkspace:(NSMenuItem *)sender
{
    NSString *path = [sender representedObject];
    if (!path) return;

    NSLog(@"AppMenuWidget: Opening folder in Workspace: %@", path);

    NSMenu *parentMenu = [sender menu];
    if (parentMenu && [parentMenu respondsToSelector:@selector(cancelTracking)]) {
        [parentMenu performSelector:@selector(cancelTracking)];
    }

    [NSThread detachNewThreadWithBlock: ^{
        NSURL *fileURL = [NSURL fileURLWithPath:path];
        NSString *uri = [fileURL absoluteString];

        NSLog(@"AppMenuWidget: Opening folder in Workspace via D-Bus: %@", uri);

        id result = [[GNUDBusConnection sessionBus] callMethod:@"ShowFolders"
                                                    onService:@"org.freedesktop.FileManager1"
                                                  objectPath:@"/org/freedesktop/FileManager1"
                                                   interface:@"org.freedesktop.FileManager1"
                                                   arguments:@[@[uri], @""]];
        if (!result)
          {
            NSLog(@"AppMenuWidget: D-Bus ShowFolders call returned nil (FileManager1 not running?)");
          }
    }];
}

- (void)closeActiveWindow:(NSMenuItem *)sender
{
    (void)sender;
    unsigned long activeWindow = [self readActiveWindowFromX11];
    if (activeWindow == 0) return;
    [self sendAltF4ToWindow:activeWindow];
}

- (void)sendAltF4ToWindow:(unsigned long)windowId
{
    Display *display = [MenuUtils sharedDisplay];
    if (!display) return;

    Window window = (Window)windowId;
    Window root = DefaultRootWindow(display);

    XSetInputFocus(display, window, RevertToParent, CurrentTime);
    XFlush(display);

    XEvent keyEvent;
    memset(&keyEvent, 0, sizeof(keyEvent));
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
    keyEvent.xkey.state = Mod1Mask;
    keyEvent.xkey.keycode = XKeysymToKeycode(display, XK_F4);
    keyEvent.xkey.same_screen = True;

    XSendEvent(display, window, True, KeyPressMask, &keyEvent);
    XSendEvent(display, root, False, KeyPressMask, &keyEvent);
    keyEvent.xkey.type = KeyRelease;
    XSendEvent(display, window, True, KeyReleaseMask, &keyEvent);
    XSendEvent(display, root, False, KeyReleaseMask, &keyEvent);
    XFlush(display);
}

#pragma mark - Debug

- (void)debugLogCurrentMenuState
{
    NSLog(@"AppMenuWidget: ===== DEBUG STATE =====");
    NSLog(@"AppMenuWidget: Window: 0x%lx  App: %@", self.currentWindowId, self.currentApplicationName ?: @"(none)");
    NSLog(@"AppMenuWidget: Menu: %@  Items: %lu", self.currentMenu ? [self.currentMenu title] : @"(none)",
          self.currentMenu ? (unsigned long)[[self.currentMenu itemArray] count] : 0);
    NSLog(@"AppMenuWidget: ===== END =====");
}

#pragma mark - Shortcut re-registration

- (void)reregisterShortcutsForMenu:(NSMenu *)menu windowId:(unsigned long)windowId
{
    /* unregisterNonDirectShortcuts (called on an app switch above) clears the
     * global X11 grabs of the app's menu shortcuts; hand the menu back to the
     * protocol manager so the owning importer re-grabs them.  Without this the
     * menu shows shortcuts that do nothing (e.g. Chrome's Alt+T). */
    [[MenuProtocolManager sharedManager] reregisterShortcutsForMenu:menu
                                                           windowId:windowId];
}

@end
