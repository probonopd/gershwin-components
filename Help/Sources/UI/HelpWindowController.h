/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/* Owns the main Help.app window (SPEC 36): toolbar with Back/Forward
 * and a search field on top, contents sidebar (NSOutlineView built
 * from the document TOC) on the left, rendered document in a scroll
 * view on the right. */
@interface HelpWindowController : NSObject

- (void)showWindow;

/* Parses path via the parser registry and displays it. Returns NO
 * when no registered parser accepts the file. */
- (BOOL)openFileAtPath:(NSString *)path;

@end

NS_ASSUME_NONNULL_END
