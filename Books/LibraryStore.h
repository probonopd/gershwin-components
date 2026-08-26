/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import "LibraryBook.h"

@interface LibraryStore : NSObject

+ (instancetype)sharedStore;
@property (nonatomic, copy, readonly) NSArray<LibraryBook *> *books;
- (void)addBookAtPath:(NSString *)path;
- (void)removeBook:(LibraryBook *)book;
- (void)save;

@end
