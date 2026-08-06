/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import "MenuProtocolManager.h"
#import "GNUStepMenuIPC.h"

@class AppMenuWidget;

@interface GNUStepMenuImporter : NSObject <MenuProtocolHandler, GSGNUstepMenuServer>

@property (nonatomic, weak) AppMenuWidget *appMenuWidget;

// Synchronously fetch fresh enabled/state data from the client and apply it
// to the stored NSMenu for windowId.  Called from AppMenuWidget.menuNeedsUpdate:
// right before a submenu is shown, guaranteeing up-to-date item states.
// Returns YES when the NSMenu was successfully refreshed.
- (BOOL)refreshMenuStateForWindow:(unsigned long)windowId;

// Returns YES when the window's enabled/checkmark states are known to be
// current (pulled or pushed within the TTL), so the click path can skip the
// synchronous pull.  Windows we do not track report YES.
- (BOOL)menuStatesAreFreshForWindow:(unsigned long)windowId withinTTL:(NSTimeInterval)ttl;

// The authoritative current menu client name for a window (from the last
// accepted menu push).  Menu item actions use this instead of the possibly
// stale client name embedded in a menu item left over from a previous app
// instance that reused the X window ID.
+ (NSString *)currentClientNameForWindow:(unsigned long)windowId;

@end
