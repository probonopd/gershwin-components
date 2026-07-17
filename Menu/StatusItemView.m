/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "StatusItemView.h"
#import "StatusItemManager.h"
#import "StatusItemsView.h"
#import "GNUstepGUI/GSTheme.h"

@interface StatusItemView ()
{
    BOOL _dragging;
    NSPoint _dragStartPoint;
    NSInteger _dragFromIndex;
}
@end

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
        _dragging = NO;
    }
    return self;
}

- (void)updateTitle:(NSString *)title
{
    if (!title) title = @"";
    if ([_title isEqualToString:title]) return;
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

    [[NSColor clearColor] set];
    NSRectFill(bounds);

    if (_highlighted) {
        NSColor *highlight = [[GSTheme theme] menuItemSelectedBackgroundColor];
        if (highlight) { [highlight set]; } else { [[NSColor selectedMenuItemColor] set]; }
        NSRectFill(bounds);
    }

    if (_title && [_title length] > 0) {
        NSDictionary *attrs = [self textAttributes];
        NSSize textSize = [_title sizeWithAttributes:attrs];
        CGFloat y = floor((bounds.size.height - textSize.height) / 2.0);
        CGFloat leftPadding = 8.0;
        NSRect textRect = NSMakeRect(leftPadding, y, bounds.size.width - (leftPadding * 2.0), textSize.height);
        [_title drawInRect:textRect withAttributes:attrs];
    }
}

- (BOOL)isOpaque
{
    return NO;
}

- (BOOL)isFlipped
{
    return NO;
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event
{
    (void)event;
    return YES;
}

#pragma mark - Mouse handling

- (void)mouseDown:(NSEvent *)event
{
    NSUInteger modifierFlags = [event modifierFlags];
    BOOL commandDrag = (modifierFlags & NSCommandKeyMask) != 0;

    if (commandDrag) {
        [self beginDragWithEvent:event];
        return;
    }

    _highlighted = YES;
    [self setNeedsDisplay:YES];

    id<StatusItemProvider> prov = _provider;
    if (!prov) {
        _highlighted = NO;
        [self setNeedsDisplay:YES];
        return;
    }

    if ([prov respondsToSelector:@selector(menu)]) {
        NSLog(@"StatusItemView: LAZY LOAD — fetching menu from provider %@", [prov identifier]);
        NSMenu *menu = [prov menu];
        if (menu) {
            if ([prov respondsToSelector:@selector(menuWillOpen)]) {
                [prov menuWillOpen];
            }
            [menu setAutoenablesItems:NO];
            [menu sizeToFit];
            [menu displayTransient];

            NSWindow *menuWin = [menu window];
            if (menuWin) {
                NSPoint origin = [self convertPoint:NSMakePoint(0, 0) toView:nil];
                origin = [[self window] convertBaseToScreen:origin];
                origin.y -= NSHeight([menuWin frame]);
                [menuWin setFrameOrigin:origin];
                [menuWin orderFront:nil];
            }

            [[menu menuRepresentation] trackWithEvent:event];

            if ([prov respondsToSelector:@selector(menuDidClose)]) {
                [prov menuDidClose];
            }
            _highlighted = NO;
            [self setNeedsDisplay:YES];
            return;
        }
    }

    if ([prov respondsToSelector:@selector(handleClick)]) {
        [prov handleClick];
    }

    _highlighted = NO;
    [self setNeedsDisplay:YES];
}

#pragma mark - Drag reordering

- (void)beginDragWithEvent:(NSEvent *)event
{
    _dragging = YES;
    _dragStartPoint = [event locationInWindow];
    _dragFromIndex = -1;

    StatusItemsView *container = (StatusItemsView *)[self superview];
    if ([container isKindOfClass:[StatusItemsView class]]) {
        _dragFromIndex = [container indexOfItemViewAtPoint:[container convertPoint:_dragStartPoint fromView:nil]];
    }

    NSPoint mouseLocation = [event locationInWindow];
    CGFloat dragThreshold = 10.0;

    while (_dragging) {
        NSEvent *nextEvent = [[self window] nextEventMatchingMask:NSLeftMouseDraggedMask | NSLeftMouseUpMask];

        if (!nextEvent) break;

        NSEventType type = [nextEvent type];
        if (type == NSEventTypeLeftMouseUp) {
            _dragging = NO;
            _highlighted = NO;
            [self setNeedsDisplay:YES];
            break;
        }

        if (type == NSEventTypeLeftMouseDragged) {
            NSPoint newLocation = [nextEvent locationInWindow];
            CGFloat deltaX = newLocation.x - mouseLocation.x;

            if (fabs(deltaX) > dragThreshold && [container isKindOfClass:[StatusItemsView class]]) {
                NSPoint pt = [container convertPoint:newLocation fromView:nil];
                NSInteger newIndex = [container indexOfItemViewAtPoint:pt];
                if (newIndex >= 0 && newIndex != _dragFromIndex && _dragFromIndex >= 0) {
                    [container moveItemView:self toIndex:newIndex];
                    _dragFromIndex = newIndex;
                }
            }
        }
    }
}

@end
