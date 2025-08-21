#import "X11ShortcutManager.h"
#import "DBusConnection.h"
#import <Foundation/Foundation.h>
#import <X11/Xlib.h>
#import <X11/keysym.h>

// Global variable to track X11 errors during key grabbing
static BOOL x11_grab_error_occurred = NO;

// X11 error handler for key grabbing
static int handleX11GrabError(Display *display, XErrorEvent *event)
{
    (void)display;  // Suppress unused parameter warning
    
    if (event->error_code == BadAccess) {
        x11_grab_error_occurred = YES;
        NSLog(@"X11ShortcutManager: X11 BadAccess error - key already grabbed by another application");
    } else {
        NSLog(@"X11ShortcutManager: X11 error during key grab: error_code=%d, request_code=%d", 
              event->error_code, event->request_code);
        x11_grab_error_occurred = YES;
    }
    return 0;
}

@implementation X11ShortcutManager {
    // X11 globals for shortcut handling
    Display *_display;
    NSMutableDictionary *_grabbedKeys;          // maps "keycode_modifier" -> menuItem key
    NSMutableDictionary *_menuItemKeyToTag;     // maps menuItem key -> tag
    NSMutableArray *_registeredShortcuts;       // array of shortcut strings
    NSMutableDictionary *_shortcutToMenuItemMap; // maps keycodeModifierKey -> menuItemKey
    
    // DBus connection info for menu actions
    NSMutableDictionary *_menuItemToServiceMap;
    NSMutableDictionary *_menuItemToObjectPathMap;
    NSMutableDictionary *_menuItemToConnectionMap;
    NSMutableDictionary *_menuItemToActionNameMap;  // maps menuItemKey -> action name
    
    NSThread *_eventMonitorThread;
    BOOL _shouldStopEventMonitoring;
    BOOL _swapCtrlAlt;
    
    // Lock key masks
    unsigned int _numlock_mask;
    unsigned int _capslock_mask;
    unsigned int _scrolllock_mask;
}

+ (instancetype)sharedManager
{
    static X11ShortcutManager *sharedInstance = nil;
    if (!sharedInstance) {
        sharedInstance = [[X11ShortcutManager alloc] init];
    }
    return sharedInstance;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _grabbedKeys = [[NSMutableDictionary alloc] init];
        _menuItemKeyToTag = [[NSMutableDictionary alloc] init];
        _registeredShortcuts = [[NSMutableArray alloc] init];
        _shortcutToMenuItemMap = [[NSMutableDictionary alloc] init];
        _menuItemToServiceMap = [[NSMutableDictionary alloc] init];
        _menuItemToObjectPathMap = [[NSMutableDictionary alloc] init];
        _menuItemToConnectionMap = [[NSMutableDictionary alloc] init];
        _menuItemToActionNameMap = [[NSMutableDictionary alloc] init];
        
        // Initialize X11 display for shortcuts
        _display = XOpenDisplay(NULL);
        if (!_display) {
            NSLog(@"X11ShortcutManager: Warning: Failed to open X11 display for shortcuts");
        } else {
            // Initialize lock masks for comprehensive key grabbing
            [self detectLockMasks];
        }
        
        // Set default value for Ctrl/Alt swapping (enabled by default)
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        if ([defaults objectForKey:@"GershwinSwapCtrlAlt"] == nil) {
            [defaults setBool:YES forKey:@"GershwinSwapCtrlAlt"];
            [defaults synchronize];
        }
        _swapCtrlAlt = [defaults boolForKey:@"GershwinSwapCtrlAlt"];
    }
    return self;
}

- (void)dealloc
{
    [self cleanup];
    [_grabbedKeys release];
    [_menuItemKeyToTag release];
    [_registeredShortcuts release];
    [_shortcutToMenuItemMap release];
    [_menuItemToServiceMap release];
    [_menuItemToObjectPathMap release];
    [_menuItemToConnectionMap release];
    [_menuItemToActionNameMap release];
    [super dealloc];
}

- (void)registerShortcutForMenuItem:(NSMenuItem *)menuItem
                        serviceName:(NSString *)serviceName
                         objectPath:(NSString *)objectPath
                     dbusConnection:(GNUDBusConnection *)dbusConnection
{
    if (!_display) {
        NSLog(@"X11ShortcutManager: Cannot register shortcut - no X11 display");
        return;
    }
    
    NSString *keyEquivalent = [menuItem keyEquivalent];
    NSUInteger modifierMask = [menuItem keyEquivalentModifierMask];
    
    if ([keyEquivalent length] == 0 || modifierMask == 0) {
        return;
    }
    
    // Create a stable key based on menu item properties instead of memory address
    // This ensures cached menus work correctly when shortcuts are re-registered
    // Include tag to ensure uniqueness since many items may have same service/title
    NSString *menuItemKey = [NSString stringWithFormat:@"%@_%@_%@_%ld", 
                            serviceName ?: @"unknown", 
                            [menuItem title] ?: @"untitled",
                            [menuItem keyEquivalent] ?: @"none",
                            [menuItem tag]];
    
    // Store the menu item tag and DBus connection info
    [_menuItemKeyToTag setObject:[NSNumber numberWithLong:[menuItem tag]] forKey:menuItemKey];
    [_menuItemToServiceMap setObject:serviceName forKey:menuItemKey];
    [_menuItemToObjectPathMap setObject:objectPath forKey:menuItemKey];
    [_menuItemToConnectionMap setObject:dbusConnection forKey:menuItemKey];
    
    // Convert key to X11 KeySym and KeyCode
    KeySym keysym = [self parseKeyString:keyEquivalent];
    if (keysym == NoSymbol) {
        NSLog(@"X11ShortcutManager: Failed to convert key '%@' to X11 KeySym", keyEquivalent);
        return;
    }
    
    KeyCode keycode = XKeysymToKeycode(_display, keysym);
    if (keycode == 0) {
        NSLog(@"X11ShortcutManager: Failed to convert KeySym to KeyCode for '%@'", keyEquivalent);
        return;
    }
    
    // Prepare shortcut strings and modifiers
    NSString *originalShortcut = [self createShortcutStringFromKey:keyEquivalent modifiers:modifierMask];
    unsigned int originalX11Modifier = [self convertToX11Modifier:modifierMask];
    
    // For <Primary> shortcuts (which now map to Control), skip the original
    // and only register Alt+key for cross-platform menu access
    BOOL isControlShortcut = (modifierMask & NSControlKeyMask) != 0;
    BOOL registeredOriginal = NO;
    BOOL registeredAlt = NO;
    
    if (!isControlShortcut) {
        // Not a Control shortcut - register normally
        registeredOriginal = [self registerSingleShortcut:keycode 
                                                  modifier:originalX11Modifier 
                                               menuItemKey:menuItemKey 
                                            shortcutString:originalShortcut];
    } else {
        NSLog(@"X11ShortcutManager: Skipping %@ (preserving app's internal shortcut)", originalShortcut);
    }
    
    // For Control shortcuts, register Alt+key for our menu system
    if (isControlShortcut) {
        // Replace Control with Alt
        NSUInteger altModifierMask = (modifierMask & ~NSControlKeyMask) | NSAlternateKeyMask;
        NSString *altShortcut = [self createShortcutStringFromKey:keyEquivalent modifiers:altModifierMask];
        unsigned int altX11Modifier = [self convertToX11Modifier:altModifierMask];
        
        registeredAlt = [self registerSingleShortcut:keycode 
                                             modifier:altX11Modifier 
                                          menuItemKey:menuItemKey 
                                       shortcutString:altShortcut];
        
        if (registeredAlt) {
            NSLog(@"X11ShortcutManager: Registered Alt+%@ for cross-platform menu access", keyEquivalent);
        }
    }
    
    // Legacy: If Ctrl/Alt swapping is enabled for other shortcuts
    if (_swapCtrlAlt && !isControlShortcut && (modifierMask & (NSControlKeyMask | NSAlternateKeyMask))) {
        NSUInteger swappedModifierMask = [self getSwappedModifierMask:modifierMask];
        NSString *swappedShortcut = [self createShortcutStringFromKey:keyEquivalent modifiers:swappedModifierMask];
        unsigned int swappedX11Modifier = [self convertToX11Modifier:swappedModifierMask];
        
        BOOL registeredSwapped = [self registerSingleShortcut:keycode 
                                                      modifier:swappedX11Modifier 
                                                   menuItemKey:menuItemKey 
                                                shortcutString:swappedShortcut];
        
        if (registeredOriginal || registeredSwapped) {
            NSLog(@"X11ShortcutManager: Registered swapped shortcuts for menu item '%@': original=%@(%s), swapped=%@(%s)", 
                  [menuItem title], originalShortcut, registeredOriginal ? "OK" : "FAILED",
                  swappedShortcut, registeredSwapped ? "OK" : "FAILED");
        }
    } else if (registeredOriginal || registeredAlt) {
        NSString *registeredShortcuts = registeredOriginal ? originalShortcut : 
                                       registeredAlt ? [self createShortcutStringFromKey:keyEquivalent 
                                                                               modifiers:(modifierMask & ~NSControlKeyMask) | NSAlternateKeyMask] : @"none";
        NSLog(@"X11ShortcutManager: Registered shortcut for menu item '%@': %@", 
              [menuItem title], registeredShortcuts);
    }
    
    // Debug: Check the state after registration
    NSLog(@"X11ShortcutManager: After registration - _grabbedKeys count: %lu, _eventMonitorThread: %@", 
          (unsigned long)[_grabbedKeys count], _eventMonitorThread ? @"EXISTS" : @"nil");
    
    // Start X11 event monitoring if this is the first shortcut
    if ([_grabbedKeys count] > 0 && !_eventMonitorThread) {
        NSLog(@"X11ShortcutManager: Starting event monitoring - have %lu grabbed keys", 
              (unsigned long)[_grabbedKeys count]);
        [self startX11EventMonitoring];
    } else {
        NSLog(@"X11ShortcutManager: Not starting event monitoring - count: %lu, thread: %@", 
              (unsigned long)[_grabbedKeys count], _eventMonitorThread ? @"EXISTS" : @"nil");
    }
}

- (void)registerShortcutForMenuItem:(NSMenuItem *)menuItem
                        serviceName:(NSString *)serviceName
                         objectPath:(NSString *)objectPath
                         actionName:(NSString *)actionName
                     dbusConnection:(GNUDBusConnection *)dbusConnection
{
    // Call the original method to handle key registration
    [self registerShortcutForMenuItem:menuItem
                          serviceName:serviceName
                           objectPath:objectPath
                       dbusConnection:dbusConnection];
    
    // Additionally store the action name for protocol detection
    // Create a stable key based on menu item properties - must be truly unique per menu item
    // Include tag to match the format used in registerShortcut methods
    NSString *menuItemKey = [NSString stringWithFormat:@"%@_%@_%@_%ld", 
                            serviceName ?: @"unknown",
                            [menuItem title] ?: @"untitled",
                            [menuItem keyEquivalent] ?: @"none",
                            (long)[menuItem tag]];
    if (actionName) {
        [_menuItemToActionNameMap setObject:actionName forKey:menuItemKey];
        NSLog(@"X11ShortcutManager: Stored action name '%@' for menu item '%@' with key '%@'", 
              actionName, [menuItem title], menuItemKey);
    }
}

- (void)unregisterAllShortcuts
{
    if ([_registeredShortcuts count] == 0) {
        return;
    }
    
    NSLog(@"X11ShortcutManager: Unregistering %lu X11 hotkeys", 
          (unsigned long)[_registeredShortcuts count]);
    
    // Stop event monitoring
    if (_eventMonitorThread && !_shouldStopEventMonitoring) {
        _shouldStopEventMonitoring = YES;
        // Wait for thread to finish
        while (_eventMonitorThread && ![_eventMonitorThread isFinished]) {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        }
        _eventMonitorThread = nil;
    }
    
    // Unregister all X11 hotkeys
    if (_display) {
        XUngrabKey(_display, AnyKey, AnyModifier, DefaultRootWindow(_display));
        XSync(_display, False);
    }
    
    [_registeredShortcuts removeAllObjects];
    [_shortcutToMenuItemMap removeAllObjects];
    [_grabbedKeys removeAllObjects];
    [_menuItemKeyToTag removeAllObjects];
    [_menuItemToServiceMap removeAllObjects];
    [_menuItemToObjectPathMap removeAllObjects];
    [_menuItemToConnectionMap removeAllObjects];
    [_menuItemToActionNameMap removeAllObjects];
}

- (BOOL)shouldSwapCtrlAlt
{
    return _swapCtrlAlt;
}

- (void)setSwapCtrlAlt:(BOOL)swap
{
    _swapCtrlAlt = swap;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:swap forKey:@"GershwinSwapCtrlAlt"];
    [defaults synchronize];
    
    NSLog(@"X11ShortcutManager: Ctrl/Alt swapping %@", swap ? @"enabled" : @"disabled");
}

- (void)cleanup
{
    NSLog(@"X11ShortcutManager: Performing cleanup...");
    [self unregisterAllShortcuts];
    
    if (_display) {
        XCloseDisplay(_display);
        _display = NULL;
    }
}

- (BOOL)isShortcutAlreadyTaken:(NSString *)shortcutString
{
    if (!_display) {
        NSLog(@"X11ShortcutManager: Cannot check shortcut availability - no X11 display");
        return YES; // Assume taken if we can't check
    }
    
    // Parse the shortcut string (e.g., "ctrl+t", "alt+shift+n")
    NSArray *components = [shortcutString componentsSeparatedByString:@"+"];
    if ([components count] < 2) {
        NSLog(@"X11ShortcutManager: Invalid shortcut format: %@", shortcutString);
        return YES;
    }
    
    // Extract key and modifiers
    NSString *keyString = [components lastObject];
    NSMutableArray *modifierStrings = [NSMutableArray arrayWithArray:components];
    [modifierStrings removeLastObject];
    
    // Convert to X11 formats
    KeySym keysym = [self parseKeyString:keyString];
    if (keysym == NoSymbol) {
        NSLog(@"X11ShortcutManager: Cannot parse key '%@' in shortcut: %@", keyString, shortcutString);
        return YES;
    }
    
    KeyCode keycode = XKeysymToKeycode(_display, keysym);
    if (keycode == 0) {
        NSLog(@"X11ShortcutManager: Cannot convert key '%@' to keycode in shortcut: %@", keyString, shortcutString);
        return YES;
    }
    
    // Convert modifier strings to X11 modifier mask
    unsigned int modifierMask = 0;
    for (NSString *mod in modifierStrings) {
        if ([mod isEqualToString:@"ctrl"]) {
            modifierMask |= ControlMask;
        } else if ([mod isEqualToString:@"alt"]) {
            modifierMask |= Mod1Mask;
        } else if ([mod isEqualToString:@"shift"]) {
            modifierMask |= ShiftMask;
        } else if ([mod isEqualToString:@"cmd"] || [mod isEqualToString:@"super"]) {
            modifierMask |= Mod4Mask;
        }
    }
    
    // Try to temporarily grab the key to see if it's available
    Window root = DefaultRootWindow(_display);
    
    // Set up error handling
    x11_grab_error_occurred = NO;
    int (*oldHandler)(Display *, XErrorEvent *) = XSetErrorHandler(handleX11GrabError);
    
    // Attempt to grab the key
    XGrabKey(_display, keycode, modifierMask, root, False, GrabModeAsync, GrabModeAsync);
    XSync(_display, False);
    
    BOOL isAvailable = !x11_grab_error_occurred;
    
    // If we successfully grabbed it, immediately ungrab it
    if (isAvailable) {
        XUngrabKey(_display, keycode, modifierMask, root);
        // Also ungrab all lock mask variants 
        if (_numlock_mask) {
            XUngrabKey(_display, keycode, modifierMask | _numlock_mask, root);
        }
        if (_capslock_mask) {
            XUngrabKey(_display, keycode, modifierMask | _capslock_mask, root);
        }
        if (_scrolllock_mask) {
            XUngrabKey(_display, keycode, modifierMask | _scrolllock_mask, root);
        }
        XSync(_display, False);
    }
    
    // Restore error handler
    XSetErrorHandler(oldHandler);
    
    return !isAvailable; // Return YES if taken, NO if available
}

- (void)checkShortcutAvailability:(NSArray *)shortcuts
{
    NSLog(@"X11ShortcutManager: Checking availability of %lu shortcuts...", (unsigned long)[shortcuts count]);
    
    NSMutableArray *availableShortcuts = [NSMutableArray array];
    NSMutableArray *takenShortcuts = [NSMutableArray array];
    
    for (NSString *shortcut in shortcuts) {
        if ([self isShortcutAlreadyTaken:shortcut]) {
            [takenShortcuts addObject:shortcut];
        } else {
            [availableShortcuts addObject:shortcut];
        }
    }
    
    NSLog(@"X11ShortcutManager: Shortcut availability results:");
    NSLog(@"X11ShortcutManager: Available (%lu): %@", 
          (unsigned long)[availableShortcuts count], 
          [availableShortcuts componentsJoinedByString:@", "]);
    NSLog(@"X11ShortcutManager: Already taken (%lu): %@", 
          (unsigned long)[takenShortcuts count], 
          [takenShortcuts componentsJoinedByString:@", "]);
}

- (BOOL)isShortcutAlreadyTaken:(KeyCode)keycode modifier:(unsigned int)x11_modifier
{
    if (!_display) {
        return YES; // Assume taken if we can't check
    }
    
    // Try to temporarily grab the key to see if it's available
    Window root = DefaultRootWindow(_display);
    
    // Set up error handling
    x11_grab_error_occurred = NO;
    int (*oldHandler)(Display *, XErrorEvent *) = XSetErrorHandler(handleX11GrabError);
    
    // Attempt to grab the key - try the base combination first
    BOOL grabbed_successfully = NO;
    
    // Try the basic combination
    XGrabKey(_display, keycode, x11_modifier, root, False, GrabModeAsync, GrabModeAsync);
    XSync(_display, False);
    
    if (!x11_grab_error_occurred) {
        grabbed_successfully = YES;
        XUngrabKey(_display, keycode, x11_modifier, root);
        
        // Try to grab all the lock combinations to see if any are taken
        // If any lock combination is taken, consider the shortcut unavailable
        
        // Test with numlock
        if (_numlock_mask && grabbed_successfully) {
            x11_grab_error_occurred = NO;
            XGrabKey(_display, keycode, x11_modifier | _numlock_mask, root, False, GrabModeAsync, GrabModeAsync);
            XSync(_display, False);
            if (!x11_grab_error_occurred) {
                XUngrabKey(_display, keycode, x11_modifier | _numlock_mask, root);
            } else {
                grabbed_successfully = NO;
            }
        }
        
        // Test with capslock
        if (_capslock_mask && grabbed_successfully) {
            x11_grab_error_occurred = NO;
            XGrabKey(_display, keycode, x11_modifier | _capslock_mask, root, False, GrabModeAsync, GrabModeAsync);
            XSync(_display, False);
            if (!x11_grab_error_occurred) {
                XUngrabKey(_display, keycode, x11_modifier | _capslock_mask, root);
            } else {
                grabbed_successfully = NO;
            }
        }
        
        XSync(_display, False);
    }
    
    // Restore error handler
    XSetErrorHandler(oldHandler);
    
    NSLog(@"X11ShortcutManager: Availability check for keycode=%d modifier=%u: %s", 
          keycode, x11_modifier, grabbed_successfully ? "AVAILABLE" : "TAKEN");
    
    return !grabbed_successfully; // Return YES if taken, NO if available
}

#pragma mark - Private Methods

- (NSUInteger)getSwappedModifierMask:(NSUInteger)modifierMask
{
    NSUInteger swappedMask = modifierMask;
    
    // Check if we have Ctrl or Alt, and swap them
    BOOL hasCtrl = (modifierMask & NSControlKeyMask) != 0;
    BOOL hasAlt = (modifierMask & NSAlternateKeyMask) != 0;
    
    if (hasCtrl || hasAlt) {
        // Remove both Ctrl and Alt
        swappedMask &= ~(NSControlKeyMask | NSAlternateKeyMask);
        
        // Add them back swapped
        if (hasCtrl) {
            swappedMask |= NSAlternateKeyMask;  // Ctrl becomes Alt
        }
        if (hasAlt) {
            swappedMask |= NSControlKeyMask;    // Alt becomes Ctrl
        }
    }
    
    return swappedMask;
}

- (BOOL)registerSingleShortcut:(KeyCode)keycode 
                      modifier:(unsigned int)x11_modifier 
                   menuItemKey:(NSString *)menuItemKey 
                shortcutString:(NSString *)shortcutString
{
    // Check if this shortcut is already taken
    if ([self isShortcutAlreadyTaken:keycode modifier:x11_modifier]) {
        NSLog(@"X11ShortcutManager: Shortcut %@ is already taken - skipping", shortcutString);
        return NO;
    }
    
    // Try to grab the key
    if (![self grabX11Key:keycode modifier:x11_modifier]) {
        NSLog(@"X11ShortcutManager: Failed to grab X11 key for shortcut %@", shortcutString);
        return NO;
    }
    
    // Store the mapping from keycode+modifier to menu item
    NSString *keycodeModifierKey = [NSString stringWithFormat:@"%d_%u", keycode, x11_modifier];
    [_shortcutToMenuItemMap setObject:menuItemKey forKey:keycodeModifierKey];
    [_grabbedKeys setObject:menuItemKey forKey:keycodeModifierKey];
    [_registeredShortcuts addObject:shortcutString];
    
    NSLog(@"X11ShortcutManager: Successfully registered shortcut: %@ (keycode=%d, modifier=%u)", 
          shortcutString, keycode, x11_modifier);
    
    return YES;
}

- (NSString *)createShortcutStringFromKey:(NSString *)key modifiers:(NSUInteger)modifiers
{
    if ([key length] == 0) {
        return nil;
    }
    
    NSMutableArray *modifierStrings = [NSMutableArray array];
    
    // Convert modifier mask to string components
    if (modifiers & NSControlKeyMask) {
        [modifierStrings addObject:@"ctrl"];
    }
    if (modifiers & NSAlternateKeyMask) {
        [modifierStrings addObject:@"alt"];
    }
    if (modifiers & NSShiftKeyMask) {
        [modifierStrings addObject:@"shift"];
    }
    if (modifiers & NSCommandKeyMask) {
        [modifierStrings addObject:@"cmd"];
    }
    
    // Convert key to the format expected by globalshortcutsd
    NSString *normalizedKey = [self normalizeKeyForGlobalShortcut:key];
    if (!normalizedKey) {
        return nil;
    }
    
    if ([modifierStrings count] > 0) {
        return [NSString stringWithFormat:@"%@+%@", 
               [modifierStrings componentsJoinedByString:@"+"], normalizedKey];
    } else {
        return normalizedKey;
    }
}

- (NSString *)normalizeKeyForGlobalShortcut:(NSString *)key
{
    if ([key length] == 0) {
        return nil;
    }
    
    // Convert special key codes back to readable format
    if ([key isEqualToString:@"\r"]) {
        return @"Return";
    } else if ([key isEqualToString:@"\t"]) {
        return @"Tab";
    } else if ([key isEqualToString:@" "]) {
        return @"space";
    } else if ([key isEqualToString:@"\033"]) {
        return @"Escape";
    } else if ([key isEqualToString:@"\b"]) {
        return @"BackSpace";
    } else if ([key isEqualToString:@"\177"]) {
        return @"Delete";
    } else if ([key length] == 1) {
        // For single characters, use lowercase (X11 expects lowercase letters with modifiers)
        return [key lowercaseString];
    }
    
    // For function keys and other special keys, return as-is
    return key;
}

- (KeySym)parseKeyString:(NSString *)keyStr
{
    if ([keyStr length] == 0) {
        return NoSymbol;
    }
    
    const char *cStr = [keyStr UTF8String];
    
    // Handle special keys based on globalshortcutsd implementation
    if ([keyStr length] == 1) {
        // Single character - try lowercase for X11
        return XStringToKeysym([keyStr UTF8String]);
    }
    
    // Handle named keys
    if ([keyStr isEqualToString:@"space"]) return XK_space;
    if ([keyStr isEqualToString:@"return"] || [keyStr isEqualToString:@"enter"]) return XK_Return;
    if ([keyStr isEqualToString:@"tab"]) return XK_Tab;
    if ([keyStr isEqualToString:@"escape"] || [keyStr isEqualToString:@"esc"]) return XK_Escape;
    if ([keyStr isEqualToString:@"backspace"]) return XK_BackSpace;
    if ([keyStr isEqualToString:@"delete"]) return XK_Delete;
    
    // Function keys
    if ([keyStr hasPrefix:@"f"] && [keyStr length] <= 3) {
        int fNum = [[keyStr substringFromIndex:1] intValue];
        if (fNum >= 1 && fNum <= 24) {
            return XK_F1 + (fNum - 1);
        }
    }
    
    // Try direct keysym lookup
    return XStringToKeysym(cStr);
}

- (unsigned int)convertToX11Modifier:(NSUInteger)modifierMask
{
    unsigned int x11_modifier = 0;
    
    if (modifierMask & NSControlKeyMask) {
        x11_modifier |= ControlMask;
    }
    if (modifierMask & NSAlternateKeyMask) {
        x11_modifier |= Mod1Mask;  // Alt is typically Mod1
    }
    if (modifierMask & NSShiftKeyMask) {
        x11_modifier |= ShiftMask;
    }
    if (modifierMask & NSCommandKeyMask) {
        x11_modifier |= Mod4Mask;  // Super/Cmd is typically Mod4
    }
    
    return x11_modifier;
}

- (BOOL)grabX11Key:(KeyCode)keycode modifier:(unsigned int)modifier
{
    if (!_display) {
        return NO;
    }

    Window root = DefaultRootWindow(_display);
    BOOL success = YES;
    
    // Set up error handling
    x11_grab_error_occurred = NO;
    int (*oldHandler)(Display *, XErrorEvent *) = XSetErrorHandler(handleX11GrabError);
    
    // Base combination
    XGrabKey(_display, keycode, modifier, root, False, GrabModeAsync, GrabModeAsync);
    XSync(_display, False);
    if (x11_grab_error_occurred) success = NO;
    
    // With numlock
    if (_numlock_mask && !x11_grab_error_occurred) {
        XGrabKey(_display, keycode, modifier | _numlock_mask, root, False, GrabModeAsync, GrabModeAsync);
        XSync(_display, False);
    }
    
    // With capslock
    if (_capslock_mask && !x11_grab_error_occurred) {
        XGrabKey(_display, keycode, modifier | _capslock_mask, root, False, GrabModeAsync, GrabModeAsync);
        XSync(_display, False);
    }
    
    // With scrolllock
    if (_scrolllock_mask && !x11_grab_error_occurred) {
        XGrabKey(_display, keycode, modifier | _scrolllock_mask, root, False, GrabModeAsync, GrabModeAsync);
        XSync(_display, False);
    }
    
    // With numlock + capslock
    if (_numlock_mask && _capslock_mask && !x11_grab_error_occurred) {
        XGrabKey(_display, keycode, modifier | _numlock_mask | _capslock_mask, root, False, GrabModeAsync, GrabModeAsync);
        XSync(_display, False);
    }
    
    // With numlock + scrolllock
    if (_numlock_mask && _scrolllock_mask && !x11_grab_error_occurred) {
        XGrabKey(_display, keycode, modifier | _numlock_mask | _scrolllock_mask, root, False, GrabModeAsync, GrabModeAsync);
        XSync(_display, False);
    }
    
    // With capslock + scrolllock
    if (_capslock_mask && _scrolllock_mask && !x11_grab_error_occurred) {
        XGrabKey(_display, keycode, modifier | _capslock_mask | _scrolllock_mask, root, False, GrabModeAsync, GrabModeAsync);
        XSync(_display, False);
    }
    
    // With all locks
    if (_numlock_mask && _capslock_mask && _scrolllock_mask && !x11_grab_error_occurred) {
        XGrabKey(_display, keycode, modifier | _numlock_mask | _capslock_mask | _scrolllock_mask, root, False, GrabModeAsync, GrabModeAsync);
        XSync(_display, False);
    }
    
    // Restore error handler
    XSetErrorHandler(oldHandler);
    
    NSLog(@"X11ShortcutManager: Key grab result for keycode=%d modifier=0x%x: %s", 
          keycode, modifier, (success && !x11_grab_error_occurred) ? "SUCCESS" : "FAILED");
    
    // Additional debug: Check if the key grab worked by testing it
    if (success && !x11_grab_error_occurred) {
        NSLog(@"X11ShortcutManager: Verifying key grab by checking connection and display");
        int fd = ConnectionNumber(_display);
        NSLog(@"X11ShortcutManager: X11 connection file descriptor: %d", fd);
        
        // Try to get the current keyboard mapping as a health check
        int min_keycode, max_keycode;
        XDisplayKeycodes(_display, &min_keycode, &max_keycode);
        NSLog(@"X11ShortcutManager: X11 keyboard range: %d-%d", min_keycode, max_keycode);
    }
    
    return success && !x11_grab_error_occurred;
}

- (void)startX11EventMonitoring
{
    if (!_display) {
        NSLog(@"X11ShortcutManager: Cannot start X11 event monitoring - no display");
        return;
    }
    
    if (_eventMonitorThread && !_shouldStopEventMonitoring) {
        NSLog(@"X11ShortcutManager: Event monitoring already running");
        return;
    }
    
    // Select KeyPress events on the root window - THIS IS CRITICAL!
    // Without this, XGrabKey won't deliver events to us
    Window root = DefaultRootWindow(_display);
    
    // Use KeyPressMask and also StructureNotifyMask for better event handling
    XSelectInput(_display, root, KeyPressMask | StructureNotifyMask);
    XSync(_display, False);
    
    // Make sure the X11 connection is flushed
    XFlush(_display);
    
    NSLog(@"X11ShortcutManager: Selected KeyPress events on root window (window ID: %lu)", root);
    
    // Start the event monitoring thread
    _shouldStopEventMonitoring = NO;
    _eventMonitorThread = [[NSThread alloc] initWithTarget:self
                                                  selector:@selector(eventMonitorThreadMain)
                                                    object:nil];
    [_eventMonitorThread start];
    
    NSLog(@"X11ShortcutManager: Started X11 event monitoring thread");
}

- (void)eventMonitorThreadMain
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    NSLog(@"X11ShortcutManager: Event monitoring thread started");
    
    while (!_shouldStopEventMonitoring && _display) {
        // Process all pending X11 events
        int eventCount = 0;
        while (XPending(_display) && !_shouldStopEventMonitoring) {
            XEvent event;
            XNextEvent(_display, &event);
            eventCount++;
            
            if (event.type == KeyPress) {
                XKeyEvent *keyEvent = &event.xkey;
                
                // Filter out lock key masks like globalshortcutsd does
                unsigned int filteredState = keyEvent->state;
                filteredState &= ~(_numlock_mask | _capslock_mask | _scrolllock_mask);
                
                NSLog(@"X11ShortcutManager: KeyPress event - keycode=%d, state=%u (filtered from %u), window=%lu", 
                      keyEvent->keycode, filteredState, keyEvent->state, keyEvent->window);
                
                // Create key for lookup using the filtered state (no swapping needed)
                NSString *keycodeModifierKey = [NSString stringWithFormat:@"%d_%u", 
                                              keyEvent->keycode, filteredState];
                
                // Find the menu item for this shortcut
                NSString *menuItemKey = [_grabbedKeys objectForKey:keycodeModifierKey];
                if (menuItemKey) {
                    NSLog(@"X11ShortcutManager: Found matching shortcut for key: %@", keycodeModifierKey);
                    // Trigger the menu action on the main thread
                    [self performSelectorOnMainThread:@selector(triggerMenuActionForKey:)
                                           withObject:menuItemKey
                                        waitUntilDone:NO];
                } else {
                    NSLog(@"X11ShortcutManager: No matching shortcut found for key: %@", keycodeModifierKey);
                    
                    // Debug: Log all registered shortcuts
                    NSLog(@"X11ShortcutManager: Currently have %lu registered shortcuts:", (unsigned long)[_grabbedKeys count]);
                    for (NSString *key in [_grabbedKeys allKeys]) {
                        NSLog(@"X11ShortcutManager:   %@ -> %@", key, [_grabbedKeys objectForKey:key]);
                    }
                }
            } else {
                // Log other event types occasionally for debugging
                static int otherEventCounter = 0;
                if (++otherEventCounter % 100 == 0) {
                    NSLog(@"X11ShortcutManager: Received non-KeyPress event type: %d (count: %d)", event.type, otherEventCounter);
                }
            }
        }
        
        // Only log thread activity when there are events or occasionally for debug
        static int debugCounter = 0;
        if (eventCount > 0 || ++debugCounter % 1000 == 0) { // Log every 10 seconds (1000 * 0.01s) or when events occur
            if (eventCount > 0) {
                NSLog(@"X11ShortcutManager: Processed %d events this cycle", eventCount);
            } else {
                NSLog(@"X11ShortcutManager: Event thread running (%d iterations, %lu grabbed keys, no events)", 
                      debugCounter, (unsigned long)[_grabbedKeys count]);
            }
        }
        
        // Small sleep to prevent busy waiting and allow other threads to run
        usleep(10000); // 10ms, similar to globalshortcutsd
    }
    
    NSLog(@"X11ShortcutManager: Event monitoring thread terminated");
    [pool release];
}

- (void)triggerMenuActionForKey:(NSString *)menuItemKey
{
    // Find the menu item using the stored mappings
    NSString *serviceName = [_menuItemToServiceMap objectForKey:menuItemKey];
    NSString *objectPath = [_menuItemToObjectPathMap objectForKey:menuItemKey];
    id connectionOrTarget = [_menuItemToConnectionMap objectForKey:menuItemKey];
    NSNumber *tagNumber = [_menuItemKeyToTag objectForKey:menuItemKey];
    NSString *actionName = [_menuItemToActionNameMap objectForKey:menuItemKey];
    
    // Check if this is a direct action (target/action pattern)
    if (connectionOrTarget && ![connectionOrTarget isKindOfClass:[GNUDBusConnection class]]) {
        // This is a direct target/action call
        id target = connectionOrTarget;
        SEL action = NSSelectorFromString(objectPath); // objectPath stores the selector string
        
        NSLog(@"X11ShortcutManager: Triggering direct action %@ on target %@", objectPath, [target class]);
        
        if ([target respondsToSelector:action]) {
            // We need to create a temporary menu item to pass the window ID
            NSMenuItem *tempMenuItem = [[NSMenuItem alloc] initWithTitle:@"Close" action:action keyEquivalent:@""];
            // The window ID should be stored in the service name field for direct actions
            NSNumber *windowId = [NSNumber numberWithUnsignedLong:(unsigned long)[serviceName longLongValue]];
            [tempMenuItem setRepresentedObject:windowId];
            
            [target performSelector:action withObject:tempMenuItem];
            [tempMenuItem release];
            NSLog(@"X11ShortcutManager: Direct action succeeded");
        } else {
            NSLog(@"X11ShortcutManager: ERROR: Target %@ does not respond to selector %@", [target class], objectPath);
        }
        return;
    }
    
    // Continue with DBus handling for regular menu items
    GNUDBusConnection *dbusConnection = (GNUDBusConnection *)connectionOrTarget;
    
    if (!serviceName || !objectPath || !dbusConnection || !tagNumber) {
        NSLog(@"X11ShortcutManager: ERROR: Missing DBus info for shortcut trigger (service=%@, path=%@, tag=%@)", 
              serviceName, objectPath, tagNumber);
        return;
    }
    
    int menuItemId = [tagNumber intValue];
    NSLog(@"X11ShortcutManager: Shortcut triggered for menu item ID=%d (service=%@, path=%@)", 
          menuItemId, serviceName, objectPath);
    
    // Try GTK Actions protocol first (modern apps like gedit)
    if (actionName && [self tryGTKAction:actionName 
                             serviceName:serviceName 
                              objectPath:objectPath 
                          dbusConnection:dbusConnection]) {
        NSLog(@"X11ShortcutManager: GTK Actions activation succeeded for action: %@", actionName);
        return;
    }
    
    // Fallback to Unity DBus menu protocol (older apps)
    if ([self tryUnityDBusMenu:menuItemId 
                   serviceName:serviceName 
                    objectPath:objectPath 
                dbusConnection:dbusConnection]) {
        NSLog(@"X11ShortcutManager: Unity DBus menu activation succeeded for menu item ID: %d", menuItemId);
        return;
    }
    
    NSLog(@"X11ShortcutManager: ERROR: Both GTK Actions and Unity DBus menu protocols failed");
}

- (BOOL)tryGTKAction:(NSString *)actionName
         serviceName:(NSString *)serviceName
          objectPath:(NSString *)objectPath
      dbusConnection:(GNUDBusConnection *)dbusConnection
{
    if (!actionName) {
        return NO;
    }
    
    NSString *actualActionName = actionName;
    NSString *actualObjectPath = objectPath;
    
    // Determine the correct action path and name based on the action scope
    if ([actionName hasPrefix:@"app."]) {
        // App-scoped actions (like app.quit, app.about) go to the application path
        if ([objectPath containsString:@"/org/gnome/gedit/menus/"]) {
            actualObjectPath = @"/org/gnome/gedit";
        } else if ([objectPath containsString:@"/com/canonical/menu/"]) {
            // For other GTK apps, try to find the app path
            // For now, use the original path
        }
        // Strip the "app." prefix since apps register actions without prefixes
        actualActionName = [actionName substringFromIndex:4];
        NSLog(@"X11ShortcutManager: Using app action: %@ -> %@ on path: %@", 
              actionName, actualActionName, actualObjectPath);
    } else if ([actionName hasPrefix:@"win."]) {
        // Window-scoped actions go to the window path
        if ([objectPath containsString:@"/org/gnome/gedit/menus/"]) {
            actualObjectPath = @"/org/gnome/gedit/window/1";
        } else if ([objectPath containsString:@"/com/canonical/menu/"]) {
            // For other GTK apps, try to find the window path
            // For leafpad and similar, the path might be different
            actualObjectPath = @"/org/appmenu/gtk/window/0";
        }
        // Strip the "win." prefix since apps register actions without prefixes
        actualActionName = [actionName substringFromIndex:4];
        NSLog(@"X11ShortcutManager: Using window action: %@ -> %@ on path: %@", 
              actionName, actualActionName, actualObjectPath);
    } else if ([actionName hasPrefix:@"unity."]) {
        // Legacy unity actions - strip the prefix and try window path first
        actualActionName = [actionName substringFromIndex:6];
        if ([objectPath containsString:@"/com/canonical/menu/"]) {
            actualObjectPath = @"/org/appmenu/gtk/window/0";
        }
        NSLog(@"X11ShortcutManager: Using unity action: %@ -> %@ on path: %@", 
              actionName, actualActionName, actualObjectPath);
    }
    
    // Prepare platform data for focus/activation context
    NSMutableDictionary *platformData = [NSMutableDictionary dictionary];
    [platformData setObject:@"" forKey:@"desktop-startup-id"];
    
    // Use empty parameter list for most actions
    NSArray *parameter = [NSArray array];
    
    // Call Activate method on org.gtk.Actions interface
    NSLog(@"X11ShortcutManager: Attempting GTK Activate: action='%@' on service=%@ path=%@", 
          actualActionName, serviceName, actualObjectPath);
    
    id result = [dbusConnection callGTKActivateMethod:actualActionName
                                            parameter:parameter
                                         platformData:platformData
                                            onService:serviceName
                                           objectPath:actualObjectPath];
    
    return result != nil;
}

- (BOOL)tryUnityDBusMenu:(int)menuItemId
             serviceName:(NSString *)serviceName
              objectPath:(NSString *)objectPath
          dbusConnection:(GNUDBusConnection *)dbusConnection
{
    // Send Event method call to activate the menu item using Unity protocol
    NSArray *arguments = [NSArray arrayWithObjects:
                         [NSNumber numberWithInt:menuItemId],   // menu item ID
                         @"clicked",                            // event type
                         @"",                                  // event data (empty)
                         [NSNumber numberWithUnsignedInt:0],    // timestamp
                         nil];
    
    NSLog(@"X11ShortcutManager: Attempting Unity DBus menu Event: ID=%d on service=%@ path=%@", 
          menuItemId, serviceName, objectPath);
    
    id result = [dbusConnection callMethod:@"Event"
                                 onService:serviceName
                                objectPath:objectPath
                                 interface:@"com.canonical.dbusmenu"
                                 arguments:arguments];
    
    return result != nil;
}

- (void)detectLockMasks
{
    if (!_display) {
        return;
    }
    
    XModifierKeymap *modmap;
    KeyCode nlock, slock;
    static int mask_table[8] = {
        ShiftMask, LockMask, ControlMask, Mod1Mask,
        Mod2Mask, Mod3Mask, Mod4Mask, Mod5Mask
    };
    
    // Initialize masks to zero
    _numlock_mask = 0;
    _scrolllock_mask = 0;
    _capslock_mask = LockMask;  // CapsLock is typically LockMask
    
    nlock = XKeysymToKeycode(_display, XK_Num_Lock);
    slock = XKeysymToKeycode(_display, XK_Scroll_Lock);
    
    modmap = XGetModifierMapping(_display);
    
    if (modmap != NULL && modmap->max_keypermod > 0) {
        for (int i = 0; i < 8 * modmap->max_keypermod; i++) {
            if (modmap->modifiermap[i] == nlock && nlock != 0)
                _numlock_mask = mask_table[i / modmap->max_keypermod];
            else if (modmap->modifiermap[i] == slock && slock != 0)
                _scrolllock_mask = mask_table[i / modmap->max_keypermod];
        }
    }
    
    if (modmap)
        XFreeModifiermap(modmap);
    
    NSLog(@"X11ShortcutManager: Detected lock masks - NumLock: 0x%x, CapsLock: 0x%x, ScrollLock: 0x%x",
          _numlock_mask, _capslock_mask, _scrolllock_mask);
}

- (void)registerDirectShortcutForMenuItem:(NSMenuItem *)menuItem
                                   target:(id)target
                                   action:(SEL)action
{
    if (!_display) {
        NSLog(@"X11ShortcutManager: Cannot register direct shortcut - no X11 display");
        return;
    }
    
    NSString *keyEquivalent = [menuItem keyEquivalent];
    NSUInteger modifierMask = [menuItem keyEquivalentModifierMask];
    
    if ([keyEquivalent length] == 0 || modifierMask == 0) {
        NSLog(@"X11ShortcutManager: Cannot register direct shortcut - no key equivalent or modifier");
        return;
    }
    
    // Create a stable key for direct shortcuts using window ID, title, and key
    NSNumber *windowId = [menuItem representedObject];
    NSString *windowIdString = windowId ? [windowId stringValue] : @"0";
    NSString *menuItemKey = [NSString stringWithFormat:@"direct_%@_%@_%@", 
                            windowIdString,
                            [menuItem title] ?: @"untitled",
                            [menuItem keyEquivalent] ?: @"none"];
    
    [_menuItemToServiceMap setObject:windowIdString forKey:menuItemKey]; // Store window ID
    [_menuItemToObjectPathMap setObject:NSStringFromSelector(action) forKey:menuItemKey]; // Store action selector
    [_menuItemToConnectionMap setObject:target forKey:menuItemKey]; // Store target
    
    // Convert key to X11 KeySym and KeyCode
    KeySym keysym = [self parseKeyString:keyEquivalent];
    if (keysym == NoSymbol) {
        NSLog(@"X11ShortcutManager: Failed to convert key '%@' to X11 KeySym", keyEquivalent);
        return;
    }
    
    KeyCode keycode = XKeysymToKeycode(_display, keysym);
    if (keycode == 0) {
        NSLog(@"X11ShortcutManager: Failed to convert KeySym to KeyCode for '%@'", keyEquivalent);
        return;
    }
    
    unsigned int x11_modifier = [self convertToX11Modifier:modifierMask];
    
    NSLog(@"X11ShortcutManager: Registering direct shortcut %@ with modifier 0x%x (keycode %d) for window %@",
          keyEquivalent, x11_modifier, keycode, windowIdString);
    
    // Register the shortcut with X11 using the same method as existing shortcuts
    if (![self grabX11Key:keycode modifier:x11_modifier]) {
        NSLog(@"X11ShortcutManager: Failed to grab X11 key for direct shortcut %@", keyEquivalent);
        return;
    }
    
    // Store the mapping for later lookup using the same format as existing shortcuts
    NSString *keycodeModifierKey = [NSString stringWithFormat:@"%d_%u", keycode, x11_modifier];
    [_shortcutToMenuItemMap setObject:menuItemKey forKey:keycodeModifierKey];
    [_grabbedKeys setObject:menuItemKey forKey:keycodeModifierKey];
    
    NSLog(@"X11ShortcutManager: Successfully registered direct shortcut for %@", keyEquivalent);
    
    // Debug: Check the state after registration
    NSLog(@"X11ShortcutManager: After registration - _grabbedKeys count: %lu, _eventMonitorThread: %@", 
          (unsigned long)[_grabbedKeys count], _eventMonitorThread ? @"EXISTS" : @"nil");
    
    // Start X11 event monitoring if this is the first shortcut
    if ([_grabbedKeys count] > 0 && !_eventMonitorThread) {
        NSLog(@"X11ShortcutManager: Starting event monitoring for direct shortcuts - have %lu grabbed keys", 
              (unsigned long)[_grabbedKeys count]);
        [self startX11EventMonitoring];
    } else {
        NSLog(@"X11ShortcutManager: Not starting event monitoring - count: %lu, thread: %@", 
              (unsigned long)[_grabbedKeys count], _eventMonitorThread ? @"EXISTS" : @"nil");
    }
}

@end
