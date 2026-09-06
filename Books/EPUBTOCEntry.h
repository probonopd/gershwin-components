/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

@interface EPUBTOCEntry : NSObject <NSCopying>

@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *contentPath;
@property (nonatomic, assign) NSUInteger playOrder;
@property (nonatomic, copy) NSArray<EPUBTOCEntry *> *children;

- (NSArray<EPUBTOCEntry *> *)flattenedEntries;

@end
