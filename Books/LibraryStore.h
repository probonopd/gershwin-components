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
// Path of the book left open the last time the app quit; the app reopens it on
// launch so a user returns to where they were reading.
@property (nonatomic, copy) NSString *currentBookPath;
- (void)addBookAtPath:(NSString *)path;
- (void)removeBook:(LibraryBook *)book;
- (void)save;

@end
