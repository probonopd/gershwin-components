/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */


#import <Foundation/Foundation.h>
#import "MBDaemon.h"
#import <signal.h>

static MBDaemon *mbDaemon = nil;

void signal_handler(int sig)
{
    NSDebugLLog(@"gwcomp", @"Received signal %d, shutting down...", sig);
    if (mbDaemon) {
        [mbDaemon stop];
    }
}

int main(int argc, const char * argv[])
{
    @autoreleasepool {
        NSDebugLLog(@"gwcomp", @"MiniBus D-Bus daemon starting...");
        
        // Set up signal handlers
        signal(SIGINT, signal_handler);
        signal(SIGTERM, signal_handler);
        
        // Default socket path
        NSString *socketPath = @"/tmp/minibus-socket";

        // Parse command line arguments
        for (int i = 1; i < argc; i++) {
            NSString *arg = [NSString stringWithUTF8String:argv[i]];
            if (![arg hasPrefix:@"-"]) {
                socketPath = arg;
            }
        }
        
        NSDebugLLog(@"gwcomp", @"Using socket path: %@", socketPath);
        
        // Create and start daemon
        mbDaemon = [[MBDaemon alloc] initWithSocketPath:socketPath];
        
        if (![mbDaemon start]) {
            NSDebugLLog(@"gwcomp", @"Failed to start daemon");
            return 1;
        }
        
        // Run daemon
        [mbDaemon run];
        
        NSDebugLLog(@"gwcomp", @"MiniBus daemon exiting");
    }
    
    return 0;
}
