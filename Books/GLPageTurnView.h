/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

@interface GLPageTurnView : NSOpenGLView

+ (BOOL)glSupported;
- (void)displayLeft:(NSBitmapImageRep *)left right:(NSBitmapImageRep *)right;

@end
