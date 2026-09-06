/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

@class GSMenuExtraContext;

@protocol GSMenuExtra <NSObject>

@required

- (NSMenu *)menu;
- (NSImage *)image;
- (NSString *)title;

@optional

- (NSView *)customView;
- (CGFloat)preferredWidth;
- (void)menuExtraDidLoad;
- (void)menuExtraWillUnload;
- (void)menuExtraWillOpenMenu;
- (void)menuExtraDidCloseMenu;
- (void)setContext:(GSMenuExtraContext *)context;

/**
 * Return NO if this MenuExtra is incompatible with the current hardware
 * (e.g., BatteryExtra when no battery is present).  Incompatible extras
 * are not loaded even if enabled, and do not appear in the preferences
 * panel.  Defaults to YES when not implemented.
 */
- (BOOL)isCompatibleWithSystem;

@end
