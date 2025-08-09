//
// main.m
// Create Live Media Assistant - Main Application Entry Point
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import "CLMController.h"
#import <unistd.h>

int main(int __attribute__((unused)) argc, const char * __attribute__((unused)) argv[])
{
    NSLog(@"CreateLiveMediaAssistant: main() starting");
    
    // Check if running as root
    if (getuid() != 0) {
        NSLog(@"ERROR: Create Live Media Assistant must be run as root (for disk writing operations)");
        NSRunAlertPanel(@"Root Privileges Required",
                       @"Create Live Media Assistant must be run as root to write to disks.\n\nPlease run this application with sudo or as the root user.",
                       @"OK", nil, nil);
        return 1;
    }
    
    @autoreleasepool {
        // Initialize application
        NSApplication *app = [NSApplication sharedApplication];
        
        // Create and show the assistant
        CLMController *controller = [[CLMController alloc] init];
        [controller showAssistant];
        
        // Run the application
        [app run];
        
        [controller release];
    }
    
    NSLog(@"CreateLiveMediaAssistant: main() exiting");
    return 0;
}
