/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "StatusItemView.h"
#import "StatusItemManager.h"
#import "GNUstepGUI/GSTheme.h"

@implementation StatusItemView

- (instancetype)initWithProvider:(id<StatusItemProvider>)provider
                      fixedWidth:(CGFloat)width
                          height:(CGFloat)height
{
    NSRect frame = NSMakeRect(0, 0, width, height);
    self = [super initWithFrame:frame];
    if (self) {
        _provider = provider;
        _fixedWidth = width;
        _title = [provider title] ? [provider title] : @"";
        _highlighted = NO;
    }
    return self;
}

- (void)updateTitle:(NSString *)title
{
    if (!title) {
        title = @"";
    }
    if ([_title isEqualToString:title]) {
        return;
    }
    _title = [title copy];
    [self setNeedsDisplay:YES];
}

- (NSDictionary *)textAttributes
{
    NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
    [style setAlignment:NSLeftTextAlignment];

    NSFont *font = [NSFont menuBarFontOfSize:0];

    return @{
        NSFontAttributeName: font,
        NSParagraphStyleAttributeName: style,
        NSForegroundColorAttributeName: [NSColor blackColor]
    };
}

- (void)drawRect:(NSRect)dirtyRect
{
    (void)dirtyRect;

    NSRect bounds = [self bounds];

    /* Match the bar's opaque background (0.992,0.992,0.992,1.0) so each
     * status item sits on the same colour as MenuBarView and the slot,
     * eliminating per-item color stripes. */
    [[NSColor colorWithCalibratedRed:0.992 green:0.992 blue:0.992 alpha:1.0] set];
    NSRectFill(bounds);

    /* Optional highlight on mouse-down */
    if (_highlighted) {
        [[NSColor colorWithCalibratedWhite:0.0 alpha:0.1] set];
        NSRectFill(bounds);
    }

    /* Draw title left-aligned inside the fixed-width bounds with consistent padding */
    if (_title && [_title length] > 0) {
        NSDictionary *attrs = [self textAttributes];
        NSSize textSize = [_title sizeWithAttributes:attrs];

        /* Centre vertically and left-align with padding */
        CGFloat y = floor((bounds.size.height - textSize.height) / 2.0);
        CGFloat leftPadding = 8.0; /* matches providers' width padding */
        NSRect textRect = NSMakeRect(leftPadding, y, bounds.size.width - (leftPadding * 2.0), textSize.height);
        [_title drawInRect:textRect withAttributes:attrs];
    }
}

- (BOOL)isOpaque
{
    return NO;
}

#pragma mark - Mouse handling

- (void)mouseDown:(NSEvent *)event
{
    _highlighted = YES;
    [self setNeedsDisplay:YES];

    id<StatusItemProvider> prov = _provider;
    if (!prov) {
        _highlighted = NO;
        [self setNeedsDisplay:YES];
        return;
    }

    /* If the provider supplies a dropdown menu, show it below this view */
    if ([prov respondsToSelector:@selector(menu)]) {
        NSMenu *menu = [prov menu];
        if (menu) {
            [NSMenu popUpContextMenu:menu withEvent:event forView:self];
            _highlighted = NO;
            [self setNeedsDisplay:YES];
            return;
        }
    }

    /* Otherwise forward to handleClick */
    if ([prov respondsToSelector:@selector(handleClick)]) {
        [prov handleClick];
    }

    _highlighted = NO;
    [self setNeedsDisplay:YES];
}

@end
