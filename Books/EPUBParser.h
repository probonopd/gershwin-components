/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

@class EPUBBook;

@interface EPUBParser : NSObject

- (EPUBBook *)parseEPUBAtPath:(NSString *)epubPath error:(NSError **)error;

@end
