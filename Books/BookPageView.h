/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

@class BookPageView;
@class BookPageTextView;

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
// string (or an index past the end) means "draw nothing" for that page.
@property (nonatomic, copy) NSArray<NSString *> *pageLabels;
// Active highlights to paint over the text. Each entry is an NSDictionary with
// keys @"range" (NSValue wrapping an NSRange, absolute in the reading text) and
// @"color" (an NSColor). Painted as translucent background behind the glyphs.
@property (nonatomic, copy) NSArray<NSDictionary *> *highlights;

- (void)configureWithAttributedString:(NSAttributedString *)attr;
- (NSSize)contentSize;
- (void)setThemeTextColor:(NSColor *)textColor;
// Total paginated visual pages. Read-only: pages are derived natively from the
// view's own geometry in -configureWithAttributedString: and on every resize.
@property (nonatomic, assign, readonly) NSUInteger pageCount;
- (NSRange)rangeForPage:(NSUInteger)page;
- (NSUInteger)spreadCount;
- (NSUInteger)currentSpread;
- (BOOL)canGoNext;
- (BOOL)canGoPrevious;
- (void)showSpread:(NSUInteger)spread animated:(BOOL)animated;
- (void)next;
- (void)previous;
- (NSUInteger)pageForCharacterIndex:(NSUInteger)idx;

@end
