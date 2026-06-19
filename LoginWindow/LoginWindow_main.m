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
#include <X11/Xauth.h>
#include <signal.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <dirent.h>
#include <ctype.h>
#include <string.h>
#if !defined(__linux__)
#include <sys/param.h>
#include <sys/user.h>
#include <sys/sysctl.h>
#endif

// Forward declarations of functions from this file
BOOL isXServerRunning(void);
BOOL waitForXServer(void);
BOOL startXServer(void);

// Generate 16 random bytes for MIT-MAGIC-COOKIE-1
static void main_generate_xauth_cookie(unsigned char cookie[16]) {
    int fd = open("/dev/urandom", O_RDONLY);
    if (fd >= 0) {
        ssize_t n = read(fd, cookie, 16);
        close(fd);
        if (n == 16) {
            return;
        }
    }
    // Fallback to arc4random if /dev/urandom fails
    for (int i = 0; i < 16; i++) {
        cookie[i] = (unsigned char)arc4random_uniform(256);
    }
}

// Write X authorization entry using libXau
static int main_write_xauth_entry(
    const char *authfile,
    const char *display,
    const unsigned char cookie[16]
) {
    Xauth xa;
    
    xa.family = FamilyLocal;
    
    char hostname[256];
    if (gethostname(hostname, sizeof(hostname)) != 0) {
        hostname[0] = '\0';
    }
    xa.address_length = strlen(hostname);
    xa.address = hostname;
    
    const char *dispnum = display;
    if (dispnum[0] == ':') {
        dispnum++;
    }
    char dispnum_copy[32];
    strncpy(dispnum_copy, dispnum, sizeof(dispnum_copy) - 1);
    dispnum_copy[sizeof(dispnum_copy) - 1] = '\0';
    char *dot = strchr(dispnum_copy, '.');
    if (dot) {
        *dot = '\0';
    }
    xa.number_length = strlen(dispnum_copy);
    xa.number = dispnum_copy;
    
    xa.name = "MIT-MAGIC-COOKIE-1";
    xa.name_length = strlen(xa.name);
    
    xa.data = (char *)cookie;
    xa.data_length = 16;
    
    FILE *fp = fopen(authfile, "ab");
    if (!fp) {
        NSDebugLLog(@"gwcomp", @"[MAIN XAUTH] Failed to open %s for writing: %s", authfile, strerror(errno));
        return -1;
    }
    
    int ret = XauWriteAuth(fp, &xa);
    fclose(fp);
    
    if (ret == 0) {
        NSDebugLLog(@"gwcomp", @"[MAIN XAUTH] Failed to write Xauth entry to %s", authfile);
        return -1;
    }
    
    NSDebugLLog(@"gwcomp", @"[MAIN XAUTH] Successfully wrote MIT-MAGIC-COOKIE-1 to %s for display %s", authfile, display);
    return 0;
}

// X11 I/O error handler for main - called when X connection is lost
static int mainXIOErrorHandler(Display *display) {
    NSDebugLLog(@"gwcomp", @"[ERROR] X11 I/O error in main() - X server connection lost");
    // Exit immediately to allow systemd to restart us
    exit(1);
}

// X11 error handler for main - called for non-fatal X errors
static int mainXErrorHandler(Display *display, XErrorEvent *error) {
    char error_text[256];
    XGetErrorText(display, error->error_code, error_text, sizeof(error_text));
    NSDebugLLog(@"gwcomp", @"[WARNING] X11 error in main(): %s (request: %d, minor: %d)",
          error_text, error->request_code, error->minor_code);
    return 0;
}

// Signal flag for alarm timeout
static volatile BOOL mainXOpenDisplayTimedOut = NO;

// Alarm signal handler for XOpenDisplay timeout in main
static void mainXOpenDisplayAlarmHandler(int sig) {
    mainXOpenDisplayTimedOut = YES;
}

// Safe XOpenDisplay with timeout for main - prevents indefinite hanging
static Display* mainSafeXOpenDisplay(const char *display_name, int timeout_seconds) {
    mainXOpenDisplayTimedOut = NO;
    
    // Set up alarm handler
    struct sigaction sa;
    struct sigaction old_sa;
    sa.sa_handler = mainXOpenDisplayAlarmHandler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    sigaction(SIGALRM, &sa, &old_sa);
    
    // Set alarm
    alarm(timeout_seconds);
    
    // Try to open display
    Display *display = XOpenDisplay(display_name);
    
    // Cancel alarm
    alarm(0);
    
    // Restore old handler
    sigaction(SIGALRM, &old_sa, NULL);
    
    if (mainXOpenDisplayTimedOut) {
        NSDebugLLog(@"gwcomp", @"[ERROR] XOpenDisplay timed out after %d seconds in main", timeout_seconds);
        return NULL;
    }
    
    return display;
}

// Helper function to check if a process is running by name
static BOOL isProcessRunningByName(const char *processName)
{
#if defined(__linux__)
    // Linux implementation using /proc filesystem
    DIR *proc_dir = opendir("/proc");
    if (!proc_dir) {
        return NO;
    }
    
    struct dirent *entry;
    BOOL found = NO;
    
    while ((entry = readdir(proc_dir)) != NULL) {
        // Skip non-numeric entries
        if (!isdigit(entry->d_name[0])) {
            continue;
        }
        
        pid_t pid = atoi(entry->d_name);
        
        // Skip kernel processes and init
        if (pid <= 1) {
            continue;
        }
        
        // Read /proc/PID/stat to get command name
        char stat_path[256];
        snprintf(stat_path, sizeof(stat_path), "/proc/%d/stat", pid);
        
        FILE *stat_file = fopen(stat_path, "r");
        if (!stat_file) {
            continue;
        }
        
        char comm[256];
        int parsed_pid;
        
        // Parse: pid (comm) ...
        if (fscanf(stat_file, "%d (%255[^)])", &parsed_pid, comm) == 2) {
            if (strcmp(comm, processName) == 0) {
                found = YES;
                fclose(stat_file);
                break;
            }
        }
        
        fclose(stat_file);
    }
    
    closedir(proc_dir);
    return found;
    
#else
    // BSD implementation using sysctl. OpenBSD's KERN_PROC needs a 6-element
    // mib carrying the struct size and element count; FreeBSD uses 3. The
    // command field is p_comm on OpenBSD, ki_comm on FreeBSD.
#if defined(__OpenBSD__)
    int mib[6] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0,
                  sizeof(struct kinfo_proc), 0};
    int miblen = 6;
#else
    int mib[3] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL};
    int miblen = 3;
#endif
    size_t size = 0;

    if (sysctl(mib, miblen, NULL, &size, NULL, 0) != 0) {
        return NO;
    }

    struct kinfo_proc *procs = malloc(size);
    if (!procs) {
        return NO;
    }

#if defined(__OpenBSD__)
    mib[5] = (int)(size / sizeof(struct kinfo_proc));
#endif
    if (sysctl(mib, miblen, procs, &size, NULL, 0) != 0) {
        free(procs);
        return NO;
    }

    int numProcs = size / sizeof(struct kinfo_proc);
    BOOL found = NO;

    for (int i = 0; i < numProcs; i++) {
#if defined(__OpenBSD__)
        const char *pcomm = procs[i].p_comm;
#else
        const char *pcomm = procs[i].ki_comm;
#endif
        if (strcmp(pcomm, processName) == 0) {
            found = YES;
            break;
        }
    }

    free(procs);
    return found;
#endif
}

BOOL isXServerRunning(void)
{
    NSDebugLLog(@"gwcomp", @"[DEBUG] Checking if X server is running");
    
    // First check if there's a lock file indicating X server should be running
    if ([[NSFileManager defaultManager] fileExistsAtPath:@"/tmp/.X0-lock"]) {
        NSDebugLLog(@"gwcomp", @"[DEBUG] Found X server lock file at /tmp/.X0-lock");
        
        // Read the PID from the lock file to see if the process is actually running
        NSString *lockContent = [NSString stringWithContentsOfFile:@"/tmp/.X0-lock" 
                                                           encoding:NSUTF8StringEncoding 
                                                              error:nil];
        if (lockContent) {
            pid_t xpid = [lockContent intValue];
            if (xpid > 0 && kill(xpid, 0) == 0) {
                NSDebugLLog(@"gwcomp", @"[DEBUG] X server process %d is running according to lock file", xpid);
            } else {
                NSDebugLLog(@"gwcomp", @"[DEBUG] X server lock file exists but process %d is not running - removing stale lock", xpid);
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
            NSDebugLLog(@"gwcomp", @"[DEBUG] Using X authority file: %@", authPath);
            break;
        }
    }
    
    // Try to open X display with timeout
    Display *testDisplay = mainSafeXOpenDisplay(display_name, 2);  // 2 second timeout
    if (testDisplay != NULL) {
        XCloseDisplay(testDisplay);
        NSDebugLLog(@"gwcomp", @"[DEBUG] X server is running and accessible on %s", display_name);
        return YES;
    } else {
        NSDebugLLog(@"gwcomp", @"[DEBUG] Cannot connect to X server on %s (may not be running or auth issue)", display_name);
        return NO;
    }
}

// Function to wait for X server to accept connections (like SLiM WaitForServer)
BOOL waitForXServer(void)
{
    NSDebugLLog(@"gwcomp", @"[DEBUG] Waiting for X server to accept connections");
    int attempts = 0;
    int maxAttempts = 120; // 120 seconds timeout like SLiM
    
    for (attempts = 0; attempts < maxAttempts; attempts++) {
        Display *testDisplay = mainSafeXOpenDisplay(":0", 2);  // 2 second timeout per attempt
        if (testDisplay != NULL) {
            XCloseDisplay(testDisplay);
            NSDebugLLog(@"gwcomp", @"[DEBUG] X server is now accepting connections after %d attempts", attempts + 1);
            return YES;
        }
        
        if (attempts % 10 == 0 && attempts > 0) {
            NSDebugLLog(@"gwcomp", @"[DEBUG] Still waiting for X server to accept connections (attempt %d/%d)", attempts, maxAttempts);
        }
        
        sleep(1);
    }
    
    NSDebugLLog(@"gwcomp", @"[DEBUG] X server failed to accept connections within timeout");
    return NO;
}

BOOL startXServer(void)
{
    NSDebugLLog(@"gwcomp", @"[DEBUG] Starting X server");
    
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
        NSDebugLLog(@"gwcomp", @"[DEBUG] X server not found in standard locations");
        return NO;
    }
    
    NSDebugLLog(@"gwcomp", @"[DEBUG] Found X server at: %@", xserverPath);
    
    // Create X authority file using libXau (no external xauth command needed)
    NSString *authFile = @"/var/run/loginwindow.auth";
    
    // Remove any existing auth file to start fresh
    unlink([authFile UTF8String]);
    
    // Generate a secure 16-byte MIT-MAGIC-COOKIE-1
    unsigned char cookie[16];
    main_generate_xauth_cookie(cookie);
    
    // Write the cookie to the X server's auth file
    if (main_write_xauth_entry([authFile UTF8String], ":0", cookie) != 0) {
        NSDebugLLog(@"gwcomp", @"[ERROR] Failed to create X authorization file");
        return NO;
    }
    
    // Set proper permissions on auth file
    chmod([authFile UTF8String], 0600);
    
    NSDebugLLog(@"gwcomp", @"[DEBUG] Created X authorization file at %@ using libXau", authFile);
    
    // Start X server on display :0
    pid_t xserver_pid = fork();
    if (xserver_pid == 0) {
        // Child process - start X server
        NSDebugLLog(@"gwcomp", @"[DEBUG] Starting X server");
        
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
        NSDebugLLog(@"gwcomp", @"[DEBUG] Failed to exec X server: %s", strerror(errno));
        exit(1);
    } else if (xserver_pid > 0) {
        // Parent process
        NSDebugLLog(@"gwcomp", @"[DEBUG] X server started with PID: %d", xserver_pid);
        
        // Wait for X server to accept connections (like SLiM WaitForServer)
        NSDebugLLog(@"gwcomp", @"[DEBUG] Waiting for X server to accept connections");
        if (waitForXServer()) {
            NSDebugLLog(@"gwcomp", @"[DEBUG] X server successfully started and ready for connections");
            return YES;
        } else {
            NSDebugLLog(@"gwcomp", @"[DEBUG] X server failed to accept connections within timeout");
            
            // Kill the X server since it's not ready
            NSDebugLLog(@"gwcomp", @"[DEBUG] Killing unresponsive X server");
            if (kill(xserver_pid, SIGTERM) == 0) {
                sleep(2);
                kill(xserver_pid, SIGKILL);
            }
            return NO;
        }
    } else {
        NSDebugLLog(@"gwcomp", @"[DEBUG] Failed to fork for X server: %s", strerror(errno));
        return NO;
    }
}

// Global variables to track Xorg state (similar to shell script)
static pid_t global_xorg_pid = 0;
static BOOL global_we_started_xorg = NO;

// Function to start Xorg using the same logic as the shell script
BOOL startXorgLikeShellScript(void)
{
    NSDebugLLog(@"gwcomp", @"[DEBUG] Starting Xorg using shell script logic");
    
    // Check if Xorg is already running using native code
    if (isProcessRunningByName("Xorg")) {
        NSDebugLLog(@"gwcomp", @"[DEBUG] Xorg already running, not starting our own instance");
        global_we_started_xorg = NO;
        return YES;
    }
    
    NSDebugLLog(@"gwcomp", @"[DEBUG] Starting Xorg server...");
    
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
        NSDebugLLog(@"gwcomp", @"[ERROR] Failed to exec Xorg");
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
        
        NSDebugLLog(@"gwcomp", @"[DEBUG] Xorg started with PID: %d", xorg_pid);
        return YES;
    } else {
        NSDebugLLog(@"gwcomp", @"[ERROR] Failed to fork for Xorg");
        return NO;
    }
}

// Function to stop Xorg using the same logic as the shell script
void stopXorgLikeShellScript(void)
{
    NSDebugLLog(@"gwcomp", @"[DEBUG] Stopping Xorg using shell script logic");
    
    // Stop Xorg only if we started it (equivalent to if [ -f ${xorg_started_flag} ])
    if (global_we_started_xorg && access("/var/run/loginwindow.xorg.started", F_OK) == 0) {
        NSDebugLLog(@"gwcomp", @"[DEBUG] Stopping Xorg server (we started it)...");
        
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
        NSDebugLLog(@"gwcomp", @"[DEBUG] Not stopping Xorg (we didn't start it)");
    }
}

int main(int argc, const char *argv[])
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    // Install X11 error handlers FIRST before any X operations
    XSetIOErrorHandler(mainXIOErrorHandler);
    XSetErrorHandler(mainXErrorHandler);
    NSDebugLLog(@"gwcomp", @"[DEBUG] X11 error handlers installed in main()");
    
    // Start Xorg at the very beginning before anything else happens
    NSDebugLLog(@"gwcomp", @"[DEBUG] Starting Xorg management");
    
    if (!startXorgLikeShellScript()) {
        NSDebugLLog(@"gwcomp", @"[ERROR] Failed to start Xorg - LoginWindow may not work properly");
        // Continue anyway, as the existing code had fallback logic
    }
    
    // Set DISPLAY environment variable to ensure GUI apps can connect
    setenv("DISPLAY", ":0", 1);
    
    // Additional delay before starting GUI application
    NSDebugLLog(@"gwcomp", @"[DEBUG] Starting LoginWindow GUI application");
    
    [NSApplication sharedApplication];
    [NSApp setDelegate: [[LoginWindow alloc] init]];
    [NSApp run];
    
    // MOVED FROM SHELL SCRIPT: Stop Xorg when LoginWindow exits
    NSDebugLLog(@"gwcomp", @"[DEBUG] LoginWindow exiting, stopping Xorg if we started it");
    stopXorgLikeShellScript();
    
    [pool drain];
    return 0;
}
