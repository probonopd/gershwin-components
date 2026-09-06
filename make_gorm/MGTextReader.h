/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef MGTEXTREADER_H
#define MGTEXTREADER_H

#import <Foundation/Foundation.h>

@class MGArchive;

@interface MGTextReader : NSObject

+ (MGArchive *)archiveFromText:(NSString *)text error:(NSError **)error;
+ (MGArchive *)archiveFromPath:(NSString *)path error:(NSError **)error;

@end

#endif
