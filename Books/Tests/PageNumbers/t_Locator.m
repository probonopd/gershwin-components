/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "EPUBPageLocator.h"

/* Unit under test: compile its implementation directly into this TU. */
#include "../../EPUBPageLocator.m"

// Helper: a full-text attributed string of `n` plain 'a' characters.
static NSAttributedString *PlainText(NSUInteger n)
{
  NSMutableString *s = [NSMutableString string];
  for (NSUInteger i = 0; i < n; i++)
    [s appendString:@"a"];
  return [[NSAttributedString alloc] initWithString:s];
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  /* --- EPUB Locators calculated algorithm: one page per 1,000 code points --- */
  {
    EPUBPageLocator *loc = [[EPUBPageLocator alloc] initWithFullText:PlainText(1)];
    PASS_EQUAL([loc calculatedLabelForCharacterOffset:0], @"1",
               "calculated page at offset 0 is 1");

    EPUBPageLocator *loc2 = [[EPUBPageLocator alloc] initWithFullText:PlainText(999)];
    PASS_EQUAL([loc2 calculatedLabelForCharacterOffset:999], @"1",
               "999 code points still on calculated page 1");

    EPUBPageLocator *loc3 = [[EPUBPageLocator alloc] initWithFullText:PlainText(1000)];
    PASS_EQUAL([loc3 calculatedLabelForCharacterOffset:1000], @"2",
               "the 1000th code point starts calculated page 2");
  }

  /* --- code points, not UTF-16 units: astral chars count as one --- */
  {
    // 999 ASCII 'a' + one astral char (emoji, 2 UTF-16 units = 1 code point)
    // => 1000 code points total, but 1001 UTF-16 chars in the string.
    NSMutableString *s = [NSMutableString string];
    for (NSUInteger i = 0; i < 999; i++) [s appendString:@"a"];
    [s appendString:@"\U0001F600"]; // grinning face
    NSAttributedString *full = [[NSAttributedString alloc] initWithString:s];
    EPUBPageLocator *loc = [[EPUBPageLocator alloc] initWithFullText:full];
    NSUInteger endOffset = [s length]; // 1001
    PASS_EQUAL([loc calculatedLabelForCharacterOffset:endOffset], @"2",
               "astral char counts as one code point, so 1000 cp -> page 2");
  }

  /* --- authored page-list lookup (greatest entry <= offset) --- */
  {
    EPUBPageLocator *loc = [[EPUBPageLocator alloc] initWithFullText:PlainText(5000)];
    NSArray *entries = @[
      [EPUBPageListEntry entryWithOffset:0 label:@"1"],
      [EPUBPageListEntry entryWithOffset:1500 label:@"ii"],
      [EPUBPageListEntry entryWithOffset:3000 label:@"iii"],
    ];
    [loc setAuthoredEntries:entries];

    PASS_EQUAL([loc authoredLabelForCharacterOffset:0], @"1",
               "offset 0 maps to first authored page");
    PASS_EQUAL([loc authoredLabelForCharacterOffset:1499], @"1",
               "just before a marker keeps the earlier page");
    PASS_EQUAL([loc authoredLabelForCharacterOffset:1500], @"ii",
               "at a marker boundary takes that page");
    PASS_EQUAL([loc authoredLabelForCharacterOffset:2999], @"ii",
               "mid-range keeps the enclosing page");

    // When the page-list does not start at offset 0, positions before the
    // first marker have no authored page.
    EPUBPageLocator *late = [[EPUBPageLocator alloc] initWithFullText:PlainText(5000)];
    [late setAuthoredEntries:@[ [EPUBPageListEntry entryWithOffset:1000 label:@"A"] ]];
    PASS([late authoredLabelForCharacterOffset:500] == nil,
         "before the first marker there is no authored page");
    PASS_EQUAL([late authoredLabelForCharacterOffset:1000], @"A",
               "at the first marker the page appears");
  }

  /* --- mode selection --- */
  {
    EPUBPageLocator *loc = [[EPUBPageLocator alloc] initWithFullText:PlainText(2500)];
    [loc setAuthoredEntries:@[ [EPUBPageListEntry entryWithOffset:0 label:@"1"],
                               [EPUBPageListEntry entryWithOffset:1000 label:@"x"] ]];

    PASS([loc labelForCharacterOffset:1500 mode:EPUBPageNumberModeOff] == nil,
         "Off mode yields no label");

    PASS_EQUAL([loc labelForCharacterOffset:1500 mode:EPUBPageNumberModeAuthored], @"x",
               "Authored mode uses the page-list label");

    PASS_EQUAL([loc labelForCharacterOffset:1500 mode:EPUBPageNumberModeCalculated], @"2",
               "Calculated mode ignores the page-list");

    // Authored mode falls back to calculated when no entry covers the offset.
    EPUBPageLocator *empty = [[EPUBPageLocator alloc] initWithFullText:PlainText(50)];
    [empty setAuthoredEntries:@[]];
    PASS_EQUAL([empty labelForCharacterOffset:10 mode:EPUBPageNumberModeAuthored], @"1",
               "Authored mode with no usable entry falls back to calculated");
  }

  [arp release];
  return 0;
}
