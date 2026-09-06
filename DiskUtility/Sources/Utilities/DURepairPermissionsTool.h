/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

// Platform-neutral repair-permissions helper. Enumerates local login users
// from /etc/passwd and makes every file under each home directory belong to
// its owner. Used by every backend's -repairHomePermissionsWithProgress:
// implementation, which simply forwards to this shared tool.
@interface DURepairPermissionsTool : NSObject

+ (void)repairHomePermissionsWithProgress:(void (^)(double progress,
                                                    NSString *message))progress
                                completion:(void (^)(NSError *error))completion;

+ (NSArray<NSDictionary *> *)enumerateUserHomes;

@end
