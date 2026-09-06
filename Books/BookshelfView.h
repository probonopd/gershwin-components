/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>
#import "LibraryBook.h"

@protocol BookshelfViewDelegate <NSObject>
- (void)bookshelfDidRequestOpen:(LibraryBook *)book;
- (void)bookshelfDidRequestAddFiles:(NSArray<NSString *> *)paths;
- (void)bookshelfDidRequestDelete:(LibraryBook *)book;
@end

@interface BookshelfView : NSView

@property (nonatomic, weak) id<BookshelfViewDelegate> delegate;
@property (nonatomic, copy) NSArray<LibraryBook *> *books;
@property (nonatomic, assign) NSInteger selectedIndex;

- (void)reloadData;
- (NSRect)rectForBookAtIndex:(NSInteger)index;

@end
