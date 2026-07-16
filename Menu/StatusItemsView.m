/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "StatusItemsView.h"
#import "StatusItemView.h"
#import "StatusItemManager.h"

@implementation StatusItemsView

- (instancetype)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        _itemViews = [NSMutableArray array];
        _interItemSpacing = 0.0;
        _rightInset = 10.0;
        [self setAutoresizingMask:NSViewMinXMargin | NSViewHeightSizable];
    }
    return self;
}

- (void)addItemView:(StatusItemView *)itemView
{
    if (!itemView) return;
    [_itemViews addObject:itemView];
    [self addSubview:itemView];
}

- (void)layoutItemViews
{
    NSRect bounds = [self bounds];
    CGFloat x = bounds.size.width - _rightInset;

    for (NSInteger i = (NSInteger)[_itemViews count] - 1; i >= 0; i--) {
        StatusItemView *view = [_itemViews objectAtIndex:(NSUInteger)i];
        CGFloat w = view.fixedWidth;
        x -= w;

        NSRect frame = NSMakeRect(x, 0, w, bounds.size.height);
        [view setFrame:frame];

        if (i > 0) {
            x -= _interItemSpacing;
        }
    }

    [self setNeedsDisplay:YES];
}

- (CGFloat)totalRequiredWidth
{
    CGFloat total = _rightInset;
    NSUInteger count = [_itemViews count];

    for (NSUInteger i = 0; i < count; i++) {
        StatusItemView *view = [_itemViews objectAtIndex:i];
        total += view.fixedWidth;
        if (i < count - 1) {
            total += _interItemSpacing;
        }
    }

    return total;
}

- (void)drawRect:(NSRect)dirtyRect
{
    (void)dirtyRect;
    [[NSColor clearColor] set];
    NSRectFill([self bounds]);
}

- (BOOL)isOpaque
{
    return NO;
}

#pragma mark - Drag reordering

- (void)moveItemView:(StatusItemView *)view toIndex:(NSInteger)newIndex
{
    NSUInteger oldIndex = [_itemViews indexOfObject:view];
    if (oldIndex == NSNotFound || oldIndex == (NSUInteger)newIndex) return;

    [_itemViews removeObjectAtIndex:oldIndex];
    [_itemViews insertObject:view atIndex:(newIndex > (NSInteger)oldIndex ? (NSUInteger)newIndex : (NSUInteger)newIndex)];

    [self layoutItemViews];
    [_manager savePreferences];
}

- (NSInteger)indexOfItemViewAtPoint:(NSPoint)point
{
    for (NSUInteger i = 0; i < [_itemViews count]; i++) {
        StatusItemView *v = [_itemViews objectAtIndex:i];
        if (NSPointInRect(point, [v frame])) {
            return (NSInteger)i;
        }
    }
    return -1;
}

#pragma mark - Mouse tracking for drag

- (void)mouseDown:(NSEvent *)event
{
}

@end
