/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUOperation.h"

#import "DUStorageBackend.h"
#import "DUPartitionPlan.h"

@class DUStorageObject;

@interface DUPartitionOperation : DUOperation

@property (nonatomic, strong, readonly) DUStorageObject *device;
@property (nonatomic, copy, readonly) DUPartitionPlan *plan;

- (instancetype)initWithBackend:(id<DUStorageBackend>)backend
                         device:(DUStorageObject *)device
                           plan:(DUPartitionPlan *)plan;

@end
