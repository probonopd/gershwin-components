/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>
#import "BookPageView.h"
#import "EPUBPageRenderer.h"
#import "GLPageTurnView.h"
#import "BookPageTextView.h"
#include <math.h>

@interface BookPageView () <BookPageTextViewOwner>
@property (nonatomic, strong) NSAttributedString *attrString;
@property (nonatomic, assign) NSUInteger currentSpread;
@property (nonatomic, assign) NSUInteger pageCount;
@property (nonatomic, strong) BookPageTextView *leftTV;
@property (nonatomic, strong) BookPageTextView *rightTV;
@property (nonatomic, strong) GLPageTurnView *glView;
@property (nonatomic, assign) BOOL usesGL;
// Per-side absolute character range currently shown, so a point in a text view
// maps straight back to a book character index.
@property (nonatomic, assign) NSRange leftRange;
@property (nonatomic, assign) NSRange rightRange;
// Page ranges are computed natively here from the view's own bounds so resize
// reflow is exact.
@property (nonatomic, strong) NSMutableArray *pageRanges;
// Drag-to-select state. Selection ranges are absolute in the reading text and
// the owner paints them onto the relevant text view(s) natively.
@property (nonatomic, assign) BOOL mouseDownActive;
@property (nonatomic, assign) BOOL selecting;
@property (nonatomic, assign) NSUInteger selAbsStart;
@property (nonatomic, assign) NSUInteger selAbsEnd;
@property (nonatomic, assign) NSUInteger selStartSide;
@property (nonatomic, assign) CGFloat scrollAccum;
// Cache of the last re-paginated geometry/text so we can skip the (still costly)
// re-pagination when setFrame: fires repeatedly with an unchanged page area.
@property (nonatomic, assign) NSSize paginatedArea;
@property (nonatomic, strong) NSAttributedString *paginatedAttr;
@end

@implementation BookPageView

- (instancetype)initWithFrame:(NSRect)frame
{
  self = [super initWithFrame:frame];
  if (self)
    {
      // The GL page-turn overlay currently leaves a black frame covering the
      // text views at rest (its hide/redraw is not reliable in this GNUstep),
      // so we render the native text views directly for now. Re-enable once
      // the overlay hide path is fixed.
      _usesGL = NO;
      _backgroundColor = [NSColor whiteColor];
      _textColor = [NSColor blackColor];
      _leftRange = NSMakeRange(NSNotFound, 0);
      _rightRange = NSMakeRange(NSNotFound, 0);
      _pageRanges = [NSMutableArray array];

      // GNUstep's NSTextView does not always create a text storage when handed
      // a bare container, so wire the storage -> layout manager -> container
      // chain ourselves; otherwise the view silently shows no text.
      // Let NSTextView create its own text storage + layout manager (the
      // reliable path in this GNUstep); we only size/configure the container
      // later in layoutTextViews.
      _leftTV = [[BookPageTextView alloc] initWithFrame:NSZeroRect];
      [_leftTV setOwner:self];

      _rightTV = [[BookPageTextView alloc] initWithFrame:NSZeroRect];
      [_rightTV setOwner:self];

      [self addSubview:_leftTV];
      [self addSubview:_rightTV];

      if (_usesGL)
        {
          _glView = [[GLPageTurnView alloc] initWithFrame:[self bounds]];
          [_glView setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];
          [_glView setHidden:YES];
          [self addSubview:_glView];
        }
      [self layoutTextViews];
    }
  return self;
}

- (void)setFrame:(NSRect)frame
{
  [super setFrame:frame];
  [self layoutTextViews];
}

// Position the two page text views and size their text containers to exactly the
// page text area (contentSize - 2*EPUBPageMargin), so a page range maps
// 1:1 onto the visible text.
- (void)layoutTextViews
{
  NSRect b = [self bounds];
  CGFloat pageW = b.size.width / 2.0;
  CGFloat pageH = b.size.height;
  CGFloat margin = EPUBPageMargin;
  // The foot of each page carries its folio (page number). Reserve the bottom
  // page margin inside every text view so the folio is part of the rendered page
  // and flips with it, instead of an overlay drawn by the superview that does not
  // refresh on page turns. The text container itself stays at the text area, so
  // the reserved foot below it is free for the folio and pagination is unchanged.
  CGFloat footReserve = margin - 26.0;
  if (footReserve < 12.0) footReserve = 12.0;
  NSSize area = NSMakeSize(MAX(1.0, pageW - 2.0 * margin),
                           MAX(1.0, pageH - 2.0 * margin));
  NSSize viewSize = NSMakeSize(area.width, area.height + footReserve);
  [_leftTV setFixedPageSize:viewSize];
  [_leftTV setFrameOrigin:NSMakePoint(margin, margin - footReserve)];
  [_rightTV setFixedPageSize:viewSize];
  [_rightTV setFrameOrigin:NSMakePoint(pageW + margin, margin - footReserve)];
  for (BookPageTextView *tv in @[ _leftTV, _rightTV ])
    {
      NSTextContainer *tc = [tv textContainer];
      // Pin the container to the exact page text area. GNUstep's NSTextView
      // defaults to widthTracksTextView/heightTracksTextView = YES, which makes
      // the container follow the view frame instead of this explicit size; the
      // container then disagrees with the layout manager's page capacity, so text
      // overflows, clips and shifts ("renders in the wrong places", and breaks
      // completely on resize). Disabling tracking keeps them in agreement.
      [tc setWidthTracksTextView:NO];
      [tc setHeightTracksTextView:NO];
      [tc setContainerSize:area];
      [tc setLineFragmentPadding:0.0];
      [tv setTextContainerInset:NSZeroSize];
    }
  // Window/geometry changed: re-paginate to the new page area so the text fills
  // exactly and reflows correctly. recomputePages is a no-op until the book text
  // has been configured.
  [self recomputePages];
}

- (void)configureWithAttributedString:(NSAttributedString *)attr
{
  self.attrString = attr;
  [self recomputePages];
  self.currentSpread = 0;
}

// The single-page text area: one half of the view, minus the page margin inset
// applied exactly once (the text container IS this area, see layoutTextViews).
- (NSSize)pageArea
{
  NSRect b = [self bounds];
  CGFloat pageW = b.size.width / 2.0;
  CGFloat pageH = b.size.height;
  return NSMakeSize(MAX(1.0, pageW - 2.0 * EPUBPageMargin),
                    MAX(1.0, pageH - 2.0 * EPUBPageMargin));
}

// Glyph-accurate pagination using GNUstep's NSLayoutManager. For each page we lay
// the remaining text into a fresh text container sized to exactly one page and
// ask the layout manager which glyphs fit inside that rectangle; that range is
// one page. Chapter breaks (EPUBPageBreakAttributeName) are honoured by ending
// the current page before the chapter's first character.
- (void)recomputePages
{
  if (self.attrString == nil)
    {
      [_pageRanges removeAllObjects];
      self.pageCount = 0;
      _paginatedArea = NSMakeSize(0.0, 0.0);
      _paginatedAttr = nil;
      return;
    }
  NSSize area = [self pageArea];
  // Skip the re-pagination when neither the page geometry nor the reading text
  // changed. setFrame: (and thus layoutTextViews) is invoked on every autoresize
  // tick, and the window manager can redrive that repeatedly, so without this
  // guard the reader re-paginates forever and pins the CPU at ~100%.
  if (_pageRanges.count > 0
      && _paginatedAttr == self.attrString
      && fabs(_paginatedArea.width - area.width) < 0.5
      && fabs(_paginatedArea.height - area.height) < 0.5)
    {
      return;
    }
  _paginatedArea = area;
  _paginatedAttr = self.attrString;
  [_pageRanges removeAllObjects];
  NSUInteger len = [self.attrString length];

  // Precompute chapter break character indices once.
  NSMutableArray *breaks = [NSMutableArray array];
  for (NSUInteger i = 0; i < len; i++)
    {
      NSRange eff;
      id brk = [self.attrString attribute:EPUBPageBreakAttributeName
                                  atIndex:i
                           effectiveRange:&eff];
      if (brk != nil) [breaks addObject:[NSNumber numberWithUnsignedInteger:i]];
    }

  // Lay the whole book out ONCE and let the layout manager flow it across one
  // text container per page. The previous code re-laid-out the remaining text for
  // every single page, which was O(N^2) and could spin the CPU for minutes on a
  // long book (and, retriggered by resize polling, never settle so clicks were
  // never serviced).
  NSTextStorage *ts = [[NSTextStorage alloc] initWithAttributedString:self.attrString];
  NSLayoutManager *lm = [[NSLayoutManager alloc] init];
  [ts addLayoutManager:lm];

  NSMutableArray *containers = [NSMutableArray array];
  NSUInteger totalGlyphs = 0;
  for (;;)
    {
      NSTextContainer *tc = [[NSTextContainer alloc] initWithContainerSize:area];
      [tc setWidthTracksTextView:NO];
      [tc setHeightTracksTextView:NO];
      [tc setLineFragmentPadding:0.0];
      [lm addTextContainer:tc];
      [containers addObject:tc];
      NSRange gr = [lm glyphRangeForTextContainer:tc];
      if (gr.length == 0 && [containers count] > 1)
        {
          [lm removeTextContainerAtIndex:[containers count] - 1];
          [containers removeLastObject];
          break;
        }
      totalGlyphs = [lm numberOfGlyphs];
      if (NSMaxRange(gr) >= totalGlyphs) break;
      if ([containers count] > 100000) break; // hard safety
    }

  // Each settled container holds at most one page of glyphs. Convert to
  // character ranges and honour explicit chapter breaks by splitting pages.
  for (NSTextContainer *tc in containers)
    {
      NSRange gr = [lm glyphRangeForTextContainer:tc];
      if (gr.length == 0) continue;
      NSRange cr = [lm characterRangeForGlyphRange:gr actualGlyphRange:NULL];
      [self _addPageRangeSplittingAtBreaks:cr breaks:breaks];
    }

  if ([_pageRanges count] == 0)
    [_pageRanges addObject:[NSValue valueWithRange:NSMakeRange(0, len)]];
  self.pageCount = [_pageRanges count];
}

- (void)_addPageRangeSplittingAtBreaks:(NSRange)r breaks:(NSArray *)breaks
{
  NSUInteger s = r.location;
  NSUInteger e = NSMaxRange(r);
  while (s < e)
    {
      NSUInteger split = e;
      for (NSNumber *n in breaks)
        {
          NSUInteger b = [n unsignedIntegerValue];
          if (b > s && b < split) split = b;
        }
      [_pageRanges addObject:[NSValue valueWithRange:NSMakeRange(s, split - s)]];
      s = split;
    }
}

- (NSUInteger)spreadCount
{
  NSUInteger pc = self.pageCount;
  if (pc == 0) return 0;
  // Page 1 (index 0) opens on the right, so spread 0 is a single right page and
  // every later spread holds {2s-1 (left), 2s (right)}.
  if (pc % 2 == 0) return pc / 2 + 1;
  return (pc + 1) / 2;
}

// A book opens on a right-hand (recto) page: page 1 sits on the right and the
// preceding left page is intentionally blank, exactly like a printed book.
- (NSUInteger)pageIndexForSpread:(NSUInteger)spread side:(NSUInteger)side
{
  if (side == 1) return spread * 2;                // right/recto = even index
  if (spread == 0) return NSNotFound;              // first spread: no left page
  return spread * 2 - 1;                            // left/verso = odd index
}

- (NSUInteger)spreadForPageIndex:(NSUInteger)page
{
  if (page % 2 == 0) return page / 2;
  return (page + 1) / 2;
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
  return NSMakeSize(MAX(50.0, w), MAX(50.0, h));
}

- (NSUInteger)pageForCharacterIndex:(NSUInteger)idx
{
  if (_pageRanges == nil || [_pageRanges count] == 0) return 0;
  for (NSUInteger i = 0; i < [_pageRanges count]; i++)
    {
      NSRange r = [[_pageRanges objectAtIndex:i] rangeValue];
      if (idx >= r.location && idx < NSMaxRange(r)) return i;
    }
  return [_pageRanges count] - 1;
}

- (NSRange)rangeForPage:(NSUInteger)page
{
  if (_pageRanges == nil || [_pageRanges count] == 0
      || page >= [_pageRanges count])
    return NSMakeRange(0, 0);
  return [[_pageRanges objectAtIndex:page] rangeValue];
}

- (void)setBackgroundColor:(NSColor *)backgroundColor
{
  _backgroundColor = backgroundColor;
  if (_leftTV) [_leftTV setBackgroundColor:backgroundColor];
  if (_rightTV) [_rightTV setBackgroundColor:backgroundColor];
  [self setNeedsDisplay:YES];
}

- (void)setThemeTextColor:(NSColor *)textColor
{
  _textColor = textColor;
  [self applyTextColor];
  [self setNeedsDisplay:YES];
}

- (void)applyTextColor
{
  for (BookPageTextView *tv in @[ _leftTV, _rightTV ])
    {
      NSTextStorage *ts = [tv textStorage];
      if (ts == nil) continue;
      [ts addAttribute:NSForegroundColorAttributeName
                 value:_textColor
                 range:NSMakeRange(0, [ts length])];
    }
}

- (void)setPageLabels:(NSArray<NSString *> *)pageLabels
{
  _pageLabels = [pageLabels copy];
  [self applyFooters];
}

- (void)applyFooters
{
  [_leftTV setFooterText:[self footerForSide:0]];
  [_rightTV setFooterText:[self footerForSide:1]];
}

- (NSString *)footerForSide:(NSUInteger)side
{
  NSUInteger pageIdx = [self pageIndexForSpread:self.currentSpread side:side];
  if (_pageLabels == nil || pageIdx == NSNotFound
      || pageIdx >= [_pageLabels count]) return @"";
  return [_pageLabels objectAtIndex:pageIdx];
}

- (void)setHighlights:(NSArray<NSDictionary *> *)arr
{
  _highlights = [arr copy];
  [self applyHighlights];
}

- (void)buildPage:(NSUInteger)side
{
  NSUInteger pageIdx = [self pageIndexForSpread:self.currentSpread side:side];
  BookPageTextView *tv = (side == 0) ? _leftTV : _rightTV;
  if (pageIdx == NSNotFound || pageIdx >= self.pageCount)
    {
      [tv setString:@""];
      [tv setHidden:YES];
      [tv setFooterText:@""];
      if (side == 0) _leftRange = NSMakeRange(NSNotFound, 0);
      else _rightRange = NSMakeRange(NSNotFound, 0);
      return;
    }
  [tv setHidden:NO];
  NSRange pr = [self rangeForPage:pageIdx];
  if (side == 0) _leftRange = pr; else _rightRange = pr;
  NSAttributedString *sub = [self.attrString attributedSubstringFromRange:pr];
  NSTextStorage *ts = [tv textStorage];
  [ts setAttributedString:sub];
  if (_textColor)
    [ts addAttribute:NSForegroundColorAttributeName
               value:_textColor
               range:NSMakeRange(0, [ts length])];
  [tv setBackgroundColor:_backgroundColor ?: [NSColor whiteColor]];
  [tv setFooterText:[self footerForSide:side]];
  [tv setFooterAlignRight:(side == 1)];
  NSRect ur = [[tv layoutManager] usedRectForTextContainer:[tv textContainer]];
  (void)ur;
}

- (void)showSpread:(NSUInteger)spread animated:(BOOL)animated
{
  if (self.attrString == nil) return;
  NSUInteger max = [self spreadCount];
  if (spread >= max) spread = max - 1;
  if (max == 0) return;

  NSBitmapImageRep *oldL = nil;
  NSBitmapImageRep *oldR = nil;
  if (animated) { oldL = [self snapshot:_leftTV]; oldR = [self snapshot:_rightTV]; }

  self.currentSpread = spread;
  [self buildPage:0];
  [self buildPage:1];
  // GNUstep's NSTextView shrinks its frame to the laid-out text height after
  // -setAttributedString: (it ignores -setVerticallyResizable:NO), so re-apply
  // the fixed page frames and container sizes here.
  [self layoutTextViews];
  [self applyHighlights];

  if (animated && self.usesGL && oldL != nil)
    {
      @try
        {
          [_glView displayLeft:oldL right:oldR];
          [_glView setHidden:NO];
          [_glView turnWithCompletion:^{
            [_glView setHidden:YES];
          }];
        }
      @catch (id ex)
        {
          [_glView setHidden:YES];
        }
    }
}

- (NSBitmapImageRep *)snapshot:(NSView *)view
{
  NSRect b = [view bounds];
  NSBitmapImageRep *rep = [view bitmapImageRepForCachingDisplayInRect:b];
  if (rep) [view cacheDisplayInRect:b toBitmapImageRep:rep];
  return rep;
}

- (void)applyHighlights
{
  for (NSUInteger side = 0; side < 2; side++)
    {
      NSRange pr = (side == 0) ? _leftRange : _rightRange;
      if (pr.location == NSNotFound) continue;
      BookPageTextView *tv = (side == 0) ? _leftTV : _rightTV;
      NSTextStorage *ts = [tv textStorage];
      if (ts == nil) continue;
      // GNUstep does not reliably paint temporary layout attributes, so mark the
      // highlight as a real background attribute on the (per-page) text storage;
      // clear any previous marks first so removes/edits take effect.
      [ts removeAttribute:NSBackgroundColorAttributeName
                     range:NSMakeRange(0, [ts length])];
      for (NSDictionary *h in _highlights)
        {
          NSRange hr = [h[@"range"] rangeValue];
          NSRange inter = NSIntersectionRange(hr, pr);
          if (inter.length == 0) continue;
          NSColor *c = h[@"color"];
          if (c == nil)
            c = [NSColor colorWithCalibratedRed:1.0 green:0.88 blue:0.18 alpha:1.0];
          [ts addAttribute:NSBackgroundColorAttributeName
                     value:[c colorWithAlphaComponent:0.35]
                     range:NSMakeRange(inter.location - pr.location, inter.length)];
        }
      [tv setNeedsDisplay:YES];
    }
}

#pragma mark - selection

- (NSUInteger)sideForView:(BookPageTextView *)tv
{
  return (tv == _leftTV) ? 0 : 1;
}

- (NSUInteger)charAtPoint:(NSPoint)p side:(NSUInteger)side
{
  BookPageTextView *tv = (side == 0) ? _leftTV : _rightTV;
  NSLayoutManager *lm = [tv layoutManager];
  NSTextContainer *tc = [tv textContainer];
  NSTextStorage *ts = [tv textStorage];
  NSUInteger len = [ts length];
  if (lm == nil || tc == nil || len == 0)
    {
      NSRange pr = (side == 0) ? _leftRange : _rightRange;
      return (pr.location == NSNotFound) ? 0 : pr.location;
    }

  // The text view's own characterIndexForPoint: is unreliable in this GNUstep
  // (its backing glyphIndexForPoint: lands ~3 lines off), so locate the glyph by
  // its true ink rect from the layout manager instead.
  NSSize inset = [tv textContainerInset];
  NSPoint cp = NSMakePoint(p.x - inset.width, p.y - inset.height);

  NSRange fullGlyph = [lm glyphRangeForTextContainer:tc];
  if (fullGlyph.length == 0)
    {
      NSRange pr = (side == 0) ? _leftRange : _rightRange;
      return (pr.location == NSNotFound) ? 0 : pr.location;
    }

  // Find the line fragment whose ink rect contains the point's y. The text
  // view is non-flipped, so y increases upward and the first line has the
  // largest y; we scan top-to-bottom (decreasing y).
  NSUInteger g = fullGlyph.location;
  NSUInteger hitLineStart = fullGlyph.location;
  while (g < NSMaxRange(fullGlyph))
    {
      NSRange lineGR;
      NSRect frag = [lm lineFragmentRectForGlyphAtIndex:g effectiveRange:&lineGR];
      CGFloat top = frag.origin.y + frag.size.height;
      CGFloat bottom = frag.origin.y;
      if (cp.y >= bottom && cp.y <= top)
        {
          hitLineStart = lineGR.location;
          break;
        }
      if (cp.y > top)
        {
          // Below this line. GNUstep lays text out y-down (origin top-left),
          // so a larger y is lower on the page; keep scanning downward. If the
          // point is past all text this lands on the last line.
          hitLineStart = lineGR.location;
          g = NSMaxRange(lineGR);
          continue;
        }
      // Above this line: only possible at the very first line, so clamp.
      hitLineStart = lineGR.location;
      break;
    }

  // Within the line, pick the glyph whose ink rect is nearest to the point.
  NSRange lineGR;
  [lm lineFragmentRectForGlyphAtIndex:hitLineStart effectiveRange:&lineGR];
  NSUInteger bestGlyph = lineGR.location;
  CGFloat bestDist = 1.0e18;
  for (NSUInteger gi = lineGR.location; gi < NSMaxRange(lineGR); gi++)
    {
      NSRect gb = [lm boundingRectForGlyphRange:NSMakeRange(gi, 1)
                                inTextContainer:tc];
      CGFloat cx = gb.origin.x + gb.size.width * 0.5;
      CGFloat cy = gb.origin.y + gb.size.height * 0.5;
      CGFloat dx = cx - cp.x;
      CGFloat dy = cy - cp.y;
      CGFloat d = dx * dx + dy * dy;
      if (d < bestDist) { bestDist = d; bestGlyph = gi; }
    }

  NSUInteger ch = [lm characterIndexForGlyphAtIndex:bestGlyph];
  if (ch > len) ch = len;
  NSRange pr = (side == 0) ? _leftRange : _rightRange;
  if (pr.location == NSNotFound) return 0;
  return pr.location + ch;
}

- (void)updateSelection
{
  NSUInteger lo = MIN(_selAbsStart, _selAbsEnd);
  NSUInteger hi = MAX(_selAbsStart, _selAbsEnd);
  [self clearSelection];
  if (hi <= lo) return;
  NSRange sel = NSMakeRange(lo, hi - lo);
  for (NSUInteger side = 0; side < 2; side++)
    {
      NSRange pr = (side == 0) ? _leftRange : _rightRange;
      if (pr.location == NSNotFound) continue;
      NSRange inter = NSIntersectionRange(sel, pr);
      if (inter.length == 0) continue;
      BookPageTextView *tv = (side == 0) ? _leftTV : _rightTV;
      NSRange local = NSMakeRange(inter.location - pr.location, inter.length);
      [tv setSelectedRanges:@[ [NSValue valueWithRange:local] ]];
    }
}

- (void)clearSelection
{
  // An empty array is rejected by GNUstep's NSTextView; use a zero-length
  // selection on each page instead, which paints no highlight.
  NSRange none = NSMakeRange(0, 0);
  NSArray *empty = @[ [NSValue valueWithRange:none] ];
  [_leftTV setSelectedRanges:empty];
  [_rightTV setSelectedRanges:empty];
}

#pragma mark - BookPageTextViewOwner

- (void)pageTextView:(BookPageTextView *)tv mouseDown:(NSEvent *)e
{
  _mouseDownActive = YES;
  _selecting = NO;
  NSPoint p = [tv convertPoint:[e locationInWindow] fromView:nil];
  NSUInteger side = [self sideForView:tv];
  _selStartSide = side;
  _selAbsStart = [self charAtPoint:p side:side];
  _selAbsEnd = _selAbsStart;
  [self updateSelection];
}

- (void)pageTextView:(BookPageTextView *)tv mouseDragged:(NSEvent *)e
{
  if (!_mouseDownActive) return;
  NSPoint p = [tv convertPoint:[e locationInWindow] fromView:nil];
  NSUInteger side = [self sideForView:tv];
  _selAbsEnd = [self charAtPoint:p side:side];
  _selecting = YES;
  [self updateSelection];
}

- (void)pageTextView:(BookPageTextView *)tv mouseUp:(NSEvent *)e
{
  if (!_mouseDownActive) return;
  NSUInteger lo = MIN(_selAbsStart, _selAbsEnd);
  NSUInteger hi = MAX(_selAbsStart, _selAbsEnd);
  BOOL wasSelecting = _selecting;
  _mouseDownActive = NO;
  _selecting = NO;
  _selAbsStart = NSNotFound;
  _selAbsEnd = NSNotFound;
  [self clearSelection];
  if (wasSelecting && hi > lo)
    {
      if ([_delegate respondsToSelector:@selector(pageView:didSelectRange:)])
        [_delegate pageView:self didSelectRange:NSMakeRange(lo, hi - lo)];
    }
  else
    {
      if (_selStartSide == 0)
        {
          if ([_delegate respondsToSelector:@selector(pageViewDidRequestPrevious:)])
            [_delegate pageViewDidRequestPrevious:self];
        }
      else
        {
          if ([_delegate respondsToSelector:@selector(pageViewDidRequestNext:)])
            [_delegate pageViewDidRequestNext:self];
        }
    }
}

- (void)pageTextView:(BookPageTextView *)tv scrollWheel:(NSEvent *)e
{
  [self scrollWheel:e];
}

- (void)pageTextView:(BookPageTextView *)tv keyDown:(NSEvent *)e
{
  [self keyDown:e];
}

#pragma mark - navigation / input

- (void)next
{
  if ([self canGoNext]) [self showSpread:self.currentSpread + 1 animated:YES];
}

- (void)previous
{
  if ([self canGoPrevious]) [self showSpread:self.currentSpread - 1 animated:YES];
}

- (void)keyDown:(NSEvent *)event
{
  NSString *s = [event charactersIgnoringModifiers];
  if ([s length] == 0) return;
  unichar c = [s characterAtIndex:0];
  if (c == NSRightArrowFunctionKey || c == ' ' || c == NSCarriageReturnCharacter)
    {
      if ([_delegate respondsToSelector:@selector(pageViewDidRequestNext:)])
        [_delegate pageViewDidRequestNext:self];
      else [self next];
    }
  else if (c == NSLeftArrowFunctionKey)
    {
      if ([_delegate respondsToSelector:@selector(pageViewDidRequestPrevious:)])
        [_delegate pageViewDidRequestPrevious:self];
      else [self previous];
    }
}

- (void)scrollWheel:(NSEvent *)event
{
  if ([event modifierFlags] & NSControlKeyMask)
    {
      if ([_delegate respondsToSelector:@selector(pageView:fontSizeDelta:)])
        [_delegate pageView:self fontSizeDelta:[event deltaY]];
      return;
    }
  _scrollAccum += [event deltaY];
  CGFloat TH = 0.8;
  while (_scrollAccum <= -TH)
    {
      if ([_delegate respondsToSelector:@selector(pageViewDidRequestNext:)])
        [_delegate pageViewDidRequestNext:self];
      else [self next];
      _scrollAccum += TH;
    }
  while (_scrollAccum >= TH)
    {
      if ([_delegate respondsToSelector:@selector(pageViewDidRequestPrevious:)])
        [_delegate pageViewDidRequestPrevious:self];
      else [self previous];
      _scrollAccum -= TH;
    }
}

#pragma mark - gutter

- (void)drawRect:(NSRect)rect
{
  NSColor *paper = _backgroundColor ?: [NSColor whiteColor];

  // Desk behind the pages: a slightly darker, subtle shade of the paper so the
  // two page rectangles read as distinct sheets instead of one continuous fill.
  // Kept light (not a dark grey) so it frames the pages rather than dominating.
  CGFloat pr, pg, pb, pa;
  [paper getRed:&pr green:&pg blue:&pb alpha:&pa];
  NSColor *desk = [NSColor colorWithCalibratedRed:pr * 0.88 + 0.04
                                             green:pg * 0.88 + 0.04
                                              blue:pb * 0.9 + 0.04
                                             alpha:1.0];
  [desk setFill];
  NSRectFill(rect);

  // Two paper pages, inset from the view edges so the desk shows as a border
  // and the gutter between them is visible.
  CGFloat inset = 26.0;
  CGFloat halfW = [self bounds].size.width / 2.0;
  CGFloat pageH = [self bounds].size.height;
  NSRect lp = NSMakeRect(inset, inset, halfW - inset, pageH - 2.0 * inset);
  NSRect rp = NSMakeRect(halfW + inset, inset, halfW - inset, pageH - 2.0 * inset);
  [paper setFill];
  NSRectFill(lp);
  NSRectFill(rp);

  // Subtle gutter shadow line down the centre fold.
  [[NSColor colorWithCalibratedWhite:0.0 alpha:0.22] setFill];
  NSRectFill(NSMakeRect(halfW - 1.0, inset, 2.0, pageH - 2.0 * inset));

  // The folio (page number) is no longer painted here: each page's text view
  // renders its own folio in the reserved foot of the page, so it is part of the
  // page and redraws together with the text on every page turn.
}

@end
