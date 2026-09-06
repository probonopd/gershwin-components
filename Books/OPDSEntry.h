/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

// A single entry from an OPDS catalog feed. Holds the metadata needed to
// display the book in a list and to fetch the EPUB when the user selects it.
@interface OPDSEntry : NSObject

@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *author;
@property (nonatomic, copy) NSString *summary;
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSURL *epubURL;
@property (nonatomic, copy) NSURL *coverURL;
// Link to the book's own OPDS feed (rel="subsection"), which contains the
// actual EPUB download URLs. The top-level search feed does not include
// acquisition links; they live in this per-book feed.
@property (nonatomic, copy) NSURL *subsectionURL;

+ (instancetype)entryWithTitle:(NSString *)title
                        author:(NSString *)author;

@end
