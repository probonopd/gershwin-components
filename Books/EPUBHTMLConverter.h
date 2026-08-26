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

@end
