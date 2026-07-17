/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

@class StatusItemManager;

@protocol StatusItemProvider <NSObject>

@required

- (NSString *)identifier;
- (NSString *)title;
- (CGFloat)width;
- (void)loadWithManager:(StatusItemManager *)manager;

@optional

- (void)update;
- (void)handleClick;
- (NSMenu *)menu;
- (NSImage *)icon;
- (NSTimeInterval)updateInterval;
- (void)unload;
- (NSInteger)displayPriority;

/**
 * Called immediately before the provider's menu is displayed.
 * Use this to refresh menu content lazily instead of polling.
 */
- (void)menuWillOpen;

/**
 * Called after the provider's menu has been dismissed.
 */
- (void)menuDidClose;

/**
 * Update menu item states (checkmarks, enabled) in-place.
 * Called when the cached submenu needs to reflect current state
 * without replacing the entire NSMenu object.
 */
- (void)refreshMenuItems:(NSMenu *)submenu;

@end
