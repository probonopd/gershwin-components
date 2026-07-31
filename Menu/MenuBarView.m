/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */


#import "MenuBarView.h"
#import "CustomMenuPanel.h"
#import "MenuProfiler.h"
#import <GNUstepGUI/GSTheme.h>

@implementation MenuBarView

- (id)initWithFrame:(NSRect)frameRect
{
    self = [super initWithFrame:frameRect];
    if (self) {
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

    // The window hook wraps the main menu window's content view with a
    // MenuGradientView that draws the theme's menu bar gradient.  When that is
    // in place, this view only acts as a transparent container.  As a fallback
    // (e.g. before the hook has run), draw the same gradient here so the bar is
    // never blank.
    NSWindow *window = [self window];
    if (window && [[window contentView] isKindOfClass:[MenuGradientView class]]) {
        [[NSColor clearColor] set];
        NSRectFill([self bounds]);
    } else {
        [[GSTheme theme] drawMenuRect:[self bounds]
                               inView:self
                         isHorizontal:YES
                            itemCells:@[]];
    }

    MENU_PROFILE_END(MenuBarViewDraw);
}

- (BOOL)isOpaque
{
    return NO;
}

@end
