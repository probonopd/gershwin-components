#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <X11/Xlib.h>

@class GNUDBusConnection;

/**
 * X11ShortcutManager handles registration and monitoring of global keyboard shortcuts
 * in X11 environments. It manages the mapping between X11 key events and NSMenuItem
 * actions, with support for Ctrl/Alt modifier swapping.
 */
@interface X11ShortcutManager : NSObject

/**
 * Get the shared instance of the shortcut manager
 */
+ (instancetype)sharedManager;

/**
 * Register a global shortcut for a menu item
 * @param menuItem The menu item to associate with the shortcut
 * @param serviceName The DBus service name for action callbacks
 * @param objectPath The DBus object path for action callbacks  
 * @param dbusConnection The DBus connection for action callbacks
 */
- (void)registerShortcutForMenuItem:(NSMenuItem *)menuItem
                        serviceName:(NSString *)serviceName
                         objectPath:(NSString *)objectPath
                     dbusConnection:(GNUDBusConnection *)dbusConnection;

/**
 * Unregister all global shortcuts
 */
- (void)unregisterAllShortcuts;

/**
 * Check if Ctrl/Alt swapping is enabled
 */
- (BOOL)shouldSwapCtrlAlt;

/**
 * Enable or disable Ctrl/Alt swapping
 */
- (void)setSwapCtrlAlt:(BOOL)swap;

/**
 * Cleanup resources (called on app termination)
 */
- (void)cleanup;

/**
 * Check availability of multiple shortcuts and log which are available vs taken
 * @param shortcuts Array of shortcut strings (e.g., @[@"ctrl+t", @"alt+n"])
 */
- (void)checkShortcutAvailability:(NSArray *)shortcuts;

/**
 * Check if a specific shortcut is already taken
 * @param shortcutString The shortcut string (e.g., @"ctrl+t")
 * @return YES if the shortcut is already taken, NO otherwise
 */
- (BOOL)isShortcutAlreadyTaken:(NSString *)shortcutString;

/**
 * Check if a specific shortcut is already taken using keycode and modifier
 * @param keycode The keycode of the shortcut
 * @param x11_modifier The modifier keys (e.g., ControlMask, Mod1Mask for Alt)
 * @return YES if the shortcut is already taken, NO otherwise
 */
- (BOOL)isShortcutAlreadyTaken:(KeyCode)keycode modifier:(unsigned int)x11_modifier;

@end
