/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */


#import "MenuApplication.h"
#import "MenuController.h"
#import "X11ShortcutManager.h"
#import "DBusMenuParser.h"
#import "DBusConnection.h"
#import "CustomMenuPanel.h"
#import "ActionSearch.h"
#import <signal.h>
#import <unistd.h>
#import <time.h>
#import <stdlib.h>
#import <sys/types.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>

// Global reference for cleanup in signal handlers
static MenuController *g_controller = nil;
static volatile sig_atomic_t cleanup_in_progress = 0;
static volatile sig_atomic_t termination_requested = 0;
static BOOL terminationSignalHandled = NO;
static BOOL existingInstanceHandled = NO;
static time_t signal_received_time = 0;

// Direct signal handler (runs in signal context, must be async-signal-safe)
static void direct_signal_handler(int sig)
{
    // If first signal, request termination via dispatch
    if (!termination_requested) {
        termination_requested = 1;
        signal_received_time = time(NULL);
        // Set a 3-second alarm: if cleanup doesn't finish, SIGALRM will force exit
        alarm(3);
        // Note: The dispatch source event will be delivered to the main queue
        // and handleTerminationSignal will be called
        return;
    }
    
    // If we get here, it's a repeated signal after termination was already requested
    // Immediately force exit (don't wait for cleanup to finish)
    write(STDERR_FILENO, "\nMenu.app: Force-exiting due to repeated signal\n", 48);
    _exit(128 + sig);
}

// SIGALRM handler for forced exit on cleanup timeout
static void alarm_handler(int sig)
{
    (void)sig;
    write(STDERR_FILENO, "\nMenu.app: Cleanup timeout - force exiting\n",
          sizeof("\nMenu.app: Cleanup timeout - force exiting\n") - 1);
    _exit(EXIT_FAILURE);
}

// Global accessor to retrieve the MenuController instance from other modules
MenuController *MenuControllerGlobal(void) { return g_controller; }

// Cleanup function for atexit
static void cleanup_on_exit(void)
{
    if (cleanup_in_progress) return;
    cleanup_in_progress = 1;
    
    NSDebugLLog(@"gwcomp", @"Menu.app: atexit cleanup...");
    
    @try {
        [[X11ShortcutManager sharedManager] cleanup];
        [DBusMenuParser cleanup];
    } @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"Menu.app: Exception during atexit cleanup: %@", exception);
    }
}

// Signal handler for graceful shutdown
// Forward declare our custom drawRect function
id menu_drawRectWithoutBottomLine(id self, SEL _cmd, NSRect dirtyRect);

@interface MenuApplication ()
{
    dispatch_source_t terminationSignalSources[3];
    NSUInteger terminationSignalSourceCount;
}
- (void)installGracefulTerminationSignals;
- (void)installTerminationSourceForSignal:(int)sig name:(NSString *)name;
- (void)handleTerminationSignal:(int)sig;
@end

@implementation MenuApplication

// Method swizzling moved from +load to avoid runtime initialization conflicts

+ (void)swizzleMenuViewDrawing
{
    // Swizzle NSMenuView's drawRect: method to remove bottom line
    Class menuViewClass = NSClassFromString(@"NSMenuView");
    if (!menuViewClass) {
        NSDebugLLog(@"gwcomp", @"MenuApplication: Warning: NSMenuView class not found for swizzling");
        return;
    }
    
    // Get the original drawRect: method
    Method originalMethod = class_getInstanceMethod(menuViewClass, @selector(drawRect:));
    
    if (!originalMethod) {
        NSDebugLLog(@"gwcomp", @"MenuApplication: Warning: NSMenuView drawRect: method not found for swizzling");
        return;
    }
    
    // Store the original implementation in a new selector
    SEL originalSelector = @selector(original_drawRect:);
    IMP originalIMP = method_getImplementation(originalMethod);
    const char *typeEncoding = method_getTypeEncoding(originalMethod);
    
    // Store the original IMP globally for proper calling from the swizzled method
    original_drawRect_IMP = (void (*)(id, SEL, NSRect))(void *)originalIMP;
    
    // Add the original implementation under a new name
    class_addMethod(menuViewClass, originalSelector, originalIMP, typeEncoding);
    
    // Replace the original drawRect: with our custom implementation
    method_setImplementation(originalMethod, (IMP)menu_drawRectWithoutBottomLine);
    
    NSDebugLLog(@"gwcomp", @"MenuApplication: Successfully swizzled NSMenuView drawRect: method");
}

// Store the original IMP globally so we can call it properly
static void (*original_drawRect_IMP)(id, SEL, NSRect) = NULL;

// Custom drawRect implementation that removes bottom line
id menu_drawRectWithoutBottomLine(id self, SEL cmd __attribute__((unused)), NSRect dirtyRect)
{
    // Call the original drawRect implementation directly via the stored IMP
    // (performSelector:withObject: cannot pass NSRect structs correctly)
    if (original_drawRect_IMP != NULL) {
        original_drawRect_IMP(self, @selector(drawRect:), dirtyRect);
    }
    /*
    // Now override any bottom line drawing by drawing over it with background color
    NSRect bounds = [self bounds];
    NSRect bottomLineRect = NSMakeRect(0, 0, bounds.size.width, 1);
    
    // Use the window's background color or a default light color
    NSColor *backgroundColor = nil;
    NSWindow *window = [self window];
    if (window && [window backgroundColor]) {
        backgroundColor = [window backgroundColor];
    } else {
        // Default to a light gray background typical of menus
        backgroundColor = [NSColor colorWithCalibratedWhite:0.95 alpha:1.0];
    }
    
    [backgroundColor set];
    NSRectFill(bottomLineRect);
    
    // Also check for any separator lines at the bottom and remove them
    NSRect bottomSeparatorRect = NSMakeRect(0, 1, bounds.size.width, 1);
    [backgroundColor set];
    NSRectFill(bottomSeparatorRect);
    
    NSDebugLLog(@"gwcomp", @"MenuApplication: Removed bottom line from menu view bounds: %@", NSStringFromRect(bounds));
    */
    return nil; // drawRect: returns void, but IMP expects id return type
}

- (void)checkForExistingMenuApplicationAsync
{
    // Run the check in a background thread to avoid blocking startup
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self checkForExistingMenuApplicationBackground];
    });
}

- (void)checkForExistingMenuApplicationBackground
{
    @autoreleasepool {
        NSDebugLLog(@"gwcomp", @"MenuApplication: Checking for existing menu applications (async)...");
        
        // Create a temporary DBus connection to check if services are already registered
        GNUDBusConnection *tempConnection = [GNUDBusConnection sessionBus];
        if (![tempConnection isConnected]) {
            NSDebugLLog(@"gwcomp", @"MenuApplication: Cannot connect to DBus to check for existing services");
            return; // If we can't connect to DBus, let the app try to start normally
        }
        
        // Check if com.canonical.AppMenu.Registrar service is already running
        BOOL serviceExists = NO;
        
        @try {
            // Use DBus introspection to check if the service exists
            id result = [tempConnection callMethod:@"NameHasOwner"
                                         onService:@"org.freedesktop.DBus"
                                        objectPath:@"/org/freedesktop/DBus"
                                         interface:@"org.freedesktop.DBus"
                                         arguments:@[@"com.canonical.AppMenu.Registrar"]];
            
            if (result && [result respondsToSelector:@selector(boolValue)]) {
                serviceExists = [result boolValue];
            }
        }
        @catch (NSException *exception) {
            NSDebugLLog(@"gwcomp", @"MenuApplication: Exception while checking for existing service: %@", exception);
            serviceExists = NO;
        }
        
        if (serviceExists) {
            NSDebugLLog(@"gwcomp", @"MenuApplication: Found existing AppMenu.Registrar service - another menu application is running");

            // Under auto-relaunch supervision, avoid modal alert loops. Terminate quietly by default.
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!existingInstanceHandled) {
                    existingInstanceHandled = YES;
                    [self showMenuConflictAlert];
                }
            });
        } else {
            NSDebugLLog(@"gwcomp", @"MenuApplication: No conflicting menu applications found");
        }
    }
}

- (void)showMenuConflictAlert
{
    NSString *interactiveConflict = [[[NSProcessInfo processInfo] environment] objectForKey:@"MENU_SHOW_CONFLICT_ALERT"];
    BOOL shouldShowAlert = (interactiveConflict != nil && [interactiveConflict length] > 0);

    if (!shouldShowAlert) {
        NSDebugLLog(@"gwcomp", @"MenuApplication: Existing Menu service detected; terminating this instance quietly");
        [self terminate:nil];
        return;
    }

    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:NSLocalizedString(@"Menu Application Already Running", @"Menu app conflict dialog title")];
    [alert setInformativeText:NSLocalizedString(@"Another menu application is already running. Only one menu application can run at a time.", @"Menu app conflict dialog message")];
    [alert addButtonWithTitle:NSLocalizedString(@"OK", @"OK button")];
    [alert setAlertStyle:NSWarningAlertStyle];
    
    NSDebugLLog(@"gwcomp", @"MenuApplication: Showing conflict alert...");
    [alert runModal];

    NSDebugLLog(@"gwcomp", @"MenuApplication: Conflict alert dismissed, terminating this instance");
    [self terminate:nil];
}

+ (MenuApplication *)sharedApplication
{
    if (NSApp == nil) {
        NSApp = [[MenuApplication alloc] init];
    }
    
    // If NSApp is not a MenuApplication instance, replace it
    if (![NSApp isKindOfClass:[MenuApplication class]]) {
        NSApp = [[MenuApplication alloc] init];
    }
    
    return (MenuApplication *)NSApp;
}

- (void)finishLaunching
{
    NSDebugLLog(@"gwcomp", @"MenuApplication: ===== FINISH LAUNCHING CALLED =====");
    
    // Set up method swizzling after runtime is fully initialized
    static BOOL hasSwizzled = NO;
    if (!hasSwizzled) {
        NSDebugLLog(@"gwcomp", @"MenuApplication: Setting up method swizzling to remove menu bottom line");
        [MenuApplication swizzleMenuViewDrawing];
        
        // Hook NSMenu panel creation to use custom styled menus
        NSDebugLLog(@"gwcomp", @"MenuApplication: Hooking NSMenu panel creation for custom styling");
        HookNSMenuPanelCreation();
        
        hasSwizzled = YES;
    }
    
    // Check for existing menu applications asynchronously (non-blocking)
    [self checkForExistingMenuApplicationAsync];
    
    // DON'T call super finishLaunching as it may be causing immediate termination
    // [super finishLaunching];
    NSDebugLLog(@"gwcomp", @"MenuApplication: Skipped super finishLaunching to prevent termination");
    
    NSDebugLLog(@"gwcomp", @"MenuApplication: Initializing application...");
    
    // Check if we're running in a terminal
    if (isatty(STDIN_FILENO)) {
        NSDebugLLog(@"gwcomp", @"MenuApplication: Running in terminal - Ctrl-C and Ctrl-D will trigger cleanup");
    } else {
        NSDebugLLog(@"gwcomp", @"MenuApplication: Running detached from terminal");
    }
    
    // Create MenuController
    NSDebugLLog(@"gwcomp", @"MenuApplication: Creating MenuController...");
    self.controller = [[MenuController alloc] init];
    g_controller = self.controller; // Store global reference for signal handlers
    

    NSDebugLLog(@"gwcomp", @"MenuApplication: Created MenuController");
    
    // Set up graceful signal delivery on the main queue.
    NSDebugLLog(@"gwcomp", @"MenuApplication: Setting up signal handling...");
    
    // CRITICAL: Ignore SIGPIPE to prevent crashes when stdout/stderr is unavailable
    // This happens when running in background without output redirection
    if (signal(SIGPIPE, SIG_IGN) == SIG_ERR) {
        NSDebugLLog(@"gwcomp", @"MenuApplication: Warning: Failed to ignore SIGPIPE - app may crash if terminal closes");
    } else {
        NSDebugLLog(@"gwcomp", @"MenuApplication: SIGPIPE handler set to ignore (prevents crashes on write to closed stdout/stderr)");
    }
    
    [self installGracefulTerminationSignals];
    
    // Set up atexit handler as additional safety
    if (atexit(cleanup_on_exit) != 0) {
        NSDebugLLog(@"gwcomp", @"MenuApplication: Warning: Failed to register atexit handler");
    } else {
        NSDebugLLog(@"gwcomp", @"MenuApplication: atexit handler registered");
    }

    NSDebugLLog(@"gwcomp", @"MenuApplication: Starting DBus global menu bar");
    
    // Create protocol manager first
    NSDebugLLog(@"gwcomp", @"MenuApplication: Creating protocol manager...");
    [self.controller createProtocolManager];
    
    // Ensure the application is activated BEFORE setting up the menu bar
    NSDebugLLog(@"gwcomp", @"MenuApplication: Activating application...");
    [self activateIgnoringOtherApps:YES];
    NSDebugLLog(@"gwcomp", @"MenuApplication: Application activated");
    
    // Setup menu bar (this calls initializeProtocols and setupWindowMonitoring internally)
    NSDebugLLog(@"gwcomp", @"MenuApplication: Setting up menu bar...");
    [self.controller setupMenuBar];
    
    // Announce global menu support via X11 properties
    NSDebugLLog(@"gwcomp", @"MenuApplication: Announcing global menu support...");
    [self.controller announceGlobalMenuSupport];
    
    // Set MenuController as delegate so applicationDidFinishLaunching gets called
    [self setDelegate:self.controller];
    NSDebugLLog(@"gwcomp", @"MenuApplication: Set MenuController as application delegate");
    
    // Ensure the application is activated (again, just in case)
    [self activateIgnoringOtherApps:YES];
    
    NSDebugLLog(@"gwcomp", @"MenuApplication: Initialization complete - Menu will appear immediately");
}

- (void)installGracefulTerminationSignals
{
    // Install SIGALRM handler for forced exit on cleanup timeout
    if (signal(SIGALRM, alarm_handler) == SIG_ERR) {
        NSDebugLLog(@"gwcomp", @"MenuApplication: Warning: failed to install SIGALRM handler");
    } else {
        NSDebugLLog(@"gwcomp", @"MenuApplication: SIGALRM handler installed");
    }
    
    terminationSignalSourceCount = 0;
    [self installTerminationSourceForSignal:SIGTERM name:@"SIGTERM"];
    [self installTerminationSourceForSignal:SIGINT name:@"SIGINT"];
    [self installTerminationSourceForSignal:SIGHUP name:@"SIGHUP"];
}

- (void)installTerminationSourceForSignal:(int)sig name:(NSString *)name
{
    // Install direct signal handler that sets termination_requested and alarm timeout
    if (signal(sig, direct_signal_handler) == SIG_ERR) {
        NSDebugLLog(@"gwcomp", @"MenuApplication: Warning: failed to install handler for %@", name);
        return;
    }

    // Create dispatch source to handle termination on the main queue
    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL,
                                                      (uintptr_t)sig,
                                                      0,
                                                      dispatch_get_main_queue());
    if (!source) {
        NSDebugLLog(@"gwcomp", @"MenuApplication: Warning: failed to create dispatch source for %@", name);
        return;
    }

    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(source, ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        [strongSelf handleTerminationSignal:sig];
    });
    dispatch_resume(source);
    if (terminationSignalSourceCount < 3) {
        terminationSignalSources[terminationSignalSourceCount++] = source;
    }

    NSDebugLLog(@"gwcomp", @"MenuApplication: %@ dispatch source registered", name);
}

- (void)handleTerminationSignal:(int)sig
{
    if (terminationSignalHandled) {
        return;
    }
    terminationSignalHandled = YES;

    const char *name = "UNKNOWN";
    switch (sig) {
        case SIGTERM: name = "SIGTERM"; break;
        case SIGINT: name = "SIGINT"; break;
        case SIGHUP: name = "SIGHUP"; break;
    }

    NSDebugLLog(@"gwcomp", @"MenuApplication: Received %s, terminating via main queue", name);
    [self terminate:nil];
}

- (void)sendEvent:(NSEvent *)event
{
    // Log events for debugging if needed
    NSEventType eventType = [event type];
    if (eventType == NSKeyDown) {
        // Log KeyDown events and route to key window / search panel
        NSWindow *keyWin = [self keyWindow];
        NSDebugLLog(@"gwcomp", @"MenuApplication: KeyDown event, key window: %@, characters: %@", 
              keyWin, [event characters]);

        // If Action Search is visible, route KeyDown events to it first to make sure
        // typing, arrows and escape are handled immediately (covers various WMs).
        ActionSearchController *search = [ActionSearchController sharedController];
        if ([search.searchPanel isVisible]) {
            // Reassert application activation and first-responder on each key event to
            // handle window-manager focus races where the panel appears but does not
            // receive keyboard input until clicked.
            [NSApp activateIgnoringOtherApps:YES];
            [search.searchPanel makeKeyWindow];
            [search.searchPanel makeFirstResponder:search.searchField];
            NSDebugLLog(@"gwcomp", @"MenuApplication: Ensured focus on ActionSearchPanel before routing key");
            [search.searchPanel sendEvent:event];
            return;
        }

        // If there is no key window, try to find an ActionSearchPanel among windows as fallback
        if (!keyWin) {
            for (NSWindow *window in [self windows]) {
                if ([window isVisible] && [[window className] isEqualToString:@"ActionSearchPanel"]) {
                    NSDebugLLog(@"gwcomp", @"MenuApplication: Routing KeyDown to ActionSearchPanel (found by class)");
                    [window sendEvent:event];
                    return;
                }
            }
        } else if (keyWin != [event window]) {
            NSDebugLLog(@"gwcomp", @"MenuApplication: Forwarding KeyDown to key window");
            [keyWin sendEvent:event];
            return;
        }
    } else if (eventType == NSLeftMouseDown || eventType == NSRightMouseDown) {
        // If the action search panel is visible and the click is outside it and not in an NSMenu, close the popup
        ActionSearchController *search = [ActionSearchController sharedController];
        if ([search.searchPanel isVisible]) {
            NSWindow *evtWin = [event window];
            if (evtWin == nil) {
                [search hideSearchPopup];
            } else {
                NSString *classname = NSStringFromClass([evtWin class]);
                if (![classname hasPrefix:@"NSMenu"] && evtWin != search.searchPanel) {
                    [search hideSearchPopup];
                }
            }
        }
    } else if (eventType == NSMouseMoved) {
        // Suppress frequent event logging
    } else if (eventType == NSLeftMouseDragged ||
               eventType == NSRightMouseDragged ||
               eventType == NSMouseEntered ||
               eventType == NSMouseExited ||
               eventType == NSLeftMouseUp ||
               eventType == NSRightMouseUp ||
               eventType == NSScrollWheel ||
               eventType == NSOtherMouseUp ||
               eventType == NSOtherMouseDragged) {
        // Suppress all high-frequency mouse tracking events to prevent log I/O tight loop
    } else {
        NSDebugLLog(@"gwcomp", @"MenuApplication: Processing event type %ld", (long)eventType);
    }
    
    [super sendEvent:event];
}

- (void)terminate:(id)sender
{
    NSDebugLLog(@"gwcomp", @"MenuApplication: Application terminating gracefully");
    
    // Cancel any pending alarm timeout
    alarm(0);
    
    if (cleanup_in_progress) {
        NSDebugLLog(@"gwcomp", @"MenuApplication: Cleanup already in progress, calling super terminate");
        [super terminate:sender];
        return;
    }
    cleanup_in_progress = 1;
    
    @try {
        // Ensure global shortcuts are cleaned up before termination
        NSDebugLLog(@"gwcomp", @"MenuApplication: Cleaning up global shortcuts...");
        [[X11ShortcutManager sharedManager] cleanup];
        [DBusMenuParser cleanup];
        
        NSDebugLLog(@"gwcomp", @"MenuApplication: Graceful cleanup completed");
    } @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"MenuApplication: Exception during graceful termination: %@", exception);
    }
    
    // Exit explicitly after cleanup completes (allows main loop to exit cleanly)
    exit(EXIT_SUCCESS);
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender
{
    NSDebugLLog(@"gwcomp", @"MenuApplication: applicationShouldTerminateAfterLastWindowClosed called - returning NO");
    return NO; // Menu app runs without visible windows
}

// configureCacheSettings removed
@end
