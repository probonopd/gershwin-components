/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>
#import "BookPageView.h"
#import "EPUBPaginator.h"
#import "EPUBPageRenderer.h"
#import "GLPageTurnView.h"
#include <math.h>

@interface BookPageView ()
@property (nonatomic, strong) NSAttributedString *attrString;
@property (nonatomic, strong) EPUBPaginator *paginator;
@property (nonatomic, strong) EPUBPageRenderer *renderer;
@property (nonatomic, assign) BOOL usesGL;
@property (nonatomic, strong) GLPageTurnView *glView;
@property (nonatomic, assign) NSUInteger currentSpread;
@property (nonatomic, assign) NSUInteger pageCount;
@property (nonatomic, strong) NSBitmapImageRep *leftImage;
@property (nonatomic, strong) NSBitmapImageRep *rightImage;
// Accumulates wheel delta between page turns so a trackpad swipe or mouse notch
// flips roughly one spread rather than firing on every tiny event.
@property (nonatomic, assign) CGFloat scrollAccum;
// Drag-to-select state. A gesture only becomes a selection once it moves past a
// small threshold; below it, mouseUp is treated as a page-turn click.
@property (nonatomic, assign) NSPoint mouseDownPoint;
@property (nonatomic, assign) NSPoint selStartPoint;
@property (nonatomic, assign) NSPoint selCurPoint;
@property (nonatomic, assign) BOOL selecting;
@end

@implementation BookPageView

- (instancetype)initWithFrame:(NSRect)frame
{
  self = [super initWithFrame:frame];
  if (self)
    {
      _usesGL = NO; /* DIAGNOSTIC: force software renderer to isolate GL issue */
      if (_usesGL)
        {
          _glView = [[GLPageTurnView alloc] initWithFrame:[self bounds]];
          [_glView setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];
          [self addSubview:_glView];
        }
      _backgroundColor = [NSColor whiteColor];
      _textColor = [NSColor blackColor];
    }
  return self;
}

- (void)configureWithAttributedString:(NSAttributedString *)attr
                            paginator:(EPUBPaginator *)pag
                             renderer:(EPUBPageRenderer *)rend
{
  self.attrString = attr;
  self.paginator = pag;
  self.renderer = rend;
  self.pageCount = [pag pageCount];
  self.currentSpread = 0;
}

- (NSUInteger)spreadCount
{
  return (self.pageCount + 1) / 2;
}

- (BOOL)canGoNext
{
  return self.currentSpread + 1 < [self spreadCount];
}

- (BOOL)canGoPrevious
{
  return self.currentSpread > 0;
}

- (NSSize)contentSize
{
  NSRect b = [self bounds];
  CGFloat w = b.size.width / 2.0;
  CGFloat h = b.size.height;
  if (w < 10) w = 450;
  if (h < 10) h = 650;
  // The renderer paints a bitmap of exactly this size and the view draws it 1:1
  // into the page rect, so there must be no extra inset here: any difference
  // between this size and the on-screen page rect would stretch the bitmap and
  // make hit-testing and highlight drawing disagree. The reader's page border
  // margin (EPUBPageMargin) is applied by the renderer/paginator, not here.
  return NSMakeSize(MAX(50.0, w), MAX(50.0, h));
}

- (NSBitmapImageRep *)renderPage:(NSUInteger)idx
{
  if (idx >= self.pageCount)
    return [self blankImage];
  NSRange r = [self.paginator rangeForPage:idx];
  NSBitmapImageRep *rep = [self.renderer imageForRange:r
                                 ofAttributedString:self.attrString
                                           pageSize:[self contentSize]
                                    backgroundColor:self.backgroundColor
                                           textColor:self.textColor];
  return rep;
}

- (NSBitmapImageRep *)blankImage
{
  NSSize s = [self contentSize];
  return [self.renderer imageForRange:NSMakeRange(0, 0)
                    ofAttributedString:nil
                              pageSize:s
                       backgroundColor:self.backgroundColor
                             textColor:self.textColor];
}

- (void)setBackgroundColor:(NSColor *)backgroundColor
{
  _backgroundColor = backgroundColor;
  [self refreshStatic];
}

- (void)setThemeTextColor:(NSColor *)textColor
{
  _textColor = textColor;
  [self refreshStatic];
}

- (void)setPageLabels:(NSArray<NSString *> *)pageLabels
{
  _pageLabels = [pageLabels copy];
  [self setNeedsDisplay:YES];
}

- (void)refreshStatic
{
  if (self.attrString == nil) return;
  [self showSpread:self.currentSpread animated:NO];
}

- (void)showSpread:(NSUInteger)spread animated:(BOOL)animated
{
  if (self.attrString == nil) return;
  NSUInteger maxSpread = [self spreadCount];
  if (spread >= maxSpread) spread = maxSpread - 1;
  if (maxSpread == 0) return;

  self.currentSpread = spread;
  self.leftImage = [self renderPage:spread * 2];
  self.rightImage = [self renderPage:spread * 2 + 1];
  if (self.usesGL && self.glView)
    [self.glView displayLeft:self.leftImage right:self.rightImage];
  else
    [self setNeedsDisplay:YES];
}

- (void)next
{
  if ([self canGoNext])
    [self showSpread:self.currentSpread + 1 animated:YES];
}

- (void)previous
{
  if ([self canGoPrevious])
    [self showSpread:self.currentSpread - 1 animated:YES];
}

- (BOOL)acceptsFirstResponder
{
  return YES;
}

// The reader shows the text as a raster page, but the reader expects to sweep a
// text selection like a word processor, so present an I-beam cursor over the
// whole page instead of the default arrow.
- (void)resetCursorRects
{
  [super resetCursorRects];
  NSRect b = [self bounds];
  CGFloat margin = EPUBPageMargin;
  CGFloat halfW = b.size.width / 2.0;
  NSRect leftR = NSMakeRect(margin, margin, halfW - 2.0 * margin, b.size.height - 2.0 * margin);
  NSRect rightR = NSMakeRect(halfW + margin, margin, halfW - 2.0 * margin, b.size.height - 2.0 * margin);
  [self addCursorRect:leftR cursor:[NSCursor IBeamCursor]];
  [self addCursorRect:rightR cursor:[NSCursor IBeamCursor]];
  [[self window] setAcceptsMouseMovedEvents:YES];
}

- (void)mouseMoved:(NSEvent *)event
{
  NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];
  NSRect b = [self bounds];
  CGFloat margin = EPUBPageMargin;
  CGFloat halfW = b.size.width / 2.0;
  NSRect leftR = NSMakeRect(margin, margin, halfW - 2.0 * margin, b.size.height - 2.0 * margin);
  NSRect rightR = NSMakeRect(halfW + margin, margin, halfW - 2.0 * margin, b.size.height - 2.0 * margin);
  if (NSMouseInRect(p, leftR, [self isFlipped]) || NSMouseInRect(p, rightR, [self isFlipped]))
    [[NSCursor IBeamCursor] set];
  else
    [[NSCursor arrowCursor] set];
}

// The reader is a static page, so a quick click in the side quarters flips the
// page, while a drag selects a run of text. We start the gesture on mouseDown and
// only decide which it is on mouseUp: a drag past the threshold becomes a
// selection (forwarded to the delegate as -pageView:didSelectRange:); anything
// shorter is a page-turn depending on where the press began.
- (void)mouseDown:(NSEvent *)event
{
  _mouseDownPoint = [self convertPoint:[event locationInWindow] fromView:nil];
  _selStartPoint = _mouseDownPoint;
  _selCurPoint = _mouseDownPoint;
  _selecting = NO;
}

- (void)mouseDragged:(NSEvent *)event
{
  NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];
  _selCurPoint = p;
  CGFloat dx = p.x - _selStartPoint.x;
  CGFloat dy = p.y - _selStartPoint.y;
  if (!_selecting && (dx * dx + dy * dy) > 16.0)
    _selecting = YES;
  if (_selecting)
    [self setNeedsDisplay:YES];
}

- (void)mouseUp:(NSEvent *)event
{
  NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];
  if (_selecting)
    {
      NSUInteger a = [self characterIndexAtPoint:_selStartPoint];
      NSUInteger b = [self characterIndexAtPoint:p];
      _selecting = NO;
      _selStartPoint = NSZeroPoint;
      _selCurPoint = NSZeroPoint;
      [self setNeedsDisplay:YES];
      if (a != NSNotFound && b != NSNotFound && a != b)
        {
          NSUInteger lo = MIN(a, b);
          NSUInteger hi = MAX(a, b);
          if (_delegate && [_delegate respondsToSelector:@selector(pageView:didSelectRange:)])
            [_delegate pageView:self didSelectRange:NSMakeRange(lo, hi - lo)];
        }
      return;
    }

  NSRect bnd = [self bounds];
  CGFloat quarter = bnd.size.width / 4.0;
  if (_mouseDownPoint.x < quarter)
    {
      if (_delegate && [_delegate respondsToSelector:@selector(pageViewDidRequestPrevious:)])
        [_delegate pageViewDidRequestPrevious:self];
      else
        [self previous];
    }
  else if (_mouseDownPoint.x > bnd.size.width - quarter)
    {
      if (_delegate && [_delegate respondsToSelector:@selector(pageViewDidRequestNext:)])
        [_delegate pageViewDidRequestNext:self];
      else
        [self next];
    }
}

- (void)keyDown:(NSEvent *)event
{
  NSString *s = [event charactersIgnoringModifiers];
  if ([s length] == 0) return;
  unichar c = [s characterAtIndex:0];
  if (c == NSRightArrowFunctionKey || c == ' ' || c == NSCarriageReturnCharacter)
    {
      if (_delegate && [_delegate respondsToSelector:@selector(pageViewDidRequestNext:)])
        [_delegate pageViewDidRequestNext:self];
      else
        [self next];
    }
  else if (c == NSLeftArrowFunctionKey)
    {
      if (_delegate && [_delegate respondsToSelector:@selector(pageViewDidRequestPrevious:)])
        [_delegate pageViewDidRequestPrevious:self];
      else
        [self previous];
    }
}

// Plain scroll wheel turns pages (down = next, up = previous); Ctrl + scroll
// wheel zooms the text. Accumulating the delta avoids hyper-sensitive flips from
// continuous trackpad events.
- (void)scrollWheel:(NSEvent *)event
{
  if ([event modifierFlags] & NSControlKeyMask)
    {
      if (_delegate && [_delegate respondsToSelector:@selector(pageView:fontSizeDelta:)])
        [_delegate pageView:self fontSizeDelta:[event deltaY]];
      return;
    }
  _scrollAccum += [event deltaY];
  CGFloat TH = 0.8;
  while (_scrollAccum <= -TH)
    {
      if (_delegate && [_delegate respondsToSelector:@selector(pageViewDidRequestNext:)])
        [_delegate pageViewDidRequestNext:self];
      else
        [self next];
      _scrollAccum += TH;
    }
  while (_scrollAccum >= TH)
    {
      if (_delegate && [_delegate respondsToSelector:@selector(pageViewDidRequestPrevious:)])
        [_delegate pageViewDidRequestPrevious:self];
      else
        [self previous];
      _scrollAccum -= TH;
    }
}

- (NSUInteger)pageForCharacterIndex:(NSUInteger)idx
{
  if (self.paginator == nil) return 0;
  return [self.paginator pageForCharacterIndex:idx];
}

- (void)setHighlights:(NSArray<NSDictionary *> *)arr
{
  _highlights = [arr copy];
  [self setNeedsDisplay:YES];
}

// Build a layout manager that reproduces exactly how EPUBPageRenderer laid out a
// single paginated page, so a point (or glyph rect) in that page maps back to a
// character index in the concatenated reading text. The renderer insets the text
// by EPUBPageMargin and the container size is contentSize - 2*margin.
- (NSLayoutManager *)layoutManagerForPage:(NSUInteger)pageIdx
                              textStorage:(NSTextStorage *__autoreleasing *)outStorage
                            textContainer:(NSTextContainer *__autoreleasing *)outContainer
{
  NSRange pageRange = [self.paginator rangeForPage:pageIdx];
  NSSize cs = [self contentSize];
  CGFloat margin = EPUBPageMargin;
  NSSize textSize = NSMakeSize(MAX(1.0, cs.width - 2.0 * margin),
                               MAX(1.0, cs.height - 2.0 * margin));
  NSTextStorage *ts = [[NSTextStorage alloc]
      initWithAttributedString:[self.attrString attributedSubstringFromRange:pageRange]];
  NSLayoutManager *lm = [[NSLayoutManager alloc] init];
  NSTextContainer *tc = [[NSTextContainer alloc] initWithContainerSize:textSize];
  [tc setLineFragmentPadding:0.0];
  [ts addLayoutManager:lm];
  [lm addTextContainer:tc];
  [lm glyphRangeForTextContainer:tc];
  if (outStorage) *outStorage = ts;
  if (outContainer) *outContainer = tc;
  return lm;
}

// Map a view point to an absolute character index in the reading text, or
// NSNotFound. The point may fall on either the left or right page of the spread.
- (NSUInteger)characterIndexAtPoint:(NSPoint)p
{
  if (self.attrString == nil || self.paginator == nil) return NSNotFound;
  NSRect b = [self bounds];
  BOOL right = (p.x >= b.size.width / 2.0);
  NSUInteger pageIdx = right ? (self.currentSpread * 2 + 1) : (self.currentSpread * 2);
  if (pageIdx >= self.pageCount) return NSNotFound;
  NSRange pageRange = [self.paginator rangeForPage:pageIdx];
  if (pageRange.length == 0) return NSNotFound;

  NSSize cs = [self contentSize];
  CGFloat margin = EPUBPageMargin;
  NSRect pageR = right
    ? NSMakeRect(b.size.width / 2.0, 0, b.size.width / 2.0, b.size.height)
    : NSMakeRect(0, 0, b.size.width / 2.0, b.size.height);

  // The renderer paints a contentSize-sized bitmap (cs.width x cs.height) and
  // the view stretches it to fill pageR. Invert that stretch to land in bitmap
  // coordinates, then drop the renderer's margin to reach text-container
  // coordinates (y measured down from the top of the page).
  CGFloat tx = (p.x - pageR.origin.x) * cs.width / pageR.size.width - margin;
  CGFloat ty = (pageR.size.height - (p.y - pageR.origin.y)) * cs.height / pageR.size.height - margin;

  NSTextStorage *ts = nil;
  NSTextContainer *tc = nil;
  NSLayoutManager *lm = [self layoutManagerForPage:pageIdx textStorage:&ts textContainer:&tc];

  // glyphIndexForPoint:inTextContainer: in this GNUstep maps a y coordinate to a
  // line several fragments above the true glyph position, so it cannot be used to
  // resolve the line. Instead walk the real line-fragment rects (which agree with
  // boundingRectForGlyphRange used for drawing) and pick the fragment containing
  // the cursor, then resolve the glyph within that fragment by x.
  NSUInteger glyphCount = [lm numberOfGlyphs];
  // lineFragmentUsedRectForGlyphAtIndex: returns glyph ranges correctly, but in
  // this GNUstep its rect origin.y is shifted several fragments away from where
  // boundingRectForGlyphRange: (which we use to paint) actually places the ink.
  // So locate the line by the TRUE glyph ink position from boundingRect, and only
  // use lineFragmentUsedRect for the (correct) glyph range of that line.
  NSMutableArray *lines = [NSMutableArray array];
  NSUInteger scan = 0;
  while (scan < glyphCount)
    {
      NSRange eff = NSMakeRange(0, 0);
      [lm lineFragmentUsedRectForGlyphAtIndex:scan
                                effectiveRange:&eff
                             withoutAdditionalLayout:YES];
      if (eff.length == 0) break;
      NSRect gr0 = [lm boundingRectForGlyphRange:NSMakeRange(eff.location, 1)
                                 inTextContainer:tc];
      NSRect gr1 = [lm boundingRectForGlyphRange:NSMakeRange(NSMaxRange(eff) - 1, 1)
                                 inTextContainer:tc];
      CGFloat yTop = MIN(gr0.origin.y, gr1.origin.y);
      CGFloat yBot = MAX(gr0.origin.y + gr0.size.height,
                         gr1.origin.y + gr1.size.height);
      [lines addObject:@[ [NSValue valueWithRange:eff], @(yTop), @(yBot) ]];
      scan = NSMaxRange(eff);
    }
  if ([lines count] == 0) return NSNotFound;
  NSRange lineRange = [[lines[0] objectAtIndex:0] rangeValue];
  BOOL found = NO;
  for (NSArray *ln in lines)
    {
      CGFloat yt = [ln[1] floatValue];
      CGFloat yb = [ln[2] floatValue];
      // include a small slop so the inter-line gap still lands on its line
      if (ty >= yt - 4.0 && ty <= yb + 4.0) { lineRange = [ln[0] rangeValue]; found = YES; break; }
    }
  if (!found)
    {
      CGFloat bestD = 1e9;
      for (NSArray *ln in lines)
        {
          CGFloat mid = ([ln[1] floatValue] + [ln[2] floatValue]) / 2.0;
          CGFloat d = fabs(ty - mid);
          if (d < bestD) { bestD = d; lineRange = [ln[0] rangeValue]; }
        }
    }
  NSUInteger glyph = lineRange.location;
  CGFloat best = 1e9;
  for (NSUInteger g = lineRange.location; g < MIN(NSMaxRange(lineRange), glyphCount); g++)
    {
      NSRect gr = [lm boundingRectForGlyphRange:NSMakeRange(g, 1) inTextContainer:tc];
      if (gr.size.width <= 0.0) continue;
      CGFloat mid = gr.origin.x + gr.size.width / 2.0;
      CGFloat d = fabs(tx - mid);
      if (d < best) { best = d; glyph = g; }
    }
  NSUInteger ch = [lm characterIndexForGlyphAtIndex:glyph];
  if (ch == NSNotFound) return NSNotFound;
  return pageRange.location + ch;
}

// Paint the glyph rectangles for an absolute reading-text range that fall on the
// current spread's pages. The per-page layout manager is built from that page's
// attributed substring, so its character/glyph coordinates are page-relative; we
// shift the absolute range into that space before asking for glyph rects, then
// map those rects from bitmap to view coordinates.
- (void)drawAbsoluteRange:(NSRange)absRange color:(NSColor *)color
{
  if (absRange.length == 0) return;
  NSRect b = [self bounds];
  NSSize cs = [self contentSize];
  CGFloat margin = EPUBPageMargin;
  for (NSUInteger side = 0; side < 2; side++)
    {
      NSUInteger pageIdx = self.currentSpread * 2 + side;
      if (pageIdx >= self.pageCount) continue;
      NSRange pageRange = [self.paginator rangeForPage:pageIdx];
      if (pageRange.length == 0) continue;
      NSRange inter = NSIntersectionRange(absRange, pageRange);
      if (inter.length == 0) continue;
      NSRange rel = NSMakeRange(inter.location - pageRange.location, inter.length);
      NSTextStorage *ts = nil;
      NSTextContainer *tc = nil;
      NSLayoutManager *lm = [self layoutManagerForPage:pageIdx textStorage:&ts textContainer:&tc];
      NSRange glyphRange = [lm glyphRangeForCharacterRange:rel actualCharacterRange:NULL];
      if (glyphRange.location == NSNotFound) continue;
      NSRect pageR = (side == 0)
        ? NSMakeRect(0, 0, b.size.width / 2.0, b.size.height)
        : NSMakeRect(b.size.width / 2.0, 0, b.size.width / 2.0, b.size.height);
      [color setFill];
      // Walk line fragments so multi-line ranges paint every fragment, not just
      // the first one rectArrayForGlyphRange: would return for the whole range.
      NSUInteger glyphIndex = glyphRange.location;
      while (glyphIndex < NSMaxRange(glyphRange))
        {
          NSRange fragRange = NSMakeRange(0, 0);
          [lm lineFragmentUsedRectForGlyphAtIndex:glyphIndex
                                  effectiveRange:&fragRange
                       withoutAdditionalLayout:YES];
          if (fragRange.length == 0) break;
          NSRange cur = NSIntersectionRange(glyphRange, fragRange);
          // Use the glyph ink bounding rect, not the line-fragment rect: the
          // fragment rect top sits a font ascent above the visible ink, which
          // made highlights paint ~one line above the text. The ink rect already
          // includes that ascent, so it lands on the glyphs.
          NSRect gr = [lm boundingRectForGlyphRange:cur inTextContainer:tc];
          if (gr.size.width <= 0.0 || gr.size.height <= 0.0)
            continue;
          // gr is in text-container coords (origin at the text inset, y down from
          // the top). The renderer drew the container origin at (margin, margin)
          // inside a contentSize-sized bitmap, which the view stretches to fill
          // pageR, so reapply that stretch (and flip y for display).
          CGFloat bx = margin + gr.origin.x;
          CGFloat by = margin + gr.origin.y;
          CGFloat vx = pageR.origin.x + (bx / cs.width) * pageR.size.width;
          CGFloat vy = pageR.size.height - (by / cs.height) * pageR.size.height;
          CGFloat vw = (gr.size.width / cs.width) * pageR.size.width;
          CGFloat vh = (gr.size.height / cs.height) * pageR.size.height;
          NSRectFill(NSMakeRect(vx, vy, vw, vh));
          if (fragRange.location + fragRange.length > glyphIndex)
            glyphIndex = fragRange.location + fragRange.length;
          else
            glyphIndex += 1;
        }
    }
}

- (void)drawRect:(NSRect)rect
{
  if (self.usesGL) return;
  NSRect b = [self bounds];
  [[self.backgroundColor shadowWithLevel:0.7] set];
  NSRectFill(b);

  NSRect leftR = NSMakeRect(0, 0, b.size.width / 2.0, b.size.height);
  NSRect rightR = NSMakeRect(b.size.width / 2.0, 0, b.size.width / 2.0, b.size.height);

  [self.leftImage drawInRect:leftR
                    fromRect:NSZeroRect
                   operation:NSCompositeSourceOver
                    fraction:1.0
               respectFlipped:NO
                    hints:nil];
  [self.rightImage drawInRect:rightR
                     fromRect:NSZeroRect
                    operation:NSCompositeSourceOver
                     fraction:1.0
               respectFlipped:NO
                    hints:nil];

  NSRect spine = NSMakeRect(b.size.width / 2.0 - 6, 0, 12, b.size.height);
  NSGradient *g = [[NSGradient alloc]
      initWithStartingColor:[NSColor colorWithCalibratedWhite:0.0 alpha:0.0]
                  endingColor:[NSColor colorWithCalibratedWhite:0.0 alpha:0.5]];
  [g drawInRect:spine angle:0.0];

  // Saved highlights: translucent text-shaped rectangles over the matching
  // runs (yellow text-marker look). The range is absolute in the reading text;
  // drawAbsoluteRange maps it onto the visible page's glyphs.
  if (_highlights != nil && [_highlights count] > 0)
    {
      for (NSDictionary *hl in _highlights)
        {
          NSColor *col = hl[@"color"];
          if (col == nil) col = [NSColor colorWithCalibratedRed:1.0 green:0.88 blue:0.18 alpha:1.0];
          [self drawAbsoluteRange:[hl[@"range"] rangeValue]
                             color:[col colorWithAlphaComponent:0.35]];
        }
    }

  // Live drag selection: paint the actual selected glyphs, not a bounding box, so
  // it reads like a word-processor text selection that follows the text lines.
  if (_selecting)
    {
      NSUInteger a = [self characterIndexAtPoint:_selStartPoint];
      NSUInteger c = [self characterIndexAtPoint:_selCurPoint];
      if (a != NSNotFound && c != NSNotFound && a != c)
        {
          NSUInteger lo = MIN(a, c);
          NSUInteger hi = MAX(a, c);
          [self drawAbsoluteRange:NSMakeRange(lo, hi - lo)
                            color:[NSColor colorWithCalibratedRed:0.2 green:0.4 blue:0.9 alpha:0.30]];
        }
    }
  // EPUB Locators: page numbers sit at the foot of each page, in the outer
  // corner like a printed book — left page number bottom-left, right page
  // number bottom-right.
  if (_pageLabels != nil && [_pageLabels count] > 0)
    {
      NSUInteger leftIdx = self.currentSpread * 2;
      NSUInteger rightIdx = leftIdx + 1;
      if (leftIdx < [_pageLabels count])
        {
          NSString *l = [_pageLabels objectAtIndex:leftIdx];
          if ([l length] > 0)
            [self drawFooter:l inRect:leftR alignRight:NO];
        }
      if (rightIdx < [_pageLabels count])
        {
          NSString *r = [_pageLabels objectAtIndex:rightIdx];
          if ([r length] > 0)
            [self drawFooter:r inRect:rightR alignRight:YES];
        }
    }
}

// Draw a page-number footer inside `pageRect`. alignRight=NO places it at the
// bottom-left (verso), alignRight=YES at the bottom-right (recto). The text is
// inset to match the body margin and sits in the lower page margin so it never
// collides with body text.
- (void)drawFooter:(NSString *)text inRect:(NSRect)pageRect alignRight:(BOOL)alignRight
{
  if (text == nil || [text length] == 0)
    return;
  CGFloat fs = 10.0;
  NSFont *font = [NSFont userFontOfSize:fs];
  if (font == nil)
    font = [NSFont systemFontOfSize:fs];
  NSDictionary *attrs = @{ NSFontAttributeName: font,
                           NSForegroundColorAttributeName: _textColor };
  NSSize ts = [text sizeWithAttributes:attrs];
  CGFloat margin = EPUBPageMargin;
  CGFloat x = alignRight
    ? (pageRect.origin.x + pageRect.size.width - margin - ts.width)
    : (pageRect.origin.x + margin);
  // Non-flipped view: a string drawn at y sits with its baseline at y and the
  // glyphs above it, so a small y keeps the number pinned to the page foot.
  CGFloat y = pageRect.origin.y + 3.0;
  [text drawAtPoint:NSMakePoint(x, y) withAttributes:attrs];
}

@end
