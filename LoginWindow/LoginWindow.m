/*
 * Copyright (c) 2025-26 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "LoginWindow.h"
#import <pwd.h>
#import <unistd.h>
#import <sys/wait.h>
#import <sys/stat.h>
#if !defined(__linux__)
#import <login_cap.h>
#import <sys/sysctl.h>
#import <sys/user.h>
#if defined(__OpenBSD__)
#import <util.h>
// OpenBSD's struct kinfo_proc uses p_* field names (and p__pgid, since
// <sys/proc.h> hijacks p_pgid); FreeBSD uses ki_*.
#define GW_KP_PID   p_pid
#define GW_KP_PPID  p_ppid
#define GW_KP_SID   p_sid
#define GW_KP_PGID  p__pgid
#define GW_KP_COMM  p_comm
#else
#import <libutil.h>
#define GW_KP_PID   ki_pid
#define GW_KP_PPID  ki_ppid
#define GW_KP_SID   ki_sid
#define GW_KP_PGID  ki_pgid
#define GW_KP_COMM  ki_comm
#endif
#endif
#import <string.h>
#import <grp.h>
#import <errno.h>
#import <signal.h>
#import <fcntl.h>
#import <limits.h>
#import <stdlib.h>
#import <X11/Xlib.h>
#import <X11/Xauth.h>
#import <X11/cursorfont.h>
#import <X11/Xatom.h>
#import <GNUstepGUI/GSDisplayServer.h>
#if defined(__linux__)
#import <dirent.h>
#import <ctype.h>
#endif

#ifdef HAVE_SHADOW
#import <shadow.h>
#endif

// Global flag to track X I/O errors
static volatile BOOL xIOErrorOccurred = NO;

// Signal flag for alarm timeout
static volatile BOOL xOpenDisplayTimedOut = NO;

// Alarm signal handler for XOpenDisplay timeout
static void xOpenDisplayAlarmHandler(int sig) {
    xOpenDisplayTimedOut = YES;
    NSDebugLLog(@"gwcomp", @"[ERROR] XOpenDisplay timed out");
}

// X11 I/O error handler - called when X connection is lost
static int xIOErrorHandler(Display *display) {
    NSDebugLLog(@"gwcomp", @"[ERROR] X11 I/O error detected - X server connection lost");
    xIOErrorOccurred = YES;
    
    // Exit immediately to allow systemd to restart us
    // This prevents hanging when X server dies
    exit(1);
}

// X11 error handler - called for non-fatal X errors
static int xErrorHandler(Display *display, XErrorEvent *error) {
    char error_text[256];
    XGetErrorText(display, error->error_code, error_text, sizeof(error_text));
    NSDebugLLog(@"gwcomp", @"[WARNING] X11 error: %s (request code: %d, minor code: %d)",
          error_text, error->request_code, error->minor_code);
    
    // Return 0 to continue execution for non-fatal errors
    return 0;
}

// Generate 16 random bytes for MIT-MAGIC-COOKIE-1
static void generate_xauth_cookie(unsigned char cookie[16]) {
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

// Global storage for the current X server cookie (shared between X server and user sessions)
static unsigned char g_xserver_cookie[16];
static BOOL g_xserver_cookie_valid = NO;

// Check if /tmp is writable by actually creating, writing to, and removing a temporary file
static BOOL isTmpWritable(void) {
    const char *dir = "/tmp";
    char tmpPath[PATH_MAX];

    // Create a unique temporary file template
    int len = snprintf(tmpPath, sizeof(tmpPath), "%s/loginwindow.XXXXXX", dir);
    if (len <= 0 || len >= (int)sizeof(tmpPath)) {
        return NO;
    }

    int fd = mkstemp(tmpPath);
    if (fd < 0) {
        // Could not create file - not writable or security restrictions
        return NO;
    }

    // Try writing a single byte and syncing to ensure real write worked
    ssize_t nw = write(fd, "x", 1);
    fsync(fd);
    close(fd);

    // Remove the temporary file
    unlink(tmpPath);

    return (nw == 1);
}

// Wait for /tmp to be writable with progress indicator
// Timeout is in seconds, checks every 0.1 seconds with dot progress
static void waitForTmpWritable(int timeoutSeconds) {
    int maxChecks = timeoutSeconds * 10;  // 10 checks per second (0.1 second interval)
    int checksPerDot = 5;                  // Print a dot every 0.5 seconds
    int dotCount = 0;

    for (int i = 0; i < maxChecks; i++) {
        if (isTmpWritable()) {
            NSDebugLLog(@"gwcomp", @"[INFO] /tmp is now writable (ready after %.1f seconds)", (float)i / 10.0);
            return;
        }

        // Print progress indicator
        if (i > 0 && (i % checksPerDot) == 0) {
            fprintf(stderr, ".");
            fflush(stderr);
            dotCount++;
        }

        // Sleep for 0.1 seconds
        usleep(100000);  // 100,000 microseconds = 0.1 seconds
    }

    // Timeout reached
    if (dotCount > 0) {
        fprintf(stderr, "\n");
        fflush(stderr);
    }
    NSDebugLLog(@"gwcomp", @"[WARNING] Timeout waiting for /tmp to be writable (waited %d seconds)", timeoutSeconds);
}

// Safe XOpenDisplay with timeout - prevents indefinite hanging
static Display* safeXOpenDisplay(const char *display_name, int timeout_seconds) {
    xOpenDisplayTimedOut = NO;
    
    // Set up alarm handler
    struct sigaction sa;
    struct sigaction old_sa;
    sa.sa_handler = xOpenDisplayAlarmHandler;
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
    
    if (xOpenDisplayTimedOut) {
        NSDebugLLog(@"gwcomp", @"[ERROR] XOpenDisplay timed out after %d seconds", timeout_seconds);
        return NULL;
    }
    
    return display;
}

// Signal handler for cleanup on termination
void signalHandler(int sig) {
    NSDebugLLog(@"gwcomp", @"[DEBUG] Received signal %d, performing cleanup", sig);
    // We can't safely call Objective-C methods from a signal handler,
    // but we can at least try to kill processes using the global variables
    // Note: This is not the safest approach, but it's better than nothing
    if (sig == SIGTERM || sig == SIGINT) {
        exit(0); // This will trigger applicationWillTerminate
    } else if (sig == SIGCHLD) {
        // Child process died - we'll handle this in the main event loop
        // Don't do complex operations in signal handler
    }
}

@implementation LoginWindow

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
    pamAuth = [[LoginWindowPAM alloc] init];
    NSDebugLLog(@"gwcomp", @"[DEBUG] pamAuth initialized: %@", pamAuth);
    sessionPid = 0;
    sessionUid = 0;
    sessionGid = 0;
    sessionStartTime = nil;
    didStartXServer = NO;
    xServerPid = 0;
    isTerminating = NO;
    
    // Install X11 error handlers FIRST to prevent hanging if X dies
    XSetIOErrorHandler(xIOErrorHandler);
    XSetErrorHandler(xErrorHandler);
    NSDebugLLog(@"gwcomp", @"[DEBUG] X11 error handlers installed");
    
    // Set up signal handlers for cleanup
    signal(SIGTERM, signalHandler);
    signal(SIGINT, signalHandler);
    signal(SIGCHLD, signalHandler);
    
    // X server should already be running from main() - just verify
    if (![self isXServerRunning]) {
        NSDebugLLog(@"gwcomp", @"[WARNING] X server is not running even after main() startup attempt");
    }
    
    [self createLoginWindow];
    
    // Validate LoginWindow.plist security BEFORE anything accesses it
    if (![self validateLoginWindowPreferencesFile]) {
        NSDebugLLog(@"gwcomp", @"[WARNING] LoginWindow.plist validation failed, skipping auto-login");
    } else {
        // Check for auto-login user after window is created but before showing it
        [self checkAutoLogin];
    }
    
    // Set X11 background to mid grey BEFORE showing the window
    [self setX11BackgroundMidGrey];
    
    [loginWindow makeKeyAndOrderFront:self];
    [NSApp activateIgnoringOtherApps:YES];

    // Explicitly set _NET_ACTIVE_WINDOW to our login window for X11 focus
    Display *display = safeXOpenDisplay(NULL, 5);
    if (display) {
        Window root = DefaultRootWindow(display);
        Atom netActiveWindow = XInternAtom(display, "_NET_ACTIVE_WINDOW", False);
        
        // Use GNUstep's way to get the X11 window ID
        GSDisplayServer *srv = GSServerForWindow(loginWindow);
        if (srv) {
            Window xid = (Window)(uintptr_t)[srv windowDevice:[loginWindow windowNumber]];
            if (xid) {
                XChangeProperty(display, root, netActiveWindow, XA_WINDOW, 32,
                               PropModeReplace, (unsigned char*)&xid, 1);
                
                // Also set input focus directly as there is no window manager
                XSetInputFocus(display, xid, RevertToParent, CurrentTime);
                
                NSDebugLLog(@"gwcomp", @"[DEBUG] Set _NET_ACTIVE_WINDOW and input focus to login window 0x%lx", xid);
            }
        }
        
        XFlush(display);
        XCloseDisplay(display);
    }
}

- (void)setX11BackgroundMidGrey
{
    NSDebugLLog(@"gwcomp", @"[DEBUG] Setting X11 background to mid grey with persistent pixmap and cursor");
    
    Display *display = safeXOpenDisplay(NULL, 5);  // 5 second timeout
    if (!display) {
        NSDebugLLog(@"gwcomp", @"[WARNING] Could not open X display");
        return;
    }

    // Set close down mode to RetainPermanent so resources persist after disconnect
    XSetCloseDownMode(display, RetainPermanent);
    
    int screen_count = ScreenCount(display);
    NSDebugLLog(@"gwcomp", @"[DEBUG] Found %d X11 screen(s)", screen_count);
    
    for (int i = 0; i < screen_count; i++) {
        int screen = i;
        Window root = RootWindow(display, screen);
        Colormap colormap = DefaultColormap(display, screen);
        
        // Mid grey: RGB(128, 128, 128) = 0x808080
        XColor color;
        color.red = 0x8080;
        color.green = 0x8080;
        color.blue = 0x8080;
        color.flags = DoRed | DoGreen | DoBlue;
        
        if (!XAllocColor(display, colormap, &color)) {
            NSDebugLLog(@"gwcomp", @"[WARNING] Could not allocate mid grey color on screen %d", i);
            continue;
        }
        
        NSDebugLLog(@"gwcomp", @"[DEBUG] Allocated color pixel: 0x%lx on screen %d", color.pixel, i);
        
        // Create a 1x1 pixmap with the mid-grey color
        unsigned int depth = DefaultDepth(display, screen);
        Pixmap pixmap = XCreatePixmap(display, root, 1, 1, depth);
        
        if (!pixmap) {
            NSDebugLLog(@"gwcomp", @"[WARNING] Could not create pixmap on screen %d", i);
            continue;
        }
        
        NSDebugLLog(@"gwcomp", @"[DEBUG] Created pixmap 0x%lx on screen %d", pixmap, i);
        
        // Fill the pixmap with the mid-grey color
        GC gc = XCreateGC(display, pixmap, 0, NULL);
        XSetForeground(display, gc, color.pixel);
        XFillRectangle(display, pixmap, gc, 0, 0, 1, 1);
        XFreeGC(display, gc);
        
        // Set the root window's background to use this pixmap
        XSetWindowBackgroundPixmap(display, root, pixmap);
        XClearWindow(display, root);
        
        // Free the pixmap (it will persist due to RetainPermanent mode)
        XFreePixmap(display, pixmap);
        
        NSDebugLLog(@"gwcomp", @"[DEBUG] Screen %d root window background set with persistent pixmap", i);

        // Set the standard arrow cursor (XC_left_ptr) on the root window
        Cursor cursor = XCreateFontCursor(display, XC_left_ptr);
        if (cursor) {
            XDefineCursor(display, root, cursor);
            XFreeCursor(display, cursor);
            NSDebugLLog(@"gwcomp", @"[DEBUG] Standard arrow cursor set on screen %d root window", i);
        } else {
            NSDebugLLog(@"gwcomp", @"[WARNING] Could not create standard arrow cursor on screen %d", i);
        }
    }
    
    XFlush(display);
    XSync(display, False);
    XCloseDisplay(display);
    
    NSDebugLLog(@"gwcomp", @"[DEBUG] X11 background set to mid grey with persistent pixmap");
}

- (void)dealloc
{
    [pamAuth release];
    [super dealloc];
}

- (void)applicationWillTerminate:(NSNotification *)notification
{
    NSDebugLLog(@"gwcomp", @"[DEBUG] Application terminating, performing session cleanup");
    
    // Set terminating flag to prevent window recreation
    isTerminating = YES;
    
    // If we have an active session, kill all its processes
    if (sessionUid > 0) {
        NSDebugLLog(@"gwcomp", @"[DEBUG] Cleaning up active session for UID: %d", sessionUid);
        [self killAllSessionProcesses:sessionUid];
        
        // Close PAM session if still open
        if (pamAuth) {
            [pamAuth closeSession];
            NSDebugLLog(@"gwcomp", @"[DEBUG] PAM session closed during termination");
        }
    }
    
    // Stop X server if we started it
    [self stopXServerIfStartedByUs];
}

- (void)scanAvailableSessions
{
    NSDebugLLog(@"gwcomp", @"[DEBUG] scanAvailableSessions started");
    NSMutableArray *sessions = [NSMutableArray array];
    NSMutableArray *execs = [NSMutableArray array];
    NSArray *dirs = @[ @"/usr/local/share/xsessions", @"/usr/share/xsessions" ];
    NSFileManager *fm = [NSFileManager defaultManager];
    
    for (NSString *dir in dirs) {
        NSDebugLLog(@"gwcomp", @"[DEBUG] Checking directory: %@", dir);
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:dir isDirectory:&isDir] && isDir) {
            NSDebugLLog(@"gwcomp", @"[DEBUG] Directory exists: %@", dir);
            NSArray *files = [fm contentsOfDirectoryAtPath:dir error:nil];
            NSDebugLLog(@"gwcomp", @"[DEBUG] Found %lu files in %@", (unsigned long)[files count], dir);
            for (NSString *file in files) {
                if ([file hasSuffix:@".desktop"]) {
                    NSDebugLLog(@"gwcomp", @"[DEBUG] Processing .desktop file: %@", file);
                    NSString *path = [dir stringByAppendingPathComponent:file];
                    NSString *name = nil;
                    NSString *exec = nil;
                    NSString *content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
                    NSArray *lines = [content componentsSeparatedByString:@"\n"];
                    for (NSString *line in lines) {
                        if ([line hasPrefix:@"Name="]) {
                            name = [line substringFromIndex:5];
                            NSDebugLLog(@"gwcomp", @"[DEBUG] Found Name: %@", name);
                        } else if ([line hasPrefix:@"Exec="]) {
                            // Extract the command portion (first token) and strip field codes
                            NSString *rawExec = [line substringFromIndex:5];
                            NSArray *components = [rawExec componentsSeparatedByString:@" "];
                            if ([components count] > 0) {
                                exec = [[components objectAtIndex:0] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                                // Remove common desktop file field codes if accidentally part of the command
                                exec = [exec stringByReplacingOccurrencesOfString:@"%U" withString:@"" options:NSLiteralSearch range:NSMakeRange(0, [exec length])];
                                exec = [exec stringByReplacingOccurrencesOfString:@"%u" withString:@"" options:NSLiteralSearch range:NSMakeRange(0, [exec length])];
                                exec = [exec stringByReplacingOccurrencesOfString:@"%F" withString:@"" options:NSLiteralSearch range:NSMakeRange(0, [exec length])];
                                exec = [exec stringByReplacingOccurrencesOfString:@"%f" withString:@"" options:NSLiteralSearch range:NSMakeRange(0, [exec length])];
                                exec = [exec stringByReplacingOccurrencesOfString:@"%i" withString:@"" options:NSLiteralSearch range:NSMakeRange(0, [exec length])];
                                exec = [exec stringByReplacingOccurrencesOfString:@"%c" withString:@"" options:NSLiteralSearch range:NSMakeRange(0, [exec length])];
                                exec = [exec stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                            } else {
                                exec = [rawExec stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                            }
                            NSDebugLLog(@"gwcomp", @"[DEBUG] Found Exec (parsed): %@ (raw: %@)", exec, rawExec);
                        }
                    }
                    if (name && exec) {
                        // Skip placeholder or invalid Exec entries (e.g., "default")
                        if ([[exec lowercaseString] isEqualToString:@"default"] || [exec length] == 0) {
                            NSDebugLLog(@"gwcomp", @"[DEBUG] Skipping session '%@' because Exec is a placeholder or empty: %@", name, exec);
                        } else {
                            NSDebugLLog(@"gwcomp", @"[DEBUG] Adding session: %@ -> %@", name, exec);
                            [sessions addObject:name];
                            [execs addObject:exec];
                        }
                    }
                }
            }
        } else {
            NSDebugLLog(@"gwcomp", @"[DEBUG] Directory does not exist or is not a directory: %@", dir);
        }
    }
    
    if ([sessions count] == 0) {
        NSDebugLLog(@"gwcomp", @"[DEBUG] No sessions found in .desktop files, adding defaults");
        [sessions addObject:@"Gershwin"];
        [execs addObject:@"/System/Library/Scripts/Gershwin.sh"];
    }
    
    // Check if Gershwin.sh exists and add it if found
    if ([[NSFileManager defaultManager] fileExistsAtPath:@"/System/Library/Scripts/Gershwin.sh"]) {
        // Check if "Gershwin" is already in the list to avoid duplicates
        NSUInteger gershwinIndex = [sessions indexOfObject:@"Gershwin"];
        if (gershwinIndex != NSNotFound) {
            // Replace existing Gershwin entry with the /System version
            [execs replaceObjectAtIndex:gershwinIndex withObject:@"/System/Library/Scripts/Gershwin.sh"];
            NSDebugLLog(@"gwcomp", @"[DEBUG] Replaced existing Gershwin session with /System/Library/Scripts/Gershwin.sh");
        } else {
            // Add new Gershwin entry
            [sessions addObject:@"Gershwin"];
            [execs addObject:@"/System/Library/Scripts/Gershwin-X11"];
            NSDebugLLog(@"gwcomp", @"[DEBUG] Added Gershwin session: /System/Library/Scripts/Gershwin-X11");
        }
    }
    
    availableSessions = [sessions copy];
    availableSessionExecs = [execs copy];
    selectedSessionExec = [execs firstObject];
    
    NSDebugLLog(@"gwcomp", @"[DEBUG] Final available sessions: %@", availableSessions);
    NSDebugLLog(@"gwcomp", @"[DEBUG] Final available execs: %@", availableSessionExecs);
    NSDebugLLog(@"gwcomp", @"[DEBUG] Initial selected exec: %@", selectedSessionExec);
}

- (void)createLoginWindow
{
    [self scanAvailableSessions];
    
    NSRect windowFrame = NSMakeRect(0, 0, 400, 310);
    
    char hostname[256] = "";
    gethostname(hostname, sizeof(hostname));
    NSString *computerName = [NSString stringWithUTF8String:hostname];
    loginWindow = [[NSWindow alloc] 
        initWithContentRect:windowFrame
                  styleMask:(NSWindowStyleMaskTitled)
                    backing:NSBackingStoreBuffered
                      defer:NO];
    [loginWindow setTitle:computerName];
    [loginWindow setBackgroundColor:[NSColor colorWithCalibratedRed:0.95 green:0.95 blue:0.95 alpha:1.0]];
    [loginWindow setLevel:NSScreenSaverWindowLevel];
    [loginWindow setCanHide:NO];
    [loginWindow setDelegate:self];

    // Golden ratio vertical positioning
    NSScreen *mainScreen = [NSScreen mainScreen];
    NSRect screenFrame = [mainScreen frame];
    CGFloat goldenRatio = 0.618;
    CGFloat windowX = (screenFrame.size.width - windowFrame.size.width) / 2.0;
    CGFloat windowY = screenFrame.origin.y + (screenFrame.size.height - windowFrame.size.height) * goldenRatio;
    [loginWindow setFrameOrigin:NSMakePoint(windowX, windowY)];

    [loginWindow makeKeyAndOrderFront:self];
    [loginWindow makeMainWindow];
    [loginWindow setIgnoresMouseEvents:NO];
    [loginWindow setAcceptsMouseMovedEvents:YES];
    
    NSView *contentView = [loginWindow contentView];
    
    // Title
    NSTextField *titleLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(50, 230+12, 300, 40)];
    [titleLabel setStringValue:computerName];
    [titleLabel setAlignment:NSCenterTextAlignment];
    [titleLabel setFont:[NSFont boldSystemFontOfSize:24]];
    [titleLabel setBezeled:NO];
    [titleLabel setDrawsBackground:NO];
    [titleLabel setEditable:NO];
    [titleLabel setSelectable:NO];
    [contentView addSubview:titleLabel];

    // Username field
    NSTextField *usernameLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(50, 180+12, 100, 20)];
    [usernameLabel setStringValue:@"Username:"];
    [usernameLabel setBezeled:NO];
    [usernameLabel setDrawsBackground:NO];
    [usernameLabel setEditable:NO];
    [usernameLabel setSelectable:NO];
    [contentView addSubview:usernameLabel];

    usernameField = [[NSTextField alloc] initWithFrame:NSMakeRect(160, 180+12, 190, 22)];
    [usernameField setBezeled:YES];
    [usernameField setBezelStyle:NSTextFieldSquareBezel];
    [usernameField setEditable:YES];
    [usernameField setSelectable:YES];
    [usernameField setEnabled:YES];
    [usernameField setDelegate:self];
    [contentView addSubview:usernameField];

    // Password field
    NSTextField *passwordLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(50, 150+12, 100, 20)];
    [passwordLabel setStringValue:@"Password:"];
    [passwordLabel setBezeled:NO];
    [passwordLabel setDrawsBackground:NO];
    [passwordLabel setEditable:NO];
    [passwordLabel setSelectable:NO];
    [contentView addSubview:passwordLabel];

    passwordField = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(160, 150+12, 190, 22)];
    [passwordField setBezeled:YES];
    [passwordField setBezelStyle:NSTextFieldSquareBezel];
    [passwordField setEditable:YES];
    [passwordField setSelectable:YES];
    [passwordField setEnabled:YES];
    [passwordField setDelegate:self];
    [contentView addSubview:passwordField];

    // Session dropdown
    BOOL showDropdown = [availableSessions count] > 1;
    if (showDropdown) {
        sessionDropdown = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(50, 110+12, 300, 24)];
        [sessionDropdown addItemsWithTitles:availableSessions];
        
        // Load last chosen session and select it
        NSString *lastSession = [self loadLastSession];
        if (lastSession) {
            NSUInteger lastSessionIndex = [availableSessionExecs indexOfObject:lastSession];
            if (lastSessionIndex != NSNotFound) {
                [sessionDropdown selectItemAtIndex:lastSessionIndex];
                selectedSessionExec = [availableSessionExecs objectAtIndex:lastSessionIndex];
                NSDebugLLog(@"gwcomp", @"[DEBUG] Pre-selected last chosen session: %@", lastSession);
            } else {
                NSDebugLLog(@"gwcomp", @"[DEBUG] Last chosen session not found in available sessions: %@", lastSession);
            }
        }
        
        [sessionDropdown setTarget:self];
        [sessionDropdown setAction:@selector(sessionChanged:)];
        [contentView addSubview:sessionDropdown];
        statusLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(50, 40+12, 300, 20)];
    } else {
        statusLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(50, 60+12, 300, 20)];
    }
    [statusLabel setStringValue:@""];
    [statusLabel setAlignment:NSCenterTextAlignment];
    [statusLabel setBezeled:NO];
    [statusLabel setDrawsBackground:NO];
    [statusLabel setEditable:NO];
    [statusLabel setSelectable:NO];
    [contentView addSubview:statusLabel];

    // Button layout with standard spacing
    CGFloat buttonWidth = 80;
    CGFloat buttonHeight = 24; // Standard button height
    CGFloat buttonSpacing = 12; // Standard button spacing
    CGFloat bottomMargin = 20; // Standard bottom margin  
    CGFloat leftX = 24; // Standard left margin
    CGFloat buttonY = bottomMargin;
    CGFloat rightX = windowFrame.size.width - buttonWidth - 24; // Standard right margin

    shutdownButton = [[NSButton alloc] initWithFrame:NSMakeRect(leftX, buttonY, buttonWidth, buttonHeight)];
    [shutdownButton setTitle:@"Shut Down"];
    [shutdownButton setTarget:self];
    [shutdownButton setAction:@selector(shutdownButtonPressed:)];
    [contentView addSubview:shutdownButton];

    restartButton = [[NSButton alloc] initWithFrame:NSMakeRect(leftX + buttonWidth + buttonSpacing, buttonY, buttonWidth, buttonHeight)];
    [restartButton setTitle:@"Restart"];
    [restartButton setTarget:self];
    [restartButton setAction:@selector(restartButtonPressed:)];
    [contentView addSubview:restartButton];

    loginButton = [[NSButton alloc] initWithFrame:NSMakeRect(rightX, buttonY, buttonWidth, buttonHeight)];
    [loginButton setTitle:@"Login"];
    [loginButton setTarget:self];
    [loginButton setAction:@selector(loginButtonPressed:)];
    [loginButton setKeyEquivalent:@"\r"];
    [loginButton setEnabled:NO]; // Initially disabled
    [loginButton setShowsBorderOnlyWhileMouseInside:NO];
    [contentView addSubview:loginButton];
    
    // Set initial focus
    [loginWindow makeFirstResponder:usernameField];
    // Make window key and main to accept input
    [loginWindow makeKeyAndOrderFront:self];
    [loginWindow setIgnoresMouseEvents:NO];
    [loginWindow setAcceptsMouseMovedEvents:YES];
    
    [usernameField setNextKeyView:passwordField];
    [passwordField setNextKeyView:usernameField];
    
    // Load and pre-fill last logged-in user
    NSString *lastUser = [self loadLastLoggedInUser];
    if (lastUser) {
        [usernameField setStringValue:lastUser];
        NSDebugLLog(@"gwcomp", @"[DEBUG] Pre-filled username field with last logged-in user: %@", lastUser);
        // If username is pre-filled, focus on password field instead
        [loginWindow makeFirstResponder:passwordField];
    } else {
        // No last user, focus on username field
        [loginWindow makeFirstResponder:usernameField];
    }
    
    // Update login button state after setting up fields
    [self updateLoginButtonState];
}

- (void)loginButtonPressed:(id)sender
{
    NSDebugLLog(@"gwcomp", @"[DEBUG] loginButtonPressed called");
    NSString *username = [usernameField stringValue];
    NSString *password = [passwordField stringValue];
    
    if ([username length] == 0) {
        [self showStatus:@"Please enter username"];
        [self shakeWindow];
        return;
    }
        
    // Attempting authentication — empty password is allowed by design for some environments
    // (e.g., GhostBSD Live ISOs) where PAM permits passwordless login.
    NSDebugLLog(@"gwcomp", @"[DEBUG] authenticateUser:password: will be called (password empty: %s)", ([password length] == 0) ? "yes" : "no");
    if ([self authenticateUser:username password:password]) {
        NSDebugLLog(@"gwcomp", @"[DEBUG] authenticateUser:password: returned YES");
        [self saveLastLoggedInUser:username];
        [self startUserSession:username];
    } else {
        NSDebugLLog(@"gwcomp", @"[DEBUG] authenticateUser:password: returned NO");
        [self showStatus:@"Authentication failed"];
        
        // Show detailed error message if available
        NSString *errorMsg = [pamAuth lastErrorMessage];
        if (errorMsg && [errorMsg length] > 0) {
            NSDebugLLog(@"gwcomp", @"[ERROR] Showing PAM error to user: %@", errorMsg);
            NSAlert *alert = [NSAlert alertWithMessageText:@"Authentication Error"
                                             defaultButton:@"OK"
                                           alternateButton:nil
                                               otherButton:nil
                                 informativeTextWithFormat:@"%@", errorMsg];
            [alert runModal];
        }
        
        [self shakeWindow];
        [passwordField setStringValue:@""];
        [loginWindow makeFirstResponder:passwordField];
    }
}

- (BOOL)trySystemAction:(NSString *)actionType 
{
    // These arrays can be expanded with more commands if needed for other systems
    // or if the current commands fail. The order is important - we try the most
    // common commands first, and if they fail, we try alternatives.
    // LoginWindow typically runs as root, so we try direct commands first, then sudo.
    NSArray *commands;
    if ([actionType isEqualToString:@"restart"]) {
        commands = [NSArray arrayWithObjects:
            // systemd-based Linux (Debian with systemd)
            [NSArray arrayWithObjects:@"/bin/systemctl", @"reboot", nil],
            [NSArray arrayWithObjects:@"/usr/bin/systemctl", @"reboot", nil],
            // Traditional Unix commands (BSD and Linux)
            [NSArray arrayWithObjects:@"/sbin/reboot", nil],
            [NSArray arrayWithObjects:@"/usr/sbin/reboot", nil],
            [NSArray arrayWithObjects:@"/sbin/shutdown", @"-r", @"now", nil],
            [NSArray arrayWithObjects:@"/usr/sbin/shutdown", @"-r", @"now", nil],
            // With sudo as fallback (if LoginWindow isn't running as root)
            [NSArray arrayWithObjects:@"sudo", @"-A", @"-E", @"/bin/systemctl", @"reboot", nil],
            [NSArray arrayWithObjects:@"sudo", @"-A", @"-E", @"/usr/bin/systemctl", @"reboot", nil],
            [NSArray arrayWithObjects:@"sudo", @"-A", @"-E", @"/sbin/reboot", nil],
            [NSArray arrayWithObjects:@"sudo", @"-A", @"-E", @"/usr/sbin/reboot", nil],
            [NSArray arrayWithObjects:@"sudo", @"-A", @"-E", @"/sbin/shutdown", @"-r", @"now", nil], nil
        ];
    } else if ([actionType isEqualToString:@"shutdown"]) {
        commands = [NSArray arrayWithObjects:
            // systemd-based Linux (Debian with systemd)
            [NSArray arrayWithObjects:@"/bin/systemctl", @"poweroff", nil],
            [NSArray arrayWithObjects:@"/usr/bin/systemctl", @"poweroff", nil],
            // Traditional Unix commands (BSD and Linux)
            [NSArray arrayWithObjects:@"/sbin/poweroff", nil],
            [NSArray arrayWithObjects:@"/usr/sbin/poweroff", nil],
            [NSArray arrayWithObjects:@"/sbin/shutdown", @"-h", @"now", nil],
            [NSArray arrayWithObjects:@"/usr/sbin/shutdown", @"-h", @"now", nil],
            [NSArray arrayWithObjects:@"/sbin/shutdown", @"-p", @"now", nil],  // BSD-style with poweroff
            [NSArray arrayWithObjects:@"/sbin/halt", @"-p", nil],  // Another BSD option
            // With sudo as fallback (if LoginWindow isn't running as root)
            [NSArray arrayWithObjects:@"sudo", @"-A", @"-E", @"/bin/systemctl", @"poweroff", nil],
            [NSArray arrayWithObjects:@"sudo", @"-A", @"-E", @"/usr/bin/systemctl", @"poweroff", nil],
            [NSArray arrayWithObjects:@"sudo", @"-A", @"-E", @"/sbin/poweroff", nil],
            [NSArray arrayWithObjects:@"sudo", @"-A", @"-E", @"/usr/sbin/poweroff", nil],
            [NSArray arrayWithObjects:@"sudo", @"-A", @"-E", @"/sbin/shutdown", @"-h", @"now", nil],
            [NSArray arrayWithObjects:@"sudo", @"-A", @"-E", @"/sbin/shutdown", @"-p", @"now", nil], nil
        ];
    } else {
        return NO;
    }
        
    for (NSArray *cmd in commands) {
        NSDebugLLog(@"gwcomp", @"Attempting system action with command: %@", [cmd componentsJoinedByString:@" "]);
        NSTask *task = [NSTask new];
        [task autorelease];
        [task setLaunchPath:[cmd objectAtIndex:0]];
        if ([cmd count] > 1) {
            [task setArguments:[cmd subarrayWithRange:NSMakeRange(1, [cmd count]-1)]];
        }
        
        @try {
            [task launch];
            [task waitUntilExit];
            
            if ([task terminationStatus] == 0) {
                NSDebugLLog(@"gwcomp", @"System action command launched successfully: %@", [cmd componentsJoinedByString:@" "]);
                
                // For restart/shutdown commands, if they succeed, the system should restart/shutdown
                // and this application should never reach this point. If we reach here, it means
                // the command succeeded but the system didn't restart/shutdown, which is an error.
                
                // Wait a bit to see if the system actually restarts/shuts down
                NSDebugLLog(@"gwcomp", @"Waiting for system to %@...", actionType);
                [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:5.0]];
                
                // If we reach here, the system didn't restart/shutdown even though the command succeeded
                // This is a failure case - the command succeeded but didn't work
                NSDebugLLog(@"gwcomp", @"System action command succeeded but system did not %@", actionType);
                // Continue to try next command
            } else {
                NSDebugLLog(@"gwcomp", @"System action failed with command: %@, exit status: %d", [cmd componentsJoinedByString:@" "], [task terminationStatus]);
                // Try next command
            }
        }
        @catch (NSException *exception) {
            NSDebugLLog(@"gwcomp", @"Exception while executing system action: %@", exception);
            // Try next command
        }
    }
    
    return NO; // All commands failed
}

- (void)shutdownButtonPressed:(id)sender
{
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:@"Shutdown Computer"];
    [alert setInformativeText:@"Are you sure you want to shut down now?"];
    [alert addButtonWithTitle:@"Shut Down"];
    [alert addButtonWithTitle:@"Cancel"];
    
    NSInteger result = [alert runModal];
    [alert release];
    if (result == NSAlertFirstButtonReturn) {
        NSDebugLLog(@"gwcomp", @"User confirmed shutdown");
        BOOL success = [self trySystemAction:@"shutdown"];
        if (!success) {
            NSAlert *errorAlert = [[NSAlert alloc] init];
            [errorAlert setMessageText:@"Error"];
            [errorAlert setInformativeText:@"Failed to execute shutdown command. No suitable command found."];
            [errorAlert addButtonWithTitle:@"OK"];
            [errorAlert runModal];
            [errorAlert release];
        }
    }
}

- (void)restartButtonPressed:(id)sender
{
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:@"Restart Computer"];
    [alert setInformativeText:@"Are you sure you want to restart now?"];
    [alert addButtonWithTitle:@"Restart"];
    [alert addButtonWithTitle:@"Cancel"];
    
    NSInteger result = [alert runModal];
    [alert release];
    if (result == NSAlertFirstButtonReturn) {
        NSDebugLLog(@"gwcomp", @"User confirmed restart");
        BOOL success = [self trySystemAction:@"restart"];
        if (!success) {
            NSAlert *errorAlert = [[NSAlert alloc] init];
            [errorAlert setMessageText:@"Error"];
            [errorAlert setInformativeText:@"Failed to execute restart command. No suitable command found."];
            [errorAlert addButtonWithTitle:@"OK"];
            [errorAlert runModal];
            [errorAlert release];
        }
    }
}

- (BOOL)authenticateUser:(NSString *)username password:(NSString *)password
{
    // Use PAM for authentication
    return [pamAuth authenticateUser:username password:password];
}

- (void)startUserSession:(NSString *)username
{
    NSDebugLLog(@"gwcomp", @"[DEBUG] startUserSession called for user: %@", username);
    const char *user_cstr = [username UTF8String];
    struct passwd *pwd = getpwnam(user_cstr);
    
    if (!pwd) {
        NSDebugLLog(@"gwcomp", @"[DEBUG] User not found: %@", username);
        [self showStatus:@"User not found"];
        return;
    }
    
    NSDebugLLog(@"gwcomp", @"[DEBUG] User found - UID: %d, GID: %d, Home: %s, Shell: %s", 
          pwd->pw_uid, pwd->pw_gid, pwd->pw_dir, pwd->pw_shell);
    
    // Save the current session choice before starting
    [self saveLastSession:selectedSessionExec];
    
    // Get PAM environment
    char **pam_envlist = [pamAuth getEnvironmentList];
    NSDebugLLog(@"gwcomp", @"[DEBUG] PAM environment list obtained: %p", pam_envlist);
    
    // Log current selected session
    NSDebugLLog(@"gwcomp", @"[DEBUG] Currently selected session executable: %@", selectedSessionExec);
    NSDebugLLog(@"gwcomp", @"[DEBUG] Available sessions: %@", availableSessions);
    NSDebugLLog(@"gwcomp", @"[DEBUG] Available session execs: %@", availableSessionExecs);
    
    // Change to user's home directory
    if (chdir(pwd->pw_dir) != 0) {
        NSDebugLLog(@"gwcomp", @"[DEBUG] Cannot change to home directory: %s", pwd->pw_dir);
        NSString *errorMsg = [NSString stringWithFormat:@"Cannot change to home directory: %s\n\nError: %s", 
                             pwd->pw_dir, strerror(errno)];
        NSAlert *alert = [NSAlert alertWithMessageText:@"Home Directory Error"
                                         defaultButton:@"OK"
                                       alternateButton:nil
                                           otherButton:nil
                             informativeTextWithFormat:@"%@", errorMsg];
        [alert runModal];
        [self showStatus:@"Cannot change to home directory"];
        [pamAuth closeSession];
        return;
    }
    
    NSDebugLLog(@"gwcomp", @"[DEBUG] Changed to user home directory: %s", pwd->pw_dir);
    
    // Verify that X11 unix socket is available for the user
    NSDebugLLog(@"gwcomp", @"[DEBUG] Verifying X11 unix socket accessibility");
    const char *x_socket_path = "/tmp/.X11-unix/X0";
    
    // Check if socket exists
    if (access(x_socket_path, F_OK) != 0) {
        NSDebugLLog(@"gwcomp", @"[ERROR] X11 unix socket does not exist at %s: %s", x_socket_path, strerror(errno));
        NSAlert *alert = [NSAlert alertWithMessageText:@"X Server Socket Not Found"
                                         defaultButton:@"OK"
                                       alternateButton:nil
                                           otherButton:nil
                             informativeTextWithFormat:@"The X server unix socket at %s does not exist. The X server may not be running properly.", x_socket_path];
        [alert runModal];
        [self showStatus:@"X server socket not found"];
        [pamAuth closeSession];
        return;
    }
    NSDebugLLog(@"gwcomp", @"[DEBUG] X11 unix socket exists at %s", x_socket_path);
    
    // Check if user has access to the socket
    struct stat socket_stat;
    if (stat(x_socket_path, &socket_stat) == 0) {
        NSDebugLLog(@"gwcomp", @"[DEBUG] Socket permissions: mode=0%o, owner=%d:%d", 
              socket_stat.st_mode & 0777, socket_stat.st_uid, socket_stat.st_gid);
        
        // Check if socket is world-writable or user has explicit access
        if (!(socket_stat.st_mode & S_IWOTH)) {
            // Not world-writable, check if user is owner or in group
            if (socket_stat.st_uid != pwd->pw_uid && socket_stat.st_gid != pwd->pw_gid) {
                NSDebugLLog(@"gwcomp", @"[WARNING] User %d may not have access to X socket (owner: %d, group: %d)",
                      pwd->pw_uid, socket_stat.st_uid, socket_stat.st_gid);
                NSAlert *alert = [NSAlert alertWithMessageText:@"X Server Access Warning"
                                                 defaultButton:@"Continue Anyway"
                                               alternateButton:@"Cancel"
                                                   otherButton:nil
                                     informativeTextWithFormat:@"The user %s may not have access to the X server socket. The X session may not work properly.", user_cstr];
                NSInteger response = [alert runModal];
                if (response != NSAlertDefaultReturn) {
                    [self showStatus:@"Login cancelled"];
                    [pamAuth closeSession];
                    return;
                }
            }
        }
    } else {
        NSDebugLLog(@"gwcomp", @"[WARNING] Could not stat X socket: %s", strerror(errno));
    }
    
    NSDebugLLog(@"gwcomp", @"[DEBUG] X11 socket verification passed");
    
    // Start the user's session
    NSDebugLLog(@"gwcomp", @"[DEBUG] About to fork for session");
    pid_t pid = fork();
    if (pid == 0) {
        // Child process - create new session to avoid X11 threading issues
        NSDebugLLog(@"gwcomp", @"[DEBUG] Child process started");
        
        // Create a new session and process group - this is critical for proper cleanup
        pid_t sessionId = setsid();
        if (sessionId == -1) {
            NSDebugLLog(@"gwcomp", @"[DEBUG] setsid() failed: %s", strerror(errno));
            exit(1);
        }
        NSDebugLLog(@"gwcomp", @"[DEBUG] Created new session with SID: %d", sessionId);
        
        // Close all file descriptors except stdin, stdout, stderr
        int maxfd = sysconf(_SC_OPEN_MAX);
        NSDebugLLog(@"gwcomp", @"[DEBUG] Closing file descriptors up to: %d", maxfd);
        for (int fd = 3; fd < maxfd; fd++) {
            close(fd);
        }
        
        NSDebugLLog(@"gwcomp", @"[DEBUG] About to set user context for user: %s (uid=%d, gid=%d)", pwd->pw_name, pwd->pw_uid, pwd->pw_gid);
        
        // Use manual setup for better error reporting
        NSDebugLLog(@"gwcomp", @"[DEBUG] Starting manual user setup");
        
        // Set supplementary groups first
        NSDebugLLog(@"gwcomp", @"[DEBUG] Calling initgroups for user: %s, gid: %d", pwd->pw_name, pwd->pw_gid);
        if (initgroups(pwd->pw_name, pwd->pw_gid) != 0) {
            int err = errno;
            perror("initgroups failed");
            NSDebugLLog(@"gwcomp", @"[DEBUG] initgroups failed for user: %s, gid: %d (errno: %d - %s)", pwd->pw_name, pwd->pw_gid, err, strerror(err));
            exit(1);
        }
        NSDebugLLog(@"gwcomp", @"[DEBUG] initgroups succeeded for user: %s", pwd->pw_name);
        
        // Set group ID
        NSDebugLLog(@"gwcomp", @"[DEBUG] Calling setgid for gid: %d", pwd->pw_gid);
        if (setgid(pwd->pw_gid) != 0) {
            int err = errno;
            perror("setgid failed");
            NSDebugLLog(@"gwcomp", @"[DEBUG] setgid failed for gid: %d (errno: %d - %s)", pwd->pw_gid, err, strerror(err));
            exit(1);
        }
        NSDebugLLog(@"gwcomp", @"[DEBUG] setgid succeeded for gid: %d", pwd->pw_gid);
        
        // Set user ID (this must be last)
        NSDebugLLog(@"gwcomp", @"[DEBUG] Calling setuid for uid: %d", pwd->pw_uid);
        if (setuid(pwd->pw_uid) != 0) {
            int err = errno;
            perror("setuid failed");
            NSDebugLLog(@"gwcomp", @"[DEBUG] setuid failed for uid: %d (errno: %d - %s)", pwd->pw_uid, err, strerror(err));
            exit(1);
        }
        NSDebugLLog(@"gwcomp", @"[DEBUG] setuid succeeded for uid: %d", pwd->pw_uid);
        
        // Verify the change worked
        uid_t real_uid = getuid();
        uid_t eff_uid = geteuid();
        gid_t real_gid = getgid();
        gid_t eff_gid = getegid();
        NSDebugLLog(@"gwcomp", @"[DEBUG] After user setup - real_uid: %d, eff_uid: %d, real_gid: %d, eff_gid: %d", 
              real_uid, eff_uid, real_gid, eff_gid);
        
        if (real_uid != pwd->pw_uid || eff_uid != pwd->pw_uid) {
            NSDebugLLog(@"gwcomp", @"[DEBUG] UID verification failed - expected: %d, got real: %d, eff: %d", pwd->pw_uid, real_uid, eff_uid);
            exit(1);
        }
        
        if (real_gid != pwd->pw_gid || eff_gid != pwd->pw_gid) {
            NSDebugLLog(@"gwcomp", @"[DEBUG] GID verification failed - expected: %d, got real: %d, eff: %d", pwd->pw_gid, real_gid, eff_gid);
            exit(1);
        }
        
        NSDebugLLog(@"gwcomp", @"[DEBUG] Manual user setup completed successfully");
        
        NSDebugLLog(@"gwcomp", @"[DEBUG] User context setup complete");
        
        // Note: X11 unix socket was verified before fork
        // Clients will connect via /tmp/.X11-unix/X0
        NSDebugLLog(@"gwcomp", @"[DEBUG] User will connect to X server via unix socket");
        
        // Clear signal handlers and reset signal mask
        signal(SIGTERM, SIG_DFL);
        signal(SIGINT, SIG_DFL);
        signal(SIGHUP, SIG_DFL);
        signal(SIGCHLD, SIG_DFL);
        
        NSDebugLLog(@"gwcomp", @"[DEBUG] Signal handlers reset");
        
        // Set up environment for the session
        clearenv();
        setenv("USER", user_cstr, 1);
        setenv("LOGNAME", user_cstr, 1);
        setenv("HOME", pwd->pw_dir, 1);
        setenv("SHELL", pwd->pw_shell, 1);
        setenv("DISPLAY", ":0", 1);
        // Build comprehensive PATH that preserves system directories and adds GNUstep paths
        NSString *systemPath = @"/sbin:/bin:/usr/sbin:/usr/bin:/usr/games:/usr/local/sbin:/usr/local/bin";
        NSString *gnustepPath = @"/home/User/Library/Tools:/Library/Tools:/System/Library/Tools";
        NSString *fullPath = [NSString stringWithFormat:@"%@:%@", systemPath, gnustepPath];
        setenv("PATH", [fullPath UTF8String], 1);
        setenv("GNUSTEP_USER_ROOT", [[NSString stringWithFormat:@"%s/GNUstep", pwd->pw_dir] UTF8String], 1);
        
        NSDebugLLog(@"gwcomp", @"[DEBUG] Basic environment set");
        
#if defined(__linux__)
        // Linux: No login_cap, skip BSD-specific login class logic
        NSDebugLLog(@"gwcomp", @"[DEBUG] Skipping BSD login_cap logic on Linux");
#else
        // Set login class environment variables
        login_cap_t *lc = login_getpwclass(pwd);
        if (lc != NULL) {
            NSDebugLLog(@"gwcomp", @"[DEBUG] Setting login class environment variables");
            
            // Iterate through all login class environment and set them
            // These can be set in the file /etc/login.conf
            const char *env_var;
            for (env_var = login_getcapstr(lc, "env", NULL, NULL); env_var != NULL; env_var = login_getcapstr(lc, "env", env_var, NULL)) {
                if (env_var && strlen(env_var) > 0) {
                    putenv((char *)env_var);
                    NSDebugLLog(@"gwcomp", @"[DEBUG] Set login class environment variable: %s", env_var);
                }
            }
            login_close(lc);
            NSDebugLLog(@"gwcomp", @"[DEBUG] Login class environment variables set");
        } else {
            NSDebugLLog(@"gwcomp", @"[DEBUG] No login class found for user");
        }
#endif
        
        // Set PAM environment variables
        if (pam_envlist) {
            NSDebugLLog(@"gwcomp", @"[DEBUG] Setting PAM environment variables");
            for (int i = 0; pam_envlist[i]; i++) {
                NSDebugLLog(@"gwcomp", @"[DEBUG] PAM env[%d]: %s", i, pam_envlist[i]);
                putenv(pam_envlist[i]);
            }
        } else {
            NSDebugLLog(@"gwcomp", @"[DEBUG] No PAM environment variables to set");
        }
        
        // Set up keyboard layout before starting session
        NSDebugLLog(@"gwcomp", @"[DEBUG] Setting up keyboard layout");
        
        // First, try to read keyboard layout from login.conf or environment
        const char *kb_layout = NULL;
        const char *kb_variant = NULL;
        const char *kb_options = NULL;
        
#if defined(__linux__)
        // Linux: Skip login_cap, use environment variables only
        NSDebugLLog(@"gwcomp", @"[DEBUG] Skipping BSD login_cap keyboard config on Linux");
#else
        // Get login capabilities for this user in child process
        login_cap_t *child_lc = login_getpwclass(pwd);
        if (child_lc != NULL) {
            kb_layout = login_getcapstr(child_lc, "keyboard.layout", NULL, NULL);
            kb_variant = login_getcapstr(child_lc, "keyboard.variant", NULL, NULL);
            kb_options = login_getcapstr(child_lc, "keyboard.options", NULL, NULL);
            NSDebugLLog(@"gwcomp", @"[DEBUG] Checked login.conf for keyboard settings");
        }
#endif
        
        // If no keyboard layout specified in login.conf, check environment
        if (!kb_layout) {
            kb_layout = getenv("XKB_DEFAULT_LAYOUT");
        }
        if (!kb_variant) {
            kb_variant = getenv("XKB_DEFAULT_VARIANT");
        }
        if (!kb_options) {
            kb_options = getenv("XKB_DEFAULT_OPTIONS");
        }
        
        // Check various system configuration files for keyboard layout
        if (!kb_layout) {
            NSDebugLLog(@"gwcomp", @"[DEBUG] No keyboard layout from login.conf or environment, checking /etc/rc.conf");
            // Check /etc/rc.conf for keyboard layout
            FILE *rc_conf = fopen("/etc/rc.conf", "r");
            if (rc_conf) {
                char line[256];
                while (fgets(line, sizeof(line), rc_conf)) {
                    if (strncmp(line, "keymap=", 7) == 0) {
                        char *keymap = strchr(line, '=') + 1;
                        char *newline = strchr(keymap, '\n');
                        if (newline) *newline = '\0';
                        // Remove quotes if present
                        if (keymap[0] == '"') {
                            keymap++;
                            char *end_quote = strchr(keymap, '"');
                            if (end_quote) *end_quote = '\0';
                        }
                        NSDebugLLog(@"gwcomp", @"[DEBUG] Found raw keymap in /etc/rc.conf: %s", keymap);
                        // Convert console keymap to X11 layout (simplified mapping)
                        if (strstr(keymap, "us")) kb_layout = "us";
                        else if (strstr(keymap, "de")) kb_layout = "de";
                        else if (strstr(keymap, "fr")) kb_layout = "fr";
                        else if (strstr(keymap, "es")) kb_layout = "es";
                        else if (strstr(keymap, "it")) kb_layout = "it";
                        else if (strstr(keymap, "pt")) kb_layout = "pt";
                        else if (strstr(keymap, "ru")) kb_layout = "ru";
                        else if (strstr(keymap, "uk") || strstr(keymap, "gb")) kb_layout = "gb";
                        else if (strstr(keymap, "dvorak")) {
                            kb_layout = "us";
                            kb_variant = "dvorak";
                        }
                        else {
                            kb_layout = "us"; // fallback
                            NSDebugLLog(@"gwcomp", @"[DEBUG] Unknown keymap '%s', using fallback 'us'", keymap);
                        }
                        NSDebugLLog(@"gwcomp", @"[DEBUG] Converted console keymap '%s' to X11 layout '%s'", keymap, kb_layout);
                        if (kb_variant) NSDebugLLog(@"gwcomp", @"[DEBUG] Set variant to '%s'", kb_variant);
                        break;
                    }
                }
                fclose(rc_conf);
            } else {
                NSDebugLLog(@"gwcomp", @"[DEBUG] Could not open /etc/rc.conf");
            }
        }
        
#if !defined(__linux__)
        // Close login capabilities if we opened them
        if (child_lc != NULL) {
            login_close(child_lc);
        }
#endif
        
        // Default to US layout if nothing found
        if (!kb_layout) {
            kb_layout = "us";
            NSDebugLLog(@"gwcomp", @"[DEBUG] No keyboard layout found, defaulting to US");
        }
        
        NSDebugLLog(@"gwcomp", @"[DEBUG] Final keyboard layout: %s", kb_layout ? kb_layout : "none");
        if (kb_variant) NSDebugLLog(@"gwcomp", @"[DEBUG] Final keyboard variant: %s", kb_variant);
        if (kb_options) NSDebugLLog(@"gwcomp", @"[DEBUG] Final keyboard options: %s", kb_options);
        
        // Clear existing keyboard options first
        NSDebugLLog(@"gwcomp", @"[DEBUG] Clearing existing keyboard options");
        system("/usr/local/bin/setxkbmap -option '' 2>/dev/null || true");
        
        // Build setxkbmap command
        char xkb_cmd[512] = "/usr/local/bin/setxkbmap";
        
        if (kb_layout && strlen(kb_layout) > 0) {
            strcat(xkb_cmd, " ");
            strcat(xkb_cmd, kb_layout);
        }
        
        if (kb_variant && strlen(kb_variant) > 0) {
            strcat(xkb_cmd, " -variant ");
            strcat(xkb_cmd, kb_variant);
        }
        
        if (kb_options && strlen(kb_options) > 0) {
            strcat(xkb_cmd, " -option ");
            strcat(xkb_cmd, kb_options);
        }
        
        strcat(xkb_cmd, " 2>/dev/null");
        
        NSDebugLLog(@"gwcomp", @"[DEBUG] Executing keyboard setup command: %s", xkb_cmd);
        int kb_result = system(xkb_cmd);
        NSDebugLLog(@"gwcomp", @"[DEBUG] Keyboard setup command result: %d", kb_result);
        
        // Verify the keyboard layout was set correctly
        NSDebugLLog(@"gwcomp", @"[DEBUG] Verifying keyboard layout after setup");
        system("/usr/local/bin/setxkbmap -query | head -10");
        
        // Also try to force refresh X11 keyboard state
        NSDebugLLog(@"gwcomp", @"[DEBUG] Refreshing X11 keyboard state");
        system("/usr/local/bin/xkbcomp $DISPLAY - 2>/dev/null < /dev/null || true");
        
        NSDebugLLog(@"gwcomp", @"[DEBUG] Keyboard layout setup complete");
        
        // Change to user's home directory
        if (chdir(pwd->pw_dir) != 0) {
            NSDebugLLog(@"gwcomp", @"[DEBUG] chdir failed in child process");
            exit(1);
        }
        
        NSDebugLLog(@"gwcomp", @"[DEBUG] Changed to home dir in child: %s", pwd->pw_dir);
        
        // Execute the selected session directly
        NSString *sessionToExecute = selectedSessionExec;
        NSDebugLLog(@"gwcomp", @"[DEBUG] Initial session to execute: '%@'", sessionToExecute ? sessionToExecute : @"(nil)");
        NSDebugLLog(@"gwcomp", @"[DEBUG] Available sessions: %@", availableSessions);
        NSDebugLLog(@"gwcomp", @"[DEBUG] Available session execs: %@", availableSessionExecs);
        
        if (!sessionToExecute || [sessionToExecute length] == 0) {
            NSDebugLLog(@"gwcomp", @"[DEBUG] No session selected, using default: GWorkspace");
            sessionToExecute = @"/System/Applications/GWorkspace.app/GWorkspace";
        }
        
        NSDebugLLog(@"gwcomp", @"[DEBUG] Final session to execute: '%@'", sessionToExecute);
        NSDebugLLog(@"gwcomp", @"[DEBUG] User shell: %s", pwd->pw_shell);
        
        // Check if the executable exists
        NSArray *sessionComponents = [sessionToExecute componentsSeparatedByString:@" "];
        NSString *mainExecutable = [sessionComponents firstObject];
        NSDebugLLog(@"gwcomp", @"[DEBUG] Main executable from session command: '%@'", mainExecutable);
        
        if ([mainExecutable hasPrefix:@"/"]) {
            // Absolute path - check if it exists
            NSDebugLLog(@"gwcomp", @"[DEBUG] Checking if session executable exists: %@", mainExecutable);
            if ([[NSFileManager defaultManager] fileExistsAtPath:mainExecutable]) {
                NSDebugLLog(@"gwcomp", @"[DEBUG] Session executable exists: %@", mainExecutable);
            } else {
                NSDebugLLog(@"gwcomp", @"[DEBUG] Session executable not found: %@", mainExecutable);
                // Try fallback
                sessionToExecute = @"/System/Applications/GWorkspace.app/GWorkspace";
                NSDebugLLog(@"gwcomp", @"[DEBUG] Using fallback session: %@", sessionToExecute);
            }
        } else {
            NSDebugLLog(@"gwcomp", @"[DEBUG] Session executable is not absolute path: %@", mainExecutable);
            // It will be resolved by the shell through PATH
        }
        
        // Execute the session through the user's shell
        NSDebugLLog(@"gwcomp", @"[DEBUG] About to execl with shell: %s, command: %s", pwd->pw_shell, [sessionToExecute UTF8String]);
        execl(pwd->pw_shell, pwd->pw_shell, "-c", [sessionToExecute UTF8String], NULL);
        
        // If execl fails, log and exit
        NSDebugLLog(@"gwcomp", @"[DEBUG] execl failed for session: %@", sessionToExecute);
        perror("execl failed");
        exit(1);
    } else if (pid > 0) {
        // Parent process - save session info and monitor it
        NSDebugLLog(@"gwcomp", @"[DEBUG] Parent process, session PID: %d", pid);
        
        printf("Session started for user %s (PID: %d)\n", user_cstr, pid);
        
        // Store session information
        sessionPid = pid;
        sessionUid = pwd->pw_uid;
        sessionGid = pwd->pw_gid;
        sessionStartTime = [[NSDate date] retain];
        
        // Hide the login window
        [loginWindow orderOut:nil];
        
        NSDebugLLog(@"gwcomp", @"[DEBUG] LoginWindow hidden, monitoring session PID %d", pid);
        
        // Start monitoring the session in the background
        [self performSelector:@selector(monitorSession) withObject:nil afterDelay:1.0];
    } else {
        NSDebugLLog(@"gwcomp", @"[DEBUG] Fork failed");
        NSString *errorMsg = [NSString stringWithFormat:@"Failed to fork process for session\n\nError: %s", 
                             strerror(errno)];
        NSAlert *alert = [NSAlert alertWithMessageText:@"Session Start Error"
                                         defaultButton:@"OK"
                                       alternateButton:nil
                                           otherButton:nil
                             informativeTextWithFormat:@"%@", errorMsg];
        [alert runModal];
        [self showStatus:@"Failed to start session"];
        [pamAuth closeSession];
    }
}

- (BOOL)validateLoginWindowPreferencesFile
{
    NSDebugLLog(@"gwcomp", @"[DEBUG] Validating LoginWindow.plist file security");
    
    NSString *plistPath = [self getLoginWindowPreferencesPath];
    
    // Security check: Verify file ownership and permissions before reading
    struct stat fileStat;
    if (stat([plistPath UTF8String], &fileStat) != 0) {
        NSDebugLLog(@"gwcomp", @"[DEBUG] LoginWindow.plist file does not exist: %s", strerror(errno));
        // It's OK if the file doesn't exist - just skip auto-login
        return NO;
    }
    
    // Check if file is owned by root (uid 0)
    if (fileStat.st_uid != 0) {
        NSDebugLLog(@"gwcomp", @"[DEBUG] Warning: LoginWindow.plist is not owned by root (owner uid: %d)", fileStat.st_uid);
        NSAlert *alert = [NSAlert alertWithMessageText:@"Autologin File Permission Error"
                                         defaultButton:@"OK"
                                       alternateButton:nil
                                           otherButton:nil
                             informativeTextWithFormat:@"The autologin configuration file is not owned by root. Please check file permissions."];
        [alert runModal];
        return NO;
    }
    
    // Check if file has permissions 644 (rw-r--r--)
    mode_t expectedMode = S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH; // 0644
    if ((fileStat.st_mode & 0777) != expectedMode) {
        NSDebugLLog(@"gwcomp", @"[DEBUG] Warning: LoginWindow.plist has incorrect permissions (expected 0644, got 0%o)", 
              fileStat.st_mode & 0777);
        NSAlert *alert = [NSAlert alertWithMessageText:@"Autologin File Permission Error"
                                         defaultButton:@"OK"
                                       alternateButton:nil
                                           otherButton:nil
                             informativeTextWithFormat:@"The autologin configuration file has incorrect permissions (expected 0644). This is a security risk."];
        [alert runModal];
        return NO;
    }
    
    NSDebugLLog(@"gwcomp", @"[DEBUG] LoginWindow.plist file security check passed (owned by root with 0644 permissions)");
    return YES;
}

- (void)checkAutoLogin
{
    NSDebugLLog(@"gwcomp", @"[DEBUG] Checking for auto-login user");
    
    // File has already been validated in applicationDidFinishLaunching
    // Read the autoLoginUser from system-wide LoginWindow.plist like other settings
    NSString *plistPath = [self getLoginWindowPreferencesPath];
    
    NSDictionary *plistData = [NSDictionary dictionaryWithContentsOfFile:plistPath];
    NSString *autoLoginUser = [plistData objectForKey:@"autoLoginUser"];
    
    NSDebugLLog(@"gwcomp", @"[DEBUG] Auto-login setting from LoginWindow.plist (%@): %@",
          plistPath, autoLoginUser ? autoLoginUser : @"(none)");
    
    if (autoLoginUser && [autoLoginUser length] > 0) {
        NSDebugLLog(@"gwcomp", @"[DEBUG] Auto-login user found: %@", autoLoginUser);
        
        // Verify that the user exists
        const char *user_cstr = [autoLoginUser UTF8String];
        struct passwd *pwd = getpwnam(user_cstr);
        
        if (pwd) {
            NSDebugLLog(@"gwcomp", @"[DEBUG] Auto-login user verified, starting session automatically");
            
            // Hide the login window immediately since we're auto-logging in
            [loginWindow orderOut:self];
            
            // Set the username field (for logging purposes)
            [usernameField setStringValue:autoLoginUser];
            
            // Start the session without password authentication for auto-login
            // Note: This bypasses password authentication for auto-login
            [self startAutoLoginSession:autoLoginUser];
        } else {
            NSDebugLLog(@"gwcomp", @"[DEBUG] Auto-login user '%@' not found in system, showing login window", autoLoginUser);
        }
    } else {
        NSDebugLLog(@"gwcomp", @"[DEBUG] No auto-login user configured, showing login window");
    }
}

- (void)startAutoLoginSession:(NSString *)username
{
    NSDebugLLog(@"gwcomp", @"[DEBUG] Starting auto-login session for user: %@", username);
    const char *user_cstr = [username UTF8String];
    struct passwd *pwd = getpwnam(user_cstr);
    
    if (!pwd) {
        NSDebugLLog(@"gwcomp", @"[DEBUG] Auto-login user not found: %@", username);
        [self showStatus:@"Auto-login user not found"];
        [loginWindow makeKeyAndOrderFront:self];
        return;
    }
    
    NSDebugLLog(@"gwcomp", @"[DEBUG] Auto-login user found - UID: %d, GID: %d, Home: %s, Shell: %s", 
          pwd->pw_uid, pwd->pw_gid, pwd->pw_dir, pwd->pw_shell);
    
    // For auto-login, we still need to open a PAM session but skip authentication
    // We'll use a simplified PAM session opening
    if (![pamAuth openSessionForUser:username]) {
        NSDebugLLog(@"gwcomp", @"[DEBUG] Failed to open PAM session for auto-login user");
        NSString *errorMsg = [pamAuth getLastError];
        NSAlert *alert = [NSAlert alertWithMessageText:@"Auto-Login PAM Error"
                                         defaultButton:@"OK"
                                       alternateButton:nil
                                           otherButton:nil
                             informativeTextWithFormat:@"%@", errorMsg];
        [alert runModal];
        // Fall back to showing login window
        [self showStatus:@"Failed to open session for auto-login"];
        [loginWindow makeKeyAndOrderFront:self];
        return;
    }
    
    NSDebugLLog(@"gwcomp", @"[DEBUG] PAM session opened successfully for auto-login");
    
    // Get PAM environment
    char **pam_envlist = [pamAuth getEnvironmentList];
    NSDebugLLog(@"gwcomp", @"[DEBUG] PAM environment list obtained: %p", pam_envlist);
    
    // Log current selected session
    NSDebugLLog(@"gwcomp", @"[DEBUG] Currently selected session executable: %@", selectedSessionExec);
    NSDebugLLog(@"gwcomp", @"[DEBUG] Available sessions: %@", availableSessions);
    NSDebugLLog(@"gwcomp", @"[DEBUG] Available session execs: %@", availableSessionExecs);
    
    // Change to user's home directory
    if (chdir(pwd->pw_dir) != 0) {
        NSDebugLLog(@"gwcomp", @"[DEBUG] Cannot change to home directory: %s", pwd->pw_dir);
        NSString *errorMsg = [NSString stringWithFormat:@"Cannot change to home directory: %s\n\nError: %s", 
                             pwd->pw_dir, strerror(errno)];
        NSAlert *alert = [NSAlert alertWithMessageText:@"Auto-Login Home Directory Error"
                                         defaultButton:@"OK"
                                       alternateButton:nil
                                           otherButton:nil
                             informativeTextWithFormat:@"%@", errorMsg];
        [alert runModal];
        [self showStatus:@"Cannot change to home directory"];
        [pamAuth closeSession];
        [loginWindow makeKeyAndOrderFront:self];
        return;
    }
    
    NSDebugLLog(@"gwcomp", @"[DEBUG] Changed to user home directory: %s", pwd->pw_dir);
    
    // Verify that X11 unix socket is available for the user
    NSDebugLLog(@"gwcomp", @"[DEBUG] Verifying X11 unix socket accessibility for auto-login");
    const char *x_socket_path_autologin = "/tmp/.X11-unix/X0";
    
    // Check if socket exists
    if (access(x_socket_path_autologin, F_OK) != 0) {
        NSDebugLLog(@"gwcomp", @"[ERROR] X11 unix socket does not exist at %s: %s", x_socket_path_autologin, strerror(errno));
        NSAlert *alert = [NSAlert alertWithMessageText:@"Auto-Login X Server Socket Not Found"
                                         defaultButton:@"OK"
                                       alternateButton:nil
                                           otherButton:nil
                             informativeTextWithFormat:@"The X server unix socket at %s does not exist. Falling back to login window.", x_socket_path_autologin];
        [alert runModal];
        [self showStatus:@"X server socket not found"];
        [pamAuth closeSession];
        [loginWindow makeKeyAndOrderFront:self];
        return;
    }
    NSDebugLLog(@"gwcomp", @"[DEBUG] X11 unix socket exists at %s", x_socket_path_autologin);
    
    // Check if user has access to the socket
    struct stat socket_stat_autologin;
    if (stat(x_socket_path_autologin, &socket_stat_autologin) == 0) {
        NSDebugLLog(@"gwcomp", @"[DEBUG] Socket permissions: mode=0%o, owner=%d:%d", 
              socket_stat_autologin.st_mode & 0777, socket_stat_autologin.st_uid, socket_stat_autologin.st_gid);
        
        // Check if socket is world-writable or user has explicit access
        if (!(socket_stat_autologin.st_mode & S_IWOTH)) {
            // Not world-writable, check if user is owner or in group
            if (socket_stat_autologin.st_uid != pwd->pw_uid && socket_stat_autologin.st_gid != pwd->pw_gid) {
                NSDebugLLog(@"gwcomp", @"[WARNING] Auto-login user %d may not have access to X socket (owner: %d, group: %d)",
                      pwd->pw_uid, socket_stat_autologin.st_uid, socket_stat_autologin.st_gid);
                NSAlert *alert = [NSAlert alertWithMessageText:@"Auto-Login X Server Access Warning"
                                                 defaultButton:@"OK"
                                               alternateButton:nil
                                                   otherButton:nil
                                     informativeTextWithFormat:@"The auto-login user %s may not have access to the X server socket. Falling back to login window.", user_cstr];
                [alert runModal];
                [self showStatus:@"Auto-login socket access failed"];
                [pamAuth closeSession];
                [loginWindow makeKeyAndOrderFront:self];
                return;
            }
        }
    } else {
        NSDebugLLog(@"gwcomp", @"[WARNING] Could not stat X socket for auto-login: %s", strerror(errno));
    }
    
    NSDebugLLog(@"gwcomp", @"[DEBUG] X11 socket verification passed for auto-login");
    
    // Start the user's session (reuse the existing session starting code)
    NSDebugLLog(@"gwcomp", @"[DEBUG] About to fork for auto-login session");
    pid_t pid = fork();
    if (pid == 0) {
        // Child process - create new session to avoid X11 threading issues
        NSDebugLLog(@"gwcomp", @"[DEBUG] Child process started for auto-login");
        
        // Create a new session and process group - this is critical for proper cleanup
        pid_t sessionId = setsid();
        if (sessionId == -1) {
            NSDebugLLog(@"gwcomp", @"[DEBUG] setsid() failed: %s", strerror(errno));
            exit(1);
        }
        NSDebugLLog(@"gwcomp", @"[DEBUG] Created new session with SID: %d", sessionId);
        
        // Close all file descriptors except stdin, stdout, stderr
        int maxfd = sysconf(_SC_OPEN_MAX);
        NSDebugLLog(@"gwcomp", @"[DEBUG] Closing file descriptors up to: %d", maxfd);
        for (int fd = 3; fd < maxfd; fd++) {
            close(fd);
        }
        
        NSDebugLLog(@"gwcomp", @"[DEBUG] About to set user context for auto-login user: %s (uid=%d, gid=%d)", pwd->pw_name, pwd->pw_uid, pwd->pw_gid);
        
        // Use manual setup for better error reporting
        NSDebugLLog(@"gwcomp", @"[DEBUG] Starting manual user setup for auto-login");
        
        // Set supplementary groups first
        NSDebugLLog(@"gwcomp", @"[DEBUG] Calling initgroups for user: %s, gid: %d", pwd->pw_name, pwd->pw_gid);
        if (initgroups(pwd->pw_name, pwd->pw_gid) != 0) {
            int err = errno;
            perror("initgroups failed");
            NSDebugLLog(@"gwcomp", @"[DEBUG] initgroups failed for user: %s, gid: %d (errno: %d - %s)", pwd->pw_name, pwd->pw_gid, err, strerror(err));
            exit(1);
        }
        NSDebugLLog(@"gwcomp", @"[DEBUG] initgroups succeeded for user: %s", pwd->pw_name);
        
        // Set group ID
        NSDebugLLog(@"gwcomp", @"[DEBUG] Calling setgid for gid: %d", pwd->pw_gid);
        if (setgid(pwd->pw_gid) != 0) {
            int err = errno;
            perror("setgid failed");
            NSDebugLLog(@"gwcomp", @"[DEBUG] setgid failed for gid: %d (errno: %d - %s)", pwd->pw_gid, err, strerror(err));
            exit(1);
        }
        NSDebugLLog(@"gwcomp", @"[DEBUG] setgid succeeded for gid: %d", pwd->pw_gid);
        
        // Set user ID (this must be last)
        NSDebugLLog(@"gwcomp", @"[DEBUG] Calling setuid for uid: %d", pwd->pw_uid);
        if (setuid(pwd->pw_uid) != 0) {
            int err = errno;
            perror("setuid failed");
            NSDebugLLog(@"gwcomp", @"[DEBUG] setuid failed for uid: %d (errno: %d - %s)", pwd->pw_uid, err, strerror(err));
            exit(1);
        }
        NSDebugLLog(@"gwcomp", @"[DEBUG] setuid succeeded for uid: %d", pwd->pw_uid);
        
        // Verify the change worked
        uid_t real_uid = getuid();
        uid_t eff_uid = geteuid();
        gid_t real_gid = getgid();
        gid_t eff_gid = getegid();
        NSDebugLLog(@"gwcomp", @"[DEBUG] After auto-login user setup - real_uid: %d, eff_uid: %d, real_gid: %d, eff_gid: %d", 
              real_uid, eff_uid, real_gid, eff_gid);
        
        if (real_uid != pwd->pw_uid || eff_uid != pwd->pw_uid) {
            NSDebugLLog(@"gwcomp", @"[DEBUG] UID verification failed - expected: %d, got real: %d, eff: %d", pwd->pw_uid, real_uid, eff_uid);
            exit(1);
        }
        
        if (real_gid != pwd->pw_gid || eff_gid != pwd->pw_gid) {
            NSDebugLLog(@"gwcomp", @"[DEBUG] GID verification failed - expected: %d, got real: %d, eff: %d", pwd->pw_gid, real_gid, eff_gid);
            exit(1);
        }
        
        NSDebugLLog(@"gwcomp", @"[DEBUG] Manual auto-login user setup completed successfully");
        
        NSDebugLLog(@"gwcomp", @"[DEBUG] Auto-login user context setup complete");
        
        // Note: X11 unix socket was verified before fork
        // Clients will connect via /tmp/.X11-unix/X0
        NSDebugLLog(@"gwcomp", @"[DEBUG] Auto-login user will connect to X server via unix socket");
        
        // Clear signal handlers and reset signal mask
        signal(SIGTERM, SIG_DFL);
        signal(SIGINT, SIG_DFL);
        signal(SIGHUP, SIG_DFL);
        signal(SIGCHLD, SIG_DFL);
        
        NSDebugLLog(@"gwcomp", @"[DEBUG] Signal handlers reset for auto-login");
        
        // Set up environment for the session (reuse existing environment setup code)
        clearenv();
        setenv("USER", user_cstr, 1);
        setenv("LOGNAME", user_cstr, 1);
        setenv("HOME", pwd->pw_dir, 1);
        setenv("SHELL", pwd->pw_shell, 1);
        setenv("DISPLAY", ":0", 1);
        // Might want to make the PATH configurable via a defaults loginwindow setting
        setenv("PATH", "/sbin:/bin:/usr/sbin:/usr/bin:/usr/games:/usr/local/sbin:/usr/local/bin", 1);
        setenv("GNUSTEP_USER_ROOT", [[NSString stringWithFormat:@"%s/GNUstep", pwd->pw_dir] UTF8String], 1);
        
        NSDebugLLog(@"gwcomp", @"[DEBUG] Basic environment set for auto-login");
        
#if defined(__linux__)
        // Linux: No login_cap, skip BSD-specific login class logic for auto-login
        NSDebugLLog(@"gwcomp", @"[DEBUG] Skipping BSD login_cap logic for auto-login on Linux");
#else
        // Set login class environment variables
        login_cap_t *lc = login_getpwclass(pwd);
        if (lc != NULL) {
            NSDebugLLog(@"gwcomp", @"[DEBUG] Setting login class environment variables for auto-login");
            
            // Set language/locale environment
            const char *lang = login_getcapstr(lc, "lang", NULL, NULL);
            if (lang != NULL) {
                setenv("LANG", lang, 1);
                NSDebugLLog(@"gwcomp", @"[DEBUG] Set LANG=%s", lang);
            }
            
            // Set character set
            const char *charset = login_getcapstr(lc, "charset", NULL, NULL);
            if (charset != NULL) {
                setenv("MM_CHARSET", charset, 1);
                NSDebugLLog(@"gwcomp", @"[DEBUG] Set MM_CHARSET=%s", charset);
            }
            
            // Set timezone
            const char *timezone = login_getcapstr(lc, "timezone", NULL, NULL);
            if (timezone != NULL) {
                setenv("TZ", timezone, 1);
                NSDebugLLog(@"gwcomp", @"[DEBUG] Set TZ=%s", timezone);
            }
            
            // Set manual path
            const char *manpath = login_getcapstr(lc, "manpath", NULL, NULL);
            if (manpath != NULL) {
                setenv("MANPATH", manpath, 1);
                NSDebugLLog(@"gwcomp", @"[DEBUG] Set MANPATH=%s", manpath);
            }
            
            login_close(lc);
            NSDebugLLog(@"gwcomp", @"[DEBUG] Login class environment variables set for auto-login");
        } else {
            NSDebugLLog(@"gwcomp", @"[DEBUG] No login class found for auto-login user");
        }
#endif
        
        // Set PAM environment variables
        if (pam_envlist) {
            NSDebugLLog(@"gwcomp", @"[DEBUG] Setting PAM environment variables for auto-login");
            for (int i = 0; pam_envlist[i]; i++) {
                NSDebugLLog(@"gwcomp", @"[DEBUG] PAM env[%d]: %s", i, pam_envlist[i]);
                putenv(pam_envlist[i]);
            }
        } else {
            NSDebugLLog(@"gwcomp", @"[DEBUG] No PAM environment variables to set for auto-login");
        }
        
        // Set up keyboard layout before starting session (reuse existing keyboard setup)
        NSDebugLLog(@"gwcomp", @"[DEBUG] Setting up keyboard layout for auto-login");
        
        // First, try to read keyboard layout from login.conf or environment
        const char *kb_layout = NULL;
        const char *kb_variant = NULL;
        const char *kb_options = NULL;
        
#if defined(__linux__)
        // Linux: Skip login_cap, use environment variables only
        NSDebugLLog(@"gwcomp", @"[DEBUG] Skipping BSD login_cap keyboard config for auto-login on Linux");
#else
        // Get login capabilities for this user in child process
        login_cap_t *child_lc = login_getpwclass(pwd);
        if (child_lc != NULL) {
            kb_layout = login_getcapstr(child_lc, "keyboard.layout", NULL, NULL);
            kb_variant = login_getcapstr(child_lc, "keyboard.variant", NULL, NULL);
            kb_options = login_getcapstr(child_lc, "keyboard.options", NULL, NULL);
            NSDebugLLog(@"gwcomp", @"[DEBUG] Checked login.conf for keyboard settings");
        }
#endif
        
        // If no keyboard layout specified in login.conf, check environment
        if (!kb_layout) {
            kb_layout = getenv("XKB_DEFAULT_LAYOUT");
        }
        if (!kb_variant) {
            kb_variant = getenv("XKB_DEFAULT_VARIANT");
        }
        if (!kb_options) {
            kb_options = getenv("XKB_DEFAULT_OPTIONS");
        }
        
        // Check various system configuration files for keyboard layout
        if (!kb_layout) {
            NSDebugLLog(@"gwcomp", @"[DEBUG] No keyboard layout from login.conf or environment, checking /etc/rc.conf");
            // Check /etc/rc.conf for keyboard layout
            FILE *rc_conf = fopen("/etc/rc.conf", "r");
            if (rc_conf) {
                char line[256];
                while (fgets(line, sizeof(line), rc_conf)) {
                    if (strncmp(line, "keymap=", 7) == 0) {
                        char *keymap = strchr(line, '=') + 1;
                        char *newline = strchr(keymap, '\n');
                        if (newline) *newline = '\0';
                        // Remove quotes if present
                        if (keymap[0] == '"') {
                            keymap++;
                            char *end_quote = strchr(keymap, '"');
                            if (end_quote) *end_quote = '\0';
                        }
                        NSDebugLLog(@"gwcomp", @"[DEBUG] Found raw keymap in /etc/rc.conf: %s", keymap);
                        // Convert console keymap to X11 layout (simplified mapping)
                        if (strstr(keymap, "us")) kb_layout = "us";
                        else if (strstr(keymap, "de")) kb_layout = "de";
                        else if (strstr(keymap, "fr")) kb_layout = "fr";
                        else if (strstr(keymap, "es")) kb_layout = "es";
                        else if (strstr(keymap, "it")) kb_layout = "it";
                        else if (strstr(keymap, "pt")) kb_layout = "pt";
                        else if (strstr(keymap, "ru")) kb_layout = "ru";
                        else if (strstr(keymap, "uk") || strstr(keymap, "gb")) kb_layout = "gb";
                        else if (strstr(keymap, "dvorak")) {
                            kb_layout = "us";
                            kb_variant = "dvorak";
                        }
                        else {
                            kb_layout = "us"; // fallback
                            NSDebugLLog(@"gwcomp", @"[DEBUG] Unknown keymap '%s', using fallback 'us'", keymap);
                        }
                        NSDebugLLog(@"gwcomp", @"[DEBUG] Converted console keymap '%s' to X11 layout '%s'", keymap, kb_layout);
                        if (kb_variant) NSDebugLLog(@"gwcomp", @"[DEBUG] Set variant to '%s'", kb_variant);
                        break;
                    }
                }
                fclose(rc_conf);
            } else {
                NSDebugLLog(@"gwcomp", @"[DEBUG] Could not open /etc/rc.conf");
            }
        }
        
#if !defined(__linux__)
        // Close login capabilities if we opened them
        if (child_lc != NULL) {
            login_close(child_lc);
        }
#endif
        
        // Default to US layout if nothing found
        if (!kb_layout) {
            kb_layout = "us";
            NSDebugLLog(@"gwcomp", @"[DEBUG] No keyboard layout found, defaulting to US");
        }
        
        NSDebugLLog(@"gwcomp", @"[DEBUG] Final keyboard layout for auto-login: %s", kb_layout ? kb_layout : "none");
        if (kb_variant) NSDebugLLog(@"gwcomp", @"[DEBUG] Final keyboard variant for auto-login: %s", kb_variant);
        if (kb_options) NSDebugLLog(@"gwcomp", @"[DEBUG] Final keyboard options for auto-login: %s", kb_options);
        
        // Clear existing keyboard options first
        NSDebugLLog(@"gwcomp", @"[DEBUG] Clearing existing keyboard options for auto-login");
        system("/usr/local/bin/setxkbmap -option '' 2>/dev/null || true");
        
        // Build setxkbmap command
        char xkb_cmd[512] = "/usr/local/bin/setxkbmap";
        
        if (kb_layout && strlen(kb_layout) > 0) {
            strcat(xkb_cmd, " ");
            strcat(xkb_cmd, kb_layout);
        }
        
        if (kb_variant && strlen(kb_variant) > 0) {
            strcat(xkb_cmd, " -variant ");
            strcat(xkb_cmd, kb_variant);
        }
        
        if (kb_options && strlen(kb_options) > 0) {
            strcat(xkb_cmd, " -option ");
            strcat(xkb_cmd, kb_options);
        }
        
        strcat(xkb_cmd, " 2>/dev/null");
        
        NSDebugLLog(@"gwcomp", @"[DEBUG] Executing keyboard setup command for auto-login: %s", xkb_cmd);
        int kb_result = system(xkb_cmd);
        NSDebugLLog(@"gwcomp", @"[DEBUG] Keyboard setup command result for auto-login: %d", kb_result);
        
        // Verify the keyboard layout was set correctly
        NSDebugLLog(@"gwcomp", @"[DEBUG] Verifying keyboard layout after auto-login setup");
        system("/usr/local/bin/setxkbmap -query | head -10");
        
        // Also try to force refresh X11 keyboard state
        NSDebugLLog(@"gwcomp", @"[DEBUG] Refreshing X11 keyboard state for auto-login");
        system("/usr/local/bin/xkbcomp $DISPLAY - 2>/dev/null < /dev/null || true");
        
        NSDebugLLog(@"gwcomp", @"[DEBUG] Keyboard layout setup complete for auto-login");
        
        // Change to user's home directory
        if (chdir(pwd->pw_dir) != 0) {
            NSDebugLLog(@"gwcomp", @"[DEBUG] chdir failed in child process for auto-login");
            exit(1);
        }
        
        NSDebugLLog(@"gwcomp", @"[DEBUG] Changed to home dir in child for auto-login: %s", pwd->pw_dir);
        
        // Execute the selected session directly
        NSString *sessionToExecute = selectedSessionExec;
        NSDebugLLog(@"gwcomp", @"[DEBUG] Initial session to execute for auto-login: '%@'", sessionToExecute ? sessionToExecute : @"(nil)");
        NSDebugLLog(@"gwcomp", @"[DEBUG] Available sessions for auto-login: %@", availableSessions);
        NSDebugLLog(@"gwcomp", @"[DEBUG] Available session execs for auto-login: %@", availableSessionExecs);
        
        if (!sessionToExecute || [sessionToExecute length] == 0) {
            NSDebugLLog(@"gwcomp", @"[DEBUG] No session selected for auto-login, using default: GWorkspace");
            sessionToExecute = @"/System/Applications/GWorkspace.app/GWorkspace";
        }
        
        NSDebugLLog(@"gwcomp", @"[DEBUG] Final session to execute for auto-login: '%@'", sessionToExecute);
        NSDebugLLog(@"gwcomp", @"[DEBUG] User shell for auto-login: %s", pwd->pw_shell);
        
        // Check if the executable exists
        NSArray *sessionComponents = [sessionToExecute componentsSeparatedByString:@" "];
        NSString *mainExecutable = [sessionComponents firstObject];
        NSDebugLLog(@"gwcomp", @"[DEBUG] Main executable from session command for auto-login: '%@'", mainExecutable);
        
        if ([mainExecutable hasPrefix:@"/"]) {
            // Absolute path - check if it exists
            NSDebugLLog(@"gwcomp", @"[DEBUG] Checking if session executable exists for auto-login: %@", mainExecutable);
            if ([[NSFileManager defaultManager] fileExistsAtPath:mainExecutable]) {
                NSDebugLLog(@"gwcomp", @"[DEBUG] Session executable exists for auto-login: %@", mainExecutable);
            } else {
                NSDebugLLog(@"gwcomp", @"[DEBUG] Session executable not found for auto-login: %@", mainExecutable);
                // Try fallback
                sessionToExecute = @"/System/Applications/GWorkspace.app/GWorkspace";
                NSDebugLLog(@"gwcomp", @"[DEBUG] Using fallback session for auto-login: %@", sessionToExecute);
            }
        } else {
            NSDebugLLog(@"gwcomp", @"[DEBUG] Session executable is not absolute path for auto-login: %@", mainExecutable);
            // It will be resolved by the shell through PATH
        }
        
        // Execute the session through the user's shell
        NSDebugLLog(@"gwcomp", @"[DEBUG] About to execl with shell for auto-login: %s, command: %s", pwd->pw_shell, [sessionToExecute UTF8String]);
        execl(pwd->pw_shell, pwd->pw_shell, "-c", [sessionToExecute UTF8String], NULL);
        
        // If execl fails, log and exit
        NSDebugLLog(@"gwcomp", @"[DEBUG] execl failed for auto-login session: %@", sessionToExecute);
        perror("execl failed");
        exit(1);
    } else if (pid > 0) {
        // Parent process - save session info and monitor it
        NSDebugLLog(@"gwcomp", @"[DEBUG] Parent process for auto-login, session PID: %d", pid);
        
        printf("Auto-login session started for user %s (PID: %d)\n", user_cstr, pid);
        
        // Store session information
        sessionPid = pid;
        sessionUid = pwd->pw_uid;
        sessionGid = pwd->pw_gid;
        sessionStartTime = [[NSDate date] retain];
        
        // Hide the login window (it's already visible from startup)
        [loginWindow orderOut:nil];
        
        NSDebugLLog(@"gwcomp", @"[DEBUG] LoginWindow hidden, monitoring auto-login session PID %d", pid);
        
        // Start monitoring the session in the background
        [self performSelector:@selector(monitorSession) withObject:nil afterDelay:1.0];
    } else {
        NSDebugLLog(@"gwcomp", @"[DEBUG] Fork failed for auto-login");
        [self showStatus:@"Failed to start auto-login session"];
        [pamAuth closeSession];
        [loginWindow makeKeyAndOrderFront:self];
    }
}

- (void)monitorSession
{
    // Check if the session process is still running
    if (sessionPid <= 0) {
        NSDebugLLog(@"gwcomp", @"[DEBUG] No session to monitor");
        return;
    }
    
    int status;
    pid_t result = waitpid(sessionPid, &status, WNOHANG);
    
    if (result == sessionPid) {
        // Session has ended
        NSDebugLLog(@"gwcomp", @"[DEBUG] Session PID %d has ended", sessionPid);
        
        // Check if session ended very quickly (within 5 seconds), indicating a startup error
        NSTimeInterval sessionDuration = -[sessionStartTime timeIntervalSinceNow];
        BOOL earlyFailure = (sessionDuration < 5.0);
        
        int exitCode = 0;
        NSString *exitReason = nil;
        
        if (WIFEXITED(status)) {
            exitCode = WEXITSTATUS(status);
            NSDebugLLog(@"gwcomp", @"[DEBUG] Session exited normally with status: %d", exitCode);
            if (exitCode != 0) {
                exitReason = [NSString stringWithFormat:@"Session exited with error code: %d", exitCode];
            }
        } else if (WIFSIGNALED(status)) {
            int signal = WTERMSIG(status);
            NSDebugLLog(@"gwcomp", @"[DEBUG] Session terminated by signal: %d", signal);
            exitReason = [NSString stringWithFormat:@"Session terminated by signal: %d (%s)", signal, strsignal(signal)];
        }
        
        // Show alert if session failed early
        if (earlyFailure && (exitCode != 0 || exitReason)) {
            NSString *errorMsg;
            if (exitReason) {
                errorMsg = [NSString stringWithFormat:@"The session failed to start properly.\n\n%@\n\nSession duration: %.1f seconds\n\nPlease check the system logs for more details.", 
                           exitReason, sessionDuration];
            } else {
                errorMsg = [NSString stringWithFormat:@"The session failed to start properly.\n\nSession duration: %.1f seconds\n\nPlease check the system logs for more details.", 
                           sessionDuration];
            }
            
            NSAlert *alert = [NSAlert alertWithMessageText:@"Session Startup Error"
                                             defaultButton:@"OK"
                                           alternateButton:nil
                                               otherButton:nil
                                 informativeTextWithFormat:@"%@", errorMsg];
            [alert runModal];
        }
        
        // Clean up any remaining session processes
        NSDebugLLog(@"gwcomp", @"[DEBUG] Cleaning up remaining session processes for UID: %d", sessionUid);
        [self killAllSessionProcesses:sessionUid];
        
        // Close PAM session
        if (pamAuth) {
            [pamAuth closeSession];
            NSDebugLLog(@"gwcomp", @"[DEBUG] PAM session closed after session ended");
        }
        
        // Reset session tracking
        sessionPid = 0;
        sessionUid = 0;
        sessionGid = 0;
        [sessionStartTime release];
        sessionStartTime = nil;
        
        // Show the login window again
        NSDebugLLog(@"gwcomp", @"[DEBUG] Session ended, showing login window again");
        [self resetLoginWindow];
        [loginWindow makeKeyAndOrderFront:self];
        [NSApp activateIgnoringOtherApps:YES];
        
    } else if (result == 0) {
        // Session is still running - check again later
        [self performSelector:@selector(monitorSession) withObject:nil afterDelay:1.0];
    } else if (result == -1) {
        // Error occurred
        if (errno == ECHILD) {
            // No child process - session already reaped
            NSDebugLLog(@"gwcomp", @"[DEBUG] Session PID %d already reaped", sessionPid);
            sessionPid = 0;
            sessionUid = 0;
            sessionGid = 0;
            [sessionStartTime release];
            sessionStartTime = nil;
            [self resetLoginWindow];
            [loginWindow makeKeyAndOrderFront:self];
            [NSApp activateIgnoringOtherApps:YES];
        } else {
            NSDebugLLog(@"gwcomp", @"[DEBUG] Error monitoring session: %s", strerror(errno));
            // Continue monitoring
            [self performSelector:@selector(monitorSession) withObject:nil afterDelay:1.0];
        }
    }
}

// Names of daemons that detach from the session (fork + new SID).
// These escape process-group and session-based cleanup, so we match
// them explicitly by UID + command name.
static const char *detachedDaemons[] = { "gpbs", "gdnc", "dbus-daemon", NULL };

static bool isDetachedDaemon(const char *comm)
{
    for (int i = 0; detachedDaemons[i] != NULL; i++) {
        if (strcmp(comm, detachedDaemons[i]) == 0)
            return true;
    }
    return false;
}

- (void)killAllSessionProcesses:(uid_t)uid
{
    NSDebugLog(@"Starting targeted session cleanup for UID: %d", uid);

    if (sessionPid <= 0) {
        NSDebugLog(@"No session PID to clean up");
        return;
    }

    NSDebugLog(@"Cleaning up session process group for PID: %d", sessionPid);

    // Step 1: Send HUP signal to the session process group
    if (killpg(sessionPid, SIGHUP) != 0) {
        if (errno != ESRCH) {
            NSDebugLog(@"Failed to send SIGHUP to process group %d: %s", sessionPid, strerror(errno));
        }
    }

    // Step 2: Send TERM signal to process group, if that fails send KILL
    if (killpg(sessionPid, SIGTERM) != 0) {
        if (errno != ESRCH) {
            NSDebugLog(@"SIGTERM failed, sending SIGKILL to process group %d", sessionPid);
            killpg(sessionPid, SIGKILL);
        }
    } else {
        usleep(500000); // 500ms grace period
        if (kill(sessionPid, 0) == 0) {
            NSDebugLog(@"Session process still alive, sending SIGKILL to process group %d", sessionPid);
            killpg(sessionPid, SIGKILL);
        }
    }

    // Step 3: Kill the main session process directly
    if (kill(sessionPid, SIGKILL) != 0) {
        if (errno != ESRCH) {
            NSDebugLog(@"Failed to kill session process %d: %s", sessionPid, strerror(errno));
        }
    }

    // Step 4: Scan for remaining session-related processes AND detached
    // daemons owned by this user (gpbs, gdnc, dbus-daemon).
    NSDebugLog(@"Scanning for remaining session processes and detached daemons");

    int sessionRelatedKilled = 0;

#if defined(__linux__)
    DIR *proc_dir = opendir("/proc");
    if (!proc_dir) {
        NSDebugLog(@"Failed to open /proc directory: %s", strerror(errno));
        return;
    }

    struct dirent *entry;
    while ((entry = readdir(proc_dir)) != NULL) {
        if (!isdigit(entry->d_name[0]))
            continue;

        pid_t pid = atoi(entry->d_name);
        if (pid <= 1 || pid == getpid())
            continue;

        // Read process UID from /proc/PID/status
        char status_path[256];
        snprintf(status_path, sizeof(status_path), "/proc/%d/status", pid);
        FILE *status_file = fopen(status_path, "r");
        if (!status_file)
            continue;

        uid_t proc_uid = (uid_t)-1;
        char line[256];
        while (fgets(line, sizeof(line), status_file)) {
            if (strncmp(line, "Uid:", 4) == 0) {
                // Format: Uid: <real> <effective> <saved> <fs>
                sscanf(line + 4, " %u", &proc_uid);
                break;
            }
        }
        fclose(status_file);

        if (proc_uid != uid)
            continue;

        // Read /proc/PID/stat for process info
        char stat_path[256];
        snprintf(stat_path, sizeof(stat_path), "/proc/%d/stat", pid);
        FILE *stat_file = fopen(stat_path, "r");
        if (!stat_file)
            continue;

        pid_t parsed_pid, ppid, pgrp, session;
        char comm[256];
        char state;

        if (fscanf(stat_file, "%d %s %c %d %d %d",
                   &parsed_pid, comm, &state, &ppid, &pgrp, &session) == 6) {

            bool shouldKill = false;

            // Session-related checks (same as before)
            if (ppid == sessionPid || session == sessionPid || pgrp == sessionPid) {
                NSDebugLog(@"Found session-related process: PID=%d, Command=%s", pid, comm);
                shouldKill = true;
            }

            // Detached daemon check — match by command name.
            // comm is in format "(name)", so strip the parens.
            char *name = comm;
            if (name[0] == '(') name++;
            char *paren = strchr(name, ')');
            if (paren) *paren = '\0';

            if (!shouldKill && isDetachedDaemon(name)) {
                NSDebugLog(@"Found detached daemon: PID=%d, Command=%s", pid, name);
                shouldKill = true;
            }

            if (shouldKill) {
                if (kill(pid, SIGKILL) == 0) {
                    sessionRelatedKilled++;
                } else if (errno != ESRCH) {
                    NSDebugLog(@"Failed to kill process %d: %s", pid, strerror(errno));
                }
            }
        }

        fclose(stat_file);
    }

    closedir(proc_dir);

#else
    // BSD implementation using sysctl. OpenBSD's KERN_PROC needs a 6-element
    // mib carrying the struct size and element count; FreeBSD uses 4.
#if defined(__OpenBSD__)
    int mib[6] = {CTL_KERN, KERN_PROC, KERN_PROC_UID, (int)uid,
                  sizeof(struct kinfo_proc), 0};
    int miblen = 6;
#else
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_UID, uid};
    int miblen = 4;
#endif
    size_t size = 0;

    if (sysctl(mib, miblen, NULL, &size, NULL, 0) != 0) {
        NSDebugLog(@"Failed to get process list size: %s", strerror(errno));
        return;
    }

    struct kinfo_proc *procs = malloc(size);
    if (!procs) {
        NSDebugLog(@"Failed to allocate memory for process list");
        return;
    }

#if defined(__OpenBSD__)
    mib[5] = (int)(size / sizeof(struct kinfo_proc));
#endif
    if (sysctl(mib, miblen, procs, &size, NULL, 0) != 0) {
        NSDebugLog(@"Failed to get process list: %s", strerror(errno));
        free(procs);
        return;
    }

    int numProcs = size / sizeof(struct kinfo_proc);
    for (int i = 0; i < numProcs; i++) {
        pid_t pid = procs[i].GW_KP_PID;
        if (pid <= 1 || pid == getpid())
            continue;

        bool shouldKill = false;

        // Session-related checks
        if (procs[i].GW_KP_PPID == sessionPid || procs[i].GW_KP_SID == sessionPid ||
            procs[i].GW_KP_PGID == sessionPid) {
            NSDebugLog(@"Found session-related process: PID=%d, Command=%s", pid, procs[i].GW_KP_COMM);
            shouldKill = true;
        }

        // Detached daemon check
        if (!shouldKill && isDetachedDaemon(procs[i].GW_KP_COMM)) {
            NSDebugLog(@"Found detached daemon: PID=%d, Command=%s", pid, procs[i].GW_KP_COMM);
            shouldKill = true;
        }

        if (shouldKill) {
            if (kill(pid, SIGKILL) == 0) {
                sessionRelatedKilled++;
            } else if (errno != ESRCH) {
                NSDebugLog(@"Failed to kill process %d: %s", pid, strerror(errno));
            }
        }
    }

    free(procs);
#endif

    NSDebugLog(@"Session cleanup complete: killed %d processes", sessionRelatedKilled);

    // Step 5: Reap any zombie children
    int status;
    int reaped = 0;
    while (waitpid(-1, &status, WNOHANG) > 0) {
        reaped++;
    }
    if (reaped > 0) {
        NSDebugLog(@"Reaped %d zombie processes", reaped);
    }
}

- (void)showStatus:(NSString *)message
{
    [statusLabel setStringValue:message];
    [statusLabel display];
}

- (void)sessionChanged:(id)sender
{
    NSInteger idx = [sessionDropdown indexOfSelectedItem];
    NSDebugLLog(@"gwcomp", @"[DEBUG] Session changed to index: %ld", (long)idx);
    if (idx >= 0 && idx < [availableSessionExecs count]) {
        selectedSessionExec = [availableSessionExecs objectAtIndex:idx];
        NSDebugLLog(@"gwcomp", @"[DEBUG] Selected session exec: %@", selectedSessionExec);
        // Save the selected session
        [self saveLastSession:selectedSessionExec];
    } else {
        NSDebugLLog(@"gwcomp", @"[DEBUG] Invalid session index: %ld (count: %lu)", (long)idx, (unsigned long)[availableSessionExecs count]);
    }
}

- (void)resetLoginWindow
{
    NSDebugLLog(@"gwcomp", @"[DEBUG] Resetting login window state");
    
    // Reset session tracking variables
    sessionPid = 0;
    sessionUid = 0;
    sessionGid = 0;
    
    // Clear input fields
    [passwordField setStringValue:@""];
    
    // Load and pre-fill last logged-in user instead of clearing username
    NSString *lastUser = [self loadLastLoggedInUser];
    if (lastUser) {
        [usernameField setStringValue:lastUser];
        NSDebugLLog(@"gwcomp", @"[DEBUG] Pre-filled username field with last logged-in user: %@", lastUser);
        // If username is pre-filled, focus on password field
        [loginWindow makeFirstResponder:passwordField];
    } else {
        [usernameField setStringValue:@""];
        // No last user, focus on username field
        [loginWindow makeFirstResponder:usernameField];
    }
    
    [self showStatus:@""];
    
    // Reset session selection to default
    if ([availableSessionExecs count] > 0) {
        selectedSessionExec = [availableSessionExecs objectAtIndex:0];
        [sessionDropdown selectItemAtIndex:0];
    }
    
    // Update login button state after resetting fields
    [self updateLoginButtonState];
    
    // Ensure window is properly positioned and visible
    // Use golden ratio vertical positioning instead of centering
    NSScreen *mainScreen = [NSScreen mainScreen];
    NSRect screenFrame = [mainScreen frame];
    CGFloat goldenRatio = 0.618;
    CGFloat windowX = (screenFrame.size.width - [loginWindow frame].size.width) / 2.0;
    CGFloat windowY = screenFrame.origin.y + (screenFrame.size.height - [loginWindow frame].size.height) * goldenRatio;
    [loginWindow setFrameOrigin:NSMakePoint(windowX, windowY)];
    [loginWindow setLevel:NSScreenSaverWindowLevel];
    [loginWindow makeKeyAndOrderFront:self];
    [loginWindow makeMainWindow];
    [NSApp activateIgnoringOtherApps:YES];
    
    NSDebugLLog(@"gwcomp", @"[DEBUG] Login window reset complete - ready for next user");
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender
{
    return YES;
}

- (NSString *)getLoginWindowPreferencesPath
{
    // Use system-wide Library/Preferences directory
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSLocalDomainMask, NO);
    NSString *libraryPath = ([paths count] > 0) ? [paths objectAtIndex:0] : @"/Library";
    NSString *preferencesDir = [libraryPath stringByAppendingPathComponent:@"Preferences"];
    return [preferencesDir stringByAppendingPathComponent:@"LoginWindow.plist"];
}

- (void)saveLastLoggedInUser:(NSString *)username
{
    if (!username || [username length] == 0) {
        NSDebugLLog(@"gwcomp", @"[DEBUG] No username provided to save");
        return;
    }
    
    NSDebugLLog(@"gwcomp", @"[DEBUG] Saving last logged-in user: %@", username);
    
    // Save to system-wide plist since LoginWindow runs as root
    NSString *plistPath = [self getLoginWindowPreferencesPath];
    NSString *plistDir = [plistPath stringByDeletingLastPathComponent];
    
    // Ensure directory exists
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *error = nil;
    if (![fm createDirectoryAtPath:plistDir withIntermediateDirectories:YES attributes:nil error:&error]) {
        NSDebugLLog(@"gwcomp", @"[DEBUG] Failed to create directory %@: %@", plistDir, error);
        return;
    }
    
    NSMutableDictionary *plistData = [NSMutableDictionary dictionaryWithContentsOfFile:plistPath];
    if (!plistData) {
        plistData = [NSMutableDictionary dictionary];
    }
    
    [plistData setObject:username forKey:@"lastLoggedInUser"];
    
    if ([plistData writeToFile:plistPath atomically:YES]) {
        NSDebugLLog(@"gwcomp", @"[DEBUG] Successfully saved last logged-in user to %@", plistPath);
    } else {
        NSDebugLLog(@"gwcomp", @"[DEBUG] Failed to save last logged-in user to %@", plistPath);
    }
}

- (NSString *)loadLastLoggedInUser
{
    NSDebugLLog(@"gwcomp", @"[DEBUG] Loading last logged-in user from system-wide plist");
    
    NSString *plistPath = [self getLoginWindowPreferencesPath];
    NSDictionary *plistData = [NSDictionary dictionaryWithContentsOfFile:plistPath];
    
    NSString *lastUser = [plistData objectForKey:@"lastLoggedInUser"];
    
    if (lastUser && [lastUser length] > 0) {
        NSDebugLLog(@"gwcomp", @"[DEBUG] Loaded last logged-in user: %@", lastUser);
        return lastUser;
    }
    
    NSDebugLLog(@"gwcomp", @"[DEBUG] No last logged-in user found in system-wide plist");
    return nil;
}

- (void)saveLastSession:(NSString *)sessionExec
{
    if (!sessionExec || [sessionExec length] == 0) {
        NSDebugLLog(@"gwcomp", @"[DEBUG] No session exec provided to save");
        return;
    }
    
    NSDebugLLog(@"gwcomp", @"[DEBUG] Saving last chosen session: %@", sessionExec);
    
    // Save to system-wide plist since LoginWindow runs as root
    NSString *plistPath = [self getLoginWindowPreferencesPath];
    NSString *plistDir = [plistPath stringByDeletingLastPathComponent];
    
    // Ensure directory exists
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *error = nil;
    if (![fm createDirectoryAtPath:plistDir withIntermediateDirectories:YES attributes:nil error:&error]) {
        NSDebugLLog(@"gwcomp", @"[DEBUG] Failed to create directory %@: %@", plistDir, error);
        return;
    }
    
    NSMutableDictionary *plistData = [NSMutableDictionary dictionaryWithContentsOfFile:plistPath];
    if (!plistData) {
        plistData = [NSMutableDictionary dictionary];
    }
    
    [plistData setObject:sessionExec forKey:@"lastSession"];
    
    if ([plistData writeToFile:plistPath atomically:YES]) {
        NSDebugLLog(@"gwcomp", @"[DEBUG] Successfully saved last chosen session to %@", plistPath);
    } else {
        NSDebugLLog(@"gwcomp", @"[DEBUG] Failed to save last chosen session to %@", plistPath);
    }
}

- (NSString *)loadLastSession
{
    NSDebugLLog(@"gwcomp", @"[DEBUG] Loading last chosen session from system-wide plist");
    
    NSString *plistPath = [self getLoginWindowPreferencesPath];
    NSDictionary *plistData = [NSDictionary dictionaryWithContentsOfFile:plistPath];
    
    NSString *lastSession = [plistData objectForKey:@"lastSession"];
    
    if (lastSession && [lastSession length] > 0) {
        NSDebugLLog(@"gwcomp", @"[DEBUG] Loaded last chosen session: %@", lastSession);
        return lastSession;
    }
    
    NSDebugLLog(@"gwcomp", @"[DEBUG] No last chosen session found in system-wide plist");
    return nil;
}

- (BOOL)isXServerRunning
{
    NSDebugLLog(@"gwcomp", @"[DEBUG] Checking if X server is running");
    
    // Try to connect to display :0 to check if X server is running
    const char *display_name = ":0";
    setenv("DISPLAY", display_name, 1);
    
    // Try to open X display directly with timeout - this is more reliable than using xset
    Display *testDisplay = safeXOpenDisplay(display_name, 2);  // 2 second timeout
    if (testDisplay != NULL) {
        XCloseDisplay(testDisplay);
        NSDebugLLog(@"gwcomp", @"[DEBUG] X server is running on %s", display_name);
        return YES;
    } else {
        NSDebugLLog(@"gwcomp", @"[DEBUG] X server is not running on %s", display_name);
        return NO;
    }
}

- (BOOL)startXServer
{
    NSDebugLLog(@"gwcomp", @"[DEBUG] Starting X server");
    
    // Only wait for /tmp if X is not already running
    if (![self isXServerRunning]) {
        // Wait for /tmp to be writable (up to 20 seconds)
        // This is important on BSD systems where filesystems may still be mounting
        NSDebugLLog(@"gwcomp", @"[DEBUG] X not running yet, checking if /tmp is writable...");
        waitForTmpWritable(20);
    } else {
        NSDebugLLog(@"gwcomp", @"[DEBUG] X server already running, skipping /tmp check");
    }
    
    // Clean up any existing X server processes first
    [self cleanupExistingXServer];
    
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
    generate_xauth_cookie(g_xserver_cookie);
    g_xserver_cookie_valid = YES;
    
    NSDebugLLog(@"gwcomp", @"[DEBUG] Generated X server cookie for unix socket use");
    
    // Note: Unix socket authentication uses file permissions, not cookies
    // The cookie is only stored for reference, not written to a file
    
    // Rotate existing X server log file before starting new session
    NSString *xorgLogPath = @"/var/log/Xorg.0.log";
    NSString *xorgLogOldPath = @"/var/log/Xorg.0.log.old";
    
    if ([[NSFileManager defaultManager] fileExistsAtPath:xorgLogPath]) {
        NSDebugLLog(@"gwcomp", @"[DEBUG] Moving existing X server log to %@", xorgLogOldPath);
        // Remove old backup if it exists
        [[NSFileManager defaultManager] removeItemAtPath:xorgLogOldPath error:nil];
        // Move current log to backup
        NSError *moveError = nil;
        if (![[NSFileManager defaultManager] moveItemAtPath:xorgLogPath toPath:xorgLogOldPath error:&moveError]) {
            NSDebugLLog(@"gwcomp", @"[DEBUG] Failed to rotate X server log: %@", moveError.localizedDescription);
            // Continue anyway - not a fatal error
        } else {
            NSDebugLLog(@"gwcomp", @"[DEBUG] Successfully rotated X server log");
        }
    }
    
    // Start X server on display :0
    pid_t xserver_pid = fork();
    if (xserver_pid == 0) {
        // Child process - start X server
        // IMMEDIATELY redirect file descriptors before ANY other operations
        // to prevent ANY output from going to LoginWindow.log
        
        // Close stdin, stdout, stderr and redirect them properly
        close(STDIN_FILENO);
        close(STDOUT_FILENO);
        close(STDERR_FILENO);
        
        // Redirect stdin to /dev/null
        int nullfd = open("/dev/null", O_RDONLY);
        if (nullfd != STDIN_FILENO) {
            dup2(nullfd, STDIN_FILENO);
            close(nullfd);
        }
        
        // Redirect stdout and stderr to X server's log file
        int logfd = open("/var/log/Xorg.0.log", O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (logfd >= 0) {
            dup2(logfd, STDOUT_FILENO);
            dup2(logfd, STDERR_FILENO);
            if (logfd != STDOUT_FILENO && logfd != STDERR_FILENO) {
                close(logfd);
            }
        } else {
            // Fallback to /dev/null if can't open log file
            int devnull = open("/dev/null", O_WRONLY);
            if (devnull >= 0) {
                dup2(devnull, STDOUT_FILENO);
                dup2(devnull, STDERR_FILENO);
                if (devnull != STDOUT_FILENO && devnull != STDERR_FILENO) {
                    close(devnull);
                }
            }
        }
        
        // Now we can safely do other setup since stdout/stderr are redirected
        // Set up environment for X server
        setenv("DISPLAY", ":0", 1);
        
        // Close all other file descriptors
        int maxfd = sysconf(_SC_OPEN_MAX);
        for (int fd = 3; fd < maxfd; fd++) {
            close(fd);
        }
        
        // Ignore signals that could interfere with X server startup
        signal(SIGTTIN, SIG_IGN);
        signal(SIGTTOU, SIG_IGN);
        signal(SIGUSR1, SIG_IGN);
        
        // Create new process group
        setpgid(0, getpid());
        
        // Start X server with FreeBSD-appropriate configuration
        execl([xserverPath UTF8String], "X", ":0", 
              "-auth", [authFile UTF8String],
              "-nolisten", "tcp", 
              "vt09", 
              (char *)NULL);
        
        // If we get here, exec failed
        // Can't use NSLog here since we redirected stderr
        exit(1);
    } else if (xserver_pid > 0) {
        // Parent process
        NSDebugLLog(@"gwcomp", @"[DEBUG] X server started with PID: %d", xserver_pid);
        
        // Store the PID and mark that we started it
        xServerPid = xserver_pid;
        didStartXServer = YES;
        
        // Wait for X server to start up properly with timeout
        NSDebugLLog(@"gwcomp", @"[DEBUG] Waiting for X server to accept connections");
        int attempts = 0;
        int maxAttempts = 120; // 120 seconds timeout like the reference implementation
        
        while (attempts < maxAttempts) {
            // Check if X server process is still running
            int status;
            pid_t result = waitpid(xserver_pid, &status, WNOHANG);
            
            if (result == xserver_pid) {
                // X server died
                NSDebugLLog(@"gwcomp", @"[DEBUG] X server died during startup");
                didStartXServer = NO;
                xServerPid =  0;
                return NO;
            }
            
            // Try to connect to X server
            if ([self isXServerRunning]) {
                NSDebugLLog(@"gwcomp", @"[DEBUG] X server successfully started and ready");
            return YES;
            }
            
            usleep(200000); // Sleep for 0.2 seconds (200,000 microseconds)
            attempts++;
            
            if (attempts % 10 == 0) {
                sleep(1); // Sleep for 1 second every 10 attempts
                NSDebugLLog(@"gwcomp", @"[DEBUG] Still waiting for X server (attempt %d/%d)", attempts, maxAttempts);
            }
        }
        
        NSDebugLLog(@"gwcomp", @"[DEBUG] X server failed to become ready within timeout");
        // Kill the X server since it's not responding
        if (kill(xServerPid, SIGTERM) == 0) {
            sleep(2);
            kill(xServerPid, SIGKILL);
        }
        didStartXServer = NO;
        xServerPid = 0;
        return NO;
    } else {
        NSDebugLLog(@"gwcomp", @"[DEBUG] Failed to fork for X server: %s", strerror(errno));
        return NO;
    }
}

- (void)ensureXServerRunning
{
    NSDebugLLog(@"gwcomp", @"[DEBUG] Ensuring X server is running");
    
    if ([self isXServerRunning]) {
        NSDebugLLog(@"gwcomp", @"[DEBUG] X server is already running");
        return;
    }
    
    NSDebugLLog(@"gwcomp", @"[DEBUG] X server is not running, attempting to start it");
    
    if ([self startXServer]) {
        NSDebugLLog(@"gwcomp", @"[DEBUG] Successfully started X server");
    } else {
        NSDebugLLog(@"gwcomp", @"[DEBUG] Failed to start X server - continuing anyway");
        // We continue even if X server fails to start, as the user might want to
        // use a different display manager or start X manually
    }
}

- (void)stopXServerIfStartedByUs
{
    if (!didStartXServer || xServerPid <= 0) {
        NSDebugLLog(@"gwcomp", @"[DEBUG] X server was not started by us, not stopping it");
        return;
    }
    
    NSDebugLLog(@"gwcomp", @"[DEBUG] Stopping X server that we started (PID: %d)", xServerPid);
    
    // Send SIGTERM first for graceful shutdown
    if (kill(xServerPid, SIGTERM) == 0) {
        NSDebugLLog(@"gwcomp", @"[DEBUG] Sent SIGTERM to X server, waiting for it to exit");
        
        // Wait up to 5 seconds for graceful shutdown
        int attempts = 0;
        while (attempts < 10) {
            int status;
            pid_t result = waitpid(xServerPid, &status, WNOHANG);
            
            if (result == xServerPid) {
                NSDebugLLog(@"gwcomp", @"[DEBUG] X server exited gracefully");
                didStartXServer = NO;
                xServerPid = 0;
                return;
            } else if (result == -1) {
                // Process doesn't exist anymore
                NSDebugLLog(@"gwcomp", @"[DEBUG] X server process no longer exists");
                didStartXServer = NO;
                xServerPid = 0;
                return;
            }
            
            usleep(500000); // 0.5 seconds
            attempts++;
        }
        
        // If still running, send SIGKILL
        NSDebugLLog(@"gwcomp", @"[DEBUG] X server didn't exit gracefully, sending SIGKILL");
        if (kill(xServerPid, SIGKILL) == 0) {
            NSDebugLLog(@"gwcomp", @"[DEBUG] Sent SIGKILL to X server");
            waitpid(xServerPid, NULL, 0); // Wait for it to die
        } else {
            NSDebugLLog(@"gwcomp", @"[DEBUG] Failed to send SIGKILL to X server: %s", strerror(errno));
        }
    } else {
        NSDebugLLog(@"gwcomp", @"[DEBUG] Failed to send SIGTERM to X server: %s", strerror(errno));
    }
    
    didStartXServer = NO;
    xServerPid = 0;
}

- (void)cleanupExistingXServer
{
    NSDebugLLog(@"gwcomp", @"[DEBUG] Cleaning up any existing X server processes");
    
    // Clean up lock files and sockets for display :0
    unlink("/tmp/.X0-lock");
    unlink("/tmp/.X11-unix/X0");
    
    // Kill any existing X server processes on display :0 using native code
    [self killProcessesMatchingPattern:@"X" displayNumber:@":0"];
    [self killProcessesMatchingPattern:@"Xorg" displayNumber:@":0"];
    
    // Wait a moment for cleanup
    usleep(500000); // 0.5 seconds
    
    NSDebugLLog(@"gwcomp", @"[DEBUG] X server cleanup complete");
}

- (void)killProcessesMatchingPattern:(NSString *)pattern displayNumber:(NSString *)displayNum
{
    NSDebugLLog(@"gwcomp", @"[DEBUG] Looking for processes matching pattern: %@", pattern);
    
#if defined(__linux__)
    // Linux implementation using /proc filesystem
    DIR *proc_dir = opendir("/proc");
    if (!proc_dir) {
        NSDebugLLog(@"gwcomp", @"[DEBUG] Failed to open /proc directory: %s", strerror(errno));
        return;
    }
    
    struct dirent *entry;
    while ((entry = readdir(proc_dir)) != NULL) {
        // Skip non-numeric entries
        if (!isdigit(entry->d_name[0])) {
            continue;
        }
        
        pid_t pid = atoi(entry->d_name);
        
        // Skip kernel processes, init, and our own process
        if (pid <= 1 || pid == getpid()) {
            continue;
        }
        
        // Read /proc/PID/cmdline to get process command line
        char cmdline_path[256];
        snprintf(cmdline_path, sizeof(cmdline_path), "/proc/%d/cmdline", pid);
        
        FILE *cmdline_file = fopen(cmdline_path, "r");
        if (!cmdline_file) {
            continue; // Process might have disappeared
        }
        
        // Read the command line (null-separated arguments)
        char cmdline[512] = {0};
        size_t bytes_read = fread(cmdline, 1, sizeof(cmdline) - 1, cmdline_file);
        fclose(cmdline_file);
        
        // Replace null separators with spaces for searching
        for (size_t i = 0; i < bytes_read; i++) {
            if (cmdline[i] == '\0') {
                cmdline[i] = ' ';
            }
        }
        cmdline[bytes_read] = '\0';
        
        // Check if command line matches pattern and display number
        NSString *cmdlineStr = [NSString stringWithUTF8String:cmdline];
        
        // Simple pattern matching: check if pattern exists and display number exists in cmdline
        if ([cmdlineStr rangeOfString:pattern].location != NSNotFound &&
            [cmdlineStr rangeOfString:displayNum].location != NSNotFound) {
            
            NSDebugLLog(@"gwcomp", @"[DEBUG] Found X server process: PID=%d, Command=%s", pid, cmdline);
            
            // Try SIGTERM first, then SIGKILL
            if (kill(pid, SIGTERM) != 0) {
                if (errno != ESRCH) {
                    NSDebugLLog(@"gwcomp", @"[DEBUG] SIGTERM failed for PID %d, trying SIGKILL: %s", pid, strerror(errno));
                    kill(pid, SIGKILL);
                }
            } else {
                // Give process time to terminate gracefully
                usleep(200000); // 200ms
                // If still alive, force kill
                if (kill(pid, 0) == 0) {
                    kill(pid, SIGKILL);
                }
            }
        }
    }
    
    closedir(proc_dir);
    
#else
    // BSD implementation using sysctl. OpenBSD's KERN_PROC needs a 6-element
    // mib carrying the struct size and element count; FreeBSD uses 3.
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
        NSDebugLLog(@"gwcomp", @"[DEBUG] Failed to get process list size: %s", strerror(errno));
        return;
    }

    struct kinfo_proc *procs = malloc(size);
    if (!procs) {
        NSDebugLLog(@"gwcomp", @"[DEBUG] Failed to allocate memory for process list");
        return;
    }

#if defined(__OpenBSD__)
    mib[5] = (int)(size / sizeof(struct kinfo_proc));
#endif
    if (sysctl(mib, miblen, procs, &size, NULL, 0) != 0) {
        NSDebugLLog(@"gwcomp", @"[DEBUG] Failed to get process list: %s", strerror(errno));
        free(procs);
        return;
    }

    int numProcs = size / sizeof(struct kinfo_proc);
    NSDebugLLog(@"gwcomp", @"[DEBUG] Checking %d processes for X server cleanup", numProcs);

    for (int i = 0; i < numProcs; i++) {
        pid_t pid = procs[i].GW_KP_PID;

        // Skip kernel processes, init, and our own process
        if (pid <= 1 || pid == getpid()) {
            continue;
        }

        // Build a searchable command-line string for this process.
        NSMutableString *cmdlineStr = [NSMutableString string];
#if defined(__OpenBSD__)
        // OpenBSD: KERN_PROC_ARGS sits directly under CTL_KERN and, with
        // KERN_PROC_ARGV, returns an argv pointer array into the buffer.
        int mib_args[4] = {CTL_KERN, KERN_PROC_ARGS, pid, KERN_PROC_ARGV};
        size_t args_size = 0;

        if (sysctl(mib_args, 4, NULL, &args_size, NULL, 0) != 0) {
            continue; // Process might have disappeared
        }

        char **argv = malloc(args_size);
        if (!argv) {
            continue;
        }

        if (sysctl(mib_args, 4, argv, &args_size, NULL, 0) != 0) {
            free(argv);
            continue;
        }

        for (char **ap = argv; *ap != NULL; ap++) {
            if ([cmdlineStr length] > 0) {
                [cmdlineStr appendString:@" "];
            }
            [cmdlineStr appendString:[NSString stringWithUTF8String:*ap]];
        }

        free(argv);
#else
        // FreeBSD: KERN_PROC_ARGS returns a flat NUL-separated argument buffer.
        int mib_args[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ARGS, pid};
        size_t args_size = 0;

        if (sysctl(mib_args, 4, NULL, &args_size, NULL, 0) != 0) {
            continue; // Process might have disappeared
        }

        char *args = malloc(args_size);
        if (!args) {
            continue;
        }

        if (sysctl(mib_args, 4, args, &args_size, NULL, 0) != 0) {
            free(args);
            continue;
        }

        char *p = args;
        char *end = args + args_size;

        while (p < end) {
            size_t len = strlen(p);
            if (len == 0) break;

            if ([cmdlineStr length] > 0) {
                [cmdlineStr appendString:@" "];
            }
            [cmdlineStr appendString:[NSString stringWithUTF8String:p]];
            p += len + 1;
        }

        free(args);
#endif

        // Check if command line matches pattern and display number
        if ([cmdlineStr rangeOfString:pattern].location != NSNotFound &&
            [cmdlineStr rangeOfString:displayNum].location != NSNotFound) {
            
            NSDebugLLog(@"gwcomp", @"[DEBUG] Found X server process: PID=%d, Command=%@", pid, cmdlineStr);
            
            // Try SIGTERM first, then SIGKILL
            if (kill(pid, SIGTERM) != 0) {
                if (errno != ESRCH) {
                    NSDebugLLog(@"gwcomp", @"[DEBUG] SIGTERM failed for PID %d, trying SIGKILL: %s", pid, strerror(errno));
                    kill(pid, SIGKILL);
                }
            } else {
                // Give process time to terminate gracefully
                usleep(200000); // 200ms
                // If still alive, force kill
                if (kill(pid, 0) == 0) {
                    kill(pid, SIGKILL);
                }
            }
        }
    }
    
    free(procs);
#endif
}
 
- (void)shakeWindow
{
    NSDebugLLog(@"gwcomp", @"[DEBUG] shakeWindow called");
    @try {
        if (!loginWindow) {
            NSDebugLLog(@"gwcomp", @"[WARNING] loginWindow is NULL, cannot shake");
            return;
        }
        
        NSRect originalFrame = [loginWindow frame];
        NSDebugLLog(@"gwcomp", @"[DEBUG] Original frame: x=%.1f, y=%.1f", originalFrame.origin.x, originalFrame.origin.y);
        
        // Simple shake without NSViewAnimation to avoid potential crashes
        CGFloat shakeDistance = 10.0;
        int shakeCount = 2; // Reduced shakes
        
        for (int i = 0; i < shakeCount; i++) {
            // Shake left
            NSRect leftFrame = originalFrame;
            leftFrame.origin.x -= shakeDistance;
            [loginWindow setFrameOrigin:leftFrame.origin];
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
            
            // Shake right
            NSRect rightFrame = originalFrame;
            rightFrame.origin.x += shakeDistance;
            [loginWindow setFrameOrigin:rightFrame.origin];
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
            shakeDistance *= 0.7;
        }
        
        // Return to original position
        [loginWindow setFrameOrigin:originalFrame.origin];
        NSDebugLLog(@"gwcomp", @"[DEBUG] Window shake complete");
    } @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"[ERROR] Exception in shakeWindow: %@", exception);
    }
}

// Allow login without password (works e.g., on GhostBSD Live ISOs)
// Enabling login when username is present even if password is empty. PAM policy may accept empty passwords in some environments (Live ISOs).
- (void)updateLoginButtonState
{
    NSString *username = [usernameField stringValue];
    NSString *password = [passwordField stringValue];
    
    BOOL hasUsername = username && [username length] > 0;
    BOOL hasPassword = password && [password length] > 0;
    // Allow login without password if username is present.
    BOOL shouldEnable = hasUsername;
    
    [loginButton setEnabled:shouldEnable];
    
    NSDebugLLog(@"gwcomp", @"[DEBUG] Login button state updated - username: %s, password: %s, enabled: %s",
          hasUsername ? "yes" : "no",
          hasPassword ? "yes" : "no", 
          shouldEnable ? "yes" : "no");
}

- (void)controlTextDidChange:(NSNotification *)notification
{
    NSTextField *textField = [notification object];
    
    if (textField == usernameField || textField == passwordField) {
        [self updateLoginButtonState];
    }
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)commandSelector
{
    NSDebugLLog(@"gwcomp", @"[DEBUG] Key command received: %@", NSStringFromSelector(commandSelector));
    
    // Handle ESC key (cancelOperation:)
    if (commandSelector == @selector(cancelOperation:)) {
        NSDebugLLog(@"gwcomp", @"[DEBUG] ESC key pressed, clearing fields and shaking");
        [self clearFieldsAndShake];
        return YES;  // Consume the event
    }
    
    return NO;  // Let the system handle other keys
}

- (void)clearFieldsAndShake
{
    NSDebugLLog(@"gwcomp", @"[DEBUG] Clearing fields and shaking window");
    
    // Clear both username and password fields
    [usernameField setStringValue:@""];
    [passwordField setStringValue:@""];
    
    // Update login button state (should be disabled now)
    [self updateLoginButtonState];
    
    // Focus on username field
    [loginWindow makeFirstResponder:usernameField];
    
    // Shake the window
    [self shakeWindow];
}

@end
