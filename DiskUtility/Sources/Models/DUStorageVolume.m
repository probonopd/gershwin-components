/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUStorageVolume.h"

@implementation DUStorageVolume

- (instancetype)initWithIdentifier:(NSString *)identifier
{
    return [super initWithType:DUStorageObjectTypeVolume identifier:identifier];
}

- (instancetype)initWithType:(DUStorageObjectType)type
                  identifier:(NSString *)identifier
{
    NSParameterAssert(type == DUStorageObjectTypeVolume);
    if ((self = [super initWithType:DUStorageObjectTypeVolume
                         identifier:identifier]) == nil) {
        return nil;
    }
    _fileCount = NSNotFound;
    _folderCount = NSNotFound;
    return self;
}

@end
