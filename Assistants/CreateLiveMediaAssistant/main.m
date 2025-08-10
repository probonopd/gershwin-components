//
// main.m
// Create Live Media Assistant - Main Application Entry Point
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import "CLMController.h"
#import <unistd.h>

@interface CLMApplicationDelegate : NSObject <NSApplicationDelegate>
@end

@implementation CLMApplicationDelegate
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    NSLog(@"CreateLiveMediaAssistant: Last window closed, terminating application");
    return YES;
}
@end

int main(int __attribute__((unused)) argc, const char * __attribute__((unused)) argv[])
{
    NSLog(@"CreateLiveMediaAssistant: main() starting");
    
    // Check if running as root
    if (getuid() != 0) {
        NSLog(@"CreateLiveMediaAssistant: Not running as root, re-executing with sudo -A -E");
        
        @autoreleasepool {
            // Build the sudo command with current executable path
            NSString *currentPath = [NSString stringWithUTF8String:argv[0]];
            NSMutableArray *sudoArgs = [NSMutableArray arrayWithObjects:@"-A", @"-E", currentPath, nil];
            
            // Add any additional command line arguments
            for (int i = 1; i < argc; i++) {
                [sudoArgs addObject:[NSString stringWithUTF8String:argv[i]]];
            }
            
            // Execute sudo with current program using NSTask
            NSTask *task = [[NSTask alloc] init];
            [task setLaunchPath:@"sudo"];
            [task setArguments:sudoArgs];
            
            @try {
                [task launch];
                [task waitUntilExit];
                int exitStatus = [task terminationStatus];
                [task release];
                return exitStatus;
            } @catch (NSException *exception) {
                NSLog(@"ERROR: Failed to re-execute with sudo: %@", [exception reason]);
                [task release];
                
                // Fall back to showing error
                NSRunAlertPanel(@"Root Privileges Required",
                               @"This installer requires root privileges but failed to re-execute with sudo.\n\nPlease run this application manually with:\nsudo -A -E %s",
                               @"OK", nil, nil, argv[0]);
                return 1;
            }
        }
    }
    
    @autoreleasepool {
        // Initialize application
        NSApplication *app = [NSApplication sharedApplication];
        
        // Set up application delegate to ensure proper termination
        CLMApplicationDelegate *appDelegate = [[CLMApplicationDelegate alloc] init];
        [app setDelegate:appDelegate];
        
        // Create and show the assistant
        CLMController *controller = [[CLMController alloc] init];
        [controller showAssistant];
        
        // Run the application
        [app run];
        
        [controller release];
        [appDelegate release];
    }
    
    NSLog(@"CreateLiveMediaAssistant: main() exiting");
    return 0;
}
