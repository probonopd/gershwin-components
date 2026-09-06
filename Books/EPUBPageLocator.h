/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

// How page numbers are derived for the on-page footer. EPUB Locators (W3C ED)
// recommends an authored page-list when the publisher provides one, and a
// deterministic calculated page count (one per 1,000 Unicode code points of
// visible text) otherwise. The user may also turn page numbers off entirely.
typedef NS_ENUM(NSInteger, EPUBPageNumberMode)
{
  EPUBPageNumberModeCalculated = 0,
  EPUBPageNumberModeAuthored = 1,
  EPUBPageNumberModeOff = 2,
};

// A single authored page-list entry: the character offset (in the concatenated
// reading text) where a print page begins, and the label the publisher gave
// it ("1", "iv", "A-12", ...). Page-list labels are free-form strings per the
// EPUB spec, so we keep them verbatim rather than forcing them to integers.
@interface EPUBPageListEntry : NSObject
@property (nonatomic, assign) NSUInteger offset;
@property (nonatomic, copy) NSString *label;
+ (instancetype)entryWithOffset:(NSUInteger)offset label:(NSString *)label;
@end

// EPUBPageLocator answers "what page number is shown at this character offset?"
// It implements the EPUB Locators calculated-page algorithm (1,000 Unicode code
// points per page) and, when the publisher shipped a page-list, the authored
// mapping. It is pure text arithmetic so it can be unit-tested without a GUI.
@interface EPUBPageLocator : NSObject

- (instancetype)initWithFullText:(NSAttributedString *)fullText;

// Authored page-list entries, sorted ascending by offset. Ignored unless the
// caller requests authored labels.
- (void)setAuthoredEntries:(NSArray<EPUBPageListEntry *> *)entries;

// EPUB Locators, calculated algorithm: one page per 1,000 Unicode code points
// of visible text. Offset 0 -> page 1. Font- and viewport-independent, so the
// same textual position always yields the same number on any reading system.
- (NSString *)calculatedLabelForCharacterOffset:(NSUInteger)offset;

// The authored label covering `offset`, or nil if no authored page-list entry
// precedes it (i.e. we are before the first marked page).
- (NSString *)authoredLabelForCharacterOffset:(NSUInteger)offset;

// Convenience: pick the label for the requested mode. Authored mode with no
// usable entry falls back to the calculated number so a page is always shown.
- (NSString *)labelForCharacterOffset:(NSUInteger)offset
                                  mode:(EPUBPageNumberMode)mode;

@end
