/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

@interface ProfileParser : NSObject

- (NSDictionary *)parseProfileAtPath:(NSString *)path;

@end
