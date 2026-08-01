/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */


#import "RoundedCornersView.h"
#import <GNUstepGUI/GSTheme.h>

@implementation RoundedCornersView

- (id)initWithFrame:(NSRect)frameRect cornerRadius:(CGFloat)radius
{
    self = [super initWithFrame:frameRect];
    if (self) {
        _cornerRadius = radius;
    }
    return self;
}

- (id)initWithFrame:(NSRect)frameRect
{
    return [self initWithFrame:frameRect cornerRadius:5.0];
}

- (void)drawRect:(NSRect)dirtyRect
{
    // Draw rounded corner masks using the theme's menu background color so corners blend in
    
    NSGraphicsContext *context = [NSGraphicsContext currentContext];
    [context saveGraphicsState];
    
    // Enable antialiasing for smooth corners
    [context setShouldAntialias:YES];
    
    NSRect bounds = [self bounds];
    CGFloat width = bounds.size.width;
    CGFloat height = bounds.size.height;
    
    // Use solid black for corner masks to match traditional appearance
    [[NSColor blackColor] setFill];
    
    // Left corner mask: draw the area that should be filled to create a rounded top-left corner
    NSBezierPath *leftCornerMask = [NSBezierPath bezierPath];
    [leftCornerMask moveToPoint:NSMakePoint(0, height)]; // Top-left corner
    [leftCornerMask lineToPoint:NSMakePoint(_cornerRadius, height)]; // Move right along top
    [leftCornerMask appendBezierPathWithArcWithCenter:NSMakePoint(_cornerRadius, height - _cornerRadius)
                                               radius:_cornerRadius
                                           startAngle:90.0   // Start at top
                                             endAngle:180.0  // End at left
                                            clockwise:NO];    // Counter-clockwise for outer curve
    [leftCornerMask lineToPoint:NSMakePoint(0, height - _cornerRadius)]; // Down to left edge
    [leftCornerMask closePath];
    [leftCornerMask fill];
    
    // Right corner mask: draw the area that should be filled to create a rounded top-right corner
    NSBezierPath *rightCornerMask = [NSBezierPath bezierPath];
    [rightCornerMask moveToPoint:NSMakePoint(width, height)]; // Top-right corner
    [rightCornerMask lineToPoint:NSMakePoint(width - _cornerRadius, height)]; // Move left along top
    [rightCornerMask appendBezierPathWithArcWithCenter:NSMakePoint(width - _cornerRadius, height - _cornerRadius)
                                                radius:_cornerRadius
                                            startAngle:90.0   // Start at top
                                              endAngle:0.0    // End at right
                                             clockwise:YES];   // Clockwise for outer curve
    [rightCornerMask lineToPoint:NSMakePoint(width, height - _cornerRadius)]; // Down to right edge
    [rightCornerMask closePath];
    [rightCornerMask fill];
    
    [context restoreGraphicsState];
}

- (BOOL)isOpaque
{
    return NO;
}

- (NSView *)hitTest:(NSPoint)aPoint
{
    // This view draws the rounded corner masks on top of the menu bar but must
    // not absorb mouse events: forward the hit to the sibling views below (the
    // menu bar background with its menu titles) so that clicking the very top
    // row of the screen still opens the dropdown menus.
    NSView *superview = [self superview];
    if (superview) {
        for (NSView *sibling in [superview subviews]) {
            if (sibling == self) continue;
            NSView *hit = [sibling hitTest:aPoint];
            if (hit != nil) return hit;
        }
    }
    return nil;
}

@end
