#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import "MenuApplication.h"
#import "MenuController.h"
#import <signal.h>

int main(int __attribute__((unused)) argc, const char * __attribute__((unused)) argv[])
{
    NSLog(@"Menu.app: Starting application initialization...");
    
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    // Create MenuApplication directly as the main application instance
    MenuApplication *app = [[MenuApplication alloc] init];
    
    // Set it as the shared application instance manually
    NSApp = app;
    
    // Run the application
    [app run];
    
    [pool drain];
    return 0;
}
