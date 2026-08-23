/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUPaneView.h"

@implementation DUPaneView

- (void)_notifyOwner
{
    if (_layoutOwner != nil && _layoutSelector != NULL &&
        [_layoutOwner respondsToSelector:_layoutSelector]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [_layoutOwner performSelector:_layoutSelector];
#pragma clang diagnostic pop
    }
}

// GNUstep's -setFrame: updates _frame directly and never routes through
// -setFrameSize:, and NSTabView/autoresizing resize item views via
// -setFrame:. Overriding it is therefore the only reliable hook for
// "this pane got a new size" (ARCHITECTURE.md section 31).
- (void)setFrame:(NSRect)frame
{
    BOOL sizeChanged = !NSEqualSizes(frame.size, self.frame.size);
    [super setFrame:frame];
    if (sizeChanged) {
        [self _notifyOwner];
    }
}

- (void)setFrameSize:(NSSize)newSize
{
    [super setFrameSize:newSize];
    [self _notifyOwner];
}

- (void)viewDidMoveToWindow
{
    [super viewDidMoveToWindow];
    // Install-time safety net: whatever frame the tab view gave us before
    // this call, our rows must be laid out against it.
    if (self.window != nil && self.superview != nil) {
        [self _notifyOwner];
    }
}

@end
