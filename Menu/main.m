#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <signal.h>
#import <unistd.h>
#import "MenuController.h"
#import "MenuApplication.h"
#import "DBusMenuParser.h"
#import "X11ShortcutManager.h"

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

int main(int argc, const char *argv[])
{
    (void)argc; // Suppress unused parameter warning
    (void)argv; // Suppress unused parameter warning
    
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    NSLog(@"Menu.app: Initializing application...");
    
    // Check if we're running in a terminal
    if (isatty(STDIN_FILENO)) {
        NSLog(@"Menu.app: Running in terminal - Ctrl-C and Ctrl-D will trigger cleanup");
    } else {
        NSLog(@"Menu.app: Running detached from terminal");
    }
    
    // Initialize the custom application
    MenuApplication *app = (MenuApplication *)[MenuApplication sharedApplication];
    
    NSLog(@"Menu.app: Creating menu controller...");
    // Create and set up the menu controller
    MenuController *controller = [[MenuController alloc] init];
    g_controller = controller; // Store global reference for signal handlers
    [app setDelegate:controller];
    
    // Set up signal handlers for graceful shutdown
    NSLog(@"Menu.app: Setting up signal handlers...");
    if (signal(SIGTERM, signalHandler) == SIG_ERR) {
        NSLog(@"Menu.app: Warning: Failed to set SIGTERM handler");
    } else {
        NSLog(@"Menu.app: SIGTERM handler registered");
    }
    
    if (signal(SIGINT, signalHandler) == SIG_ERR) {
        NSLog(@"Menu.app: Warning: Failed to set SIGINT handler");
    } else {
        NSLog(@"Menu.app: SIGINT handler registered (Ctrl-C will trigger cleanup)");
    }
    
    if (signal(SIGHUP, signalHandler) == SIG_ERR) {
        NSLog(@"Menu.app: Warning: Failed to set SIGHUP handler");
    } else {
        NSLog(@"Menu.app: SIGHUP handler registered");
    }
    
    // Set up atexit handler as additional safety
    if (atexit(cleanup_on_exit) != 0) {
        NSLog(@"Menu.app: Warning: Failed to register atexit handler");
    } else {
        NSLog(@"Menu.app: atexit handler registered");
    }
    
    NSLog(@"Menu.app: Starting DBus global menu bar");
    
    // For menu bar apps, we need to trigger the initial setup manually
    // since applicationDidFinishLaunching might not be called without windows
    NSLog(@"Menu.app: Creating DBus importer...");
    [controller createDBusImporter];
    
    NSLog(@"Menu.app: Setting up top bar...");
    [controller setupMenuBar];
    
    // Initialize DBus connection after top bar is created
    NSLog(@"Menu.app: Initializing DBus connection...");
    [controller initializeDBusConnection];
    
    // Set up timers and notifications since applicationDidFinishLaunching won't be called
    NSLog(@"Menu.app: Setting up window monitoring...");
    [controller setupWindowMonitoring];
    
    // Announce global menu support via X11 properties
    NSLog(@"Menu.app: Announcing global menu support...");
    [controller announceGlobalMenuSupport];
    
    // Ensure the application is activated
    [app activateIgnoringOtherApps:YES];
    
    NSLog(@"Menu.app: Running application main loop...");
    // Run the application
    [app run];
    
    NSLog(@"Menu.app: Application finished running");
    
    // Clean up global shortcuts before exiting
    NSLog(@"Menu.app: Cleaning up global shortcuts...");
    [[X11ShortcutManager sharedManager] cleanup];
    [DBusMenuParser cleanup];
    
    [controller release];
    [pool release];
    
    return 0;
}
