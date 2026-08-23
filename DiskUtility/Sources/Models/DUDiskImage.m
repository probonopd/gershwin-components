/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUDiskImage.h"

@implementation DUDiskImage

- (instancetype)initWithIdentifier:(NSString *)identifier
{
    return [super initWithType:DUStorageObjectTypeDiskImage identifier:identifier];
}

- (instancetype)initWithType:(DUStorageObjectType)type
                  identifier:(NSString *)identifier
{
    NSParameterAssert(type == DUStorageObjectTypeDiskImage);
    return [super initWithType:DUStorageObjectTypeDiskImage identifier:identifier];
}

@end
