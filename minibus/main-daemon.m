#import <Foundation/Foundation.h>
#import "MBDaemon.h"
#import <signal.h>

static MBDaemon *mbDaemon = nil;

void signal_handler(int sig)
{
    NSLog(@"Received signal %d, shutting down...", sig);
    if (mbDaemon) {
        [mbDaemon stop];
    }
}

int main(int argc, const char * argv[])
{
    @autoreleasepool {
        NSLog(@"MiniBus D-Bus daemon starting...");
        
        // Set up signal handlers
        signal(SIGINT, signal_handler);
        signal(SIGTERM, signal_handler);
        
        // Default socket path
        NSString *socketPath = @"/tmp/minibus-socket";
        BOOL verbose = NO;
        
        // Parse command line arguments
        for (int i = 1; i < argc; i++) {
            NSString *arg = [NSString stringWithUTF8String:argv[i]];
            if ([arg isEqualToString:@"-v"] || [arg isEqualToString:@"--verbose"]) {
                verbose = YES;
            } else if (![arg hasPrefix:@"-"]) {
                socketPath = arg;
            }
        }
        
        NSLog(@"Using socket path: %@", socketPath);
        
        // Create and start daemon
        mbDaemon = [[MBDaemon alloc] initWithSocketPath:socketPath];
        
        if (![mbDaemon start]) {
            NSLog(@"Failed to start daemon");
            return 1;
        }
        
        // Run daemon
        [mbDaemon run];
        
        NSLog(@"MiniBus daemon exiting");
    }
    
    return 0;
}
