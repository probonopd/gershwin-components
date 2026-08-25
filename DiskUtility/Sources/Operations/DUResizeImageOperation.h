/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUOperation.h"
#import "DUStorageBackend.h"

// Resize a disk-image file through the backend's optional resizeImage
// verb. Options carry @"deltaBytes" (signed).
@interface DUResizeImageOperation : DUOperation

@property (nonatomic, strong, readonly) DUStorageObject *object;
@property (nonatomic, copy, readonly) NSDictionary *options;

- (instancetype)initWithBackend:(id<DUStorageBackend>)backend
                         object:(DUStorageObject *)object
                        options:(NSDictionary *)options;

@end
