#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import "LoginWindow.h"
#include <X11/Xlib.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>
#include <errno.h>

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

int main(int argc, const char *argv[])
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    // CRITICAL: Start X server at the very beginning before any GUI operations
    NSLog(@"[DEBUG] Ensuring X server is running before starting LoginWindow");
    
    // First check if we can connect to existing X server
    if (!isXServerRunning()) {
        NSLog(@"[DEBUG] X server is not accessible, attempting to start it");
        
        if (!startXServer()) {
            NSLog(@"[ERROR] Failed to start X server - LoginWindow may not work properly");
            // Try to create a minimal auth file as fallback
            NSLog(@"[DEBUG] Creating fallback X authority file");
            system("touch /tmp/loginwindow.auth");
            system("chmod 600 /tmp/loginwindow.auth");
            setenv("XAUTHORITY", "/tmp/loginwindow.auth", 1);
        } else {
            // Give X server additional time to fully initialize after being ready
            NSLog(@"[DEBUG] X server started successfully, waiting additional 2 seconds for full initialization");
            sleep(2);
        }
    } else {
        NSLog(@"[DEBUG] X server is already running and accessible");
    }
    
    // Set DISPLAY environment variable to ensure GUI apps can connect
    setenv("DISPLAY", ":0", 1);
    
    // Additional delay before starting GUI application
    NSLog(@"[DEBUG] Starting LoginWindow GUI application");
    
    [NSApplication sharedApplication];
    [NSApp setDelegate: [[LoginWindow alloc] init]];
    [NSApp run];
    
    [pool drain];
    return 0;
}
