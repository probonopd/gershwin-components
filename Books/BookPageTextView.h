/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

@class BookPageTextView;

// The page view owns all gesture logic (click = page turn, drag = select,
// cross-page selection); the text view only renders text and forwards its
// raw mouse/key/scroll events upward so the owner can drive native selection.
@protocol BookPageTextViewOwner <NSObject>
- (void)pageTextView:(BookPageTextView *)tv mouseDown:(NSEvent *)e;
- (void)pageTextView:(BookPageTextView *)tv mouseDragged:(NSEvent *)e;
- (void)pageTextView:(BookPageTextView *)tv mouseUp:(NSEvent *)e;
- (void)pageTextView:(BookPageTextView *)tv scrollWheel:(NSEvent *)e;
- (void)pageTextView:(BookPageTextView *)tv keyDown:(NSEvent *)e;
@end

@interface BookPageTextView : NSTextView

@property (weak) id<BookPageTextViewOwner> owner;

// Pin the view's size to the page rectangle. GNUstep's NSTextView otherwise
// shrinks its frame to the laid-out text height during a deferred relayout
// (ignoring -setVerticallyResizable:NO), which collapses the page into a strip.
- (void)setFixedPageSize:(NSSize)size;

@end
