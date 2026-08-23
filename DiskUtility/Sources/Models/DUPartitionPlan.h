/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

@class DUPartition;
@class DUPartitionLayout;
@class DUStorageObject;

// Immutable description of a partitioning operation (ARCHITECTURE.md
// section 87). The backend receives this validated snapshot instead of
// loosely related UI values.
@interface DUPartitionPlan : NSObject

@property (nonatomic, copy, readonly) NSString *diskIdentifier;
@property (nonatomic, copy, readonly) NSString *scheme;

// Deep-copied snapshot of the layout's partitions at plan time.
@property (nonatomic, copy, readonly) NSArray<DUPartition *> *entries;

@property (nonatomic, readonly) BOOL destructive;
// Partition table edits always run privileged.
@property (nonatomic, readonly) BOOL requiresPrivilege;

+ (instancetype)planFromLayout:(DUPartitionLayout *)layout
                    forDevice:(DUStorageObject *)device
                   destructive:(BOOL)destructive;


@end
