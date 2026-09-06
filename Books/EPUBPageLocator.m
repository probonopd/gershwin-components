/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "EPUBPageLocator.h"

// EPUB Locators: one calculated page per this many Unicode code points of
// uncompressed visible-to-the-reader text. The spec leaves the exact constant
// open ("number TBD"); 1,000 is its worked example and is what we use.
static const NSUInteger EPUBCodePointsPerCalculatedPage = 1000;

@implementation EPUBPageListEntry
+ (instancetype)entryWithOffset:(NSUInteger)offset label:(NSString *)label
{
  EPUBPageListEntry *e = [[EPUBPageListEntry alloc] init];
  e.offset = offset;
  e.label = [label copy];
  return e;
}
@end

@interface EPUBPageLocator ()
@property (nonatomic, copy) NSAttributedString *fullText;
@property (nonatomic, copy) NSArray<EPUBPageListEntry *> *authoredEntries;
@end

@implementation EPUBPageLocator

- (instancetype)initWithFullText:(NSAttributedString *)fullText
{
  self = [super init];
  if (self)
    {
      _fullText = [fullText copy];
      _authoredEntries = @[];
    }
  return self;
}

- (void)setAuthoredEntries:(NSArray<EPUBPageListEntry *> *)entries
{
  // Keep ascending by offset so binary search (greatest entry <= offset) works.
  NSArray *sorted = [entries sortedArrayUsingComparator:
    ^NSComparisonResult(EPUBPageListEntry *a, EPUBPageListEntry *b)
    {
      if (a.offset < b.offset) return NSOrderedAscending;
      if (a.offset > b.offset) return NSOrderedDescending;
      return NSOrderedSame;
    }];
  _authoredEntries = sorted;
}

// Count real Unicode code points in [0, idx), NOT UTF-16 code units. Astral
// characters are encoded as a high+low surrogate pair in NSString; we count
// the pair once by skipping the high surrogate. This is what makes the
// calculated page number match the spec's "Unicode code points" wording.
- (NSUInteger)codePointCountUpToIndex:(NSUInteger)idx
{
  NSString *s = [_fullText string];
  NSUInteger len = [s length];
  if (idx > len) idx = len;
  NSUInteger cp = 0;
  for (NSUInteger i = 0; i < idx; i++)
    {
      unichar c = [s characterAtIndex:i];
      if (c >= 0xD800 && c <= 0xDBFF)
        continue; // high surrogate: counted with its low surrogate
      cp++;
    }
  return cp;
}

- (NSString *)calculatedLabelForCharacterOffset:(NSUInteger)offset
{
  NSUInteger cp = [self codePointCountUpToIndex:offset];
  NSUInteger page = cp / EPUBCodePointsPerCalculatedPage + 1;
  return [NSString stringWithFormat:@"%lu", (unsigned long)page];
}

- (NSString *)authoredLabelForCharacterOffset:(NSUInteger)offset
{
  NSArray *entries = _authoredEntries;
  if ([entries count] == 0)
    return nil;
  // Binary search for the greatest entry whose offset <= `offset`.
  NSInteger lo = 0, hi = (NSInteger)[entries count] - 1;
  NSInteger found = -1;
  while (lo <= hi)
    {
      NSInteger mid = (lo + hi) / 2;
      if ([entries[mid] offset] <= offset)
        {
          found = mid;
          lo = mid + 1;
        }
      else
        {
          hi = mid - 1;
        }
    }
  if (found < 0)
    return nil; // before the first marked page
  return [entries[found] label];
}

- (NSString *)labelForCharacterOffset:(NSUInteger)offset
                                  mode:(EPUBPageNumberMode)mode
{
  if (mode == EPUBPageNumberModeOff)
    return nil;
  if (mode == EPUBPageNumberModeAuthored)
    {
      NSString *auth = [self authoredLabelForCharacterOffset:offset];
      if (auth != nil)
        return auth;
      // No usable authored entry: fall back so the reader still shows something.
      return [self calculatedLabelForCharacterOffset:offset];
    }
  return [self calculatedLabelForCharacterOffset:offset];
}

@end
