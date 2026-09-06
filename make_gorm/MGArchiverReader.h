/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

@class MGArchive;

@interface MGArchiverReader : NSObject
- (MGArchive *)parseArchiveFromData:(NSData *)data error:(NSError **)error;
+ (NSArray *)parseValuesFromRawData:(NSData *)data error:(NSError **)error;
@end
