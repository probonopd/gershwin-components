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
  // The folio is part of the rendered page: it is painted by the page's own text
  // view (in the reserved foot below the text container) so it redraws together
  // with the text on every page turn, instead of an overlay that goes stale.
  if (_footerText == nil || [_footerText length] == 0)
    return;
  NSFont *f = nil;
  NSColor *col = nil;
  NSTextStorage *ts = [self textStorage];
  if (ts != nil && [ts length] > 0)
    {
      f = [ts attribute:NSFontAttributeName atIndex:0 effectiveRange:NULL];
      col = [ts attribute:NSForegroundColorAttributeName atIndex:0 effectiveRange:NULL];
    }
  if (f == nil) f = [NSFont userFontOfSize:12.0];
  CGFloat size = [f pointSize] * 0.7;
  if (size < 8.0) size = 8.0;
  NSFont *folioFont = [NSFont fontWithName:[f fontName] size:size];
  if (folioFont == nil) folioFont = f;
  if (col == nil) col = [NSColor blackColor];
  NSDictionary *attrs = @{ NSFontAttributeName: folioFont,
                           NSForegroundColorAttributeName: col };
  NSSize fs = [_footerText sizeWithAttributes:attrs];
  CGFloat pad = 10.0;
  // A left-hand page carries its folio at the left, a right-hand page at the
  // right - the outer corner, as in a printed book.
  CGFloat x = _footerAlignRight
    ? (NSMaxX([self bounds]) - fs.width - pad)
    : pad;
  CGFloat y = pad;
  [_footerText drawAtPoint:NSMakePoint(x, y) withAttributes:attrs];
}

@end
