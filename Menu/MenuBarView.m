/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */


#import "MenuBarView.h"
#import "MenuProfiler.h"

@implementation MenuBarView

- (id)initWithFrame:(NSRect)frameRect
{
    self = [super initWithFrame:frameRect];
    if (self) {
        NSColor *startColor = [NSColor colorWithCalibratedRed:0.95
                                                         green:0.95
                                                          blue:0.95
                                                         alpha:0.95];
        NSColor *endColor = [NSColor colorWithCalibratedRed:0.85
                                                       green:0.85
                                                        blue:0.85
                                                       alpha:0.85];
        _gradient = [[NSGradient alloc] initWithStartingColor:startColor
                                                   endingColor:endColor];
        _needsRedraw = YES;
    }
    return self;
}

- (void)setNeedsRedraw
{
    _needsRedraw = YES;
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect
{
    MENU_PROFILE_BEGIN(MenuBarViewDraw);

    if (_gradient) {
        [_gradient drawInRect:[self bounds] angle:-90];
    } else {
        [[NSColor colorWithCalibratedWhite:0.95 alpha:1.0] set];
        NSRectFill([self bounds]);
    }

    MENU_PROFILE_END(MenuBarViewDraw);
}

- (BOOL)isOpaque
{
    return NO;
}

@end
