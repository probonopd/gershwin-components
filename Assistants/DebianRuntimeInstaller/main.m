//
// main.m
// Debian Runtime Installer - Main Application Entry Point
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import "DRIController.h"
#import <unistd.h>

int main(int __attribute__((unused)) argc, const char * __attribute__((unused)) argv[])
{
    NSLog(@"DebianRuntimeInstaller: main() starting");
    
    // Check if running as root
    if (getuid() != 0) {
        NSLog(@"ERROR: Debian Runtime Installer must be run as root (for system modifications)");
        NSRunAlertPanel(@"Root Privileges Required",
                       @"Debian Runtime Installer must be run as root to install system components.\n\nPlease run this application with sudo or as the root user.",
                       @"OK", nil, nil);
        return 1;
    }
    
    @autoreleasepool {
        // Initialize application
        NSApplication *app = [NSApplication sharedApplication];
        
        // Create and show the installer
        DRIController *controller = [[DRIController alloc] init];
        [controller showAssistant];
        
        // Run the application
        [app run];
        
        [controller release];
    }
    
    NSLog(@"DebianRuntimeInstaller: main() exiting");
    return 0;
}
