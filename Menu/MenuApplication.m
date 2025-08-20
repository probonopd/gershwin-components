#import "MenuApplication.h"
#import "MenuController.h"
#import "X11ShortcutManager.h"
#import "DBusMenuParser.h"
#import "DBusConnection.h"
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
        [alert release];
        
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
        NSApplication *oldApp = NSApp;
        NSApp = [[MenuApplication alloc] init];
        [oldApp release];
    }
    
    return (MenuApplication *)NSApp;
}

- (void)finishLaunching
{
    NSLog(@"MenuApplication: ===== FINISH LAUNCHING CALLED =====");
    
    // Check for existing menu applications before proceeding
    [self checkForExistingMenuApplication];
    
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

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender
{
    NSLog(@"MenuApplication: applicationShouldTerminateAfterLastWindowClosed called - returning NO");
    return NO; // Menu app runs without visible windows
}

@end
