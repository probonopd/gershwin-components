#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import "MenuController.h"
#import "MenuApplication.h"

int main(int argc, const char *argv[])
{
    (void)argc; // Suppress unused parameter warning
    (void)argv; // Suppress unused parameter warning
    
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    // Initialize the custom application
    MenuApplication *app = (MenuApplication *)[MenuApplication sharedApplication];
    
    // Create and set up the menu controller
    MenuController *controller = [[MenuController alloc] init];
    [app setDelegate:controller];
    
    NSLog(@"Menu.app: Starting DBus global menu bar");
    
    // Run the application
    [app run];
    
    [controller release];
    [pool release];
    
    return 0;
}
