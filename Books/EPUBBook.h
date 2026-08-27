/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import "EPUBTOCEntry.h"

@interface EPUBBook : NSObject

@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *author;
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *language;
@property (nonatomic, copy) NSString *publisher;
@property (nonatomic, copy) NSString *coverPath;
// EPUB RS 3.3, 5.5: nil means the reading system MUST assume "default".
@property (nonatomic, copy) NSString *pageProgressionDirection;
@property (nonatomic, copy) NSArray<NSString *> *spine;
@property (nonatomic, copy) NSArray<EPUBTOCEntry *> *tableOfContents;
// EPUB Locators / EPUB 3.3 nav `page-list`: the publisher's print page map.
// Each entry is @{ @"href": <relative ref, may carry #fragment>,
//                   @"label": <page label string, e.g. "1", "iv", "A-12"> }.
// Absent (nil) when the publication ships no page-list.
@property (nonatomic, copy) NSArray<NSDictionary<NSString *, NSString *> *> *pageList;
@property (nonatomic, copy, readonly) NSString *extractedRoot;

- (instancetype)initWithEPUBAtPath:(NSString *)epubPath error:(NSError **)error;
- (NSString *)absolutePathForContent:(NSString *)relativePath;
- (void)cleanupExtraction;

@end
