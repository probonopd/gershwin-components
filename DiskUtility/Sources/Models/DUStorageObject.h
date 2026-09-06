/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

#import "DUStorageCapabilities.h"

// Kind of node in the storage hierarchy (ARCHITECTURE.md section 9).
typedef NS_ENUM(NSInteger, DUStorageObjectType) {
    DUStorageObjectTypeDevice = 0,
    DUStorageObjectTypePartition,
    DUStorageObjectTypeVolume,
    DUStorageObjectTypeOpticalMedia,
    DUStorageObjectTypeDiskImage,
    DUStorageObjectTypeRAIDSet,
};

@class DUStorageObject;

// Abstract base of the storage domain model. identifier is stable across
// rescans and must never be replaced by displayName in UI logic.
@interface DUStorageObject : NSObject

@property (nonatomic, copy, readonly) NSString *identifier;
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, readonly) DUStorageObjectType type;

// Weak so a child never keeps its parent alive during tree rebuilds.
@property (nonatomic, weak) DUStorageObject *parent;

// Live child list; mutation goes through addChild:/removeChild: so the
// parent pointers stay consistent with the hierarchy.
@property (nonatomic, strong, readonly) NSArray<DUStorageObject *> *children;

// Platform device node (/dev/sda, /dev/ada0p2, ...); opaque to UI code.
@property (nonatomic, copy) NSString *backendPath;

@property (nonatomic, strong) DUStorageCapabilities *capabilities;

- (instancetype)initWithType:(DUStorageObjectType)type
                  identifier:(NSString *)identifier NS_DESIGNATED_INITIALIZER;

- (void)addChild:(DUStorageObject *)child;
- (void)removeChild:(DUStorageObject *)child;

// Depth-first search over self and all descendants; nil when absent.
- (DUStorageObject *)objectForIdentifier:(NSString *)identifier;

// Self plus every descendant, pre-order.
- (NSArray<DUStorageObject *> *)flattenObjects;

@end
