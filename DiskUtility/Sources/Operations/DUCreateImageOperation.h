/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUOperation.h"
#import "DUStorageBackend.h"

// Streams a device or volume into a disk-image file through the backend's
// optional createImageFromObject verb. Options carry @"path" and @"format".
@interface DUCreateImageOperation : DUOperation

@property (nonatomic, strong, readonly) DUStorageObject *object;
@property (nonatomic, copy, readonly) NSDictionary *options;

- (instancetype)initWithBackend:(id<DUStorageBackend>)backend
                         object:(DUStorageObject *)object
                        options:(NSDictionary *)options;

@end
