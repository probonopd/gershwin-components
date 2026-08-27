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
// Ctrl + scroll wheel: `delta` is the wheel's deltaY (positive = zoom in).
- (void)pageView:(BookPageView *)view fontSizeDelta:(CGFloat)delta;
// A drag over the page selected a run of reading text; `range` is the absolute
// character range in the book's concatenated reading text. Sent on mouse-up when
// the drag exceeded the click threshold (otherwise the gesture is a page turn).
- (void)pageView:(BookPageView *)view didSelectRange:(NSRange)range;
@end

@interface BookPageView : NSView

@property (nonatomic, weak) id<BookPageViewDelegate> delegate;

@property (nonatomic, strong) NSColor *backgroundColor;
@property (nonatomic, strong) NSColor *textColor;
// Footer page numbers, one per paginated visual page, in page order. An empty
// string (or an index past the end) means "draw nothing" for that page. The
// reader fills these from the EPUB Locators page-number model.
@property (nonatomic, copy) NSArray<NSString *> *pageLabels;
// Active highlights to paint over the rendered pages. Each entry is an
// NSDictionary with keys @"range" (NSValue wrapping an NSRange, absolute in the
// reading text) and @"color" (an NSColor). Painted as translucent rectangles
// behind the footer but over the page bitmap.
@property (nonatomic, copy) NSArray<NSDictionary *> *highlights;

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
