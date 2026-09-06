/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

@class GSMenuExtraInstance;

@protocol MenuExtraConfigProtocol
- (BOOL)updateEnabledExtras:(NSArray *)identifiers;
@end

@interface MenuExtraManager : NSObject <MenuExtraConfigProtocol>

@property (nonatomic, strong) NSMutableArray<GSMenuExtraInstance *> *menuExtras;
@property (nonatomic, strong) NSTimer *updateTimer;
@property (nonatomic, assign) CGFloat screenWidth;
@property (nonatomic, assign) CGFloat menuBarHeight;

- (instancetype)initWithScreenWidth:(CGFloat)width
                      menuBarHeight:(CGFloat)height;

- (void)loadMenuExtras;
- (NSView *)createExtrasMenuView;
- (CGFloat)extrasMenuWidth;
- (void)startUpdateTimers;
- (void)stopUpdateTimers;
- (void)unloadAllMenuExtras;

- (void)refreshExtraWithIdentifier:(NSString *)identifier;
- (void)savePreferences;
- (void)reloadEnabledFromDefaults;
- (NSArray<GSMenuExtraInstance *> *)allMenuExtras;

- (void)showPreferencesPanel;

@end
