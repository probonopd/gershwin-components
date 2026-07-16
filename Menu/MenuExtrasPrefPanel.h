/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

@class StatusItemManager;

@interface MenuExtrasPrefPanel : NSWindowController

- (instancetype)initWithManager:(StatusItemManager *)manager;

@end
