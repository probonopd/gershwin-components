/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUOpticalMedia.h"

@implementation DUOpticalMedia

- (instancetype)initWithIdentifier:(NSString *)identifier
{
    return [super initWithType:DUStorageObjectTypeOpticalMedia identifier:identifier];
}

- (instancetype)initWithType:(DUStorageObjectType)type
                  identifier:(NSString *)identifier
{
    NSParameterAssert(type == DUStorageObjectTypeOpticalMedia);
    return [super initWithType:DUStorageObjectTypeOpticalMedia identifier:identifier];
}

@end
