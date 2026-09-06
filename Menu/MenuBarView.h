/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */


#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

@interface MenuBarView : NSView
{
    BOOL _needsRedraw;
}

- (void)drawRect:(NSRect)dirtyRect;
- (void)setNeedsRedraw;

@end
