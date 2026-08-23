/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUStorageObject.h"

@class DUStorageVolume;

// Disk image file ("raw", "qcow2", ...) (ARCHITECTURE.md section 14).
@interface DUDiskImage : DUStorageObject

@property (nonatomic, copy) NSString *path;
@property (nonatomic, copy) NSString *format;
@property (nonatomic) unsigned long long sizeBytes;
@property (nonatomic) BOOL compressed;
@property (nonatomic) BOOL encrypted;
@property (nonatomic) BOOL readOnly;
@property (nonatomic) BOOL mounted;

// Volume exposed by the attached image; also a child of this object.
@property (nonatomic, strong) DUStorageVolume *backingVolume;

- (instancetype)initWithIdentifier:(NSString *)identifier;

@end
