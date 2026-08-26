/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

@interface EPUBPageRenderer : NSObject

- (NSBitmapImageRep *)imageForRange:(NSRange)range
       ofAttributedString:(NSAttributedString *)attrString
                 pageSize:(NSSize)size
          backgroundColor:(NSColor *)background
                textColor:(NSColor *)text;

@end
