/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

@class DUPartition;

// Pending-layout editing model (ARCHITECTURE.md section 43). All edits stay
// in memory until commitAsBaseline; nothing here touches a real disk.
// Pure Foundation logic, fully unit-testable without a backend.
@interface DUPartitionLayout : NSObject

@property (nonatomic, readonly) unsigned long long capacityBytes;

// Scheme identifier: "gpt", "mbr", "bsd" or nil when unknown.
@property (nonatomic, copy, readonly) NSString *scheme;

// Partitions ordered by offset. The objects are owned by the layout; edit
// methods take these instances and mutate them in place.
@property (nonatomic, readonly) NSArray<DUPartition *> *partitions;

// YES while the working set differs from the committed baseline.
@property (nonatomic, readonly) BOOL hasPendingChanges;

- (instancetype)initWithCapacity:(unsigned long long)bytes
                          scheme:(NSString *)schemeIdentifier
    NS_DESIGNATED_INITIALIZER;

// Allocates the first gap that fits, scanning from the start of the disk;
// fails with DUErrorInvalidArgument when size is below the minimum or no
// gap has room left under the scheme's partition-count limit.
- (BOOL)addPartitionWithSize:(unsigned long long)sizeBytes
                        name:(NSString *)name
                       error:(NSError **)error;

- (BOOL)removePartition:(DUPartition *)partition error:(NSError **)error;

// Grows into the following free gap or shrinks leaving a gap; never moves
// offsets and never overlaps neighbours.
- (BOOL)resizePartition:(DUPartition *)partition
             toSizeBytes:(unsigned long long)newSizeBytes
                   error:(NSError **)error;

- (void)renamePartition:(DUPartition *)partition toName:(NSString *)name;

// Records a pending filesystem format for the partition.
- (void)setFormat:(NSString *)filesystemType forPartition:(DUPartition *)partition;

// Free bytes between this partition and the next one (or disk end);
// 0 for unknown partitions.
- (unsigned long long)freeBytesAfterPartition:(DUPartition *)partition;

- (unsigned long long)totalUsedBytes;

// Geometry check per ARCHITECTURE.md section 44: everything fits the
// capacity, nothing overlaps, every partition is at least 1 MiB, and the
// count stays within the scheme limits (gpt 128, mbr 15, bsd 8).
- (BOOL)validate:(NSError **)error;

// Apply/Revert semantics from section 43.
- (void)commitAsBaseline;
- (void)revertToCommitted;

@end
