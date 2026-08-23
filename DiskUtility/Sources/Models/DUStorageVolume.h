/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUStorageObject.h"

// Mounted or mountable filesystem (ARCHITECTURE.md section 13).
// Metrics a filesystem does not expose stay at their sentinel values so the
// UI can render an unavailable placeholder instead of a wrong number.
@interface DUStorageVolume : DUStorageObject

@property (nonatomic, copy) NSString *mountPoint; // nil when unmounted
@property (nonatomic, copy) NSString *filesystemType;
@property (nonatomic) unsigned long long capacityBytes;
@property (nonatomic) unsigned long long availableBytes;
@property (nonatomic) unsigned long long usedBytes;
@property (nonatomic) BOOL mounted;
@property (nonatomic) BOOL readOnly;

// ownersEnabledKnown distinguishes "owners disabled" from "not reported".
@property (nonatomic) BOOL ownersEnabled;
@property (nonatomic) BOOL ownersEnabledKnown;

// NSNotFound while unknown.
@property (nonatomic) NSUInteger fileCount;
@property (nonatomic) NSUInteger folderCount;

- (instancetype)initWithIdentifier:(NSString *)identifier;

@end
