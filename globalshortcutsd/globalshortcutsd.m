#include <Foundation/Foundation.h>
#include <AppKit/AppKit.h>
#include <X11/Xlib.h>
#include <X11/keysym.h>
#include <X11/XKBlib.h>
#include <signal.h>
#include <unistd.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <stdarg.h>

// Forward declarations
@class globalshortcutsd;

// Global variables
static BOOL x11_error_occurred = NO;
static globalshortcutsd *globalInstance = nil;

@interface globalshortcutsd : NSObject
{
@public
    Display *display;
    NSDictionary *shortcuts;
    unsigned int numlock_mask;
    unsigned int capslock_mask;
    unsigned int scrolllock_mask;
    BOOL verbose;
    BOOL running;
}

- (id)init;
- (void)dealloc;
- (void)loadShortcuts;
- (void)setupX11;
- (void)getOffendingModifiers;
- (void)grabKeys;
- (void)ungrabKeys;
- (void)eventLoop;
- (void)runCommand:(NSString *)command;
- (void)handleSignal:(int)sig;
- (KeySym)parseKeyString:(NSString *)keyStr;
- (void)terminate;
- (NSString *)findExecutableInPath:(NSString *)command;
- (void)logWithFormat:(NSString *)format, ...;
- (BOOL)grabKey:(KeyCode)keycode modifier:(unsigned int)modifier forCombo:(NSString *)combo;
- (BOOL)matchesEvent:(XKeyEvent *)keyEvent withKeyCombo:(NSString *)keyCombo;

@end

// C function for X11 error handling
static int x11ErrorHandler(Display *dpy, XErrorEvent *error)
{
    x11_error_occurred = YES;
    
    if (error->error_code == BadAccess && error->request_code == 33) {
        // BadAccess on X_GrabKey - key already grabbed
        if (globalInstance && globalInstance->verbose) {
            [globalInstance logWithFormat:@"Warning: key combination already grabbed by another application (keycode=%d)", 
                error->resourceid];
        }
        return 0;
    }
    
    if (globalInstance) {
        [globalInstance logWithFormat:@"X11 Error: code=%d, request=%d, resource=0x%lx", 
              error->error_code, error->request_code, error->resourceid];
    }
    
    return 0;
}

// Signal handler
static void signalHandler(int sig)
{
    if (globalInstance) {
        [globalInstance handleSignal:sig];
    }
}

@implementation globalshortcutsd

- (id)init
{
    self = [super init];
    if (self) {
        display = NULL;
        shortcuts = nil;
        numlock_mask = 0;
        capslock_mask = 0;
        scrolllock_mask = 0;
        verbose = NO;
        running = YES;
        globalInstance = self;
    }
    return self;
}

- (void)dealloc
{
    [self ungrabKeys];
    if (display) {
        XCloseDisplay(display);
    }
    [shortcuts release];
    [super dealloc];
}

- (void)loadShortcuts
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSDictionary *config = [defaults dictionaryForKey:@"GlobalShortcuts"];
    
    if (!config) {
        [self logWithFormat:@"No GlobalShortcuts configuration found in defaults"];
        [self logWithFormat:@"Use: defaults write NSGlobalDomain GlobalShortcuts '{\"ctrl+shift+t\" = \"xterm\";}'"];
        return;
    }
    
    [shortcuts release];
    shortcuts = [config retain];
    
    [self logWithFormat:@"Loaded %lu shortcuts", (unsigned long)[shortcuts count]];
    if (verbose) {
        NSEnumerator *enumerator = [shortcuts keyEnumerator];
        NSString *key;
        while ((key = [enumerator nextObject])) {
            [self logWithFormat:@"  %@ -> %@", key, [shortcuts objectForKey:key]];
        }
    }
}

- (void)setupX11
{
    display = XOpenDisplay(NULL);
    if (!display) {
        [self logWithFormat:@"Could not open X11 display"];
        exit(1);
    }
    
    XAllowEvents(display, AsyncBoth, CurrentTime);
    
    for (int screen = 0; screen < ScreenCount(display); screen++) {
        XSelectInput(display, RootWindow(display, screen),
                    KeyPressMask | KeyReleaseMask);
    }
    
    [self getOffendingModifiers];
}

- (void)getOffendingModifiers
{
    XModifierKeymap *modmap;
    KeyCode nlock, slock;
    static int mask_table[8] = {
        ShiftMask, LockMask, ControlMask, Mod1Mask,
        Mod2Mask, Mod3Mask, Mod4Mask, Mod5Mask
    };
    
    nlock = XKeysymToKeycode(display, XK_Num_Lock);
    slock = XKeysymToKeycode(display, XK_Scroll_Lock);
    
    modmap = XGetModifierMapping(display);
    
    if (modmap != NULL && modmap->max_keypermod > 0) {
        for (int i = 0; i < 8 * modmap->max_keypermod; i++) {
            if (modmap->modifiermap[i] == nlock && nlock != 0)
                numlock_mask = mask_table[i / modmap->max_keypermod];
            else if (modmap->modifiermap[i] == slock && slock != 0)
                scrolllock_mask = mask_table[i / modmap->max_keypermod];
        }
    }
    
    capslock_mask = LockMask;
    
    if (modmap)
        XFreeModifiermap(modmap);
}

- (void)grabKeys
{
    if (!shortcuts || !display) return;
    
    NSEnumerator *enumerator = [shortcuts keyEnumerator];
    NSString *keyCombo;
    
    while ((keyCombo = [enumerator nextObject])) {
        // Parse key combination like "ctrl+shift+t" or "ctrl+shift+code:28"
        NSArray *parts = [keyCombo componentsSeparatedByString:@"+"];
        if ([parts count] < 1) continue;
        
        unsigned int modifier = 0;
        NSString *keyString = nil;
        
        for (int i = 0; i < [parts count]; i++) {
            NSString *part = [[parts objectAtIndex:i] lowercaseString];
            if ([part isEqualToString:@"ctrl"] || [part isEqualToString:@"control"]) {
                modifier |= ControlMask;
            } else if ([part isEqualToString:@"shift"]) {
                modifier |= ShiftMask;
            } else if ([part isEqualToString:@"alt"] || [part isEqualToString:@"mod1"]) {
                modifier |= Mod1Mask;
            } else if ([part isEqualToString:@"mod2"]) {
                modifier |= Mod2Mask;
            } else if ([part isEqualToString:@"mod3"]) {
                modifier |= Mod3Mask;
            } else if ([part isEqualToString:@"mod4"]) {
                modifier |= Mod4Mask;
            } else if ([part isEqualToString:@"mod5"]) {
                modifier |= Mod5Mask;
            } else {
                // This should be the key
                keyString = part;
            }
        }
        
        if (!keyString) continue;
        
        KeyCode keycode = 0;
        
        // Check if it's a raw keycode (format: "code:28")
        if ([keyString hasPrefix:@"code:"]) {
            NSString *codeStr = [keyString substringFromIndex:5];
            keycode = [codeStr intValue];
            if (keycode == 0) {
                [self logWithFormat:@"Warning: invalid keycode '%@' in combination '%@'", keyString, keyCombo];
                continue;
            }
        } else {
            // Parse as keysym
            KeySym keysym = [self parseKeyString:keyString];
            if (keysym == NoSymbol) {
                [self logWithFormat:@"Warning: unknown key '%@' in combination '%@'", keyString, keyCombo];
                continue;
            }
            
            keycode = XKeysymToKeycode(display, keysym);
            if (keycode == 0) {
                [self logWithFormat:@"Warning: no keycode for key '%@'", keyString];
                continue;
            }
        }
        
        // Grab the key with all possible lock combinations
        BOOL success = [self grabKey:keycode modifier:modifier forCombo:keyCombo];
        
        if (success && verbose) {
            [self logWithFormat:@"Grabbed key combination: %@ (keycode=%d, modifier=0x%x)", 
                  keyCombo, keycode, modifier];
        }
    }
}

- (BOOL)grabKey:(KeyCode)keycode modifier:(unsigned int)modifier forCombo:(NSString *)combo
{
    Window root = DefaultRootWindow(display);
    BOOL success = YES;
    
    // Set up X11 error handler
    XErrorHandler oldHandler = XSetErrorHandler(x11ErrorHandler);
    
    // Reset error flag
    x11_error_occurred = NO;
    
    // Base combination
    XGrabKey(display, keycode, modifier, root, False, GrabModeAsync, GrabModeAsync);
    XSync(display, False);
    if (x11_error_occurred) success = NO;
    
    // With numlock
    if (numlock_mask && !x11_error_occurred) {
        XGrabKey(display, keycode, modifier | numlock_mask, root, False, GrabModeAsync, GrabModeAsync);
        XSync(display, False);
    }
    
    // With capslock
    if (capslock_mask && !x11_error_occurred) {
        XGrabKey(display, keycode, modifier | capslock_mask, root, False, GrabModeAsync, GrabModeAsync);
        XSync(display, False);
    }
    
    // With scrolllock
    if (scrolllock_mask && !x11_error_occurred) {
        XGrabKey(display, keycode, modifier | scrolllock_mask, root, False, GrabModeAsync, GrabModeAsync);
        XSync(display, False);
    }
    
    // With numlock + capslock
    if (numlock_mask && capslock_mask && !x11_error_occurred) {
        XGrabKey(display, keycode, modifier | numlock_mask | capslock_mask, root, False, GrabModeAsync, GrabModeAsync);
        XSync(display, False);
    }
    
    // With numlock + scrolllock
    if (numlock_mask && scrolllock_mask && !x11_error_occurred) {
        XGrabKey(display, keycode, modifier | numlock_mask | scrolllock_mask, root, False, GrabModeAsync, GrabModeAsync);
        XSync(display, False);
    }
    
    // With capslock + scrolllock
    if (capslock_mask && scrolllock_mask && !x11_error_occurred) {
        XGrabKey(display, keycode, modifier | capslock_mask | scrolllock_mask, root, False, GrabModeAsync, GrabModeAsync);
        XSync(display, False);
    }
    
    // With all locks
    if (numlock_mask && capslock_mask && scrolllock_mask && !x11_error_occurred) {
        XGrabKey(display, keycode, modifier | numlock_mask | capslock_mask | scrolllock_mask, root, False, GrabModeAsync, GrabModeAsync);
        XSync(display, False);
    }
    
    // Restore previous error handler
    XSetErrorHandler(oldHandler);
    
    return success && !x11_error_occurred;
}

- (void)ungrabKeys
{
    if (display) {
        XUngrabKey(display, AnyKey, AnyModifier, DefaultRootWindow(display));
    }
}

- (KeySym)parseKeyString:(NSString *)keyStr
{
    const char *cStr = [keyStr UTF8String];
    
    // Handle special keys
    if ([keyStr length] == 1) {
        // Single character
        return XStringToKeysym(cStr);
    }
    
    // Handle named keys
    if ([keyStr isEqualToString:@"space"]) return XK_space;
    if ([keyStr isEqualToString:@"return"] || [keyStr isEqualToString:@"enter"]) return XK_Return;
    if ([keyStr isEqualToString:@"tab"]) return XK_Tab;
    if ([keyStr isEqualToString:@"escape"] || [keyStr isEqualToString:@"esc"]) return XK_Escape;
    if ([keyStr isEqualToString:@"backspace"]) return XK_BackSpace;
    if ([keyStr isEqualToString:@"delete"]) return XK_Delete;
    if ([keyStr isEqualToString:@"home"]) return XK_Home;
    if ([keyStr isEqualToString:@"end"]) return XK_End;
    if ([keyStr isEqualToString:@"page_up"]) return XK_Page_Up;
    if ([keyStr isEqualToString:@"page_down"]) return XK_Page_Down;
    if ([keyStr isEqualToString:@"up"]) return XK_Up;
    if ([keyStr isEqualToString:@"down"]) return XK_Down;
    if ([keyStr isEqualToString:@"left"]) return XK_Left;
    if ([keyStr isEqualToString:@"right"]) return XK_Right;
    
    // Function keys
    if ([keyStr hasPrefix:@"f"] && [keyStr length] <= 3) {
        int fNum = [[keyStr substringFromIndex:1] intValue];
        if (fNum >= 1 && fNum <= 24) {
            return XK_F1 + (fNum - 1);
        }
    }
    
    // Multimedia keys - XF86 symbols
    if ([keyStr isEqualToString:@"volume_up"]) return 0x1008FF13;     // XF86AudioRaiseVolume
    if ([keyStr isEqualToString:@"volume_down"]) return 0x1008FF11;   // XF86AudioLowerVolume
    if ([keyStr isEqualToString:@"volume_mute"]) return 0x1008FF12;   // XF86AudioMute
    if ([keyStr isEqualToString:@"play_pause"]) return 0x1008FF14;    // XF86AudioPlay
    if ([keyStr isEqualToString:@"stop"]) return 0x1008FF15;          // XF86AudioStop
    if ([keyStr isEqualToString:@"prev"]) return 0x1008FF16;          // XF86AudioPrev
    if ([keyStr isEqualToString:@"next"]) return 0x1008FF17;          // XF86AudioNext
    if ([keyStr isEqualToString:@"rewind"]) return 0x1008FF3E;        // XF86AudioRewind
    if ([keyStr isEqualToString:@"forward"]) return 0x1008FF40;       // XF86AudioForward
    
    // Brightness controls
    if ([keyStr isEqualToString:@"brightness_up"]) return 0x1008FF02;   // XF86MonBrightnessUp
    if ([keyStr isEqualToString:@"brightness_down"]) return 0x1008FF03; // XF86MonBrightnessDown
    
    // Other multimedia keys
    if ([keyStr isEqualToString:@"mail"]) return 0x1008FF19;          // XF86Mail
    if ([keyStr isEqualToString:@"www"]) return 0x1008FF2E;           // XF86WWW
    if ([keyStr isEqualToString:@"homepage"]) return 0x1008FF18;      // XF86HomePage
    if ([keyStr isEqualToString:@"search"]) return 0x1008FF1B;        // XF86Search
    if ([keyStr isEqualToString:@"calculator"]) return 0x1008FF1D;    // XF86Calculator
    if ([keyStr isEqualToString:@"sleep"]) return 0x1008FF2F;         // XF86Sleep
    if ([keyStr isEqualToString:@"wakeup"]) return 0x1008FF2B;        // XF86WakeUp
    if ([keyStr isEqualToString:@"power"]) return 0x1008FF2A;         // XF86PowerOff
    
    // Screen controls
    if ([keyStr isEqualToString:@"screensaver"]) return 0x1008FF2D;   // XF86ScreenSaver
    if ([keyStr isEqualToString:@"standby"]) return 0x1008FF10;       // XF86Standby
    
    // Media controls
    if ([keyStr isEqualToString:@"record"]) return 0x1008FF1C;        // XF86AudioRecord
    if ([keyStr isEqualToString:@"eject"]) return 0x1008FF2C;         // XF86Eject
    
    // Try direct keysym lookup
    return XStringToKeysym(cStr);
}

- (void)eventLoop
{
    XEvent event;
    
    // Set up signal handlers for graceful shutdown
    signal(SIGTERM, signalHandler);
    signal(SIGINT, signalHandler);  // Ctrl+C
    signal(SIGQUIT, signalHandler); // Ctrl+D equivalent
    signal(SIGHUP, signalHandler);
    signal(SIGCHLD, SIG_IGN); // Ignore child signals
    
    [self logWithFormat:@"Starting event loop..."];
    
    while (running) {
        // Use XPending to check for events without blocking
        while (XPending(display) && running) {
            XNextEvent(display, &event);
            
            if (event.type == KeyPress) {
                if (verbose) {
                    [self logWithFormat:@"Key press: keycode=%d, state=0x%x", 
                          event.xkey.keycode, event.xkey.state];
                }
                
                // Mask out lock keys
                event.xkey.state &= ~(numlock_mask | capslock_mask | scrolllock_mask);
                
                // Find matching shortcut
                NSEnumerator *enumerator = [shortcuts keyEnumerator];
                NSString *keyCombo;
                
                while ((keyCombo = [enumerator nextObject])) {
                    if ([self matchesEvent:&event.xkey withKeyCombo:keyCombo]) {
                        NSString *command = [shortcuts objectForKey:keyCombo];
                        [self logWithFormat:@"Executing command for %@: %@", keyCombo, command];
                        [self runCommand:command];
                        break;
                    }
                }
            }
        }
        
        // Small sleep to prevent busy waiting and allow signal processing
        usleep(10000); // 10ms
    }
    
    [self logWithFormat:@"Event loop terminated"];
}

- (BOOL)matchesEvent:(XKeyEvent *)keyEvent withKeyCombo:(NSString *)keyCombo
{
    NSArray *parts = [keyCombo componentsSeparatedByString:@"+"];
    if ([parts count] < 1) return NO;
    
    unsigned int modifier = 0;
    NSString *keyString = nil;
    
    for (int i = 0; i < [parts count]; i++) {
        NSString *part = [[parts objectAtIndex:i] lowercaseString];
        if ([part isEqualToString:@"ctrl"] || [part isEqualToString:@"control"]) {
            modifier |= ControlMask;
        } else if ([part isEqualToString:@"shift"]) {
            modifier |= ShiftMask;
        } else if ([part isEqualToString:@"alt"] || [part isEqualToString:@"mod1"]) {
            modifier |= Mod1Mask;
        } else if ([part isEqualToString:@"mod2"]) {
            modifier |= Mod2Mask;
        } else if ([part isEqualToString:@"mod3"]) {
            modifier |= Mod3Mask;
        } else if ([part isEqualToString:@"mod4"]) {
            modifier |= Mod4Mask;
        } else if ([part isEqualToString:@"mod5"]) {
            modifier |= Mod5Mask;
        } else {
            keyString = part;
        }
    }
    
    if (!keyString) return NO;
    
    KeyCode keycode = 0;
    
    // Check if it's a raw keycode (format: "code:28")
    if ([keyString hasPrefix:@"code:"]) {
        NSString *codeStr = [keyString substringFromIndex:5];
        keycode = [codeStr intValue];
    } else {
        // Parse as keysym
        KeySym keysym = [self parseKeyString:keyString];
        keycode = XKeysymToKeycode(display, keysym);
    }
    
    return (keyEvent->keycode == keycode && keyEvent->state == modifier);
}

- (void)runCommand:(NSString *)command
{
    if (!command || [command length] == 0) return;
    
    // Parse command and arguments
    NSArray *components = [command componentsSeparatedByString:@" "];
    if ([components count] == 0) return;
    
    NSString *executable = [components objectAtIndex:0];
    NSString *fullPath = [self findExecutableInPath:executable];
    
    if (!fullPath) {
        [self logWithFormat:@"Warning: executable '%@' not found in PATH", executable];
        return;
    }
    
    if (verbose) {
        [self logWithFormat:@"Found executable: %@ -> %@", executable, fullPath];
    }
    
    pid_t pid = fork();
    if (pid == 0) {
        // Child process
        setsid();
        if (fork() == 0) {
            // Grandchild process - execute command
            const char *shell = getenv("SHELL");
            if (!shell) shell = "/bin/sh";
            
            execl(shell, shell, "-c", [command UTF8String], (char *)NULL);
            _exit(1);
        }
        _exit(0);
    } else if (pid > 0) {
        // Parent process - wait for child to exit
        waitpid(pid, NULL, 0);
    } else {
        [self logWithFormat:@"Error: failed to fork process for command: %@", command];
    }
}

- (void)handleSignal:(int)sig
{
    switch (sig) {
        case SIGTERM:
        case SIGINT:
        case SIGQUIT:
            [self logWithFormat:@"Received termination signal (%d), shutting down gracefully...", sig];
            running = NO;
            break;
        case SIGHUP:
            [self logWithFormat:@"Received HUP signal, reloading configuration..."];
            [self ungrabKeys];
            [self loadShortcuts];
            [self grabKeys];
            break;
        default:
            [self logWithFormat:@"Received unexpected signal: %d", sig];
            break;
    }
}

- (void)terminate
{
    running = NO;
}

- (NSString *)findExecutableInPath:(NSString *)command
{
    // If command contains a slash, treat it as an absolute or relative path
    if ([command containsString:@"/"]) {
        struct stat statbuf;
        const char *cPath = [command UTF8String];
        if (stat(cPath, &statbuf) == 0 && (statbuf.st_mode & S_IXUSR)) {
            return command;
        }
        return nil;
    }
    
    // Search in PATH
    NSString *pathEnv = [[[NSProcessInfo processInfo] environment] objectForKey:@"PATH"];
    if (!pathEnv) {
        pathEnv = @"/usr/local/bin:/usr/bin:/bin";
    }
    
    NSArray *pathComponents = [pathEnv componentsSeparatedByString:@":"];
    NSEnumerator *enumerator = [pathComponents objectEnumerator];
    NSString *pathDir;
    
    while ((pathDir = [enumerator nextObject])) {
        if ([pathDir length] == 0) continue;
        
        NSString *fullPath = [pathDir stringByAppendingPathComponent:command];
        struct stat statbuf;
        const char *cPath = [fullPath UTF8String];
        
        if (stat(cPath, &statbuf) == 0 && (statbuf.st_mode & S_IXUSR)) {
            return fullPath;
        }
    }
    
    return nil;
}

- (void)logWithFormat:(NSString *)format, ...
{
    va_list args;
    va_start(args, format);
    
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    
    NSLog(@"%@", message);
    
    [message release];
}

@end

// Usage function
void showUsage(const char *progname)
{
    printf("Usage: %s [options]\n", progname);
    printf("Options:\n");
    printf("  -v, --verbose    Enable verbose output\n");
    printf("  -h, --help       Show this help\n");
    printf("\n");
    printf("Configuration:\n");
    printf("Use GNUstep defaults to configure shortcuts:\n");
    printf("  defaults write NSGlobalDomain GlobalShortcuts '{\"ctrl+shift+t\" = \"Terminal\"; \"ctrl+shift+f\" = \"Browser\";}'\n");
    printf("\n");
    printf("Key combinations use format: modifier+modifier+key\n");
    printf("Modifiers: ctrl, shift, alt, mod2, mod3, mod4, mod5\n");
    printf("Keys: a-z, 0-9, f1-f24, space, return, tab, escape, etc.\n");
    printf("Raw keycodes: code:28 (where 28 is the keycode number)\n");
    printf("\n");
    printf("Multimedia keys:\n");
    printf("  volume_up, volume_down, volume_mute\n");
    printf("  play_pause, stop, prev, next, rewind, forward\n");
    printf("  brightness_up, brightness_down\n");
    printf("  mail, www, homepage, search, calculator\n");
    printf("  sleep, wakeup, power, screensaver, standby\n");
    printf("  record, eject\n");
}

int main(int argc, char *argv[])
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    BOOL verbose = NO;
    
    // Parse command line arguments
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-v") == 0 || strcmp(argv[i], "--verbose") == 0) {
            verbose = YES;
        } else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
            showUsage(argv[0]);
            [pool release];
            return 0;
        } else {
            fprintf(stderr, "Unknown option: %s\n", argv[i]);
            showUsage(argv[0]);
            [pool release];
            return 1;
        }
    }
    
    // Initialize GNUstep
    [[NSProcessInfo processInfo] setProcessName:@"globalshortcutsd"];
    
    globalshortcutsd *daemon = [[globalshortcutsd alloc] init];
    daemon->verbose = verbose;
    
    [daemon logWithFormat:@"globalshortcutsd starting (verbose=%@)...", verbose ? @"YES" : @"NO"];
    
    @try {
        [daemon setupX11];
        [daemon loadShortcuts];
        [daemon grabKeys];
        [daemon eventLoop];
    }
    @catch (NSException *exception) {
        [daemon logWithFormat:@"Fatal error: %@", [exception reason]];
        [pool release];
        return 1;
    }
    
    [daemon logWithFormat:@"globalshortcutsd terminated"];
    [daemon release];
    [pool release];
    
    return 0;
}
