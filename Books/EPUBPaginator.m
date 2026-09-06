/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "EPUBPaginator.h"
#import "EPUBPageRenderer.h"

@interface EPUBPaginator ()
@property (nonatomic, strong) NSAttributedString *attrString;
@property (nonatomic, assign) NSSize pageSize;
@property (nonatomic, strong) NSMutableArray<NSValue *> *ranges;
@end

NSString *EPUBPageBreakAttributeName = @"EPUBPageBreak";

@implementation EPUBPaginator

- (instancetype)initWithAttributedString:(NSAttributedString *)attrString
                                pageRect:(NSRect)pageRect
{
  self = [super init];
  if (self == nil)
    return nil;
  _attrString = attrString;
  _pageSize = pageRect.size;
  _ranges = [NSMutableArray array];
  [self buildPages];
  return self;
}

- (NSUInteger)pageCount
{
  return [_ranges count];
}

- (NSRange)rangeForPage:(NSUInteger)pageIndex
{
  if ([_ranges count] == 0)
    return NSMakeRange(NSNotFound, 0);
  if (pageIndex >= [_ranges count])
    pageIndex = [_ranges count] - 1;
  return [[_ranges objectAtIndex:pageIndex] rangeValue];
}

- (NSUInteger)pageForCharacterIndex:(NSUInteger)idx
{
  NSUInteger count = [_ranges count];
  if (count == 0)
    return NSNotFound;
  for (NSUInteger i = 0; i < count; i++)
    {
      NSRange r = [[_ranges objectAtIndex:i] rangeValue];
      if (idx >= r.location && idx < NSMaxRange(r))
        return i;
    }
  // idx past the end: report the last page.
  return count - 1;
}

- (void)buildPages
{
  if (_attrString == nil || [_attrString length] == 0)
    return;

  @try
    {
      // The paginator must agree with how the page text view lays out text: the
      // renderer/view insets the text by EPUBPageMargin on every side, so the
      // effective container area is pageSize - 2*margin. Using the same area here
      // keeps each paginated range exactly one screen of text in the view.
      CGFloat margin = EPUBPageMargin;
      NSSize textSize = NSMakeSize(MAX(1.0, _pageSize.width - 2.0 * margin),
                                   1.0e7);
      CGFloat pageH = MAX(1.0, _pageSize.height - 2.0 * margin);

      NSLayoutManager *lm = [[NSLayoutManager alloc] init];
      NSTextContainer *tc = [[NSTextContainer alloc]
        initWithContainerSize:textSize];
      [tc setWidthTracksTextView:NO];
      [tc setHeightTracksTextView:NO];
      [tc setLineFragmentPadding:0.0];
      [lm addTextContainer:tc];

      NSTextStorage *ts = [[NSTextStorage alloc]
        initWithAttributedString:_attrString];
      [ts addLayoutManager:lm];

      // Force the full text to be laid out into the (very tall) container.
      NSRange fullGlyph = [lm glyphRangeForTextContainer:tc];
      (void)[lm usedRectForTextContainer:tc];

      NSUInteger glyphEnd = NSMaxRange(fullGlyph);
      NSUInteger glyphIndex = 0;

      while (glyphIndex < glyphEnd)
        {
          NSUInteger pageStartGlyph = glyphIndex;
          CGFloat accumulatedHeight = 0.0;

          while (glyphIndex < glyphEnd)
            {
              NSRange lineRange;
              NSRect frag = [lm lineFragmentRectForGlyphAtIndex:glyphIndex
                                                  effectiveRange:&lineRange];
              // A line already placed plus this one would overflow the page.
              if (accumulatedHeight > 0.0
                  && accumulatedHeight + frag.size.height > pageH)
                break;

              // A chapter break: do not let the line that carries the marker
              // share a page with preceding content; start the chapter fresh.
              NSRange lineCharRange = [lm characterRangeForGlyphRange:lineRange
                                                  actualGlyphRange:NULL];
              id breakVal = (lineCharRange.length > 0)
                ? [_attrString attribute:EPUBPageBreakAttributeName
                                 atIndex:lineCharRange.location
                          effectiveRange:NULL]
                : nil;
              if (breakVal != nil && accumulatedHeight > 0.0)
                break;

              accumulatedHeight += frag.size.height;
              glyphIndex = NSMaxRange(lineRange);
            }

          NSRange glyphPageRange = NSMakeRange(pageStartGlyph,
                                              glyphIndex - pageStartGlyph);
          NSRange charRange = [lm characterRangeForGlyphRange:glyphPageRange
                                             actualGlyphRange:NULL];
          [_ranges addObject:[NSValue valueWithRange:charRange]];
        }
    }
  @catch (id exc)
    {
      _ranges = [NSMutableArray array];
    }

  // Fallback so the reader never deadlocks on a zero-page result.
  if ([_ranges count] == 0)
    [self buildPagesByCount];
}

// Used only when the text system is unavailable (no screen) and real layout
// produced no pages. Estimate characters per page from the page area and split.
- (void)buildPagesByCount
{
  NSUInteger len = [_attrString length];
  if (len == 0)
    return;
  double maxChars = (_pageSize.height / 20.0) * (_pageSize.width / 8.0);
  if (maxChars < 1.0)
    maxChars = 1.0;
  NSUInteger step = (NSUInteger)maxChars;
  for (NSUInteger loc = 0; loc < len; loc += step)
    {
      NSUInteger remaining = len - loc;
      NSUInteger size = remaining < step ? remaining : step;
      [_ranges addObject:[NSValue valueWithRange:NSMakeRange(loc, size)]];
    }
}

@end
