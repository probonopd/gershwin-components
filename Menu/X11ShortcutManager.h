/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */


#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <X11/Xlib.h>

#include <unistd.h>

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
 * Register a global shortcut for a menu item with action name for protocol detection
 * @param menuItem The menu item to associate with the shortcut
 * @param serviceName The DBus service name for action callbacks
 * @param objectPath The DBus object path for action callbacks  
 * @param actionName The action name (e.g., "win.print", "app.quit")
 * @param dbusConnection The DBus connection for action callbacks
 */
- (void)registerShortcutForMenuItem:(NSMenuItem *)menuItem
                        serviceName:(NSString *)serviceName
                         objectPath:(NSString *)objectPath
                         actionName:(NSString *)actionName
                     dbusConnection:(GNUDBusConnection *)dbusConnection;

/**
 * Register a global shortcut for a menu item with direct target/action (no DBus)
 * @param menuItem The menu item to associate with the shortcut
 * @param target The target object for the action
 * @param action The selector to call on the target
 */
- (BOOL)registerDirectShortcutForMenuItem:(NSMenuItem *)menuItem
                                   target:(id)target
                                   action:(SEL)action; // Returns YES on success, NO on failure

/**
 * Unregister all global shortcuts
 */
- (void)unregisterAllShortcuts;

/**
 * Unregister shortcuts that were registered from DBus/app menus (non-direct shortcuts).
 * This preserves direct shortcuts (those registered with registerDirectShortcutForMenuItem:)
 * so global hotkeys like Cmd/Alt+Space remain active across application switches.
 */
- (void)unregisterNonDirectShortcuts;

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
 * Temporarily suspend all global key grabs (allows other windows to receive keyboard input)
 */
- (void)suspendKeyGrabs;

/**
 * Resume global key grabs after suspension
 */
- (void)resumeKeyGrabs;

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

/**
 * Check whether a (keycode, modifier) pair is the reserved Alt+Space (Action
 * Search) global shortcut that Menu.app keeps for itself.  App menus must not
 * be able to claim it, and it always dispatches the Action Search toggle.
 * @param keycode The keycode of the shortcut
 * @param x11_modifier The modifier keys (Mod1Mask = Alt)
 * @return YES if this is the reserved Alt+Space
 */
- (BOOL)isReservedActionSearchShortcut:(KeyCode)keycode modifier:(unsigned int)x11_modifier;

/**
 * Register a special XF86 key (volume, brightness, etc.) without modifier.
 * The key is grabbed with AnyModifier; lock masks are filtered at dispatch.
 * @param keysym The X11 keysym (e.g. XF86XK_AudioRaiseVolume)
 * @param target The target object for the action
 * @param action The selector to call on the target
 * @return YES on success
 */
- (BOOL)registerXF86Key:(KeySym)keysym target:(id)target action:(SEL)action;

/**
 * Register a special XF86 key with separate press and release handlers.
 * Used for keys that need press/release tracking (e.g. the power key, where
 * a short press and a long press perform different actions).  The key is
 * grabbed the same way as registerXF86Key:target:action:.
 * @param keysym The X11 keysym (e.g. XF86XK_PowerOff)
 * @param target The target for the press action
 * @param action The selector called on press
 * @param releaseTarget The target for the release action
 * @param releaseAction The selector called on release
 * @return YES on success
 */
- (BOOL)registerXF86Key:(KeySym)keysym
                 target:(id)target
                 action:(SEL)action
          releaseTarget:(id)releaseTarget
          releaseAction:(SEL)releaseAction;

@end
