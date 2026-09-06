/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

@interface EPUBHTMLConverter : NSObject

+ (NSAttributedString *)attributedStringFromXHTMLAtPath:(NSString *)path
                                                  baseURL:(NSURL *)base
                                                    error:(NSError **)error;

// containerRoot is the directory the EPUB was extracted to. When provided,
// resources are constrained to stay inside it and file: URLs are rejected
// (EPUB RS 3.3, 3.4 / 3.5 / 4.1.1).
+ (NSAttributedString *)attributedStringFromXHTMLAtPath:(NSString *)path
                                                  baseURL:(NSURL *)base
                                           containerRoot:(NSString *)containerRoot
                                                    error:(NSError **)error;

// Same as the containerRoot variant, but also returns a map of element id
// (from any `id="..."` attribute) to the character offset in the produced
// attributed string where that element's content begins. The reader uses this
// to resolve an EPUB page-list (or TOC) anchor such as "chapter3.xhtml#loc-42"
// to a concrete position in the concatenated reading text.
+ (NSAttributedString *)attributedStringFromXHTMLAtPath:(NSString *)path
                                                  baseURL:(NSURL *)base
                                           containerRoot:(NSString *)containerRoot
                                                 anchors:(NSDictionary<NSString *, NSNumber *> **)outAnchors
                                                    error:(NSError **)error;

@end
