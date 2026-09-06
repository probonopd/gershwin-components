/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DURAIDSet.h"

@implementation DURAIDSet

- (instancetype)initWithIdentifier:(NSString *)identifier
{
    return [super initWithType:DUStorageObjectTypeRAIDSet identifier:identifier];
}

- (instancetype)initWithType:(DUStorageObjectType)type
                  identifier:(NSString *)identifier
{
    NSParameterAssert(type == DUStorageObjectTypeRAIDSet);
    if ((self = [super initWithType:DUStorageObjectTypeRAIDSet
                         identifier:identifier]) == nil) {
        return nil;
    }
    _members = @[];
    return self;
}

@end
