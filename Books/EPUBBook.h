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
@property (nonatomic, copy) NSArray<NSString *> *spine;
@property (nonatomic, copy) NSArray<EPUBTOCEntry *> *tableOfContents;
@property (nonatomic, copy, readonly) NSString *extractedRoot;

- (instancetype)initWithEPUBAtPath:(NSString *)epubPath error:(NSError **)error;
- (NSString *)absolutePathForContent:(NSString *)relativePath;
- (void)cleanupExtraction;

@end
