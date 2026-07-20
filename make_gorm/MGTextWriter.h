/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef MGTEXTWRITER_H
#define MGTEXTWRITER_H

#import <Foundation/Foundation.h>

@class MGArchive;

@interface MGTextWriter : NSObject

+ (NSString *)textFromArchive:(MGArchive *)archive;
+ (BOOL)writeArchive:(MGArchive *)archive toPath:(NSString *)path error:(NSError **)error;

@end

#endif
