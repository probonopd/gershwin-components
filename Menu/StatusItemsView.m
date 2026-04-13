/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "StatusItemsView.h"
#import "StatusItemView.h"

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
    if (!itemView) {
        return;
    }
    [_itemViews addObject:itemView];
    [self addSubview:itemView];
}

- (void)layoutItemViews
{
    NSRect bounds = [self bounds];
    CGFloat x = bounds.size.width - _rightInset;

    /*
     * Layout right-to-left: the LAST item in the array has the highest
     * displayPriority and is placed at the rightmost position.
     */
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
    /* Fill with the same opaque RGBA Eau's slot panel and MenuBarView use
     * (0.992,0.992,0.992,1.0). Previously this filled with clearColor and
     * relied on MenuBarView's background to show through, but
     * MenuBarView's drawRect cache skipped repainting under partial
     * dirty rects, exposing the NSWindow background instead — visible as
     * a darker stripe on the right of the bar. */
    (void)dirtyRect;
    [[NSColor colorWithCalibratedRed:0.992 green:0.992 blue:0.992 alpha:1.0] set];
    NSRectFill([self bounds]);
}

- (BOOL)isOpaque
{
    return YES;
}

@end
