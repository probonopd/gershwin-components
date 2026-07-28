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

@end
