/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "EPUBPageRenderer.h"

/* WHY a flipped view instead of a flip transform: GNUstep's glyph drawing
 * (NSLayoutManager) assumes a top-left, y-down coordinate system. Drawing into
 * a plain NSImage context (non-flipped) leaves the text upright but laid out
 * from the bottom; forcing the layout to the top with an NSAffineTransform
 * scaleY(-1) mirrors every glyph vertically, turning the page upside down.
 * Like the Help app's picture/table fix, the correct approach is a genuinely
 * flipped drawing context: NSLayoutManager then lays the text out top-down and
 * the glyphs themselves are drawn upright. */
@interface EPUBPageRenderView : NSView
@end
@implementation EPUBPageRenderView
- (BOOL)isFlipped { return YES; }
@end

CGFloat EPUBPageMargin = 24.0;

@implementation EPUBPageRenderer
{
  NSWindow *_offscreen;
  EPUBPageRenderView *_view;
}

- (NSBitmapImageRep *)imageForRange:(NSRange)range
         ofAttributedString:(NSAttributedString *)attrString
                   pageSize:(NSSize)size
            backgroundColor:(NSColor *)background
                  textColor:(NSColor *)text
{
  int w = (int)round(size.width);
  int h = (int)round(size.height);
  if (w < 1) w = 1;
  if (h < 1) h = 1;

  if (_offscreen == nil)
    {
      _offscreen = [[NSWindow alloc]
          initWithContentRect:NSMakeRect(0, 0, w, h)
                    styleMask:0
                      backing:NSBackingStoreBuffered
                        defer:NO];
      [_offscreen setReleasedWhenClosed:NO];
      _view = [[EPUBPageRenderView alloc] initWithFrame:NSMakeRect(0, 0, w, h)];
      [_offscreen setContentView:_view];
    }
  else
    {
      [_offscreen setContentSize:NSMakeSize(w, h)];
      [_view setFrame:NSMakeRect(0, 0, w, h)];
    }

  // WHY lockFocus + initWithFocusedViewRect: GNUstep's glyph drawing crashes
  // (objc_msgSend_fpret ABI bug in -[NSLayoutManager drawGlyphsForGlyphRange:])
  // when the current context is a bitmap rep context. Drawing into a view
  // (here a flipped offscreen window) uses a different (working) context
  // class; we then capture the result with initWithFocusedViewRect:, which
  // yields an NSBitmapImageRep.
  [_view lockFocus];

  if (background != nil)
    {
      [background set];
      NSRectFill(NSMakeRect(0.0, 0.0, w, h));
    }

  BOOL valid = (attrString != nil && [attrString length] > 0
                && range.location != NSNotFound
                && NSMaxRange(range) <= [attrString length]);

  if (valid)
    {
      CGFloat margin = EPUBPageMargin;
      NSSize textSize = NSMakeSize(w - 2.0 * margin, h - 2.0 * margin);

      NSLayoutManager *lm = [[NSLayoutManager alloc] init];
      NSTextContainer *tc = [[NSTextContainer alloc]
        initWithContainerSize:textSize];
      [tc setWidthTracksTextView:NO];
      [tc setHeightTracksTextView:NO];
      [tc setLineFragmentPadding:0.0];
      [lm addTextContainer:tc];

      NSAttributedString *sub = [attrString attributedSubstringFromRange:range];
      NSTextStorage *ts = [[NSTextStorage alloc] initWithAttributedString:sub];
      [ts addLayoutManager:lm];

      NSRange glyphRange = [lm glyphRangeForTextContainer:tc];
      NSPoint origin = NSMakePoint(margin, margin);
      [lm drawBackgroundForGlyphRange:glyphRange atPoint:origin];
      [lm drawGlyphsForGlyphRange:glyphRange atPoint:origin];
    }

  NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
      initWithFocusedViewRect:NSMakeRect(0.0, 0.0, w, h)];
  [_view unlockFocus];
  return rep;
}

@end
