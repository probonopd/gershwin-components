/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

// Inset (points) drawn around the text inside each page bitmap. The page text
// views and the renderer must agree on this so a paginated page never overflows
// the area the renderer actually draws into. It is a mutable global so the
// reader can adjust the page border margin at runtime; the controller assigns
// it before paginating and before each render.
extern CGFloat EPUBPageMargin;

// Attribute (set on the first character of a chapter in the converted attributed
// string) that tells the paginator to force a page break before that character
// so each chapter opens on a fresh page.
extern NSString *EPUBPageBreakAttributeName;

@interface EPUBPageRenderer : NSObject

- (NSBitmapImageRep *)imageForRange:(NSRange)range
       ofAttributedString:(NSAttributedString *)attrString
                 pageSize:(NSSize)size
          backgroundColor:(NSColor *)background
                textColor:(NSColor *)text;

@end
