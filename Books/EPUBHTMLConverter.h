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

@end
