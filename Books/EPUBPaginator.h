/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

// Marks the first character of a chapter; the paginator forces a page break
// before any line carrying this attribute so chapters start on a fresh page.
extern NSString *EPUBPageBreakAttributeName;

@interface EPUBPaginator : NSObject

- (instancetype)initWithAttributedString:(NSAttributedString *)attrString
                                pageRect:(NSRect)pageRect;

@property (nonatomic, readonly) NSUInteger pageCount;

- (NSRange)rangeForPage:(NSUInteger)pageIndex;
- (NSUInteger)pageForCharacterIndex:(NSUInteger)idx;

@end
