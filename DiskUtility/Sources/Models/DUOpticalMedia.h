/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUStorageObject.h"

// Disc in an optical drive (e.g. "CD-RW", "DVD+R").
@interface DUOpticalMedia : DUStorageObject

@property (nonatomic, copy) NSString *mediaType;
@property (nonatomic, copy) NSString *filesystemType;
@property (nonatomic) unsigned long long capacityBytes;
@property (nonatomic) unsigned long long usedBytes;
@property (nonatomic) unsigned long long freeBytes;
@property (nonatomic) BOOL writable;
@property (nonatomic) BOOL ejectable;

- (instancetype)initWithIdentifier:(NSString *)identifier;

@end
