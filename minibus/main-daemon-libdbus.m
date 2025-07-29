#import <Foundation/Foundation.h>
#import "MBDaemonLibDBus.h"
#import <signal.h>

static MBDaemonLibDBus *globalDaemon = nil;

static void signal_handler(int sig) {
    NSLog(@"Received signal %d, stopping daemon...", sig);
    if (globalDaemon) {
        [globalDaemon stop];
    }
}

int main(int argc, const char *argv[]) {
    (void)argc; (void)argv; // Suppress unused parameter warnings
    
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    NSLog(@"Starting MiniBus daemon (libdbus version)...");
    
    MBDaemonLibDBus *daemon = [[MBDaemonLibDBus alloc] init];
    globalDaemon = daemon;
    
    // Start the daemon
    if (![daemon startWithSocketPath:@"/tmp/minibus-socket"]) {
        NSLog(@"Failed to start daemon");
        [daemon release];
        [pool drain];
        return 1;
    }
    
    // Set up signal handling
    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);
    
    // Run main loop
    [daemon runMainLoop];
    
    [daemon release];
    globalDaemon = nil;
    [pool drain];
    
    NSLog(@"MiniBus daemon (libdbus version) stopped");
    return 0;
}
