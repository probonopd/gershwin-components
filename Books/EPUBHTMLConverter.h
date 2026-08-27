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

// resourceResolver maps a resource's absolute path to the path the converter
// should actually load. Used by LCP to serve decrypted bytes; when nil the
// path is used as-is.
+ (NSAttributedString *)attributedStringFromXHTMLAtPath:(NSString *)path
                                                 baseURL:(NSURL *)base
                                          containerRoot:(NSString *)containerRoot
                                        resourceResolver:(NSString *(^)(NSString *))resolver
                                                   error:(NSError **)error;

@end
