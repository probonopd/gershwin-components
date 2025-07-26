#import "LoginWindowApp.h"
#import <pwd.h>
#import <unistd.h>
#import <sys/wait.h>
#import <login_cap.h>
#import <string.h>
#import <grp.h>
#import <errno.h>

#ifdef HAVE_SHADOW
#import <shadow.h>
#endif

@implementation LoginWindowApp

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
    pamAuth = [[LoginWindowPAM alloc] init];
    NSLog(@"[DEBUG] pamAuth initialized: %@", pamAuth);
    [self createLoginWindow];
    [loginWindow makeKeyAndOrderFront:self];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)dealloc
{
    [pamAuth release];
    [super dealloc];
}

- (void)scanAvailableSessions
{
    NSLog(@"[DEBUG] scanAvailableSessions started");
    NSMutableArray *sessions = [NSMutableArray array];
    NSMutableArray *execs = [NSMutableArray array];
    NSArray *dirs = @[ @"/usr/local/share/xsessions", @"/usr/share/xsessions" ];
    NSFileManager *fm = [NSFileManager defaultManager];
    
    for (NSString *dir in dirs) {
        NSLog(@"[DEBUG] Checking directory: %@", dir);
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:dir isDirectory:&isDir] && isDir) {
            NSLog(@"[DEBUG] Directory exists: %@", dir);
            NSArray *files = [fm contentsOfDirectoryAtPath:dir error:nil];
            NSLog(@"[DEBUG] Found %lu files in %@", (unsigned long)[files count], dir);
            for (NSString *file in files) {
                if ([file hasSuffix:@".desktop"]) {
                    NSLog(@"[DEBUG] Processing .desktop file: %@", file);
                    NSString *path = [dir stringByAppendingPathComponent:file];
                    NSString *name = nil;
                    NSString *exec = nil;
                    NSString *content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
                    NSArray *lines = [content componentsSeparatedByString:@"\n"];
                    for (NSString *line in lines) {
                        if ([line hasPrefix:@"Name="]) {
                            name = [line substringFromIndex:5];
                            NSLog(@"[DEBUG] Found Name: %@", name);
                        } else if ([line hasPrefix:@"Exec="]) {
                            exec = [line substringFromIndex:5];
                            NSLog(@"[DEBUG] Found Exec: %@", exec);
                        }
                    }
                    if (name && exec) {
                        NSLog(@"[DEBUG] Adding session: %@ -> %@", name, exec);
                        [sessions addObject:name];
                        [execs addObject:exec];
                    }
                }
            }
        } else {
            NSLog(@"[DEBUG] Directory does not exist or is not a directory: %@", dir);
        }
    }
    
    if ([sessions count] == 0) {
        NSLog(@"[DEBUG] No sessions found in .desktop files, adding defaults");
        [sessions addObject:@"Gershwin (default)"];
        [execs addObject:@"/System/Applications/GWorkspace.app/GWorkspace"];
        
        // Check if mate-session is available
        if ([[NSFileManager defaultManager] fileExistsAtPath:@"/usr/local/bin/mate-session"]) {
            [sessions addObject:@"MATE"];
            [execs addObject:@"/usr/local/bin/mate-session"];
            NSLog(@"[DEBUG] Added MATE session");
        }
        
        // Check if window managers are available
        if ([[NSFileManager defaultManager] fileExistsAtPath:@"/usr/local/bin/wmaker"]) {
            [sessions addObject:@"WindowMaker"];
            [execs addObject:@"/usr/local/bin/wmaker"];
            NSLog(@"[DEBUG] Added WindowMaker");
        }
        if ([[NSFileManager defaultManager] fileExistsAtPath:@"/usr/bin/twm"]) {
            [sessions addObject:@"TWM"];
            [execs addObject:@"/usr/bin/twm"];
            NSLog(@"[DEBUG] Added TWM");
        }
    }
    
    availableSessions = [sessions copy];
    availableSessionExecs = [execs copy];
    selectedSessionExec = [execs firstObject];
    
    NSLog(@"[DEBUG] Final available sessions: %@", availableSessions);
    NSLog(@"[DEBUG] Final available execs: %@", availableSessionExecs);
    NSLog(@"[DEBUG] Initial selected exec: %@", selectedSessionExec);
}

- (void)createLoginWindow
{
    [self scanAvailableSessions];
    
    NSRect windowFrame = NSMakeRect(0, 0, 400, 300);
    
    char hostname[256] = "";
    gethostname(hostname, sizeof(hostname));
    NSString *computerName = [NSString stringWithUTF8String:hostname];
    loginWindow = [[NSWindow alloc] 
        initWithContentRect:windowFrame
                  styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                    backing:NSBackingStoreBuffered
                      defer:NO];
    [loginWindow setTitle:computerName];
    [loginWindow setBackgroundColor:[NSColor colorWithCalibratedRed:0.95 green:0.95 blue:0.95 alpha:1.0]];
    [loginWindow setLevel:NSScreenSaverWindowLevel];
    [loginWindow setCanHide:NO];
    [loginWindow center];
    [loginWindow makeKeyAndOrderFront:self];
    [loginWindow makeMainWindow];
    [loginWindow setIgnoresMouseEvents:NO];
    [loginWindow setAcceptsMouseMovedEvents:YES];
    
    NSView *contentView = [loginWindow contentView];
    
    // Logo/Title
    NSTextField *titleLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(50, 220, 300, 40)];
    [titleLabel setStringValue:computerName];
    [titleLabel setAlignment:NSCenterTextAlignment];
    [titleLabel setFont:[NSFont boldSystemFontOfSize:24]];
    [titleLabel setBezeled:NO];
    [titleLabel setDrawsBackground:NO];
    [titleLabel setEditable:NO];
    [titleLabel setSelectable:NO];
    [contentView addSubview:titleLabel];
    
    // Username field
    NSTextField *usernameLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(50, 180, 100, 20)];
    [usernameLabel setStringValue:@"Username:"];
    [usernameLabel setBezeled:NO];
    [usernameLabel setDrawsBackground:NO];
    [usernameLabel setEditable:NO];
    [usernameLabel setSelectable:NO];
    [contentView addSubview:usernameLabel];
    
    usernameField = [[NSTextField alloc] initWithFrame:NSMakeRect(160, 180, 190, 22)];
    [usernameField setBezeled:YES];
    [usernameField setBezelStyle:NSTextFieldSquareBezel];
    [usernameField setEditable:YES];
    [usernameField setSelectable:YES];
    [usernameField setEnabled:YES];
    [contentView addSubview:usernameField];
    
    // Password field
    NSTextField *passwordLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(50, 150, 100, 20)];
    [passwordLabel setStringValue:@"Password:"];
    [passwordLabel setBezeled:NO];
    [passwordLabel setDrawsBackground:NO];
    [passwordLabel setEditable:NO];
    [passwordLabel setSelectable:NO];
    [contentView addSubview:passwordLabel];
    
    passwordField = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(160, 150, 190, 22)];
    [passwordField setBezeled:YES];
    [passwordField setBezelStyle:NSTextFieldSquareBezel];
    [passwordField setEditable:YES];
    [passwordField setSelectable:YES];
    [passwordField setEnabled:YES];
    [contentView addSubview:passwordField];
    
    // Login button
    loginButton = [[NSButton alloc] initWithFrame:NSMakeRect(160, 110, 80, 32)];
    [loginButton setTitle:@"Login"];
    [loginButton setBezelStyle:NSRoundedBezelStyle];
    [loginButton setTarget:self];
    [loginButton setAction:@selector(loginButtonPressed:)];
    [loginButton setKeyEquivalent:@"\r"];
    [contentView addSubview:loginButton];
    
    // Shutdown button
    shutdownButton = [[NSButton alloc] initWithFrame:NSMakeRect(50, 50, 80, 32)];
    [shutdownButton setTitle:@"Shutdown"];
    [shutdownButton setBezelStyle:NSRoundedBezelStyle];
    [shutdownButton setTarget:self];
    [shutdownButton setAction:@selector(shutdownButtonPressed:)];
    [contentView addSubview:shutdownButton];
    
    // Restart button
    restartButton = [[NSButton alloc] initWithFrame:NSMakeRect(140, 50, 80, 32)];
    [restartButton setTitle:@"Restart"];
    [restartButton setBezelStyle:NSRoundedBezelStyle];
    [restartButton setTarget:self];
    [restartButton setAction:@selector(restartButtonPressed:)];
    [contentView addSubview:restartButton];
    
    // Status label
    statusLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(50, 20, 300, 20)];
    [statusLabel setStringValue:@""];
    [statusLabel setAlignment:NSCenterTextAlignment];
    [statusLabel setBezeled:NO];
    [statusLabel setDrawsBackground:NO];
    [statusLabel setEditable:NO];
    [statusLabel setSelectable:NO];
    [statusLabel setTextColor:[NSColor redColor]];
    [contentView addSubview:statusLabel];
    
    // Session dropdown
    sessionDropdown = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(50, 80, 300, 24)];
    [sessionDropdown addItemsWithTitles:availableSessions];
    [sessionDropdown setTarget:self];
    [sessionDropdown setAction:@selector(sessionChanged:)];
    [contentView addSubview:sessionDropdown];
    
    // Set initial focus
    [loginWindow makeFirstResponder:usernameField];
    // Make window key and main to accept input
    [loginWindow makeKeyAndOrderFront:self];
    [loginWindow setIgnoresMouseEvents:NO];
    [loginWindow setAcceptsMouseMovedEvents:YES];
    
    [usernameField setNextKeyView:passwordField];
    [passwordField setNextKeyView:usernameField];
}

- (void)loginButtonPressed:(id)sender
{
    NSLog(@"[DEBUG] loginButtonPressed called");
    NSString *username = [usernameField stringValue];
    NSString *password = [passwordField stringValue];
    
    if ([username length] == 0) {
        [self showStatus:@"Please enter username"];
        return;
    }
    
    if ([password length] == 0) {
        [self showStatus:@"Please enter password"];
        return;
    }
    
    [self showStatus:@"Authenticating..."];
    
    NSLog(@"[DEBUG] authenticateUser:password: will be called");
    if ([self authenticateUser:username password:password]) {
        NSLog(@"[DEBUG] authenticateUser:password: returned YES");
        [self showStatus:@"Login successful"];
        [self startUserSession:username];
    } else {
        NSLog(@"[DEBUG] authenticateUser:password: returned NO");
        [self showStatus:@"Authentication failed"];
        [passwordField setStringValue:@""];
        [loginWindow makeFirstResponder:passwordField];
    }
}

- (void)shutdownButtonPressed:(id)sender
{
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:@"Shutdown Computer"];
    [alert setInformativeText:@"Are you sure you want to shutdown the computer?"];
    [alert addButtonWithTitle:@"Shutdown"];
    [alert addButtonWithTitle:@"Cancel"];
    
    NSInteger result = [alert runModal];
    if (result == NSAlertFirstButtonReturn) {
        system("sudo -A shutdown -h now");
    }
}

- (void)restartButtonPressed:(id)sender
{
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:@"Restart Computer"];
    [alert setInformativeText:@"Are you sure you want to restart the computer?"];
    [alert addButtonWithTitle:@"Restart"];
    [alert addButtonWithTitle:@"Cancel"];
    
    NSInteger result = [alert runModal];
    if (result == NSAlertFirstButtonReturn) {
        system("sudo -A shutdown -r now");
    }
}

- (BOOL)authenticateUser:(NSString *)username password:(NSString *)password
{
    // Use PAM for authentication (just like SLiM does)
    return [pamAuth authenticateUser:username password:password];
}

- (void)startUserSession:(NSString *)username
{
    NSLog(@"[DEBUG] startUserSession called for user: %@", username);
    const char *user_cstr = [username UTF8String];
    struct passwd *pwd = getpwnam(user_cstr);
    
    if (!pwd) {
        NSLog(@"[DEBUG] User not found: %@", username);
        [self showStatus:@"User not found"];
        return;
    }
    
    NSLog(@"[DEBUG] User found - UID: %d, GID: %d, Home: %s, Shell: %s", 
          pwd->pw_uid, pwd->pw_gid, pwd->pw_dir, pwd->pw_shell);
    
    // Open PAM session
    if (![pamAuth openSession]) {
        NSLog(@"[DEBUG] Failed to open PAM session");
        [self showStatus:@"Failed to open PAM session"];
        return;
    }
    
    NSLog(@"[DEBUG] PAM session opened successfully");
    
    // Get PAM environment
    char **pam_envlist = [pamAuth getEnvironmentList];
    NSLog(@"[DEBUG] PAM environment list obtained: %p", pam_envlist);
    
    // Log current selected session
    NSLog(@"[DEBUG] Currently selected session executable: %@", selectedSessionExec);
    NSLog(@"[DEBUG] Available sessions: %@", availableSessions);
    NSLog(@"[DEBUG] Available session execs: %@", availableSessionExecs);
    
    // Change to user's home directory
    if (chdir(pwd->pw_dir) != 0) {
        NSLog(@"[DEBUG] Cannot change to home directory: %s", pwd->pw_dir);
        [self showStatus:@"Cannot change to home directory"];
        [pamAuth closeSession];
        return;
    }
    
    NSLog(@"[DEBUG] Changed to user home directory: %s", pwd->pw_dir);
    
    // Start the user's session
    NSLog(@"[DEBUG] About to fork for session");
    pid_t pid = fork();
    if (pid == 0) {
        // Child process - create new session to avoid X11 threading issues
        NSLog(@"[DEBUG] Child process started");
        setsid();
        
        // Close all file descriptors except stdin, stdout, stderr
        int maxfd = sysconf(_SC_OPEN_MAX);
        NSLog(@"[DEBUG] Closing file descriptors up to: %d", maxfd);
        for (int fd = 3; fd < maxfd; fd++) {
            close(fd);
        }
        
        NSLog(@"[DEBUG] About to set user context for user: %s (uid=%d, gid=%d)", pwd->pw_name, pwd->pw_uid, pwd->pw_gid);
        
        // Use manual setup for better error reporting
        NSLog(@"[DEBUG] Starting manual user setup");
        
        // Set supplementary groups first
        NSLog(@"[DEBUG] Calling initgroups for user: %s, gid: %d", pwd->pw_name, pwd->pw_gid);
        if (initgroups(pwd->pw_name, pwd->pw_gid) != 0) {
            int err = errno;
            perror("initgroups failed");
            NSLog(@"[DEBUG] initgroups failed for user: %s, gid: %d (errno: %d - %s)", pwd->pw_name, pwd->pw_gid, err, strerror(err));
            exit(1);
        }
        NSLog(@"[DEBUG] initgroups succeeded for user: %s", pwd->pw_name);
        
        // Set group ID
        NSLog(@"[DEBUG] Calling setgid for gid: %d", pwd->pw_gid);
        if (setgid(pwd->pw_gid) != 0) {
            int err = errno;
            perror("setgid failed");
            NSLog(@"[DEBUG] setgid failed for gid: %d (errno: %d - %s)", pwd->pw_gid, err, strerror(err));
            exit(1);
        }
        NSLog(@"[DEBUG] setgid succeeded for gid: %d", pwd->pw_gid);
        
        // Set user ID (this must be last)
        NSLog(@"[DEBUG] Calling setuid for uid: %d", pwd->pw_uid);
        if (setuid(pwd->pw_uid) != 0) {
            int err = errno;
            perror("setuid failed");
            NSLog(@"[DEBUG] setuid failed for uid: %d (errno: %d - %s)", pwd->pw_uid, err, strerror(err));
            exit(1);
        }
        NSLog(@"[DEBUG] setuid succeeded for uid: %d", pwd->pw_uid);
        
        // Verify the change worked
        uid_t real_uid = getuid();
        uid_t eff_uid = geteuid();
        gid_t real_gid = getgid();
        gid_t eff_gid = getegid();
        NSLog(@"[DEBUG] After user setup - real_uid: %d, eff_uid: %d, real_gid: %d, eff_gid: %d", 
              real_uid, eff_uid, real_gid, eff_gid);
        
        if (real_uid != pwd->pw_uid || eff_uid != pwd->pw_uid) {
            NSLog(@"[DEBUG] UID verification failed - expected: %d, got real: %d, eff: %d", pwd->pw_uid, real_uid, eff_uid);
            exit(1);
        }
        
        if (real_gid != pwd->pw_gid || eff_gid != pwd->pw_gid) {
            NSLog(@"[DEBUG] GID verification failed - expected: %d, got real: %d, eff: %d", pwd->pw_gid, real_gid, eff_gid);
            exit(1);
        }
        
        NSLog(@"[DEBUG] Manual user setup completed successfully");
        
        NSLog(@"[DEBUG] User context setup complete");
        
        // Clear signal handlers and reset signal mask
        signal(SIGTERM, SIG_DFL);
        signal(SIGINT, SIG_DFL);
        signal(SIGHUP, SIG_DFL);
        signal(SIGCHLD, SIG_DFL);
        
        NSLog(@"[DEBUG] Signal handlers reset");
        
        // Set up environment for the session
        clearenv();
        setenv("USER", user_cstr, 1);
        setenv("LOGNAME", user_cstr, 1);
        setenv("HOME", pwd->pw_dir, 1);
        setenv("SHELL", pwd->pw_shell, 1);
        setenv("DISPLAY", ":0", 1);
        setenv("PATH", "/usr/local/bin:/usr/bin:/bin", 1);
        setenv("GNUSTEP_USER_ROOT", [[NSString stringWithFormat:@"%s/GNUstep", pwd->pw_dir] UTF8String], 1);
        setenv("XAUTHORITY", [[NSString stringWithFormat:@"%s/.Xauthority", pwd->pw_dir] UTF8String], 1);
        
        NSLog(@"[DEBUG] Basic environment set");
        
        // Set PAM environment variables
        if (pam_envlist) {
            NSLog(@"[DEBUG] Setting PAM environment variables");
            for (int i = 0; pam_envlist[i]; i++) {
                NSLog(@"[DEBUG] PAM env[%d]: %s", i, pam_envlist[i]);
                putenv(pam_envlist[i]);
            }
        } else {
            NSLog(@"[DEBUG] No PAM environment variables to set");
        }
        
        // Change to user's home directory
        if (chdir(pwd->pw_dir) != 0) {
            NSLog(@"[DEBUG] chdir failed in child process");
            exit(1);
        }
        
        NSLog(@"[DEBUG] Changed to home dir in child: %s", pwd->pw_dir);
        
        // Execute the selected session directly (like SLiM does)
        NSString *sessionToExecute = selectedSessionExec;
        NSLog(@"[DEBUG] Initial session to execute: '%@'", sessionToExecute ? sessionToExecute : @"(nil)");
        NSLog(@"[DEBUG] Available sessions: %@", availableSessions);
        NSLog(@"[DEBUG] Available session execs: %@", availableSessionExecs);
        
        if (!sessionToExecute || [sessionToExecute length] == 0) {
            NSLog(@"[DEBUG] No session selected, using default: GWorkspace");
            sessionToExecute = @"/System/Applications/GWorkspace.app/GWorkspace";
        }
        
        NSLog(@"[DEBUG] Final session to execute: '%@'", sessionToExecute);
        NSLog(@"[DEBUG] User shell: %s", pwd->pw_shell);
        
        // Check if the executable exists
        NSArray *sessionComponents = [sessionToExecute componentsSeparatedByString:@" "];
        NSString *mainExecutable = [sessionComponents firstObject];
        NSLog(@"[DEBUG] Main executable from session command: '%@'", mainExecutable);
        
        if ([mainExecutable hasPrefix:@"/"]) {
            // Absolute path - check if it exists
            NSLog(@"[DEBUG] Checking if session executable exists: %@", mainExecutable);
            if ([[NSFileManager defaultManager] fileExistsAtPath:mainExecutable]) {
                NSLog(@"[DEBUG] Session executable exists: %@", mainExecutable);
            } else {
                NSLog(@"[DEBUG] Session executable not found: %@", mainExecutable);
                // Try fallback
                sessionToExecute = @"/System/Applications/GWorkspace.app/GWorkspace";
                NSLog(@"[DEBUG] Using fallback session: %@", sessionToExecute);
            }
        } else {
            NSLog(@"[DEBUG] Session executable is not absolute path: %@", mainExecutable);
            // It will be resolved by the shell through PATH
        }
        
        // Execute the session through the user's shell
        NSLog(@"[DEBUG] About to execl with shell: %s, command: %s", pwd->pw_shell, [sessionToExecute UTF8String]);
        execl(pwd->pw_shell, pwd->pw_shell, "-c", [sessionToExecute UTF8String], NULL);
        
        // If execl fails, log and exit
        NSLog(@"[DEBUG] execl failed for session: %@", sessionToExecute);
        perror("execl failed");
        exit(1);
    } else if (pid > 0) {
        // Parent process - wait for session to complete like SLiM does
        NSLog(@"[DEBUG] Parent process, session PID: %d", pid);
        printf("Session started for user %s (PID: %d)\n", user_cstr, pid);
        
        // Hide the login window during session
        [loginWindow orderOut:self];
        NSLog(@"[DEBUG] Login window hidden, waiting for session to end");
        
        // Wait for the session to end
        int status;
        pid_t wpid = -1;
        while (wpid != pid) {
            wpid = waitpid(pid, &status, 0);
        }
        
        NSLog(@"[DEBUG] Session ended with status: %d", status);
        if (WIFEXITED(status)) {
            NSLog(@"[DEBUG] Session exited normally with code: %d", WEXITSTATUS(status));
        } else if (WIFSIGNALED(status)) {
            NSLog(@"[DEBUG] Session terminated by signal: %d", WTERMSIG(status));
        }
        
        // Session ended, close PAM session
        [pamAuth closeSession];
        
        // Show login window again and reset fields
        [loginWindow makeKeyAndOrderFront:self];
        [passwordField setStringValue:@""];
        [usernameField setStringValue:@""];
        [self showStatus:@"Session ended"];
        [loginWindow makeFirstResponder:usernameField];
        NSLog(@"[DEBUG] Login window restored");
    } else {
        NSLog(@"[DEBUG] Fork failed");
        [self showStatus:@"Failed to start session"];
        [pamAuth closeSession];
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
    NSLog(@"[DEBUG] Session changed to index: %ld", (long)idx);
    if (idx >= 0 && idx < [availableSessionExecs count]) {
        selectedSessionExec = [availableSessionExecs objectAtIndex:idx];
        NSLog(@"[DEBUG] Selected session exec: %@", selectedSessionExec);
    } else {
        NSLog(@"[DEBUG] Invalid session index: %ld (count: %lu)", (long)idx, (unsigned long)[availableSessionExecs count]);
    }
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender
{
    return YES;
}

@end
