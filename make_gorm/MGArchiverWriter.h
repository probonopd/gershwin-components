/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import "MGTypes.h"

@interface MGArchiverWriter : NSObject
- (NSData *)archiveDataFromArchive:(MGArchive *)archive error:(NSError **)error;
@end
