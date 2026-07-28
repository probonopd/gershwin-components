/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

@class MenuExtraManager;

@interface MenuExtrasPrefPanel : NSWindowController

- (instancetype)initWithManager:(MenuExtraManager *)manager;
- (void)reloadExtras;

@end
