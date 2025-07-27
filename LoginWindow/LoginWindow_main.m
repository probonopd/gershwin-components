// Copyright (c) 2025, Simon Peter
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//
// 1. Redistributions of source code must retain the above copyright notice,
//    this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright notice,
//    this list of conditions and the following disclaimer in the documentation
//    and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
// ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
// LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGE.

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import "LoginWindow.h"
#include <X11/Xlib.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>

// Forward declarations of functions from this file
BOOL isXServerRunning(void);
BOOL waitForXServer(void);
BOOL startXServer(void);

BOOL isXServerRunning(void)
{
    NSLog(@"[DEBUG] Checking if X server is running");
    
    // First check if there's a lock file indicating X server should be running
    if ([[NSFileManager defaultManager] fileExistsAtPath:@"/tmp/.X0-lock"]) {
        NSLog(@"[DEBUG] Found X server lock file at /tmp/.X0-lock");
        
        // Read the PID from the lock file to see if the process is actually running
        NSString *lockContent = [NSString stringWithContentsOfFile:@"/tmp/.X0-lock" 
                                                           encoding:NSUTF8StringEncoding 
                                                              error:nil];
        if (lockContent) {
            pid_t xpid = [lockContent intValue];
            if (xpid > 0 && kill(xpid, 0) == 0) {
                NSLog(@"[DEBUG] X server process %d is running according to lock file", xpid);
            } else {
                NSLog(@"[DEBUG] X server lock file exists but process %d is not running - removing stale lock", xpid);
                [[NSFileManager defaultManager] removeItemAtPath:@"/tmp/.X0-lock" error:nil];
                [[NSFileManager defaultManager] removeItemAtPath:@"/tmp/.X11-unix/X0" error:nil];
                return NO;
            }
        }
    }
    
    // Set up proper environment for X11 connection
    const char *display_name = ":0";
    setenv("DISPLAY", display_name, 1);
    
    // Set up X authority - try common locations
    NSArray *authPaths = @[@"/var/run/loginwindow.auth", @"/tmp/loginwindow.auth", @"/root/.Xauth"];
    for (NSString *authPath in authPaths) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:authPath]) {
            setenv("XAUTHORITY", [authPath UTF8String], 1);
            NSLog(@"[DEBUG] Using X authority file: %@", authPath);
            break;
        }
    }
    
    // Try to open X display
    Display *testDisplay = XOpenDisplay(display_name);
    if (testDisplay != NULL) {
        XCloseDisplay(testDisplay);
        NSLog(@"[DEBUG] X server is running and accessible on %s", display_name);
        return YES;
    } else {
        NSLog(@"[DEBUG] Cannot connect to X server on %s (may not be running or auth issue)", display_name);
        return NO;
    }
}

// Function to wait for X server to accept connections (like SLiM WaitForServer)
BOOL waitForXServer(void)
{
    NSLog(@"[DEBUG] Waiting for X server to accept connections");
    int attempts = 0;
    int maxAttempts = 120; // 120 seconds timeout like SLiM
    
    for (attempts = 0; attempts < maxAttempts; attempts++) {
        Display *testDisplay = XOpenDisplay(":0");
        if (testDisplay != NULL) {
            XCloseDisplay(testDisplay);
            NSLog(@"[DEBUG] X server is now accepting connections after %d attempts", attempts + 1);
            return YES;
        }
        
        if (attempts % 10 == 0 && attempts > 0) {
            NSLog(@"[DEBUG] Still waiting for X server to accept connections (attempt %d/%d)", attempts, maxAttempts);
        }
        
        sleep(1);
    }
    
    NSLog(@"[DEBUG] X server failed to accept connections within timeout");
    return NO;
}

BOOL startXServer(void)
{
    NSLog(@"[DEBUG] Starting X server");
    
    // Find X server executable
    NSString *xserverPath = nil;
    NSArray *possiblePaths = @[@"/usr/local/bin/X", @"/usr/local/bin/Xorg", @"/usr/bin/Xorg"];
    
    for (NSString *path in possiblePaths) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
            xserverPath = path;
            break;
        }
    }
    
    if (!xserverPath) {
        NSLog(@"[DEBUG] X server not found in standard locations");
        return NO;
    }
    
    NSLog(@"[DEBUG] Found X server at: %@", xserverPath);
    
    // Create X authority file
    NSString *authFile = @"/var/run/loginwindow.auth";
    // Generate a random 32-character hex cookie using arc4random
    NSMutableString *mcookie = [NSMutableString stringWithCapacity:32];
    for (int i = 0; i < 32; i++) {
        [mcookie appendFormat:@"%x", arc4random_uniform(16)];
    }
    // Create xauth command to add cookie
    NSString *xauthCmd = [NSString stringWithFormat:@"/usr/local/bin/xauth -f %@ add :0 . %@", authFile, mcookie];
    system([xauthCmd UTF8String]);
    
    // Start X server on display :0
    pid_t xserver_pid = fork();
    if (xserver_pid == 0) {
        // Child process - start X server
        NSLog(@"[DEBUG] Starting X server");
        
        // Set up environment for X server
        setenv("DISPLAY", ":0", 1);
        
        // Close file descriptors except stdin, stdout, stderr
        int maxfd = sysconf(_SC_OPEN_MAX);
        for (int fd = 3; fd < maxfd; fd++) {
            close(fd);
        }
        
        // Ignore signals that could interfere with X server startup (like SLiM)
        signal(SIGTTIN, SIG_IGN);
        signal(SIGTTOU, SIG_IGN);
        signal(SIGUSR1, SIG_IGN);  // X server ignores this signal, doesn't use it for readiness
        signal(SIGHUP, SIG_IGN);
        
        // Create new process group
        setpgid(0, getpid());
        
        // Start X server with FreeBSD-appropriate configuration (like SLiM)
        execl([xserverPath UTF8String], "X", ":0", 
              "-auth", [authFile UTF8String],
              "-nolisten", "tcp", 
              "vt09", 
              (char *)NULL);
        
        // If we get here, exec failed
        NSLog(@"[DEBUG] Failed to exec X server: %s", strerror(errno));
        exit(1);
    } else if (xserver_pid > 0) {
        // Parent process
        NSLog(@"[DEBUG] X server started with PID: %d", xserver_pid);
        
        // Wait for X server to accept connections (like SLiM WaitForServer)
        NSLog(@"[DEBUG] Waiting for X server to accept connections");
        if (waitForXServer()) {
            NSLog(@"[DEBUG] X server successfully started and ready for connections");
            return YES;
        } else {
            NSLog(@"[DEBUG] X server failed to accept connections within timeout");
            
            // Kill the X server since it's not ready
            NSLog(@"[DEBUG] Killing unresponsive X server");
            if (kill(xserver_pid, SIGTERM) == 0) {
                sleep(2);
                kill(xserver_pid, SIGKILL);
            }
            return NO;
        }
    } else {
        NSLog(@"[DEBUG] Failed to fork for X server: %s", strerror(errno));
        return NO;
    }
}

// Global variables to track Xorg state (similar to shell script)
static pid_t global_xorg_pid = 0;
static BOOL global_we_started_xorg = NO;

// Function to start Xorg using the same logic as the shell script
BOOL startXorgLikeShellScript(void)
{
    NSLog(@"[DEBUG] Starting Xorg using shell script logic");
    
    // Check if Xorg is already running (equivalent to pgrep -q Xorg)
    FILE *pipe = popen("pgrep -q Xorg", "r");
    int pgrep_result = pclose(pipe);
    
    if (pgrep_result == 0) {
        NSLog(@"[DEBUG] Xorg already running, not starting our own instance");
        global_we_started_xorg = NO;
        return YES;
    }
    
    NSLog(@"[DEBUG] Starting Xorg server...");
    
    // Prepare log file
    const char *logfile = "/var/log/LoginWindow.log";
    unlink(logfile);
    int logfd = open(logfile, O_CREAT | O_WRONLY | O_TRUNC, 0644);
    if (logfd >= 0) {
        close(logfd);
    }
    
    // Start Xorg in background and save PID (equivalent to Xorg :0 -auth /var/run/xauth &)
    pid_t xorg_pid = fork();
    if (xorg_pid == 0) {
        // Child process - start Xorg
        // Redirect stdout and stderr to log file
        int logfd = open(logfile, O_WRONLY | O_APPEND);
        if (logfd >= 0) {
            dup2(logfd, STDOUT_FILENO);
            dup2(logfd, STDERR_FILENO);
            close(logfd);
        }
        
        // Execute Xorg
        execl("/usr/local/bin/Xorg", "Xorg", ":0", "-auth", "/var/run/xauth", (char *)NULL);
        // If exec fails, try alternative path
        execl("/usr/bin/Xorg", "Xorg", ":0", "-auth", "/var/run/xauth", (char *)NULL);
        
        // If we get here, exec failed
        NSLog(@"[ERROR] Failed to exec Xorg");
        exit(1);
    } else if (xorg_pid > 0) {
        // Parent process - save PID and mark that we started it
        global_xorg_pid = xorg_pid;
        global_we_started_xorg = YES;
        
        // Write PID to file (equivalent to echo $xorg_pid > ${xorg_pidfile})
        FILE *pidfile = fopen("/var/run/Xorg.loginwindow.pid", "w");
        if (pidfile) {
            fprintf(pidfile, "%d\n", xorg_pid);
            fclose(pidfile);
        }
        
        // Mark that we started Xorg (equivalent to touch ${xorg_started_flag})
        int flagfd = open("/var/run/loginwindow.xorg.started", O_CREAT | O_WRONLY | O_TRUNC, 0644);
        if (flagfd >= 0) {
            close(flagfd);
        }
        
        // Wait a moment for Xorg to initialize
        sleep(1);
        setenv("DISPLAY", ":0", 1);
        
        NSLog(@"[DEBUG] Xorg started with PID: %d", xorg_pid);
        return YES;
    } else {
        NSLog(@"[ERROR] Failed to fork for Xorg");
        return NO;
    }
}

// Function to stop Xorg using the same logic as the shell script
void stopXorgLikeShellScript(void)
{
    NSLog(@"[DEBUG] Stopping Xorg using shell script logic");
    
    // Stop Xorg only if we started it (equivalent to if [ -f ${xorg_started_flag} ])
    if (global_we_started_xorg && access("/var/run/loginwindow.xorg.started", F_OK) == 0) {
        NSLog(@"[DEBUG] Stopping Xorg server (we started it)...");
        
        if (global_xorg_pid > 0) {
            kill(global_xorg_pid, SIGTERM);
        } else {
            // Try to read PID from file
            FILE *pidfile = fopen("/var/run/Xorg.loginwindow.pid", "r");
            if (pidfile) {
                int pid;
                if (fscanf(pidfile, "%d", &pid) == 1 && pid > 0) {
                    kill(pid, SIGTERM);
                }
                fclose(pidfile);
            }
        }
        
        // Remove PID file (equivalent to rm -f ${xorg_pidfile})
        unlink("/var/run/Xorg.loginwindow.pid");
        
        // Remove flag file (equivalent to rm -f ${xorg_started_flag})
        unlink("/var/run/loginwindow.xorg.started");
        
        global_we_started_xorg = NO;
        global_xorg_pid = 0;
    } else {
        NSLog(@"[DEBUG] Not stopping Xorg (we didn't start it)");
    }
}

int main(int argc, const char *argv[])
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    // Start Xorg at the very beginning before anything else happens
    NSLog(@"[DEBUG] Starting Xorg management");
    
    if (!startXorgLikeShellScript()) {
        NSLog(@"[ERROR] Failed to start Xorg - LoginWindow may not work properly");
        // Continue anyway, as the existing code had fallback logic
    }
    
    // Set DISPLAY environment variable to ensure GUI apps can connect
    setenv("DISPLAY", ":0", 1);
    
    // Additional delay before starting GUI application
    NSLog(@"[DEBUG] Starting LoginWindow GUI application");
    
    [NSApplication sharedApplication];
    [NSApp setDelegate: [[LoginWindow alloc] init]];
    [NSApp run];
    
    // MOVED FROM SHELL SCRIPT: Stop Xorg when LoginWindow exits
    NSLog(@"[DEBUG] LoginWindow exiting, stopping Xorg if we started it");
    stopXorgLikeShellScript();
    
    [pool drain];
    return 0;
}
