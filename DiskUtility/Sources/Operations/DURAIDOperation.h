/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUOperation.h"

#import "DUStorageBackend.h"

@class DUStorageObject;

// Builds a RAID set from whole devices. The pinned backend protocol has no
// RAID verb, so the operation drives the platform tool itself through
// DUAuthorizationManager; unsupported level/platform combinations fail hard
// instead of degrading silently (ARCHITECTURE.md section 15).
@interface DURAIDOperation : DUOperation

@property (nonatomic, copy, readonly) NSString *level;
@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, copy, readonly) NSArray<DUStorageObject *> *members;

- (instancetype)initWithBackend:(id<DUStorageBackend>)backend
                          level:(NSString *)level
                           name:(NSString *)name
                        members:(NSArray<DUStorageObject *> *)members;

@end
