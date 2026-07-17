/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */


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
    NSDebugLLog(@"gwcomp", @"CreateLiveMediaAssistant: Last window closed, terminating application");
    return YES;
}
@end

int main(int __attribute__((unused)) argc, const char * __attribute__((unused)) argv[])
{
    NSDebugLLog(@"gwcomp", @"CreateLiveMediaAssistant: main() starting");
    
    // Check if running as root
    if (getuid() != 0) {
        NSDebugLLog(@"gwcomp", @"CreateLiveMediaAssistant: Not running as root, re-executing with sudo -A -E");
        
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
                return exitStatus;
            } @catch (NSException *exception) {
                NSDebugLLog(@"gwcomp", @"ERROR: Failed to re-execute with sudo: %@", [exception reason]);
                
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
        
        // Set application icon from bundle.
        // mainBundle may fail when re-executed via sudo; fall back to argv[0] path.
        NSImage *appIcon = nil;
        NSString *iconPath = [[NSBundle mainBundle] pathForResource:@"Create_Live_Media"
                                                             ofType:@"png"];
        if (!iconPath && argv[0]) {
            NSString *exeDir = [[NSString stringWithUTF8String:argv[0]]
                stringByDeletingLastPathComponent];
            if ([exeDir length] > 0) {
                iconPath = [exeDir stringByAppendingPathComponent:
                    @"Resources/Create_Live_Media.png"];
            }
        }
        if (iconPath) {
            appIcon = [[NSImage alloc] initWithContentsOfFile:iconPath];
        }
        if (appIcon) {
            [app setApplicationIconImage:appIcon];
        }
        
        // Set up application delegate to ensure proper termination
        CLMApplicationDelegate *appDelegate = [[CLMApplicationDelegate alloc] init];
        [app setDelegate:appDelegate];
        
        // Create and show the assistant
        CLMController *controller = [[CLMController alloc] init];
        [controller showAssistant];
        
        // Run the application
        [app run];
    }
    
    NSDebugLLog(@"gwcomp", @"CreateLiveMediaAssistant: main() exiting");
    return 0;
}
