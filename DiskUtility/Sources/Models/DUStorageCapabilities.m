/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUStorageCapabilities.h"

@implementation DUStorageCapabilities

- (void)setAllCapabilities:(BOOL)value
{
    _canVerify = value;
    _canRepair = value;
    _canErase = value;
    _canPartition = value;
    _canResize = value;
    _canMount = value;
    _canUnmount = value;
    _canEject = value;
    _canBurn = value;
    _canBlankDisc = value;
    _canVerifyDisc = value;
    _canCreateImage = value;
    _canRestore = value;
    _canCreateRAID = value;
    _canRepairPermissions = value;
    _canConvertImage = value;
    _canResizeImage = value;
    _canToggleJournaling = value;
}

+ (instancetype)capabilitiesWithAll:(BOOL)value
{
    DUStorageCapabilities *capabilities = [[self alloc] init];
    [capabilities setAllCapabilities:value];
    return capabilities;
}

@end
