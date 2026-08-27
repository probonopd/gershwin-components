/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

@interface LibraryBook : NSObject <NSCoding>

@property (nonatomic, copy) NSString *epubPath;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *author;
@property (nonatomic, copy) NSString *coverPath;
@property (nonatomic, copy) NSDate *addedDate;
@property (nonatomic, assign) NSUInteger lastSpreadIndex;
@property (nonatomic, assign) CGFloat fontSize;
@property (nonatomic, assign) NSInteger theme;
// Page-number footer mode: 0 = calculated, 1 = authored page-list, 2 = off.
// Mirrors EPUBPageNumberMode; kept as NSInteger for NSCoding simplicity.
@property (nonatomic, assign) NSInteger pageNumberMode;
// Reader presentation settings (persisted per book).
@property (nonatomic, assign) CGFloat lineSpacing;   // extra inter-line leading, points
@property (nonatomic, assign) CGFloat pageMargin;     // text inset from page edge, points
@property (nonatomic, copy) NSString *fontFamily;     // nil = book default face

- (instancetype)initWithEpubPath:(NSString *)path;
- (NSString *)displayTitle;
- (NSString *)displayAuthor;

@end
