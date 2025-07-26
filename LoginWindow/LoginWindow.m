#import "LoginWindow.h"
#import <pwd.h>
#import <unistd.h>
#import <sys/wait.h>
#import <login_cap.h>
#import <string.h>
#import <grp.h>
#import <errno.h>
#import <signal.h>
#import <sys/sysctl.h>
#import <sys/user.h>
#import <libutil.h>

#ifdef HAVE_SHADOW
#import <shadow.h>
#endif

// Signal handler for cleanup on termination
void signalHandler(int sig) {
    NSLog(@"[DEBUG] Received signal %d, performing cleanup", sig);
    // We can't safely call Objective-C methods from a signal handler,
    // but we can at least try to kill processes using the global variables
    // Note: This is not the safest approach, but it's better than nothing
    if (sig == SIGTERM || sig == SIGINT) {
        exit(0); // This will trigger applicationWillTerminate
    }
}

@implementation LoginWindow

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
    pamAuth = [[LoginWindowPAM alloc] init];
    NSLog(@"[DEBUG] pamAuth initialized: %@", pamAuth);
    sessionPid = 0;
    sessionUid = 0;
    sessionGid = 0;
    
    // Set up signal handlers for cleanup
    signal(SIGTERM, signalHandler);
    signal(SIGINT, signalHandler);
    
    [self createLoginWindow];
    [loginWindow makeKeyAndOrderFront:self];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)dealloc
{
    [pamAuth release];
    [super dealloc];
}

- (void)applicationWillTerminate:(NSNotification *)notification
{
    NSLog(@"[DEBUG] Application terminating, performing session cleanup");
    
    // If we have an active session, kill all its processes
    if (sessionUid > 0) {
        NSLog(@"[DEBUG] Cleaning up active session for UID: %d", sessionUid);
        [self killAllSessionProcesses:sessionUid];
        
        // Close PAM session if still open
        if (pamAuth) {
            [pamAuth closeSession];
            NSLog(@"[DEBUG] PAM session closed during termination");
        }
    }
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

- (BOOL)trySystemAction:(NSString *)actionType 
{
    // These arrays can be expanded with more commands if needed for other systems
    // or if the current commands fail. The order is important - we try the most
    // common commands first, and if they fail, we try alternatives.
    NSArray *commands;
    if ([actionType isEqualToString:@"restart"]) {
        commands = [NSArray arrayWithObjects:
            [NSArray arrayWithObjects:@"/sbin/shutdown", @"-r", @"now", nil], nil
        ];
    } else if ([actionType isEqualToString:@"shutdown"]) {
        commands = [NSArray arrayWithObjects:
            [NSArray arrayWithObjects:@"/sbin/shutdown", @"-p", @"now", nil], nil
        ];
    } else {
        return NO;
    }
        
    for (NSArray *cmd in commands) {
        NSLog(@"Attempting system action with command: %@", [cmd componentsJoinedByString:@" "]);
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
                NSLog(@"System action command launched successfully: %@", [cmd componentsJoinedByString:@" "]);
                
                // For restart/shutdown commands, if they succeed, the system should restart/shutdown
                // and this application should never reach this point. If we reach here, it means
                // the command succeeded but the system didn't restart/shutdown, which is an error.
                
                // Wait a bit to see if the system actually restarts/shuts down
                NSLog(@"Waiting for system to %@...", actionType);
                [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:5.0]];
                
                // If we reach here, the system didn't restart/shutdown even though the command succeeded
                // This is a failure case - the command succeeded but didn't work
                NSLog(@"System action command succeeded but system did not %@", actionType);
                // Continue to try next command
            } else {
                NSLog(@"System action failed with command: %@, exit status: %d", [cmd componentsJoinedByString:@" "], [task terminationStatus]);
                // Try next command
            }
        }
        @catch (NSException *exception) {
            NSLog(@"Exception while executing system action: %@", exception);
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
        NSLog(@"User confirmed shutdown");
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
        NSLog(@"User confirmed restart");
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
        
        // Create a new session and process group - this is critical for proper cleanup
        pid_t sessionId = setsid();
        if (sessionId == -1) {
            NSLog(@"[DEBUG] setsid() failed: %s", strerror(errno));
            exit(1);
        }
        NSLog(@"[DEBUG] Created new session with SID: %d", sessionId);
        
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
        
        // Set login class environment variables
        login_cap_t *lc = login_getpwclass(pwd);
        if (lc != NULL) {
            NSLog(@"[DEBUG] Setting login class environment variables");
            
            // Set language/locale environment
            const char *lang = login_getcapstr(lc, "lang", NULL, NULL);
            if (lang != NULL) {
                setenv("LANG", lang, 1);
                NSLog(@"[DEBUG] Set LANG=%s", lang);
            }
            
            // Set character set
            const char *charset = login_getcapstr(lc, "charset", NULL, NULL);
            if (charset != NULL) {
                setenv("MM_CHARSET", charset, 1);
                NSLog(@"[DEBUG] Set MM_CHARSET=%s", charset);
            }
            
            // Set timezone
            const char *timezone = login_getcapstr(lc, "timezone", NULL, NULL);
            if (timezone != NULL) {
                setenv("TZ", timezone, 1);
                NSLog(@"[DEBUG] Set TZ=%s", timezone);
            }
            
            // Set manual path
            const char *manpath = login_getcapstr(lc, "manpath", NULL, NULL);
            if (manpath != NULL) {
                setenv("MANPATH", manpath, 1);
                NSLog(@"[DEBUG] Set MANPATH=%s", manpath);
            }
            
            login_close(lc);
            NSLog(@"[DEBUG] Login class environment variables set");
        } else {
            NSLog(@"[DEBUG] No login class found for user");
        }
        
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
        
        // Set up keyboard layout before starting session
        NSLog(@"[DEBUG] Setting up keyboard layout");
        
        // First, try to read keyboard layout from login.conf or environment
        const char *kb_layout = NULL;
        const char *kb_variant = NULL;
        const char *kb_options = NULL;
        
        // Get login capabilities for this user in child process
        login_cap_t *child_lc = login_getpwclass(pwd);
        if (child_lc != NULL) {
            kb_layout = login_getcapstr(child_lc, "keyboard.layout", NULL, NULL);
            kb_variant = login_getcapstr(child_lc, "keyboard.variant", NULL, NULL);
            kb_options = login_getcapstr(child_lc, "keyboard.options", NULL, NULL);
            NSLog(@"[DEBUG] Checked login.conf for keyboard settings");
        }
        
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
            NSLog(@"[DEBUG] No keyboard layout from login.conf or environment, checking /etc/rc.conf");
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
                        NSLog(@"[DEBUG] Found raw keymap in /etc/rc.conf: %s", keymap);
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
                            NSLog(@"[DEBUG] Unknown keymap '%s', using fallback 'us'", keymap);
                        }
                        NSLog(@"[DEBUG] Converted console keymap '%s' to X11 layout '%s'", keymap, kb_layout);
                        if (kb_variant) NSLog(@"[DEBUG] Set variant to '%s'", kb_variant);
                        break;
                    }
                }
                fclose(rc_conf);
            } else {
                NSLog(@"[DEBUG] Could not open /etc/rc.conf");
            }
        }
        
        // Close login capabilities if we opened them
        if (child_lc != NULL) {
            login_close(child_lc);
        }
        
        // Default to US layout if nothing found
        if (!kb_layout) {
            kb_layout = "us";
            NSLog(@"[DEBUG] No keyboard layout found, defaulting to US");
        }
        
        NSLog(@"[DEBUG] Final keyboard layout: %s", kb_layout ? kb_layout : "none");
        if (kb_variant) NSLog(@"[DEBUG] Final keyboard variant: %s", kb_variant);
        if (kb_options) NSLog(@"[DEBUG] Final keyboard options: %s", kb_options);
        
        // Clear existing keyboard options first
        NSLog(@"[DEBUG] Clearing existing keyboard options");
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
        
        NSLog(@"[DEBUG] Executing keyboard setup command: %s", xkb_cmd);
        int kb_result = system(xkb_cmd);
        NSLog(@"[DEBUG] Keyboard setup command result: %d", kb_result);
        
        // Verify the keyboard layout was set correctly
        NSLog(@"[DEBUG] Verifying keyboard layout after setup");
        system("/usr/local/bin/setxkbmap -query | head -10");
        
        // Also try to force refresh X11 keyboard state
        NSLog(@"[DEBUG] Refreshing X11 keyboard state");
        system("/usr/local/bin/xkbcomp $DISPLAY - 2>/dev/null < /dev/null || true");
        
        NSLog(@"[DEBUG] Keyboard layout setup complete");
        
        // Change to user's home directory
        if (chdir(pwd->pw_dir) != 0) {
            NSLog(@"[DEBUG] chdir failed in child process");
            exit(1);
        }
        
        NSLog(@"[DEBUG] Changed to home dir in child: %s", pwd->pw_dir);
        
        // Execute the selected session directly
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
        // Parent process - wait for session to complete
        NSLog(@"[DEBUG] Parent process, session PID: %d", pid);
        
        // Store session information for cleanup
        sessionPid = pid;
        sessionUid = pwd->pw_uid;
        sessionGid = pwd->pw_gid;
        
        printf("Session started for user %s (PID: %d)\n", user_cstr, pid);
        
        // Hide the login window during session
        [loginWindow orderOut:self];
        NSLog(@"[DEBUG] Login window hidden, waiting for session to end");
        
        // Wait for the session to end
        int status;
        pid_t wpid = -1;
        while (wpid != pid) {
            wpid = waitpid(pid, &status, 0);
            if (wpid == -1) {
                if (errno == EINTR) {
                    continue; // Interrupted by signal, try again
                }
                NSLog(@"[DEBUG] waitpid error: %s", strerror(errno));
                break;
            }
        }
        
        NSLog(@"[DEBUG] Session ended with status: %d", status);
        if (WIFEXITED(status)) {
            NSLog(@"[DEBUG] Session exited normally with code: %d", WEXITSTATUS(status));
        } else if (WIFSIGNALED(status)) {
            NSLog(@"[DEBUG] Session terminated by signal: %d", WTERMSIG(status));
        }
        
        // Forcefully kill all remaining session processes
        NSLog(@"[DEBUG] Starting forceful cleanup of session processes");
        [self killAllSessionProcesses:sessionUid];
        
        // Session ended, close PAM session
        [pamAuth closeSession];
        NSLog(@"[DEBUG] PAM session closed");
        
        // Reset session tracking variables
        sessionPid = 0;
        sessionUid = 0;
        sessionGid = 0;
        
        // Reset login window for next user
        NSLog(@"[DEBUG] Session ended, resetting login window for next user");
        [self resetLoginWindow];
    } else {
        NSLog(@"[DEBUG] Fork failed");
        [self showStatus:@"Failed to start session"];
        [pamAuth closeSession];
    }
}

- (void)killAllSessionProcesses:(uid_t)uid
{
    NSLog(@"[DEBUG] Starting targeted session cleanup for UID: %d", uid);
    
    // 1. Only kill the session process group, not all user processes
    // 2. Use the session PID to target only session-related processes
    // 3. Don't kill unrelated user processes (like those started from command line)
    
    if (sessionPid <= 0) {
        NSLog(@"[DEBUG] No session PID to clean up");
        return;
    }
    
    NSLog(@"[DEBUG] Cleaning up session process group for PID: %d", sessionPid);
    
    // Step 1: Send HUP signal to the session process group 
    NSLog(@"[DEBUG] Sending SIGHUP to process group %d", sessionPid);
    if (killpg(sessionPid, SIGHUP) != 0) {
        if (errno != ESRCH) {
            NSLog(@"[DEBUG] Failed to send SIGHUP to process group %d: %s", sessionPid, strerror(errno));
        }
    }
    
    // Step 2: Send TERM signal to process group, if that fails send KILL
    NSLog(@"[DEBUG] Sending SIGTERM to process group %d", sessionPid);
    if (killpg(sessionPid, SIGTERM) != 0) {
        if (errno != ESRCH) {
            NSLog(@"[DEBUG] SIGTERM failed, sending SIGKILL to process group %d", sessionPid);
            killpg(sessionPid, SIGKILL);
        }
    } else {
        // Give processes a moment to terminate gracefully
        usleep(500000); // 500ms
        
        // Check if the session process still exists, if so, force kill
        if (kill(sessionPid, 0) == 0) {
            NSLog(@"[DEBUG] Session process still alive, sending SIGKILL to process group %d", sessionPid);
            killpg(sessionPid, SIGKILL);
        }
    }
    
    // Step 3: Kill the main session process directly
    NSLog(@"[DEBUG] Killing main session process %d", sessionPid);
    if (kill(sessionPid, SIGKILL) != 0) {
        if (errno != ESRCH) {
            NSLog(@"[DEBUG] Failed to kill session process %d: %s", sessionPid, strerror(errno));
        }
    }
    
    // Step 4: Additional cleanup - find any processes that might still be in the same session
    NSLog(@"[DEBUG] Looking for remaining processes in session %d", sessionPid);
    
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_UID, uid};
    size_t size = 0;
    
    if (sysctl(mib, 4, NULL, &size, NULL, 0) != 0) {
        NSLog(@"[DEBUG] Failed to get process list size: %s", strerror(errno));
        return;
    }
    
    struct kinfo_proc *procs = malloc(size);
    if (!procs) {
        NSLog(@"[DEBUG] Failed to allocate memory for process list");
        return;
    }
    
    if (sysctl(mib, 4, procs, &size, NULL, 0) != 0) {
        NSLog(@"[DEBUG] Failed to get process list: %s", strerror(errno));
        free(procs);
        return;
    }
    
    int numProcs = size / sizeof(struct kinfo_proc);
    NSLog(@"[DEBUG] Checking %d processes for session cleanup", numProcs);
    
    int sessionRelatedKilled = 0;
    for (int i = 0; i < numProcs; i++) {
        pid_t pid = procs[i].ki_pid;
        
        // Skip kernel processes, init, and our own process
        if (pid <= 1 || pid == getpid()) {
            continue;
        }
        
        // Only kill processes that are related to our session:
        // 1. Processes whose PPID is our session PID (direct children)
        // 2. Processes whose SID is our session PID (same session)
        // 3. Processes whose PGID is our session PID (same process group)
        bool isSessionRelated = false;
        
        if (procs[i].ki_ppid == sessionPid) {
            NSLog(@"[DEBUG] Found child process: PID=%d, Command=%s", pid, procs[i].ki_comm);
            isSessionRelated = true;
        } else if (procs[i].ki_sid == sessionPid) {
            NSLog(@"[DEBUG] Found session process: PID=%d, SID=%d, Command=%s", pid, procs[i].ki_sid, procs[i].ki_comm);
            isSessionRelated = true;
        } else if (procs[i].ki_pgid == sessionPid) {
            NSLog(@"[DEBUG] Found process group member: PID=%d, PGID=%d, Command=%s", pid, procs[i].ki_pgid, procs[i].ki_comm);
            isSessionRelated = true;
        }
        
        if (isSessionRelated) {
            NSLog(@"[DEBUG] Killing session-related process: PID=%d, Command=%s", pid, procs[i].ki_comm);
            if (kill(pid, SIGKILL) == 0) {
                sessionRelatedKilled++;
            } else if (errno != ESRCH) {
                NSLog(@"[DEBUG] Failed to kill session process %d: %s", pid, strerror(errno));
            }
        }
    }
    
    free(procs);
    
    NSLog(@"[DEBUG] Session cleanup complete: killed %d session-related processes", sessionRelatedKilled);
    
    // Step 5: Reap any zombie children
    int status;
    int reaped = 0;
    while (waitpid(-1, &status, WNOHANG) > 0) {
        reaped++;
    }
    if (reaped > 0) {
        NSLog(@"[DEBUG] Reaped %d zombie processes", reaped);
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

- (void)resetLoginWindow
{
    NSLog(@"[DEBUG] Resetting login window state");
    
    // Reset session tracking variables
    sessionPid = 0;
    sessionUid = 0;
    sessionGid = 0;
    
    // Clear input fields
    [passwordField setStringValue:@""];
    [usernameField setStringValue:@""];
    [self showStatus:@""];
    
    // Reset session selection to default
    if ([availableSessionExecs count] > 0) {
        selectedSessionExec = [availableSessionExecs objectAtIndex:0];
        [sessionDropdown selectItemAtIndex:0];
    }
    
    // Ensure window is properly positioned and visible
    [loginWindow center];
    [loginWindow setLevel:NSScreenSaverWindowLevel];
    [loginWindow makeKeyAndOrderFront:self];
    [loginWindow makeMainWindow];
    [loginWindow makeFirstResponder:usernameField];
    [NSApp activateIgnoringOtherApps:YES];
    
    NSLog(@"[DEBUG] Login window reset complete - ready for next user");
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender
{
    return YES;
}

@end
