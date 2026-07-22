/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */


#import "CustomMenuPanel.h"

@implementation MenuGradientView

- (void)drawRect:(NSRect)dirtyRect
{
    [[NSColor colorWithCalibratedWhite:0.95 alpha:1.0] set];
    NSRectFill(dirtyRect);
}

@end

@implementation CustomMenuPanel
@end

@implementation CustomMenuView
@end

void HookNSMenuPanelCreation(void)
{
}

