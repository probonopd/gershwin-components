/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

@protocol GSGNUstepMenuServer
- (oneway void)updateMenuForWindow:(bycopy NSNumber *)windowId
                          menuData:(bycopy NSDictionary *)menuData
                        clientName:(bycopy NSString *)clientName;
- (oneway void)unregisterWindow:(bycopy NSNumber *)windowId
                       clientName:(bycopy NSString *)clientName;
// Lightweight: patches only enabled/state on the existing NSMenu without
// rebuilding it. This path is still subject to the short enabled-state
// throttling gate (currently 50 ms), so updates are not strictly immediate.
- (oneway void)updateMenuEnabledStatesForWindow:(bycopy NSNumber *)windowId
                                       menuData:(bycopy NSDictionary *)menuData
                                     clientName:(bycopy NSString *)clientName;
@end

@protocol GSGNUstepMenuClient
- (oneway void)activateMenuItemAtPath:(NSArray *)indexPath
                            forWindow:(NSNumber *)windowId;

// Request the client to push its current menu for the given X11 window ID.
// This allows the server to import menus from already-mapped GNUstep windows
// (for example the Desktop) by asking the client to send its menu via
// updateMenuForWindow:menuData:clientName:.
- (oneway void)requestMenuUpdateForWindow:(NSNumber *)windowId;

// Synchronous: validate and return fresh menu data (including enabled/state).
// Menu.app calls this right before opening a submenu so that item states
// (enabled/disabled, checkmarks) are up-to-date before the user sees them.
// Must respond promptly (< 300 ms).
- (bycopy NSDictionary *)validateMenuStateForWindow:(NSNumber *)windowId;
@end
