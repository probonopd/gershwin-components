/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

@interface EPUBPaginator : NSObject

- (instancetype)initWithAttributedString:(NSAttributedString *)attrString
                                pageRect:(NSRect)pageRect;

@property (nonatomic, readonly) NSUInteger pageCount;

- (NSRange)rangeForPage:(NSUInteger)pageIndex;
- (NSUInteger)pageForCharacterIndex:(NSUInteger)idx;

@end
