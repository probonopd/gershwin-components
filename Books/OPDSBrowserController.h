/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

// Browse and search an OPDS catalog feed. Presents a searchable list of books;
// selecting one and clicking "Download" fetches the EPUB and adds it to the
// library.
@interface OPDSBrowserController : NSWindowController

// Open the browser for the given feed URL and optional title.
- (instancetype)initWithFeedURL:(NSURL *)url title:(NSString *)title;

@end
