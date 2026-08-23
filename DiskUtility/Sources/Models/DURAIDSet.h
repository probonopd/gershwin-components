/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUStorageObject.h"

@class DUStorageDevice;

// Logical RAID set (ARCHITECTURE.md section 15).
@interface DURAIDSet : DUStorageObject

// Canonical level name: "stripe", "mirror" or "concat".
@property (nonatomic, copy) NSString *raidLevel;

@property (nonatomic, copy) NSArray<DUStorageDevice *> *members;
@property (nonatomic) unsigned long long capacityBytes;
@property (nonatomic, copy) NSString *status;
@property (nonatomic) BOOL degraded;

- (instancetype)initWithIdentifier:(NSString *)identifier;

@end
