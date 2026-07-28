/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */


#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import "MenuApplication.h"
#import "MenuController.h"
#import "MenuProfiler.h"
#import "CrashHandler.h"
#import <signal.h>
#import <sys/types.h>
#import <unistd.h>
#import <dirent.h>
#import <X11/Xlib.h>

// Function to resolve a symlink to its actual path
static NSString *resolveSymlink(NSString *linkPath) {
    char buffer[PATH_MAX];
    ssize_t len = readlink([linkPath fileSystemRepresentation], buffer, sizeof(buffer) - 1);
    if (len != -1) {
        buffer[len] = '\0';
        return [NSString stringWithUTF8String:buffer];
    }
    return nil;
}

// Resolve an executable path to its canonical absolute path when possible.
static NSString *canonicalPathForExecutable(NSString *path)
{
    char resolved[PATH_MAX];

    if (!path) {
        return nil;
    }

    if (realpath([path fileSystemRepresentation], resolved) != NULL) {
        return [NSString stringWithUTF8String:resolved];
    }

    return path;
}

// Function to kill any other instances of this application
static void killOtherInstances(void) {
    // Get the path to the current executable
    NSString *currentPath = [[NSBundle mainBundle] executablePath];
    if (!currentPath) {
        NSDebugLLog(@"gwcomp", @"Menu.app: Warning - could not determine executable path");
        return;
    }
    
    pid_t currentPID = getpid();
    
    // Resolve the current executable path to its real path
    NSString *currentRealPath = canonicalPathForExecutable(currentPath);
    
    NSDebugLLog(@"gwcomp", @"Menu.app: Current executable: %@ (real: %@)", currentPath, currentRealPath);
    
    // Scan /proc filesystem for other instances (works on Linux and BSD with /proc)
    DIR *procDir = opendir("/proc");
    if (!procDir) {
        NSDebugLLog(@"gwcomp", @"Menu.app: Warning - could not open /proc directory");
        return;
    }
    
    struct dirent *entry;
    while ((entry = readdir(procDir)) != NULL) {
        // Skip non-numeric entries and . and ..
        if (entry->d_name[0] < '0' || entry->d_name[0] > '9') {
            continue;
        }
        
        pid_t otherPID = (pid_t)strtol(entry->d_name, NULL, 10);
        if (otherPID <= 0 || otherPID == currentPID) {
            continue;
        }
        
        // Try to read the exe link (works on Linux and some BSDs)
        NSString *exePath = [NSString stringWithFormat:@"/proc/%d/exe", otherPID];
        NSString *linkedPath = resolveSymlink(exePath);
        
        // If exe link doesn't work, try file link (some BSDs)
        if (!linkedPath) {
            exePath = [NSString stringWithFormat:@"/proc/%d/file", otherPID];
            linkedPath = resolveSymlink(exePath);
        }
        
        if (!linkedPath) {
            continue;
        }
        
        // Resolve the found process's executable to real path for comparison
        NSString *otherRealPath = canonicalPathForExecutable(linkedPath);
        
        // Compare the executable paths
        if ([otherRealPath isEqualToString:currentRealPath]) {
            NSDebugLLog(@"gwcomp", @"Menu.app: Killing other instance with PID %d", otherPID);
            kill(otherPID, SIGTERM);
            // Give it a moment to terminate gracefully
            usleep(100000); // 100ms
            // Force kill if still running
            kill(otherPID, SIGKILL);
        }
    }
    
    closedir(procDir);
}

int main(int __attribute__((unused)) argc, const char * __attribute__((unused)) argv[])
{
    MenuInstallCrashHandlers();

    // Initialize X11 threading support
    if (!XInitThreads()) {
        fprintf(stderr, "Menu.app: Failed to initialize X11 threading support\n");
        return 1;
    }

    NSDebugLLog(@"gwcomp", @"Menu.app: Starting application initialization...");
    
    // Kill any other instances of Menu.app before proceeding
    killOtherInstances();
    
    @autoreleasepool {
        @try {
            // Create MenuApplication directly as the main application instance
            MenuApplication *app = [[MenuApplication alloc] init];
            
            // Set it as the shared application instance manually
            NSApp = app;
            
            NSDebugLLog(@"gwcomp", @"Menu.app: About to start main run loop...");
            
            // Install profiling signal handler (SIGUSR1 dumps stats)
            menuProfileInstallSignalHandler();
            
            // Run the application with better exception handling
            @try {
                [app run];
            } @catch (NSException *runException) {
                NSDebugLLog(@"gwcomp", @"Menu.app: Exception in run loop: %@", runException);
                NSDebugLLog(@"gwcomp", @"Menu.app: Run loop exception reason: %@", [runException reason]);
            }
            
            // GNUstep's [NSApp run] may return when it detects no regular windows.
            // The menu bar is borderless (NSBorderlessWindowMask) and is not counted.
            // Keep the run loop alive manually to prevent premature exit.
            while (YES) {
                @autoreleasepool {
                    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate distantFuture]];
                }
            }
            
            NSDebugLLog(@"gwcomp", @"Menu.app: Main run loop exited normally");
        } @catch (NSException *exception) {
            NSDebugLLog(@"gwcomp", @"Menu.app: Caught exception in main: %@", exception);
            NSDebugLLog(@"gwcomp", @"Menu.app: Exception reason: %@", [exception reason]);
            NSDebugLLog(@"gwcomp", @"Menu.app: Exception stack: %@", [exception callStackSymbols]);
            return 1;
        }
    }
    
    NSDebugLLog(@"gwcomp", @"Menu.app: Application exiting normally");
    return 0;
}
