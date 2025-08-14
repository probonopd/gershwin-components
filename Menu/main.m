#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import "MenuController.h"
#import "MenuApplication.h"

int main(int argc, const char *argv[])
{
    (void)argc; // Suppress unused parameter warning
    (void)argv; // Suppress unused parameter warning
    
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    NSLog(@"Menu.app: Initializing application...");
    
    // Initialize the custom application
    MenuApplication *app = (MenuApplication *)[MenuApplication sharedApplication];
    
    NSLog(@"Menu.app: Creating menu controller...");
    // Create and set up the menu controller
    MenuController *controller = [[MenuController alloc] init];
    [app setDelegate:controller];
    
    NSLog(@"Menu.app: Starting DBus global menu bar");
    
    // For menu bar apps, we need to trigger the initial setup manually
    // since applicationDidFinishLaunching might not be called without windows
    NSLog(@"Menu.app: Creating DBus importer...");
    [controller createDBusImporter];
    
    NSLog(@"Menu.app: Setting up initial menu bar...");
    [controller setupMenuBar];
    
    // Initialize DBus connection after menu bar is created
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
    
    [controller release];
    [pool release];
    
    return 0;
}
