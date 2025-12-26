#import "MenuApplication.h"
#import "MenuController.h"
#import "X11ShortcutManager.h"
#import "DBusMenuParser.h"
#import "DBusConnection.h"
#import "MenuCacheManager.h"
#import <signal.h>
#import <unistd.h>
#import <objc/runtime.h>
#import <objc/message.h>

// Global reference for cleanup in signal handlers
static MenuController *g_controller = nil;
static volatile sig_atomic_t cleanup_in_progress = 0;
static volatile sig_atomic_t received_signal = 0;
static int signal_pipe[2] = {-1, -1};

// Cleanup function for atexit
static void cleanup_on_exit(void)
{
    if (cleanup_in_progress) return;
    cleanup_in_progress = 1;
    
    // Write to stderr to indicate cleanup is starting
    const char *msg = "\n[CLEANUP_ON_EXIT] Cleanup initiated\n";
    (void)write(STDERR_FILENO, msg, 35);
    
    NSLog(@"Menu.app: atexit cleanup...");
    
    @try {
        [[X11ShortcutManager sharedManager] cleanup];
        [DBusMenuParser cleanup];
        
        // Log final cache statistics
        [[MenuCacheManager sharedManager] logCacheStatistics];
    } @catch (NSException *exception) {
        NSLog(@"Menu.app: Exception during atexit cleanup: %@", exception);
    }
}

// Signal handler for graceful shutdown - only set flag and write to pipe
// NOTE: Signal handlers must only call async-signal-safe functions
static void signalHandler(int sig)
{
    // This function is called from signal context - must be async-signal-safe
    // Only safe operations: write to volatile sig_atomic_t, write() syscall
    if (received_signal != 0) return; // Already handling a signal
    received_signal = sig;
    
    // Also write to stderr in a safe way to indicate signal was received
    const char *msg = "\n[SIGNAL HANDLER] Signal received!\n";
    (void)write(STDERR_FILENO, msg, 29);
    
    // Write to self-pipe to wake up the main run loop
    // write() is async-signal-safe
    if (signal_pipe[1] >= 0) {
        char c = 1;
        (void)write(signal_pipe[1], &c, 1);
    }
}

// Forward declare our custom drawRect function
id menu_drawRectWithoutBottomLine(id self, SEL _cmd, NSRect dirtyRect);

@implementation MenuApplication

// Method swizzling moved from +load to avoid runtime initialization conflicts

+ (void)swizzleMenuViewDrawing
{
    // Swizzle NSMenuView's drawRect: method to remove bottom line
    Class menuViewClass = NSClassFromString(@"NSMenuView");
    if (!menuViewClass) {
        NSLog(@"MenuApplication: Warning: NSMenuView class not found for swizzling");
        return;
    }
    
    // Get the original drawRect: method
    Method originalMethod = class_getInstanceMethod(menuViewClass, @selector(drawRect:));
    
    if (!originalMethod) {
        NSLog(@"MenuApplication: Warning: NSMenuView drawRect: method not found for swizzling");
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
    
    NSLog(@"MenuApplication: Successfully swizzled NSMenuView drawRect: method");
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
    
    NSLog(@"MenuApplication: Removed bottom line from menu view bounds: %@", NSStringFromRect(bounds));
    */
    return nil; // drawRect: returns void, but IMP expects id return type
}

- (BOOL)checkForExistingMenuApplication
{
    NSLog(@"MenuApplication: Checking for existing menu applications...");
    
    // Create a temporary DBus connection to check if services are already registered
    GNUDBusConnection *tempConnection = [GNUDBusConnection sessionBus];
    if (![tempConnection isConnected]) {
        NSLog(@"MenuApplication: Cannot connect to DBus to check for existing services");
        return NO; // If we can't connect to DBus, let the app try to start normally
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
        NSLog(@"MenuApplication: Exception while checking for existing service: %@", exception);
        serviceExists = NO;
    }
    
    if (serviceExists) {
        NSLog(@"MenuApplication: Found existing AppMenu.Registrar service - another menu application is running");
        
        // Show NSAlert to inform user
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:NSLocalizedString(@"Menu Application Already Running", @"Menu app conflict dialog title")];
        [alert setInformativeText:NSLocalizedString(@"Another menu application is already running. Only one menu application can run at a time.", @"Menu app conflict dialog message")];
        [alert addButtonWithTitle:NSLocalizedString(@"OK", @"OK button")];
        [alert setAlertStyle:NSWarningAlertStyle];
        
        NSLog(@"MenuApplication: Showing conflict alert...");
        [alert runModal];
        
        NSLog(@"MenuApplication: Exiting due to service conflict");
        exit(1);
    }
    
    NSLog(@"MenuApplication: No conflicting menu applications found");
    return YES;
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
    NSLog(@"MenuApplication: ===== FINISH LAUNCHING CALLED =====");
    
    // Set up method swizzling after runtime is fully initialized
    static BOOL hasSwizzled = NO;
    if (!hasSwizzled) {
        NSLog(@"MenuApplication: Setting up method swizzling to remove menu bottom line");
        [MenuApplication swizzleMenuViewDrawing];
        hasSwizzled = YES;
    }
    
    // Check for existing menu applications before proceeding
    [self checkForExistingMenuApplication];
    
    // Configure menu cache settings from command line arguments
    [self configureCacheSettings];
    
    // DON'T call super finishLaunching as it may be causing immediate termination
    // [super finishLaunching];
    NSLog(@"MenuApplication: Skipped super finishLaunching to prevent termination");
    
    NSLog(@"MenuApplication: Initializing application...");
    
    // Check if we're running in a terminal
    if (isatty(STDIN_FILENO)) {
        NSLog(@"MenuApplication: Running in terminal - Ctrl-C and Ctrl-D will trigger cleanup");
    } else {
        NSLog(@"MenuApplication: Running detached from terminal");
    }
    
    // Create MenuController
    NSLog(@"MenuApplication: Creating MenuController...");
    MenuController *controller = [[MenuController alloc] init];
    g_controller = controller; // Store global reference for signal handlers
    NSLog(@"MenuApplication: Created MenuController");
    
    // Set up self-pipe for async-signal-safe signal handling
    if (pipe(signal_pipe) == 0) {
        NSLog(@"MenuApplication: Signal pipe created successfully");
        
        // Set up file handle to monitor the read end of the pipe
        NSFileHandle *signalFileHandle = [[NSFileHandle alloc] initWithFileDescriptor:signal_pipe[0] closeOnDealloc:YES];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleSignalPipeRead:)
                                                     name:NSFileHandleDataAvailableNotification
                                                   object:signalFileHandle];
        [signalFileHandle waitForDataInBackgroundAndNotify];
    } else {
        NSLog(@"MenuApplication: Warning: Failed to create signal pipe - signal handling may be unsafe");
    }
    
    // Set up signal handlers for graceful shutdown
    NSLog(@"MenuApplication: Setting up signal handlers...");
    if (signal(SIGTERM, signalHandler) == SIG_ERR) {
        NSLog(@"MenuApplication: Warning: Failed to set SIGTERM handler");
    } else {
        NSLog(@"MenuApplication: SIGTERM handler registered");
    }
    
    if (signal(SIGINT, signalHandler) == SIG_ERR) {
        NSLog(@"MenuApplication: Warning: Failed to set SIGINT handler");
    } else {
        NSLog(@"MenuApplication: SIGINT handler registered (Ctrl-C will trigger cleanup)");
    }
    
    if (signal(SIGHUP, signalHandler) == SIG_ERR) {
        NSLog(@"MenuApplication: Warning: Failed to set SIGHUP handler");
    } else {
        NSLog(@"MenuApplication: SIGHUP handler registered");
    }
    
    // Set up a timer to check for received signals
    // Run loop modes must include NSDefaultRunLoopMode and NSEventTrackingRunLoopMode
    NSTimer *signalCheckTimer = [NSTimer timerWithTimeInterval:0.1 
                                                       target:self 
                                                     selector:@selector(checkForSignal) 
                                                     userInfo:nil 
                                                      repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:signalCheckTimer forMode:NSDefaultRunLoopMode];
    [[NSRunLoop mainRunLoop] addTimer:signalCheckTimer forMode:NSEventTrackingRunLoopMode];
    NSLog(@"MenuApplication: Signal check timer installed in multiple run loop modes");
    
    // Set up atexit handler as additional safety
    if (atexit(cleanup_on_exit) != 0) {
        NSLog(@"MenuApplication: Warning: Failed to register atexit handler");
    } else {
        NSLog(@"MenuApplication: atexit handler registered");
    }
    
    NSLog(@"MenuApplication: Starting DBus global menu bar");
    
    // Create protocol manager first
    NSLog(@"MenuApplication: Creating protocol manager...");
    [controller createProtocolManager];
    
    // Setup menu bar (this calls initializeProtocols and setupWindowMonitoring internally)
    NSLog(@"MenuApplication: Setting up menu bar...");
    [controller setupMenuBar];
    
    // Announce global menu support via X11 properties
    NSLog(@"MenuApplication: Announcing global menu support...");
    [controller announceGlobalMenuSupport];
    
    // Set ourselves as delegate to handle termination decisions
    [self setDelegate:self];
    NSLog(@"MenuApplication: Set self as application delegate");
    
    // Ensure the application is activated
    [self activateIgnoringOtherApps:YES];
    
    NSLog(@"MenuApplication: Initialization complete");
    
    // Add a brief delay to let everything settle before entering main run loop
    NSLog(@"MenuApplication: Allowing brief settling period...");
    [NSThread sleepForTimeInterval:0.1];
}

// Called from main run loop when signal is received via self-pipe
- (void)handleSignalPipeRead:(NSNotification *)notification
{
    if (cleanup_in_progress) return;
    cleanup_in_progress = 1;
    
    int sig = received_signal;
    const char *signame = "UNKNOWN";
    switch(sig) {
        case SIGTERM: signame = "SIGTERM"; break;
        case SIGINT:  signame = "SIGINT"; break;
        case SIGHUP:  signame = "SIGHUP"; break;
    }
    
    NSLog(@"Menu.app: Received signal %d (%s) via safe pipe, performing cleanup...", sig, signame);
    
    @try {
        // Clean up global shortcuts - safe to call Objective-C methods now
        [[X11ShortcutManager sharedManager] cleanup];
        [DBusMenuParser cleanup];
        
        // Log final cache statistics
        [[MenuCacheManager sharedManager] logCacheStatistics];
    } @catch (NSException *exception) {
        NSLog(@"Menu.app: Exception during signal cleanup: %@", exception);
    }
    
    NSLog(@"Menu.app: Cleanup complete, terminating...");
    
    // Use proper AppKit termination
    [self terminate:nil];
}

// Check for received signals and handle them
- (void)checkForSignal
{
    static int checkCount = 0;
    if (++checkCount % 10 == 0) {
        // Log every 10th check (every 1 second) to avoid log spam
        NSLog(@"MenuApplication: Signal check (received_signal=%d, cleanup_in_progress=%d)", received_signal, cleanup_in_progress);
    }
    
    if (received_signal != 0 && !cleanup_in_progress) {
        cleanup_in_progress = 1;
        
        int sig = received_signal;
        const char *signame = "UNKNOWN";
        switch(sig) {
            case SIGTERM: signame = "SIGTERM"; break;
            case SIGINT:  signame = "SIGINT"; break;
            case SIGHUP:  signame = "SIGHUP"; break;
        }
        
        NSLog(@"Menu.app: Detected signal %d (%s), performing cleanup...", sig, signame);
        
        @try {
            // Clean up global shortcuts - safe to call Objective-C methods now
            [[X11ShortcutManager sharedManager] cleanup];
            [DBusMenuParser cleanup];
            
            // Log final cache statistics
            [[MenuCacheManager sharedManager] logCacheStatistics];
        } @catch (NSException *exception) {
            NSLog(@"Menu.app: Exception during signal cleanup: %@", exception);
        }
        
        NSLog(@"Menu.app: Cleanup complete, terminating...");
        
        // Use proper AppKit termination
        [self terminate:nil];
    }
}

- (void)sendEvent:(NSEvent *)event
{
    // Log events for debugging if needed
    NSEventType eventType = [event type];
    if (eventType == NSKeyDown || eventType == NSMouseMoved) {
        // Suppress frequent event logging
    } else {
        NSLog(@"MenuApplication: Processing event type %ld", (long)eventType);
    }
    
    [super sendEvent:event];
}

- (void)terminate:(id)sender
{
    NSLog(@"MenuApplication: Application terminating gracefully");
    
    if (cleanup_in_progress) {
        NSLog(@"MenuApplication: Cleanup already in progress, calling super terminate");
        [super terminate:sender];
        return;
    }
    cleanup_in_progress = 1;
    
    @try {
        // Ensure global shortcuts are cleaned up before termination
        NSLog(@"MenuApplication: Cleaning up global shortcuts...");
        [[X11ShortcutManager sharedManager] cleanup];
        [DBusMenuParser cleanup];
        
        // Log final cache statistics
        [[MenuCacheManager sharedManager] logCacheStatistics];
        
        NSLog(@"MenuApplication: Graceful cleanup completed");
    } @catch (NSException *exception) {
        NSLog(@"MenuApplication: Exception during graceful termination: %@", exception);
    }
    
    [super terminate:sender];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender
{
    NSLog(@"MenuApplication: applicationShouldTerminateAfterLastWindowClosed called - returning NO");
    return NO; // Menu app runs without visible windows
}

- (void)configureCacheSettings
{
    NSLog(@"MenuApplication: Configuring menu cache settings...");
    
    MenuCacheManager *cacheManager = [MenuCacheManager sharedManager];
    NSArray *arguments = [[NSProcessInfo processInfo] arguments];
    
    // Parse command line arguments for cache configuration
    for (NSUInteger i = 1; i < [arguments count]; i++) {
        NSString *arg = [arguments objectAtIndex:i];
        
        if ([arg isEqualToString:@"--cache-size"]) {
            if (i + 1 < [arguments count]) {
                NSString *sizeStr = [arguments objectAtIndex:i + 1];
                NSUInteger cacheSize = [sizeStr integerValue];
                if (cacheSize > 0 && cacheSize <= 100) {
                    [cacheManager setMaxCacheSize:cacheSize];
                    NSLog(@"MenuApplication: Set cache size to %lu", (unsigned long)cacheSize);
                } else {
                    NSLog(@"MenuApplication: Invalid cache size %@, must be 1-100", sizeStr);
                }
                i++; // Skip next argument
            }
        } else if ([arg isEqualToString:@"--cache-age"]) {
            if (i + 1 < [arguments count]) {
                NSString *ageStr = [arguments objectAtIndex:i + 1];
                NSTimeInterval maxAge = [ageStr doubleValue];
                if (maxAge > 0 && maxAge <= 3600) {
                    [cacheManager setMaxCacheAge:maxAge];
                    NSLog(@"MenuApplication: Set cache max age to %.1fs", maxAge);
                } else {
                    NSLog(@"MenuApplication: Invalid cache age %@, must be 1-3600 seconds", ageStr);
                }
                i++; // Skip next argument
            }
        } else if ([arg isEqualToString:@"--cache-stats"]) {
            // Enable periodic cache statistics logging
            NSLog(@"MenuApplication: Enabled cache statistics logging");
            // This will be logged automatically by the cache manager
        } else if ([arg isEqualToString:@"--help"]) {
            NSLog(@"MenuApplication: Usage: Menu.app [options]");
            NSLog(@"MenuApplication:   --cache-size N    Set max cache size (1-100 windows, default: 20)");
            NSLog(@"MenuApplication:   --cache-age N     Set max cache age (1-3600 seconds, default: 300)");
            NSLog(@"MenuApplication:   --cache-stats     Enable periodic cache statistics logging");
            NSLog(@"MenuApplication:   --help            Show this help");
        }
    }
    
    // Log current cache configuration
    NSDictionary *stats = [cacheManager getCacheStatistics];
    NSLog(@"MenuApplication: Cache configured - size: %@, max age: %.1fs", 
          stats[@"maxCacheSize"], [stats[@"maxCacheAge"] doubleValue]);
}

@end