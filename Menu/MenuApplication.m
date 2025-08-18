#import "MenuApplication.h"
#import "MenuController.h"
#import "X11ShortcutManager.h"
#import "DBusMenuParser.h"
#import <signal.h>
#import <unistd.h>

// Global reference for cleanup in signal handlers
static MenuController *g_controller = nil;

// Cleanup function for atexit
static void cleanup_on_exit(void)
{
    NSLog(@"Menu.app: atexit cleanup...");
    [[X11ShortcutManager sharedManager] cleanup];
    [DBusMenuParser cleanup];
}

// Signal handler for graceful shutdown
static void signalHandler(int sig)
{
    const char *signame = "UNKNOWN";
    switch(sig) {
        case SIGTERM: signame = "SIGTERM"; break;
        case SIGINT:  signame = "SIGINT"; break;
        case SIGHUP:  signame = "SIGHUP"; break;
    }
    
    NSLog(@"Menu.app: Received signal %d (%s), performing cleanup...", sig, signame);
    
    // Clean up global shortcuts
    [[X11ShortcutManager sharedManager] cleanup];
    [DBusMenuParser cleanup];
    
    // Reset signal handlers to default to avoid infinite loops
    signal(sig, SIG_DFL);
    
    // Exit gracefully
    NSLog(@"Menu.app: Cleanup complete, exiting...");
    exit(0);
}

@implementation MenuApplication

+ (MenuApplication *)sharedApplication
{
    if (NSApp == nil) {
        NSApp = [[MenuApplication alloc] init];
    }
    
    // If NSApp is not a MenuApplication instance, replace it
    if (![NSApp isKindOfClass:[MenuApplication class]]) {
        NSApplication *oldApp = NSApp;
        NSApp = [[MenuApplication alloc] init];
        [oldApp release];
    }
    
    return (MenuApplication *)NSApp;
}

- (void)finishLaunching
{
    NSLog(@"MenuApplication: ===== FINISH LAUNCHING CALLED =====");
    
    // Call super first
    [super finishLaunching];
    NSLog(@"MenuApplication: Super finishLaunching completed");
    
    NSLog(@"MenuApplication: Initializing application...");
    
    // Check if we're running in a terminal
    if (isatty(STDIN_FILENO)) {
        NSLog(@"MenuApplication: Running in terminal - Ctrl-C and Ctrl-D will trigger cleanup");
    } else {
        NSLog(@"MenuApplication: Running detached from terminal");
    }
    
    // Get the existing controller that should have been set as delegate
    MenuController *controller = (MenuController *)[self delegate];
    if (!controller || ![controller isKindOfClass:[MenuController class]]) {
        NSLog(@"MenuApplication: No MenuController delegate found, creating one...");
        controller = [[MenuController alloc] init];
        g_controller = controller; // Store global reference for signal handlers
        [self setDelegate:controller];
        NSLog(@"MenuApplication: Created and set new MenuController delegate");
    } else {
        NSLog(@"MenuApplication: Using existing MenuController delegate: %@", controller);
        g_controller = controller; // Store global reference for signal handlers
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
    
    // Set up atexit handler as additional safety
    if (atexit(cleanup_on_exit) != 0) {
        NSLog(@"MenuApplication: Warning: Failed to register atexit handler");
    } else {
        NSLog(@"MenuApplication: atexit handler registered");
    }
    
    NSLog(@"MenuApplication: Starting DBus global menu bar");
    
    // For menu bar apps, we need to trigger the initial setup manually
    // since applicationDidFinishLaunching might not be called without windows
    NSLog(@"MenuApplication: Creating protocol manager...");
    [controller createProtocolManager];
    
    NSLog(@"MenuApplication: Setting up menu bar...");
    [controller setupMenuBar];
    
    // Initialize protocols after menu bar is created
    NSLog(@"MenuApplication: Initializing menu protocols...");
    [controller initializeProtocols];
    
    // Set up timers and notifications since applicationDidFinishLaunching won't be called
    NSLog(@"MenuApplication: Setting up window monitoring...");
    [controller setupWindowMonitoring];
    
    // Announce global menu support via X11 properties
    NSLog(@"MenuApplication: Announcing global menu support...");
    [controller announceGlobalMenuSupport];
    
    // Ensure the application is activated
    [self activateIgnoringOtherApps:YES];
    
    NSLog(@"MenuApplication: Initialization complete");
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
    NSLog(@"MenuApplication: Application terminating");
    
    // Ensure global shortcuts are cleaned up before termination
    NSLog(@"MenuApplication: Cleaning up global shortcuts...");
    [[X11ShortcutManager sharedManager] cleanup];
    [DBusMenuParser cleanup];
    
    [super terminate:sender];
}

@end
