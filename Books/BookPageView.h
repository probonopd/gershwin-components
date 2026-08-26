/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>
#import "EPUBPaginator.h"
#import "EPUBPageRenderer.h"

@class BookPageView;

@protocol BookPageViewDelegate <NSObject>
- (void)pageViewDidRequestNext:(BookPageView *)view;
- (void)pageViewDidRequestPrevious:(BookPageView *)view;
@end

@interface BookPageView : NSView

@property (nonatomic, weak) id<BookPageViewDelegate> delegate;

@property (nonatomic, strong) NSColor *backgroundColor;
@property (nonatomic, strong) NSColor *textColor;

- (void)configureWithAttributedString:(NSAttributedString *)attr
                            paginator:(EPUBPaginator *)pag
                             renderer:(EPUBPageRenderer *)rend;
- (NSSize)contentSize;
- (void)setThemeTextColor:(NSColor *)textColor;
- (NSUInteger)spreadCount;
- (NSUInteger)currentSpread;
- (BOOL)canGoNext;
- (BOOL)canGoPrevious;
- (void)showSpread:(NSUInteger)spread animated:(BOOL)animated;
- (void)next;
- (void)previous;
- (NSUInteger)pageForCharacterIndex:(NSUInteger)idx;

@end
