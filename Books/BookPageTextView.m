/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "BookPageTextView.h"

@implementation BookPageTextView
{
  NSSize _fixedSize;
}

- (instancetype)initWithFrame:(NSRect)frame textContainer:(NSTextContainer *)tc
{
  self = [super initWithFrame:frame textContainer:tc];
  if (self)
    {
      // A reader is non-editable but selectable: the owner drives selection
      // ranges and the view paints them natively.
      [self setEditable:NO];
      [self setSelectable:YES];
      [self setRichText:NO];
      [self setImportsGraphics:NO];
      [self setDrawsBackground:YES];
      [self setHorizontallyResizable:NO];
      [self setVerticallyResizable:NO];
      [self setMinSize:NSZeroSize];
      [self setMaxSize:NSMakeSize(1.0e7, 1.0e7)];
      [self setSelectedTextAttributes:
        @{ NSBackgroundColorAttributeName:
             [NSColor colorWithCalibratedRed:0.2 green:0.4 blue:0.9 alpha:0.30] }];
      [self setTextContainerInset:NSMakeSize(0.0, 0.0)];
    }
  return self;
}

// Keep the page frame fixed; defeat GNUstep's automatic shrink-to-content
// resize that fires on a deferred layout pass after -setAttributedString:.
- (void)setFrame:(NSRect)r
{
  if (_fixedSize.width > 0) r.size = _fixedSize;
  [super setFrame:r];
}

- (void)setFrameSize:(NSSize)s
{
  if (_fixedSize.width > 0) s = _fixedSize;
  [super setFrameSize:s];
}

- (void)setFixedPageSize:(NSSize)size
{
  _fixedSize = size;
  [self setFrameSize:size];
}

// Forward raw events to the owner; we deliberately do NOT call super for mouse
// events so the text view never starts its own (conflicting) selection.
- (void)mouseDown:(NSEvent *)e
{
  if (_owner) [_owner pageTextView:self mouseDown:e];
}
- (void)mouseDragged:(NSEvent *)e
{
  if (_owner) [_owner pageTextView:self mouseDragged:e];
}
- (void)mouseUp:(NSEvent *)e
{
  if (_owner) [_owner pageTextView:self mouseUp:e];
}
- (void)scrollWheel:(NSEvent *)e
{
  if (_owner) [_owner pageTextView:self scrollWheel:e];
}
- (void)keyDown:(NSEvent *)e
{
  if (_owner) [_owner pageTextView:self keyDown:e];
}

- (void)drawRect:(NSRect)rect
{
  [super drawRect:rect];
}

@end
