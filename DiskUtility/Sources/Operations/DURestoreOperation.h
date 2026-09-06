/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUOperation.h"

#import "DUStorageBackend.h"

@class DUStorageObject;

// Block-level copy from source to destination. The source is the primary
// object for conflict detection because it is the one being read whole.
@interface DURestoreOperation : DUOperation

@property (nonatomic, strong, readonly) DUStorageObject *source;
@property (nonatomic, strong, readonly) DUStorageObject *destination;
@property (nonatomic, copy, readonly) NSDictionary *options;

- (instancetype)initWithBackend:(id<DUStorageBackend>)backend
                         source:(DUStorageObject *)source
                     destination:(DUStorageObject *)destination
                         options:(NSDictionary *)options;

@end
