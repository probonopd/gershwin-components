/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>
#import "LibraryBook.h"

@interface BookshelfController : NSWindowController
- (void)reload;
- (void)addBook:(id)sender;
// Open a book, hiding the shelf; returns YES if a reader was launched.
- (BOOL)openBook:(LibraryBook *)book;
// Find and open the book whose epub lives at the given path.
- (BOOL)openBookForPath:(NSString *)path;
// The book in the library matching the given epub path, or nil.
- (LibraryBook *)bookForPath:(NSString *)path;
@end
