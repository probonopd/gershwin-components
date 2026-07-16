/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

@interface GSMenuExtraBundle : NSObject

@property (readonly) NSBundle *bundle;
@property (readonly) NSString *identifier;
@property (readonly) NSString *displayName;
@property (readonly) NSURL *URL;
@property (readonly) BOOL isGSMenuExtra;

- (instancetype)initWithURL:(NSURL *)URL;

@end
