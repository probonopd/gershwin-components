/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUStorageObject.h"

@class DUStorageVolume;

// Partition-table entry (ARCHITECTURE.md section 12).
@interface DUPartition : DUStorageObject <NSCopying>

@property (nonatomic) NSInteger index;
@property (nonatomic) unsigned long long offsetBytes;
@property (nonatomic) unsigned long long sizeBytes;

// Raw table-level type string as reported by the backend.
@property (nonatomic, copy) NSString *partitionType;

// Label/name from the partition table ("partitionName" in section 12);
// not localized, may be nil.
@property (nonatomic, copy) NSString *name;

@property (nonatomic, copy) NSString *filesystemType; // e.g. "ext4" or nil
@property (nonatomic) BOOL bootable;
@property (nonatomic) BOOL readOnly;

// Filesystem contained in this partition; nil while unknown/unformatted.
@property (nonatomic, strong) DUStorageVolume *volume;

- (instancetype)initWithIdentifier:(NSString *)identifier;

@end
