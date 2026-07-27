/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

@interface ProfileGenerator : NSObject

+ (BOOL)generateProfileAtPath:(NSString *)path
                    name:(NSString *)name
              whitePoint:(double)whitePointK
                   gamma:(double)gamma
                forAllUsers:(BOOL)forAllUsers;

+ (NSString *)profilesDirectoryForAllUsers:(BOOL)allUsers;

@end
