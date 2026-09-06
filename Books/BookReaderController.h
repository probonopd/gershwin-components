/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>
#import "LibraryBook.h"

@interface BookReaderController : NSWindowController

- (instancetype)initWithLibraryBook:(LibraryBook *)book;
- (void)showWithZoomFromRect:(NSRect)screenRect;

// The library book this reader is displaying; used to track the open book.
@property (nonatomic, readonly, strong) LibraryBook *libraryBook;

@end
