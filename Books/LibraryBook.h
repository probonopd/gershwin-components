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

- (instancetype)initWithEpubPath:(NSString *)path;
- (NSString *)displayTitle;
- (NSString *)displayAuthor;

@end
