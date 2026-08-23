/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

// Plain capability holder per ARCHITECTURE.md section 16. The UI derives
// toolbar/tab enabled state from these flags instead of asking which OS it
// is running on. All flags default to NO.
@interface DUStorageCapabilities : NSObject

@property (nonatomic) BOOL canVerify;
@property (nonatomic) BOOL canRepair;
@property (nonatomic) BOOL canErase;
@property (nonatomic) BOOL canPartition;
@property (nonatomic) BOOL canResize;
@property (nonatomic) BOOL canMount;
@property (nonatomic) BOOL canUnmount;
@property (nonatomic) BOOL canEject;
@property (nonatomic) BOOL canBurn;
@property (nonatomic) BOOL canCreateImage;
@property (nonatomic) BOOL canRestore;
@property (nonatomic) BOOL canCreateRAID;
@property (nonatomic) BOOL canRepairPermissions;
@property (nonatomic) BOOL canConvertImage;
@property (nonatomic) BOOL canResizeImage;
@property (nonatomic) BOOL canToggleJournaling;

- (void)setAllCapabilities:(BOOL)value;

+ (instancetype)capabilitiesWithAll:(BOOL)value;

@end
