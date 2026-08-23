/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUStorageObject.h"

// Physical or virtual storage device (ARCHITECTURE.md section 11).
@interface DUStorageDevice : DUStorageObject

@property (nonatomic, copy) NSString *devicePath;
@property (nonatomic, copy) NSString *connectionType; // e.g. "SATA", "USB"
@property (nonatomic) BOOL connectionIsInternal;
@property (nonatomic) unsigned long long capacityBytes;
@property (nonatomic) BOOL removable;
@property (nonatomic) BOOL readOnly;
@property (nonatomic) BOOL ejectable;

// Partition table scheme identifier: "gpt", "mbr", "bsd" or nil.
@property (nonatomic, copy) NSString *partitionScheme;

@property (nonatomic, copy) NSString *healthStatus;

@property (nonatomic) BOOL optical;
// Only meaningful when optical is YES.
@property (nonatomic) BOOL mediaPresent;

- (instancetype)initWithIdentifier:(NSString *)identifier;

@end
