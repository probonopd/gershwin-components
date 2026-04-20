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

/* Minimum interval between system menu (⌘) app-list rebuilds. */
#define SYSTEM_MENU_CACHE_TTL   30.0

/* Startup desktop menu retry budget */
#define STARTUP_RETRY_INTERVAL  0.2
#define STARTUP_RETRY_MAX       50       /* 50 × 0.2 = 10 seconds budget */

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
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setupInitialMenu];
        });
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
        /* No active window.  Preserve the current menu briefly to ride out
           transient WM states (modal close, workspace switch). */
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        if (self.currentMenu && self.currentWindowId != 0 && (now - self.lastSwitchTime) < 2.0) {
            NSDebugLLog(@"gwcomp", @"AppMenuWidget: No-window grace - preserving current menu");
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

    /* Same window, same menu already displayed? Nothing to do. */
    if (windowId == self.currentWindowId && self.currentMenu && self.menuView && ![self.menuView isHidden]) {
        if ([self.protocolManager hasMenuForWindow:windowId]) {
            NSMenu *incoming = [self.protocolManager getMenuForWindow:windowId];
            if (incoming && [self topLevelMenusMatch:self.currentMenu with:incoming]) {
                NSDebugLLog(@"gwcomp", @"AppMenuWidget: Window 0x%lx menu unchanged — skipping", windowId);
                return;
            }
        } else {
            /* Same window, still has its menu shown — nothing to do. */
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

    /* Skip no-op rebuilds: same window, same top-level structure. */
    if (self.currentWindowId == windowId && self.currentMenu && self.menuView &&
        ![self.menuView isHidden] && [self.menuView menu] == self.currentMenu &&
        [self topLevelMenusMatch:self.currentMenu with:menu]) {
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Skipping menu rebuild for 0x%lx (unchanged)", windowId);
        MENU_PROFILE_END(loadMenuForWindow);
        return;
    }

    pid_t previousPID = self.currentWindowPID;
    self.currentWindowId = windowId;
    self.currentWindowPID = [MenuUtils getWindowPID:windowId];
    self.lastDisplayedPID = self.currentWindowPID;
    self.needsRedraw = YES;

    /* Clear shortcuts only on cross-app switch. */
    BOOL switchingApp = (previousPID != 0 && self.currentWindowPID != 0 && previousPID != self.currentWindowPID);
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
    [self reregisterShortcutsForMenu:menu];
    MENU_PROFILE_END(loadMenuForWindow);
}

- (void)setupMenuViewWithMenu:(NSMenu *)menu
{
    MENU_PROFILE_BEGIN(setupMenuViewWithMenu);
    if (!menu) {
        MENU_PROFILE_END(setupMenuViewWithMenu);
        return;
    }

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

        NSMenuItem *prefsItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"System Preferences", nil)
                                                           action:@selector(openSystemPreferences:)
                                                    keyEquivalent:@""];
        [prefsItem setTarget:self];
        [sysMenu addItem:prefsItem];
        [sysMenu addItem:[NSMenuItem separatorItem]];

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

        /* Set this widget as delegate for all first-level submenus so that
           menuWillOpen: fires when the user opens any submenu (e.g. "Edit"),
           allowing refreshMenuStateForWindow: to pull fresh enabled/state
           values from the app before the user sees the items.  Without this,
           the pull path is never triggered and Copy stays greyed out after
           Select All because the push path (updateMenuForWindow:) is blocked
           by the _materializationTimeByWindow dedup guard. */
        for (NSMenuItem *__menuItem in [menu itemArray]) {
            NSMenu *__sub = [__menuItem submenu];
            if (__sub && __sub != self.systemMenu) {
                [__sub setDelegate:self];
            }
        }

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
    NSDebugLog(@"AppMenuWidget: menuWillOpen: '%@'", [menu title] ?: @"(no title)");

    /* Populate system menu on first open (delegate method may fire before
       NSMenuDidBeginTrackingNotification in some GNUstep versions). */
    if (menu == self.systemMenu) {
        NSDebugLog(@"AppMenuWidget: menuWillOpen system menu, populating");
        [self populateSystemMenu];
        return;
    }
    
    if (self.currentWindowId == 0) return;
    if (![self.protocolManager hasMenuForWindow:self.currentWindowId]) return;

    BOOL refreshed = [self.protocolManager refreshMenuStateForWindow:self.currentWindowId];
    if (refreshed) {
        NSDebugLLog(@"gwcomp", @"AppMenuWidget: Refreshed menu state for window 0x%lx before opening menu '%@'", self.currentWindowId, [menu title] ?: @"(no title)");
    }
}

- (void)menuNeedsUpdate:(NSMenu *)menu
{
    /* Populate system menu but with throttling to avoid CPU thrashing from
       GNUstep calling menuNeedsUpdate: on every run-loop cycle for every
       submenu that has a delegate. */
    if (menu != self.systemMenu) {
        return;
    }

    NSDebugLog(@"AppMenuWidget: menuNeedsUpdate called for system menu");

    /* Throttle updates to avoid repeated app tree scanning. */
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - self.lastSystemMenuUpdateTime < 0.1) {
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

    /* Find insertion point (after "System Preferences" + separator). */
    NSArray *items = [menu itemArray];
    NSInteger startIndex = 3;
    for (NSUInteger i = 0; i < [items count]; i++) {
        if ([[[items objectAtIndex:i] title] isEqualToString:NSLocalizedString(@"System Preferences", nil)]) {
            startIndex = (NSInteger)i + 2;
            break;
        }
    }
    while ([menu numberOfItems] > startIndex) {
        [menu removeItemAtIndex:startIndex];
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

    NSMenuItem *appsItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Applications", nil)
                                                      action:nil keyEquivalent:@""];
    [appsItem setSubmenu:appsSubmenu];
    [menu insertItem:appsItem atIndex:startIndex];
    NSLog(@"AppMenuWidget: Inserted Applications submenu at index %ld, menu now has %ld items", (long)startIndex, (long)[menu numberOfItems]);

    self.systemMenuPopulatedFromCache = YES;
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
        NSMutableDictionary *node = tree;
        for (NSString *component in relPath) {
            NSMutableDictionary *child = node[component];
            if (!child) {
                child = [NSMutableDictionary dictionary];
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

- (void)addMenuItemsFromTree:(NSDictionary *)tree toMenu:(NSMenu *)menu
{
    /* Collect both subdirectory submenus and app items, then interleave
       them alphabetically so the list feels natural. */
    NSMutableArray *entries = [NSMutableArray array];

    for (NSString *key in [tree allKeys]) {
        if ([key isEqualToString:@"_apps"]) continue;
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
            NSMenu *submenu = [[NSMenu alloc] initWithTitle:entry[@"_name"]];
            [self addMenuItemsFromTree:subtree toMenu:submenu];
            if ([submenu numberOfItems] > 0) {
                NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:entry[@"_name"]
                                                              action:nil keyEquivalent:@""];
                [item setSubmenu:submenu];
                [menu addItem:item];
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

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSArray *names = @[@"System Preferences", @"SystemPreferences", @"System-Preferences"];
        for (NSString *name in names) {
            if ([[NSWorkspace sharedWorkspace] launchApplication:name]) return;
        }

        NSArray *paths = @[@"/System/Applications/System Preferences.app",
                           @"/System/Applications/SystemPreferences.app",
                           @"/Applications/System Preferences.app",
                           @"/Applications/SystemPreferences.app"];
        NSFileManager *fm = [NSFileManager defaultManager];
        for (NSString *p in paths) {
            if ([fm fileExistsAtPath:p]) {
                [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:p]];
                return;
            }
        }
        NSLog(@"AppMenuWidget: Could not find System Preferences to launch");
    });
}

- (void)openApplicationBundle:(NSMenuItem *)sender
{
    NSString *path = [sender representedObject];
    if (!path) return;

    NSMenu *parentMenu = [sender menu];
    if (parentMenu && [parentMenu respondsToSelector:@selector(cancelTracking)]) {
        [parentMenu performSelector:@selector(cancelTracking)];
    }

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSWorkspace *ws = [NSWorkspace sharedWorkspace];
        NSString *bundleName = [[path lastPathComponent] stringByDeletingPathExtension];
        if (bundleName && [ws launchApplication:bundleName]) return;

        NSString *infoPath = [path stringByAppendingPathComponent:@"Contents/Info.plist"];
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPath];
        NSString *bundleID = info[@"CFBundleIdentifier"];
        if (bundleID && [ws launchApplication:bundleID]) return;

        if ([ws openURL:[NSURL fileURLWithPath:path]]) return;
        if ([ws openFile:path]) return;

        NSLog(@"AppMenuWidget: Failed to launch application at %@", path);
    });
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

- (void)reregisterShortcutsForMenu:(NSMenu *)menu
{
    (void)menu;
    NSDebugLLog(@"gwcomp", @"AppMenuWidget: Shortcut re-registration delegated to protocol managers");
}

@end
