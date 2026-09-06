/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUOperation.h"
#import "DUStorageBackend.h"

// Convert a disk-image file into another format through the backend's
// optional convertImage verb. Options carry @"path" and @"format".
@interface DUConvertImageOperation : DUOperation

@property (nonatomic, strong, readonly) DUStorageObject *object;
@property (nonatomic, copy, readonly) NSDictionary *options;

- (instancetype)initWithBackend:(id<DUStorageBackend>)backend
                         object:(DUStorageObject *)object
                        options:(NSDictionary *)options;

@end
