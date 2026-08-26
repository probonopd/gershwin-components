/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

// Inset (points) drawn around the text inside each page bitmap. The paginator
// and the renderer must agree on this so a paginated page never overflows the
// area the renderer actually draws into.
extern const CGFloat EPUBPageMargin;

@interface EPUBPageRenderer : NSObject

- (NSBitmapImageRep *)imageForRange:(NSRange)range
       ofAttributedString:(NSAttributedString *)attrString
                 pageSize:(NSSize)size
          backgroundColor:(NSColor *)background
                textColor:(NSColor *)text;

@end
