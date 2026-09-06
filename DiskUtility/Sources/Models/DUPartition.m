/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUPartition.h"

#import "DUStorageVolume.h"

@implementation DUPartition

- (instancetype)initWithIdentifier:(NSString *)identifier
{
    return [super initWithType:DUStorageObjectTypePartition identifier:identifier];
}

- (instancetype)initWithType:(DUStorageObjectType)type
                  identifier:(NSString *)identifier
{
    NSParameterAssert(type == DUStorageObjectTypePartition);
    return [super initWithType:DUStorageObjectTypePartition identifier:identifier];
}

// Deep value copy; the volume association is kept as a reference because a
// copy represents the same logical partition, not a clone of its filesystem.
- (instancetype)copyWithZone:(NSZone *)zone
{
    DUPartition *copy =
        [[DUPartition allocWithZone:zone] initWithIdentifier:self.identifier];
    if (copy == nil) {
        return nil;
    }
    copy.displayName = self.displayName;
    copy.backendPath = self.backendPath;
    copy.index = _index;
    copy.offsetBytes = _offsetBytes;
    copy.sizeBytes = _sizeBytes;
    copy.partitionType = _partitionType;
    copy.name = _name;
    copy.filesystemType = _filesystemType;
    copy.bootable = _bootable;
    copy.readOnly = _readOnly;
    copy.volume = _volume;
    return copy;
}

@end
