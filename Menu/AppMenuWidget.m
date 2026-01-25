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
        NSLog(@"AppMenuWidget: X11 BadWindow error (window disappeared) - error_code=%d, request_code=%d", 
              event->error_code, event->request_code);
        
        // Track this window as invalid to prevent future access
        if (event->resourceid != 0) {
            NSNumber *windowKey = [NSNumber numberWithUnsignedLong:event->resourceid];
            [invalidWindows addObject:windowKey];
            NSLog(@"AppMenuWidget: Marked window %lu as invalid to prevent future access", event->resourceid);
        }
              
        // If we have a current widget and the error is for our tracked window, clean up immediately
        if (currentWidget && event->resourceid != 0) {
            [currentWidget handleWindowDisappeared:event->resourceid];
        }
    } else if (event->error_code == BadDrawable) {
        NSLog(@"AppMenuWidget: X11 BadDrawable error - error_code=%d, request_code=%d", 
              event->error_code, event->request_code);
        
        // Also track bad drawables as invalid
        if (event->resourceid != 0) {
            NSNumber *windowKey = [NSNumber numberWithUnsignedLong:event->resourceid];
            [invalidWindows addObject:windowKey];
        }
    } else {
        NSLog(@"AppMenuWidget: X11 error - error_code=%d, request_code=%d", 
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
        NSLog(@"AppMenuWidget: X11 error occurred during call, executing cleanup"); \
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
- (BOOL)displayDesktopMenuIfAvailableWithReason:(NSString *)reason;
- (void)clearMenuAndHideView;

@end

@implementation AppMenuWidget

// Called when the system submenu begins tracking (is about to be shown)
- (void)systemMenuDidBeginTracking:(NSNotification *)note
{
    // Populate the menu now
    NSMenu *menu = (NSMenu *)[note object];
    if (menu != self.systemMenu) return;

    NSLog(@"AppMenuWidget: systemMenuDidBeginTracking - populating apps");
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
        NSLog(@"AppMenuWidget: Skipping X11 operation on invalid window %lu", windowId);
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
        
        // Register this widget for X11 error handling
        [AppMenuWidget setCurrentWidget:self];
        
        NSLog(@"AppMenuWidget: Initialized with frame %.0f,%.0f %.0fx%.0f", 
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
    
    NSLog(@"AppMenuWidget: Setting up placeholder menu with initial item (deferred)");
    NSMenu *placeholderMenu = [[NSMenu alloc] initWithTitle:@""];
    NSMenuItem *helloItem = [[NSMenuItem alloc] initWithTitle:@" " action:nil keyEquivalent:@""];
    [helloItem setEnabled:NO];
    [placeholderMenu addItem:helloItem];
    
    @try {
        [self setupMenuViewWithMenu:placeholderMenu];
        NSLog(@"AppMenuWidget: Successfully set up initial menu view with placeholder");
    }
    @catch (NSException *exception) {
        NSLog(@"AppMenuWidget: Exception during placeholder menu setup: %@", exception);
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
        NSLog(@"AppMenuWidget: No protocol manager available");
        return;
    }

    // Defensive validation: if our current tracked window is gone, clear the menu immediately
    if (self.currentWindowId != 0 && ![AppMenuWidget isWindowStillValid:self.currentWindowId]) {
        NSLog(@"AppMenuWidget: Current tracked window %lu is no longer valid - clearing menu and re-evaluating active window", self.currentWindowId);
        [self clearMenuAndHideView];
        self.currentWindowId = 0;
        self.currentApplicationName = nil;
        self.currentMenu = nil;
    }

    // Get the active window using X11
    Display *display = XOpenDisplay(NULL);
    if (!display) {
        NSLog(@"AppMenuWidget: Cannot open X11 display");
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
        NSLog(@"AppMenuWidget: Failed to get active window due to X11 error");
    });
    
    XCloseDisplay(display);

    [self updateForActiveWindowId:activeWindow];
}

- (void)updateForActiveWindowId:(unsigned long)windowId
{
    if (!self.protocolManager) {
        NSLog(@"AppMenuWidget: No protocol manager available (updateForActiveWindowId)");
        return;
    }

    NSLog(@"AppMenuWidget: updateForActiveWindowId called with 0x%lx", windowId);

    unsigned long activeWindow = windowId;

    // Validate active window; if invalid, treat as no focused window
    if (activeWindow != 0 && ![AppMenuWidget isWindowStillValid:activeWindow]) {
        NSLog(@"AppMenuWidget: Active window %lu is invalid - treating as no focused window", activeWindow);
        activeWindow = 0;
    }

    // Exclude the Menu application itself from triggering updates.
    // If we focus on the menu bar or its components, we want to keep the current app menu.
    if (activeWindow != 0 && [NSApp windowWithWindowNumber:activeWindow] != nil) {
        NSLog(@"AppMenuWidget: Focus is on Menu app itself (0x%lx) - ignoring update to preserve current menu", activeWindow);
        return;
    }

    // Similarly, ignore and preserve if the process that launched the old and new menu have the same PID.
    // This avoids flickering or clearing menus when switching between windows of the same application.
    if (activeWindow != 0 && self.currentWindowId != 0 && activeWindow != self.currentWindowId) {
        pid_t oldPid = [MenuUtils getWindowPID:self.currentWindowId];
        pid_t newPid = [MenuUtils getWindowPID:activeWindow];
        if (oldPid != 0 && oldPid == newPid) {
            NSLog(@"AppMenuWidget: Focus changed within same PID %d (0x%lx -> 0x%lx) - preserving current menu", (int)newPid, self.currentWindowId, activeWindow);
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
            NSLog(@"AppMenuWidget: Active window is 0 but within 0.2s grace period (%.3fs) - preserving menu for PID %d", 
                  timeSinceLastSwitch, (int)self.lastWindowPID);
            return;
        }
        
        // If we have a menu and this is the first time seeing window==0, preserve it briefly
        // This handles cases where lastWindowSwitchTime is very old or zero
        if (self.currentMenu != nil && self.currentWindowId != 0) {
            NSLog(@"AppMenuWidget: Active window is 0, have current menu from window %lu - preserving briefly", self.currentWindowId);
            // Update timestamp so subsequent calls within 0.2s will use the grace period above
            self.lastWindowSwitchTime = currentTime;
            return;
        }
        
        // Otherwise, clear the menu (past grace period and no current menu to preserve)
        NSLog(@"AppMenuWidget: Active window is 0 and past grace period (%.3fs) - clearing menu", timeSinceLastSwitch);
        [self clearMenuAndHideView];
        self.lastWindowPID = 0;
        self.lastWindowSwitchTime = currentTime;
        return;
    }

    BOOL shouldUpdate = (activeWindow != self.currentWindowId);
    if (!shouldUpdate && activeWindow != 0) {
        // Force a refresh if menu is missing or we don't have a current menu
        if (!self.currentMenu || ![self.protocolManager hasMenuForWindow:activeWindow]) {
            NSLog(@"AppMenuWidget: Active window unchanged (%lu) but menu missing - forcing refresh", activeWindow);
            shouldUpdate = YES;
        }
    }

    if (shouldUpdate) {
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
            NSLog(@"AppMenuWidget: Detected new active window: %lu (App: %@)", activeWindow, newAppName ?: @"Unknown");
            lastDetectedWindowId = activeWindow;
        }

        BOOL isDifferentApp = !self.currentApplicationName ||
                             ![self.currentApplicationName isEqualToString:newAppName];

        self.currentWindowId = activeWindow;
        
        // Track PID and timestamp for the new anti-flicker mechanism
        pid_t newPid = [MenuUtils getWindowPID:activeWindow];
        self.lastWindowPID = newPid;
        self.lastWindowSwitchTime = [NSDate timeIntervalSinceReferenceDate];

        // Use @try/@catch to prevent crashes during menu setup for invalid/transitioning windows
        @try {
            [self displayMenuForWindow:activeWindow isDifferentApp:isDifferentApp];
        }
        @catch (NSException *exception) {
            NSLog(@"AppMenuWidget: Exception displaying menu for window %lu: %@", activeWindow, exception);
            // Clear menu on exception to prevent further issues
            [self clearMenuAndHideView];
        }
    } else if (activeWindow == 0) {
        // No active window and no Desktop menu - ensure view is hidden
        [self clearMenuAndHideView];
    }
}

- (void)noMenuGracePeriodExpired:(NSTimer *)timer
{
    NSNumber *windowIdNum = [timer userInfo];
    unsigned long windowId = [windowIdNum unsignedLongValue];
    
    self.noMenuGracePeriodTimer = nil;
    self.pendingClearWindowId = 0;
    
    NSLog(@"AppMenuWidget: Grace period expired for window %lu - checking if menu now available", windowId);
    
    // CRITICAL: Only clear menu if we're still on the same window
    // If we've switched to a different window, this timer is stale
    if (self.currentWindowId != windowId) {
        NSLog(@"AppMenuWidget: Window changed from %lu to %lu - ignoring stale grace period timer", windowId, self.currentWindowId);
        return;
    }
    
    // Check if this window now has a menu registered
    if ([self.protocolManager hasMenuForWindow:windowId]) {
        NSLog(@"AppMenuWidget: Window %lu now has menu - loading it", windowId);
        // Trigger a refresh to load the newly available menu
        [self updateForActiveWindowId:windowId];
        return;
    }
    
    // Still no menu after grace period AND still on same window - clear the old menu
    NSLog(@"AppMenuWidget: Window %lu still has no menu after grace period - clearing", windowId);
    if ([self displayDesktopMenuIfAvailableWithReason:@"grace period expired, no menu"]) {
        return;
    }
    [self clearMenuAndHideView];
}

- (unsigned long)findDesktopWindowId
{
    return [MenuUtils findDesktopWindow];
}

- (BOOL)displayDesktopMenuIfAvailableWithReason:(NSString *)reason
{
    if (!self.protocolManager) {
        NSLog(@"AppMenuWidget: Cannot display Desktop menu (%@) - no protocol manager", reason);
        return NO;
    }

    unsigned long desktopWindowId = [self findDesktopWindowId];
    if (desktopWindowId == 0) {
        NSLog(@"AppMenuWidget: Desktop menu not available (%@) - no Desktop window", reason);
        return NO;
    }

    if (![self.protocolManager hasMenuForWindow:desktopWindowId]) {
        NSLog(@"AppMenuWidget: Desktop window 0x%lx has no registered menu (%@)", desktopWindowId, reason);
        return NO;
    }

    NSString *desktopAppName = nil;
    @try {
        desktopAppName = [MenuUtils getApplicationNameForWindow:desktopWindowId];
    }
    @catch (NSException *exception) {
        NSLog(@"AppMenuWidget: Exception getting Desktop app name for window 0x%lx: %@", desktopWindowId, exception);
        desktopAppName = nil;
    }

    BOOL isDifferentApp = !self.currentApplicationName || !desktopAppName || ![self.currentApplicationName isEqualToString:desktopAppName];
    NSLog(@"AppMenuWidget: Switching to Desktop menu 0x%lx (%@)", desktopWindowId, reason);
    self.currentWindowId = desktopWindowId;
    [self displayMenuForWindow:desktopWindowId isDifferentApp:isDifferentApp];
    return YES;
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
    self.currentMenu = nil;
    self.currentWindowId = 0; // Ensure we stop showing menus for this window
    self.needsRedraw = YES;
    if (self.menuView) {
        [self.menuView setHidden:YES];
    }
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
    NSLog(@"AppMenuWidget: Clearing menu state");
    
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
    // Defensive check: ensure we're initialized
    if (!self.protocolManager) {
        NSLog(@"AppMenuWidget: Protocol manager not initialized, cannot display menu for window %lu", windowId);
        return;
    }
    
    // ANTI-FLICKER: Don't clear the old menu yet - keep it visible while loading the new one
    // We'll clear it after successfully loading the new menu
    
    // If no window specified, always try Desktop fallback first; if not available, clear immediately
    if (windowId == 0) {
        NSLog(@"AppMenuWidget: displayMenuForWindow called with 0 - attempting Desktop fallback");
        if ([self displayDesktopMenuIfAvailableWithReason:@"no focused window"]) {
            return; // Desktop menu displayed
        }
        [self clearMenuAndHideView];
        return;
    }

    // Defensive check: ensure the window still exists (it may have been closed since the event)
    BOOL windowValid = [AppMenuWidget isWindowStillValid:windowId];
    if (!windowValid) {
        NSLog(@"AppMenuWidget: Window %lu validity check failed - may be closing or not yet mapped", windowId);
        // Try Desktop fallback immediately; if not available clear the menu instantly
        if ([self displayDesktopMenuIfAvailableWithReason:@"window invalid/closing"]) {
            return;
        }

        // If a menu is registered for this window despite validation failure, attempt to load it
        if ([self.protocolManager hasMenuForWindow:windowId]) {
            NSLog(@"AppMenuWidget: Menu is registered for window %lu - attempting to load despite validation failure", windowId);
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
        NSLog(@"AppMenuWidget: Exception getting app name for window %lu in displayMenuForWindow: %@", windowId, exception);
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
            NSLog(@"AppMenuWidget: Application %@ has no visible windows - not displaying its menu", appName);
            if (![MenuUtils isDesktopWindow:windowId] &&
                [self displayDesktopMenuIfAvailableWithReason:@"application has no visible windows"]) {
                return;
            }
            [self clearMenuAndHideView];
            return;
        }

        self.currentApplicationName = appName;
        NSLog(@"AppMenuWidget: Window %lu belongs to application: %@", windowId, appName);
    }
    
    NSLog(@"AppMenuWidget: Displaying menu for window %lu", windowId);
    
    // Check if this window has a DBus menu registered
    @try {
        if (![self.protocolManager hasMenuForWindow:windowId]) {
            static unsigned long lastMissingMenuWindowId = 0;
            if (lastMissingMenuWindowId != windowId) {
                NSLog(@"AppMenuWidget: No registered menu for window %lu yet", windowId);
                lastMissingMenuWindowId = windowId;
            }

            // DON'T trigger immediate scan here - it can interfere with app startup
            // The periodic scanning will pick it up safely

            // If it's the Desktop window and it has no menu, clear immediately
            if ([MenuUtils isDesktopWindow:windowId]) {
                NSLog(@"AppMenuWidget: Desktop window %lu has no menu registered yet", windowId);
                if ([self displayDesktopMenuIfAvailableWithReason:@"desktop has no menu"]) {
                    return;
                }
                [self clearMenuAndHideView];
                return;
            }

            // Try Desktop fallback for active window with no registered menu
            if ([self displayDesktopMenuIfAvailableWithReason:@"active window has no menu"]) {
                return;
            }

            // ANTI-FLICKER: Don't clear immediately - app might be registering its menu
            // Keep old menu visible for 0.2s grace period, then clear if still no menu
            if (self.currentMenu != nil) {
                NSLog(@"AppMenuWidget: Window %lu has no menu yet - keeping old menu visible for 0.2s grace period", windowId);
                
                // Cancel any existing grace period timer
                if (self.noMenuGracePeriodTimer) {
                    [self.noMenuGracePeriodTimer invalidate];
                    self.noMenuGracePeriodTimer = nil;
                }
                
                // Schedule timer to clear menu after grace period
                self.pendingClearWindowId = windowId;
                self.noMenuGracePeriodTimer = [NSTimer scheduledTimerWithTimeInterval:0.2
                                                                                target:self
                                                                              selector:@selector(noMenuGracePeriodExpired:)
                                                                              userInfo:[NSNumber numberWithUnsignedLong:windowId]
                                                                               repeats:NO];
                return;
            }
            
            // No current menu to preserve - clear immediately
            [self clearMenuAndHideView];
            return;
        } else {
            // If we already have a menu, ensure we don't have any scheduled fallback (no-op in current flow)
            [self cancelScheduledFallbackForWindow:windowId];
            
            // Cancel grace period timer if this is the window we were waiting for
            if (self.noMenuGracePeriodTimer && self.pendingClearWindowId == windowId) {
                NSLog(@"AppMenuWidget: Window %lu now has a menu - canceling grace period timer", windowId);
                [self.noMenuGracePeriodTimer invalidate];
                self.noMenuGracePeriodTimer = nil;
                self.pendingClearWindowId = 0;
            }
        }
    }
    @catch (NSException *exception) {
        NSLog(@"AppMenuWidget: Exception during menu protocol check for window %lu: %@", windowId, exception);
        // Prevent fallback menu for desktop windows
        if ([MenuUtils isDesktopWindow:windowId]) {
            NSLog(@"AppMenuWidget: Suppressing fallback menu for desktop window %lu on exception", windowId);
            [self clearMenuAndHideView];
            return;
        }

        if ([self displayDesktopMenuIfAvailableWithReason:@"exception during menu protocol check"]) {
            return;
        }
#if ENABLE_FALLBACK_MENUS
        // Create fallback File->Close menu on exception
        NSMenu *fallbackMenu = [self createFileMenuWithClose:windowId];
        [self loadMenu:fallbackMenu forWindow:windowId];
#else
        NSLog(@"AppMenuWidget: Exception occurred but fallback menus disabled at compile time");
        [self clearMenuAndHideView];
#endif
        return;
    }
    
    NSLog(@"AppMenuWidget: ===== LOADING MENU FROM PROTOCOL MANAGER =====");
    NSLog(@"AppMenuWidget: This is where AboutToShow events should be triggered for submenus");

    // Get the menu from protocol manager for registered windows
    NSMenu *menu = nil;
    @try {
        menu = [self.protocolManager getMenuForWindow:windowId];
    }
    @catch (NSException *exception) {
        NSLog(@"AppMenuWidget: Exception getting menu from protocol manager for window %lu: %@", windowId, exception);
        menu = nil;
    }

    if (!menu) {
        NSLog(@"AppMenuWidget: Failed to get menu for window %lu (protocol manager)", windowId);
        // Prevent fallback menu for desktop windows
        if ([MenuUtils isDesktopWindow:windowId]) {
            NSLog(@"AppMenuWidget: Desktop window %lu has no menu from protocol manager", windowId);
            if ([self displayDesktopMenuIfAvailableWithReason:@"desktop protocol returned nil"]) {
                return;
            }
            [self clearMenuAndHideView];
            return;
        }

        // Try desktop fallback first
        if ([self displayDesktopMenuIfAvailableWithReason:@"protocol manager returned nil menu"]) {
            return;
        }

        // Otherwise clear and hide - no built-in fallbacks
        [self clearMenuAndHideView];
        return;
    }
    
    // Debug: Log menu details for placeholder detection
    NSLog(@"AppMenuWidget: Menu has %lu items", (unsigned long)[[menu itemArray] count]);
    if ([[menu itemArray] count] > 0) {
        NSMenuItem *firstItem = [[menu itemArray] objectAtIndex:0];
        NSLog(@"AppMenuWidget: First menu item: '%@' (enabled: %@)", [firstItem title], [firstItem isEnabled] ? @"YES" : @"NO");
    }
    
    BOOL isPlaceholder = [self isPlaceholderMenu:menu];
    NSLog(@"AppMenuWidget: isPlaceholderMenu: %@", isPlaceholder ? @"YES" : @"NO");
    
    // If this is a placeholder menu, prefer Desktop fallback; otherwise clear immediately
    if (isPlaceholder) {
        // Prevent fallback menu for desktop windows
        if ([MenuUtils isDesktopWindow:windowId]) {
            NSLog(@"AppMenuWidget: Desktop window %lu provided placeholder menu", windowId);
            [self clearMenuAndHideView];
            return;
        }

        if ([self displayDesktopMenuIfAvailableWithReason:@"placeholder menu for active window"]) {
            return;
        }

        NSLog(@"AppMenuWidget: Placeholder menu detected and no Desktop fallback available - clearing");
        [self clearMenuAndHideView];
        return;
    }
    
    [self loadMenu:menu forWindow:windowId];
    NSLog(@"AppMenuWidget: Imported %lu menu items for window %lu", (unsigned long)[[menu itemArray] count], windowId);
}

- (void)setupMenuViewWithMenu:(NSMenu *)menu
{
    if (!menu) {
        NSLog(@"AppMenuWidget: Cannot setup menu view with nil menu");
        return;
    }

    NSLog(@"AppMenuWidget: Setting up menu view with menu: %@", [menu title]);
    
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
            NSLog(@"AppMenuWidget: Removed existing menu view before creating new one");
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
            NSLog(@"AppMenuWidget: Removed %lu duplicate Command menu item(s)", (unsigned long)[commandItemIndexes count]);
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

        // Add "Window" submenu with tiling options
        NSMenuItem *windowItem = [[NSMenuItem alloc] initWithTitle:@"Window" action:nil keyEquivalent:@""];
        NSMenu *windowMenu = [[NSMenu alloc] initWithTitle:@"Window"];

        // Center window
        NSMenuItem *centerItem = [[NSMenuItem alloc] initWithTitle:@"Center" action:@selector(centerWindow:) keyEquivalent:@""];
        [centerItem setTarget:self];
        [windowMenu addItem:centerItem];

        // Maximize vertical/horizontal
        NSMenuItem *maxVertItem = [[NSMenuItem alloc] initWithTitle:@"Maximize Vertical" action:@selector(maximizeWindowVertically:) keyEquivalent:@""];
        [maxVertItem setTarget:self];
        [windowMenu addItem:maxVertItem];

        NSMenuItem *maxHorizItem = [[NSMenuItem alloc] initWithTitle:@"Maximize Horizontal" action:@selector(maximizeWindowHorizontally:) keyEquivalent:@""];
        [maxHorizItem setTarget:self];
        [windowMenu addItem:maxHorizItem];

        [windowMenu addItem:[NSMenuItem separatorItem]];

        // Half-screen tiling
        NSMenuItem *tileLeftItem = [[NSMenuItem alloc] initWithTitle:@"Tile Left" action:@selector(tileWindowLeft:) keyEquivalent:@""];
        [tileLeftItem setTarget:self];
        [windowMenu addItem:tileLeftItem];

        NSMenuItem *tileRightItem = [[NSMenuItem alloc] initWithTitle:@"Tile Right" action:@selector(tileWindowRight:) keyEquivalent:@""];
        [tileRightItem setTarget:self];
        [windowMenu addItem:tileRightItem];

        [windowMenu addItem:[NSMenuItem separatorItem]];

        // Quarter-screen tiling
        NSMenuItem *tileTopLeftItem = [[NSMenuItem alloc] initWithTitle:@"Tile Top Left" action:@selector(tileWindowTopLeft:) keyEquivalent:@""];
        [tileTopLeftItem setTarget:self];
        [windowMenu addItem:tileTopLeftItem];

        NSMenuItem *tileTopRightItem = [[NSMenuItem alloc] initWithTitle:@"Tile Top Right" action:@selector(tileWindowTopRight:) keyEquivalent:@""];
        [tileTopRightItem setTarget:self];
        [windowMenu addItem:tileTopRightItem];

        NSMenuItem *tileBottomLeftItem = [[NSMenuItem alloc] initWithTitle:@"Tile Bottom Left" action:@selector(tileWindowBottomLeft:) keyEquivalent:@""];
        [tileBottomLeftItem setTarget:self];
        [windowMenu addItem:tileBottomLeftItem];

        NSMenuItem *tileBottomRightItem = [[NSMenuItem alloc] initWithTitle:@"Tile Bottom Right" action:@selector(tileWindowBottomRight:) keyEquivalent:@""];
        [tileBottomRightItem setTarget:self];
        [windowMenu addItem:tileBottomRightItem];

        [windowItem setSubmenu:windowMenu];
        [systemMenu addItem:windowItem];
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
        NSLog(@"AppMenuWidget: System submenu initially has %lu items: %@", (unsigned long)[sysItems count], titles);

        
        [systemItem setSubmenu:systemMenu];

        // Insert at the beginning of the menu
        [menu insertItem:systemItem atIndex:0];

        // Create a new horizontal menu view that fits within our widget frame, starting after the text
        NSRect menuViewFrame = NSMakeRect(textWidth, 0, [self bounds].size.width - textWidth, [self bounds].size.height);
        self.menuView = [[AppMenuView alloc] initWithFrame:menuViewFrame];

        if (!self.menuView) {
            NSLog(@"AppMenuWidget: Failed to create menu view - aborting setup");
            return;
        }

        // Configure the menu view for horizontal display (like a menu bar)
        [self.menuView setHorizontal:YES];
        [self.menuView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

        // Set the menu for the menu view
        [self.menuView setMenu:menu];
        
        // Set ourselves as the delegate of the main menu to catch AboutToShow events
        [menu setDelegate:self];
        NSLog(@"AppMenuWidget: Set AppMenuWidget as delegate for main menu: %@", [menu title]);
        
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
                        NSLog(@"AppMenuWidget: Detected GNUStep menu via representedObject - preserving original target/action");
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
            NSLog(@"AppMenuWidget: Setting up item %lu: '%@' (submenu: %@, target: %@, action: %@)", 
                  i, [item title], [item hasSubmenu] ? @"YES" : @"NO",
                  [item target], NSStringFromSelector([item action]));
            
            // Skip items that already have a target (they have proper action handlers)
            // Skip items with submenus (NSMenuView handles their display)
            // Only set placeholder actions for items without handlers
            if (!isGNUStepMenu && ![item hasSubmenu]) {
                if (![item target]) {
                    // This item doesn't have an action - set our placeholder
                    NSLog(@"AppMenuWidget: Item '%@' has NO target - setting placeholder action", [item title]);
                    [item setTarget:self];
                    [item setAction:@selector(menuItemClicked:)];
                    NSLog(@"AppMenuWidget: Set placeholder action for item without handler: '%@'", [item title]);
                } else {
                    // Item already has a target - preserve it
                    NSLog(@"AppMenuWidget: Item '%@' already has target '%@' with action '%@' - PRESERVING", 
                          [item title], [item target], NSStringFromSelector([item action]));
                }
            }
        }
        
        // Add the menu view to our widget (this makes it visible)
        [self addSubview:self.menuView];
        
        [self setNeedsDisplay:YES];
        
        NSLog(@"AppMenuWidget: Menu view setup complete with %lu menu items", 
              (unsigned long)[[menu itemArray] count]);
    }
    @finally {
        // Re-enable window drawing and flush all pending updates
        if (window) {
            [window enableFlushWindow];
            [window flushWindow];
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
    Display *display = XOpenDisplay(NULL);
    if (!display) {
        NSLog(@"AppMenuWidget: Cannot open X11 display for checking active window");
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
        NSLog(@"AppMenuWidget: Failed to get active window for newly registered window check due to X11 error");
    });
    
    XCloseDisplay(display);
    
    // If the newly registered window is the currently active window, display its menu immediately
    if (activeWindow == windowId) {
        NSLog(@"AppMenuWidget: Newly registered window %lu is currently active, updating menu immediately", windowId);
        @try {
            [self updateForActiveWindowId:activeWindow];
        }
        @catch (NSException *exception) {
            NSLog(@"AppMenuWidget: Exception updating menu for newly registered window %lu: %@", windowId, exception);
        }
    } else {
        NSLog(@"AppMenuWidget: Newly registered window %lu is not currently active (active: %lu)", windowId, activeWindow);
    }
}

// Debug method implementation

// MARK: - NSMenuDelegate Methods for Main Menu

- (void)menuWillOpen:(NSMenu *)menu
{
    // Keep legacy logging for the main menu
    NSLog(@"AppMenuWidget: ===== MAIN MENU WILL OPEN =====");
    NSLog(@"AppMenuWidget: menuWillOpen called for main menu: '%@'", [menu title] ?: @"(no title)");
    NSLog(@"AppMenuWidget: Main menu object: %@", menu);
    NSLog(@"AppMenuWidget: Main menu has %lu items", (unsigned long)[[menu itemArray] count]);
    NSLog(@"AppMenuWidget: Current window ID: %lu", self.currentWindowId);
    NSLog(@"AppMenuWidget: Current application: %@", self.currentApplicationName ?: @"(none)");
    // Log coordinates of the submenu itself
    if (self.menuView) {
        NSRect menuViewFrame = [self.menuView frame];
        NSRect menuViewFrameInWindow = [self.menuView convertRect:menuViewFrame toView:nil];
        NSPoint menuViewOriginScreen = [self.window convertBaseToScreen:menuViewFrameInWindow.origin];
        NSLog(@"AppMenuWidget: Submenu view frame: %@, screen origin: %@", NSStringFromRect(menuViewFrame), NSStringFromPoint(menuViewOriginScreen));
    }
    NSLog(@"AppMenuWidget: ===== MAIN MENU WILL OPEN COMPLETE =====");
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
    NSLog(@"AppMenuWidget: System submenu needs update - populating System Applications list");

    @try {


    NSArray *items = [menu itemArray];
    NSInteger windowIndex = NSNotFound;
    for (NSUInteger i = 0; i < [items count]; i++) {
        NSMenuItem *it = [items objectAtIndex:i];
        if ([[it title] isEqualToString:@"Window"]) {
            windowIndex = (NSInteger)i;
            break;
        }
    }

    // App list starts after Window menu + separator (windowIndex + 2)
    NSInteger startIndex = (windowIndex != NSNotFound) ? (windowIndex + 2) : 5; // where app list should begin

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

    NSLog(@"AppMenuWidget: Found %lu application bundles after dedupe", (unsigned long)[appsByKey count]);

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
    NSLog(@"AppMenuWidget: Main menu did close: '%@'", [menu title] ?: @"(no title)");
}

- (void)menu:(NSMenu *)menu willHighlightItem:(NSMenuItem *)item
{
    if (item) {
        NSLog(@"AppMenuWidget: ===== MAIN MENU ITEM HIGHLIGHT =====");
        NSLog(@"AppMenuWidget: Main menu will highlight item: '%@' (has submenu: %@)", 
              [item title], [item hasSubmenu] ? @"YES" : @"NO");
        
        if ([item hasSubmenu]) {
            NSMenu *submenu = [item submenu];
            id<NSMenuDelegate> submenuDelegate = [submenu delegate];
            NSLog(@"AppMenuWidget: Item has submenu with %lu items", 
                  (unsigned long)[[submenu itemArray] count]);
            NSLog(@"AppMenuWidget: Submenu delegate: %@ (%@)", 
                  submenuDelegate, submenuDelegate ? NSStringFromClass([submenuDelegate class]) : @"nil");
            NSLog(@"AppMenuWidget: THIS IS WHERE ABOUTTOSHOW SHOULD BE TRIGGERED!");
            NSLog(@"AppMenuWidget: If you don't see AboutToShow logging after this, the delegate isn't working");
        }
        NSLog(@"AppMenuWidget: ===== END MAIN MENU ITEM HIGHLIGHT =====");
    } else {
        NSLog(@"AppMenuWidget: Main menu will unhighlight current item");
    }
}

- (BOOL)menu:(NSMenu *)menu updateItem:(NSMenuItem *)item atIndex:(NSInteger)index shouldCancel:(BOOL)shouldCancel
{
    NSLog(@"AppMenuWidget: Main menu update item at index %ld: '%@' (shouldCancel: %@)", 
          (long)index, [item title], shouldCancel ? @"YES" : @"NO");

    // Don't re-trigger menu population from inside updateItem — this causes tight loops.
    // The menu system will call menuNeedsUpdate: at appropriate times; we also protect with
    // `isUpdatingSystemMenu` inside menuNeedsUpdate to avoid re-entrancy.

    return YES; // Allow the update
}

- (NSInteger)numberOfItemsInMenu:(NSMenu *)menu
{
    NSInteger count = [[menu itemArray] count];
    NSLog(@"AppMenuWidget: Main menu numberOfItemsInMenu called, returning: %ld", (long)count);
    return count;
}

- (NSRect)confinementRectForMenu:(NSMenu *)menu onScreen:(NSScreen *)screen
{
    // Return the full screen bounds - no confinement
    NSRect screenFrame = [screen frame];
    NSLog(@"AppMenuWidget: confinementRectForMenu called, returning full screen bounds");
    return screenFrame;
}

// MARK: - Mouse Event Tracking

- (void)mouseEntered:(NSEvent *)theEvent
{
    NSLog(@"AppMenuWidget: ===== MOUSE ENTERED MENU AREA =====");
    NSLog(@"AppMenuWidget: Mouse entered at location: %@", NSStringFromPoint([theEvent locationInWindow]));
    [super mouseEntered:theEvent];
}

- (void)mouseExited:(NSEvent *)theEvent
{
    NSLog(@"AppMenuWidget: ===== MOUSE EXITED MENU AREA =====");
    NSLog(@"AppMenuWidget: Mouse exited at location: %@", NSStringFromPoint([theEvent locationInWindow]));
    [super mouseExited:theEvent];
}

- (void)mouseMoved:(NSEvent *)theEvent
{
    NSPoint location = [theEvent locationInWindow];
    NSPoint localPoint = [self convertPoint:location fromView:nil];
    NSLog(@"AppMenuWidget: Mouse moved to: %@ (local: %@)", NSStringFromPoint(location), NSStringFromPoint(localPoint));
    
    // Check if we're over a specific menu item
    if (self.menuView) {
        NSPoint menuViewPoint = [self.menuView convertPoint:location fromView:nil];
        NSLog(@"AppMenuWidget: Menu view point: %@", NSStringFromPoint(menuViewPoint));
        
        // Try to determine which menu item we're over
        if ([self.menuView respondsToSelector:@selector(itemAtPoint:)]) {
            NSMenuItem *item = [(id)self.menuView performSelector:@selector(itemAtPoint:) withObject:[NSValue valueWithPoint:menuViewPoint]];
            if (item) {
                NSLog(@"AppMenuWidget: Mouse over menu item: '%@'", [item title]);
            }
        }
    }
    
    [super mouseMoved:theEvent];
}

- (void)mouseDown:(NSEvent *)theEvent
{
    NSLog(@"AppMenuWidget: ===== MOUSE DOWN IN MENU =====");
    NSPoint location = [theEvent locationInWindow];
    NSPoint localPoint = [self convertPoint:location fromView:nil];
    NSLog(@"AppMenuWidget: Mouse down at: %@ (local: %@)", NSStringFromPoint(location), NSStringFromPoint(localPoint));
    
    if (self.menuView && self.currentMenu) {
        NSPoint menuViewPoint = [self.menuView convertPoint:location fromView:nil];
        NSLog(@"AppMenuWidget: Menu view click point: %@", NSStringFromPoint(menuViewPoint));
        
        // Check if we clicked on a menu item
        NSArray *items = [self.currentMenu itemArray];
        for (NSUInteger i = 0; i < [items count]; i++) {
            NSMenuItem *item = [items objectAtIndex:i];
            // Try to get the menu item's frame (this is a bit of a hack)
            NSRect itemFrame = NSMakeRect(i * 80, 0, 80, [self bounds].size.height); // Approximate
            if (NSPointInRect(localPoint, itemFrame)) {
                NSLog(@"AppMenuWidget: Clicked on menu item %lu: '%@'", i, [item title]);
                
                if ([item hasSubmenu]) {
                    NSLog(@"AppMenuWidget: Item has submenu - this should trigger AboutToShow!");
                    NSMenu *submenu = [item submenu];
                    id<NSMenuDelegate> delegate = [submenu delegate];
                    NSLog(@"AppMenuWidget: Submenu delegate: %@", delegate);
                    // Log coordinates of the menu item that opens the submenu
                    NSRect itemFrameInView = [self convertRect:itemFrame toView:nil];
                    NSPoint itemOriginScreen = [self.window convertBaseToScreen:itemFrameInView.origin];
                    NSLog(@"AppMenuWidget: Menu item frame: %@, screen origin: %@", NSStringFromRect(itemFrame), NSStringFromPoint(itemOriginScreen));
                    // Manually trigger menuWillOpen to test AboutToShow
                    if (delegate && [delegate respondsToSelector:@selector(menuWillOpen:)]) {
                        NSLog(@"AppMenuWidget: MANUALLY TRIGGERING menuWillOpen for testing...");
                        [delegate menuWillOpen:submenu];
                    }
                }
                break;
            }
        }
        
        // Let the menu view handle the click
        [self.menuView mouseDown:theEvent];
        NSLog(@"AppMenuWidget: Forwarded mouse down to menu view");
    }
    
    [super mouseDown:theEvent];
}

- (void)mouseUp:(NSEvent *)theEvent
{
    NSLog(@"AppMenuWidget: ===== MOUSE UP IN MENU =====");
    NSLog(@"AppMenuWidget: Mouse up at: %@", NSStringFromPoint([theEvent locationInWindow]));
    
    if (self.menuView) {
        [self.menuView mouseUp:theEvent];
        NSLog(@"AppMenuWidget: Forwarded mouse up to menu view");
    }
    
}

// MARK: - Debug Methods

- (void)menuItemClicked:(NSMenuItem *)sender
{
    NSLog(@"AppMenuWidget: ===== MENU ITEM CLICKED =====");
    NSLog(@"AppMenuWidget: Clicked menu item: '%@'", [sender title]);
    NSLog(@"AppMenuWidget: Item tag: %ld", (long)[sender tag]);
    NSLog(@"AppMenuWidget: Item has submenu: %@", [sender hasSubmenu] ? @"YES" : @"NO");
    
    // If this item has representedObject data (from protocol handler), try to trigger the action
    if ([sender representedObject]) {
        NSLog(@"AppMenuWidget: Item has representedObject: %@", [sender representedObject]);
        
        // If the item's original target is set, call its action
        if ([sender target]) {
            SEL action = [sender action];
            if (action && [sender.target respondsToSelector:action]) {
                NSLog(@"AppMenuWidget: Forwarding action %@ to target: %@", NSStringFromSelector(action), [sender target]);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                [sender.target performSelector:action withObject:sender];
#pragma clang diagnostic pop
                return;
            }
        }
    }
    
    NSLog(@"AppMenuWidget: No action handler found for menu item: '%@'", [sender title]);
    NSLog(@"AppMenuWidget: ===== END MENU ITEM CLICKED =====");
}

- (void)debugLogCurrentMenuState
{
    NSLog(@"AppMenuWidget: ===== DEBUG MENU STATE =====");
    NSLog(@"AppMenuWidget: Current window ID: %lu", self.currentWindowId);
    NSLog(@"AppMenuWidget: Current application: %@", self.currentApplicationName ?: @"(none)");
    NSLog(@"AppMenuWidget: Current menu: %@", self.currentMenu ? [self.currentMenu title] : @"(none)");
    
    if (self.currentMenu) {
        NSLog(@"AppMenuWidget: Current menu has %lu items", (unsigned long)[[self.currentMenu itemArray] count]);
        NSArray *items = [self.currentMenu itemArray];
        for (NSUInteger i = 0; i < [items count]; i++) {
            NSMenuItem *item = [items objectAtIndex:i];
            NSLog(@"AppMenuWidget: Item %lu: '%@' (submenu: %@)", 
                  i, [item title], [item hasSubmenu] ? @"YES" : @"NO");
        }
    }
    
    NSLog(@"AppMenuWidget: Menu view: %@", self.menuView);
    NSLog(@"AppMenuWidget: Protocol manager: %@", self.protocolManager);
    NSLog(@"AppMenuWidget: ===== END DEBUG MENU STATE =====");
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
        NSLog(@"AppMenuWidget: Suppressing fallback menu for desktop window %lu (delayed)", windowId);
        return;
    }

    NSLog(@"AppMenuWidget: No menu received for window %lu after delay, providing fallback menu", windowId);
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
        NSLog(@"AppMenuWidget: closeWindow called but no window ID in representedObject");
        return;
    }
    
    unsigned long windowId = [windowIdNumber unsignedLongValue];
    NSLog(@"AppMenuWidget: Closing window %lu", windowId);
    
    // Send Alt+F4 to close the window
    [self sendAltF4ToWindow:windowId];
#else
    (void)sender;  // Suppress unused parameter warning
#endif
}

- (void)sendAltF4ToWindow:(unsigned long)windowId
{
    Display *display = XOpenDisplay(NULL);
    if (!display) {
        NSLog(@"AppMenuWidget: Failed to open X11 display for window close");
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
    
    NSLog(@"AppMenuWidget: Sent Alt+F4 key event to window %lu", windowId);
    
    XFlush(display);
    XCloseDisplay(display);
}

// preWarmCacheForApplication removed

- (void)loadMenu:(NSMenu *)menu forWindow:(unsigned long)windowId
{
    if (!menu) {
        NSLog(@"AppMenuWidget: Cannot load nil menu for window %lu", windowId);
        return;
    }
    
    // Cancel any scheduled fallback for this window since we're loading a real menu
    [self cancelScheduledFallbackForWindow:windowId];

    NSLog(@"AppMenuWidget: Loading menu for window %lu", windowId);
    
    // Clear the waiting flag - we have a new menu
    self.isWaitingForMenu = NO;
    self.currentMenu = menu;
    self.needsRedraw = YES;  // Mark that we need to redraw with new menu
    
    NSLog(@"AppMenuWidget: ===== MENU LOADED, SETTING UP VIEW =====");
    NSLog(@"AppMenuWidget: Menu has %lu top-level items", (unsigned long)[[menu itemArray] count]);
    
    // Log each top-level menu item and whether it has submenus
    NSArray *items = [menu itemArray];
    for (NSUInteger i = 0; i < [items count]; i++) {
        NSMenuItem *item = [items objectAtIndex:i];
        NSLog(@"AppMenuWidget: Top-level item %lu: '%@' (has submenu: %@, submenu items: %lu)", 
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
            NSLog(@"AppMenuWidget: Switching to different app (PID %d -> %d) - clearing non-direct shortcuts", 
                  (int)oldPid, (int)newPid);
            [[X11ShortcutManager sharedManager] unregisterNonDirectShortcuts];
        } else {
            NSLog(@"AppMenuWidget: Same app (PID %d) - keeping shortcuts registered", (int)newPid);
        }
    }
    
    @try {
        [self setupMenuViewWithMenu:menu];
        NSLog(@"AppMenuWidget: setupMenuViewWithMenu completed successfully");
    }
    @catch (NSException *exception) {
        NSLog(@"AppMenuWidget: EXCEPTION in setupMenuViewWithMenu: %@", exception);
        NSLog(@"AppMenuWidget: Exception details - name: %@, reason: %@", [exception name], [exception reason]);
    }
    
    // Re-register shortcuts for this menu since we may have cleared them above
    [self reregisterShortcutsForMenu:menu];
    
    NSLog(@"AppMenuWidget: Successfully loaded fallback menu with %lu items", (unsigned long)[[menu itemArray] count]);
    
    // For fallback menus, also register Alt+W shortcut through X11ShortcutManager
    [self registerAltWShortcutForWindow:windowId];
}

- (void)registerAltWShortcutForWindow:(unsigned long)windowId
{
    // Create a temporary menu item for Alt+W registration
    NSMenuItem *altWMenuItem = [[NSMenuItem alloc] initWithTitle:@"Close" action:@selector(closeActiveWindow:) keyEquivalent:@"w"];
    [altWMenuItem setKeyEquivalentModifierMask:NSAlternateKeyMask];
    [altWMenuItem setTarget:self];
    // Don't set representedObject - we'll determine the active window dynamically
    
    // Register this shortcut with the X11ShortcutManager
    BOOL ok = [[X11ShortcutManager sharedManager] registerDirectShortcutForMenuItem:altWMenuItem
                                                                              target:self
                                                                              action:@selector(closeActiveWindow:)];
    if (!ok) {
        NSLog(@"AppMenuWidget: Failed to register Alt+W fallback shortcut for window %lu", windowId);
    } else {
        NSLog(@"AppMenuWidget: Registered Alt+W fallback shortcut for window %lu", windowId);
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

- (void)sendTileClientMessage:(const char *)atomName
{
    // Send an X11 client message to the window manager to trigger tiling
    Display *display = XOpenDisplay(NULL);
    if (!display) {
        NSLog(@"AppMenuWidget: Cannot open X11 display for tile message");
        return;
    }

    Window root = DefaultRootWindow(display);

    // Create the client message event
    XEvent event;
    memset(&event, 0, sizeof(event));
    event.xclient.type = ClientMessage;
    event.xclient.serial = 0;
    event.xclient.send_event = True;
    event.xclient.window = root;
    event.xclient.message_type = XInternAtom(display, atomName, False);
    event.xclient.format = 32;
    event.xclient.data.l[0] = 0;
    event.xclient.data.l[1] = CurrentTime;
    event.xclient.data.l[2] = 0;
    event.xclient.data.l[3] = 0;
    event.xclient.data.l[4] = 0;

    // Send to root window with SubstructureRedirect | SubstructureNotify mask
    // so the window manager receives it
    XSendEvent(display, root, False,
               SubstructureRedirectMask | SubstructureNotifyMask, &event);
    XFlush(display);
    XCloseDisplay(display);

    NSLog(@"AppMenuWidget: Sent %s client message to window manager", atomName);
}

- (void)centerWindow:(NSMenuItem *)sender
{
    (void)sender;
    NSLog(@"AppMenuWidget: Center Window requested");
    [self sendTileClientMessage:"_GERSHWIN_CENTER_WINDOW"];
}

- (void)maximizeWindowVertically:(NSMenuItem *)sender
{
    (void)sender;
    NSLog(@"AppMenuWidget: Maximize Window Vertically requested");
    [self sendTileClientMessage:"_GERSHWIN_MAXIMIZE_VERTICAL"];
}

- (void)maximizeWindowHorizontally:(NSMenuItem *)sender
{
    (void)sender;
    NSLog(@"AppMenuWidget: Maximize Window Horizontally requested");
    [self sendTileClientMessage:"_GERSHWIN_MAXIMIZE_HORIZONTAL"];
}

- (void)tileWindowLeft:(NSMenuItem *)sender
{
    (void)sender;
    NSLog(@"AppMenuWidget: Tile Window Left requested");
    [self sendTileClientMessage:"_GERSHWIN_TILE_LEFT"];
}

- (void)tileWindowRight:(NSMenuItem *)sender
{
    (void)sender;
    NSLog(@"AppMenuWidget: tileWindowRight: called! sender=%@", sender);
    [self sendTileClientMessage:"_GERSHWIN_TILE_RIGHT"];
}

- (void)tileWindowTopLeft:(NSMenuItem *)sender
{
    (void)sender;
    NSLog(@"AppMenuWidget: Tile Window Top Left requested");
    [self sendTileClientMessage:"_GERSHWIN_TILE_TOP_LEFT"];
}

- (void)tileWindowTopRight:(NSMenuItem *)sender
{
    (void)sender;
    NSLog(@"AppMenuWidget: tileWindowTopRight: called! sender=%@", sender);
    [self sendTileClientMessage:"_GERSHWIN_TILE_TOP_RIGHT"];
}

- (void)tileWindowBottomLeft:(NSMenuItem *)sender
{
    (void)sender;
    NSLog(@"AppMenuWidget: Tile Window Bottom Left requested");
    [self sendTileClientMessage:"_GERSHWIN_TILE_BOTTOM_LEFT"];
}

- (void)tileWindowBottomRight:(NSMenuItem *)sender
{
    (void)sender;
    NSLog(@"AppMenuWidget: Tile Window Bottom Right requested");
    [self sendTileClientMessage:"_GERSHWIN_TILE_BOTTOM_RIGHT"];
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
                NSLog(@"AppMenuWidget: Launched System Preferences by name: %@", name);
                return;
            }
        }

        NSFileManager *fm = [NSFileManager defaultManager];

        // Try exact candidate paths first and log checks
        for (NSString *p in candidatePaths) {
            BOOL exists = [fm fileExistsAtPath:p];
            NSLog(@"AppMenuWidget: Checking candidate path for prefs: %@ (exists=%@)", p, exists ? @"YES" : @"NO");
            if (exists) {
                NSURL *url = [NSURL fileURLWithPath:p];
                NSString *bundleName = [[p lastPathComponent] stringByDeletingPathExtension];
                if (bundleName && [bundleName length] > 0) {
                    if ([[NSWorkspace sharedWorkspace] launchApplication:bundleName]) {
                        NSLog(@"AppMenuWidget: Launched System Preferences using bundle name: %@", bundleName);
                        return;
                    }
                    NSLog(@"AppMenuWidget: launchApplication: failed for %@", bundleName);
                }

                BOOL ok = [[NSWorkspace sharedWorkspace] openURL:url];
                if (ok) {
                    NSLog(@"AppMenuWidget: Opened System Preferences bundle at %@", p);
                } else {
                    NSLog(@"AppMenuWidget: Failed to open System Preferences at %@", p);
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
                            NSLog(@"AppMenuWidget: Found probable System Preferences at %@", fullPath);
                            NSURL *url = [NSURL fileURLWithPath:fullPath];
                            NSString *bundleName = [entry stringByDeletingPathExtension];
                            if ([[NSWorkspace sharedWorkspace] launchApplication:bundleName]) {
                                NSLog(@"AppMenuWidget: Launched System Preferences via bundle name: %@", bundleName);
                                return;
                            }
                            if ([[NSWorkspace sharedWorkspace] openURL:url]) {
                                NSLog(@"AppMenuWidget: Opened System Preferences bundle at %@", fullPath);
                                return;
                            }
                        }
                    }
                }
            }
        }

        NSLog(@"AppMenuWidget: Could not find System Preferences to launch");
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
                NSLog(@"AppMenuWidget: Launched application by name: %@", bundleName);
                return;
            }
            NSLog(@"AppMenuWidget: launchApplication: failed for %@", bundleName);
        }

        // Try reading Info.plist to find a bundle identifier or executable
        NSString *infoPath = [path stringByAppendingPathComponent:@"Contents/Info.plist"];
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPath];
        if (info) {
            NSString *bundleID = info[@"CFBundleIdentifier"];
            if (bundleID && [bundleID length] > 0) {
                if ([ws launchApplication:bundleID]) {
                    NSLog(@"AppMenuWidget: Launched application using bundle identifier: %@", bundleID);
                    return;
                }
                NSLog(@"AppMenuWidget: launchApplication: failed for bundle identifier %@", bundleID);
            }
        }

        // Fallback: open the bundle URL (best-effort)
        NSURL *url = [NSURL fileURLWithPath:path];
        if ([ws openURL:url]) {
            NSLog(@"AppMenuWidget: Opened application bundle at %@", path);
            return;
        }

        // Final fallback: try openFile which some environments handle specially
        if ([ws openFile:path]) {
            NSLog(@"AppMenuWidget: Opened application bundle via openFile: %@", path);
            return;
        }

        NSLog(@"AppMenuWidget: Failed to launch application at %@", path);
    }];
}

- (void)closeActiveWindow:(NSMenuItem *)sender
{
    // Get the currently active window using X11
    Display *display = XOpenDisplay(NULL);
    if (!display) {
        NSLog(@"AppMenuWidget: Cannot open X11 display for active window detection");
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
        NSLog(@"AppMenuWidget: Failed to get active window for close operation due to X11 error");
    });
    
    XCloseDisplay(display);
    
    if (activeWindow == 0) {
        NSLog(@"AppMenuWidget: Could not determine active window for Alt+W close");
        return;
    }
    
    NSLog(@"AppMenuWidget: Alt+W triggered - closing currently active window %lu", activeWindow);
    
    // Send Alt+F4 to close the currently active window
    [self sendAltF4ToWindow:activeWindow];
}

- (void)reregisterShortcutsForMenu:(NSMenu *)menu
{
    // This method is now handled by the protocol managers when they return cached menus
    // GTKMenuImporter and DBusMenuImporter will re-register shortcuts automatically
    NSLog(@"AppMenuWidget: Shortcut re-registration handled by protocol managers");
}

- (void)reregisterGTKShortcut:(NSMenuItem *)item
{
    // For GTK shortcuts, we need to get the stored action data and re-register
    // We would need access to GTKActionHandler's static data, but for now
    // let's register it as a basic shortcut that will trigger the existing action
    NSLog(@"AppMenuWidget: Re-registering GTK shortcut for item: %@", [item title]);
    
    [[X11ShortcutManager sharedManager] registerShortcutForMenuItem:item
                                                        serviceName:nil
                                                         objectPath:nil 
                                                     dbusConnection:nil];
}

- (void)reregisterDBusShortcut:(NSMenuItem *)item
{
    // For DBus shortcuts, similar approach
    NSLog(@"AppMenuWidget: Re-registering DBus shortcut for item: %@", [item title]);
    
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
    
    Display *display = XOpenDisplay(NULL);
    if (!display) {
        NSLog(@"AppMenuWidget: Cannot open X11 display for window validation");
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
    
    XCloseDisplay(display);
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
    NSLog(@"AppMenuWidget: Window %lu disappeared, performing emergency cleanup", windowId);
    
    // If this is our current window, clear everything immediately
    if (self.currentWindowId == windowId) {
        NSLog(@"AppMenuWidget: Current window disappeared, clearing all state");
        
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

        // Try to switch to Desktop menu if available
        if (![self displayDesktopMenuIfAvailableWithReason:@"current window disappeared"]) {
            NSLog(@"AppMenuWidget: Desktop menu not available after window disappearance");
        }
    }
}

@end
