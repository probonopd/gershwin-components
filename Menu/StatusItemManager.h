/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import "StatusItemProvider.h"

@class MenuExtrasPrefPanel;

@interface StatusItemManager : NSObject

@property (nonatomic, strong) NSMutableArray<id<StatusItemProvider>> *statusItems;
@property (nonatomic, strong) NSMutableDictionary *updateTimers;
@property (nonatomic, assign) CGFloat screenWidth;
@property (nonatomic, assign) CGFloat menuBarHeight;

- (instancetype)initWithScreenWidth:(CGFloat)width
                      menuBarHeight:(CGFloat)height;

- (void)loadStatusItems;
- (NSView *)createExtrasMenuView;
- (CGFloat)extrasMenuWidth;
- (void)startUpdateTimers;
- (void)stopUpdateTimers;
- (void)unloadAllStatusItems;

- (void)refreshExtraWithIdentifier:(NSString *)identifier;
- (void)savePreferences;

- (void)showPreferencesPanel;

@end
