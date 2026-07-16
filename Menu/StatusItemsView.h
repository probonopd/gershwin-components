/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

@class StatusItemView;
@class StatusItemManager;

@interface StatusItemsView : NSView

@property (nonatomic, strong, readonly) NSMutableArray<StatusItemView *> *itemViews;
@property (nonatomic, assign) CGFloat interItemSpacing;
@property (nonatomic, assign) CGFloat rightInset;
@property (nonatomic, weak) StatusItemManager *manager;

- (instancetype)initWithFrame:(NSRect)frame;
- (void)addItemView:(StatusItemView *)itemView;
- (void)layoutItemViews;
- (CGFloat)totalRequiredWidth;
- (void)moveItemView:(StatusItemView *)view toIndex:(NSInteger)newIndex;
- (NSInteger)indexOfItemViewAtPoint:(NSPoint)point;

@end
