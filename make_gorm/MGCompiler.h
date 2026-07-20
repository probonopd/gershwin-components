/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

@class MGArchive;

@interface MGCompiler : NSObject
- (NSData *)compileArchive:(MGArchive *)archive error:(NSError **)error;
@end
