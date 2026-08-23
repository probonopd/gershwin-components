/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUStorageDevice.h"

@implementation DUStorageDevice

- (instancetype)initWithIdentifier:(NSString *)identifier
{
    return [super initWithType:DUStorageObjectTypeDevice identifier:identifier];
}

// The type is fixed by the class; refuse mismatches instead of guessing.
- (instancetype)initWithType:(DUStorageObjectType)type
                  identifier:(NSString *)identifier
{
    NSParameterAssert(type == DUStorageObjectTypeDevice);
    return [super initWithType:DUStorageObjectTypeDevice identifier:identifier];
}

@end
