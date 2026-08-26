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

@end
