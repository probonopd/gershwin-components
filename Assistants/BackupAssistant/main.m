//
// main.m
// Backup Assistant - Main Application Entry Point
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import "BAController.h"
#import <unistd.h>

@interface BAApplicationDelegate : NSObject <NSApplicationDelegate>
@end

@implementation BAApplicationDelegate
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    NSLog(@"BackupAssistant: Last window closed, terminating application");
    return YES;
}
@end

int main(int __attribute__((unused)) argc, const char * __attribute__((unused)) argv[])
{
    NSLog(@"BackupAssistant: main() starting");
    
    // Check if running as root
    if (getuid() != 0) {
        NSLog(@"BackupAssistant: Not running as root, re-executing with sudo -A -E");
        
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
                               @"The Backup Assistant requires root privileges but failed to re-execute with sudo.\n\nPlease run this application manually with:\nsudo -A -E %s",
                               @"OK", nil, nil, argv[0]);
                return 1;
            }
        }
    }
    
    @autoreleasepool {
        // Initialize application
        NSApplication *app = [NSApplication sharedApplication];
        
        // Set up application delegate to ensure proper termination
        BAApplicationDelegate *appDelegate = [[BAApplicationDelegate alloc] init];
        [app setDelegate:appDelegate];
        
        // Create and show the assistant
        BAController *controller = [[BAController alloc] init];
        [controller showAssistant];
        
        // Run the application
        [app run];
        
        [controller release];
        [appDelegate release];
    }
    
    NSLog(@"BackupAssistant: main() exiting");
    return 0;
}
