/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUDeviceOutlineView.h"

@implementation DUDeviceOutlineView

- (instancetype)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (self == nil) {
        return nil;
    }
    // Compact rows per SPEC section 6.3; no header keeps the pane clean.
    self.rowHeight = 20.0;
    self.intercellSpacing = NSMakeSize(2.0, 1.0);
    self.headerView = nil;
    self.allowsColumnReordering = NO;
    self.allowsMultipleSelection = NO;
    self.focusRingType = NSFocusRingTypeExterior;
    return self;
}

- (BOOL)acceptsFirstResponder
{
    return YES;
}

@end
