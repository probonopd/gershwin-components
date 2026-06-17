/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

@protocol UIBridgeProtocol <NSObject>

- (bycopy NSString *)rootObjectsJSON;
- (bycopy NSString *)detailsForObjectJSON:(NSString *)objID;
- (bycopy NSString *)fullTreeForObjectJSON:(NSString *)objID;
- (bycopy NSString *)invokeSelectorJSON:(NSString *)selectorName onObject:(NSString *)objID withArgs:(NSArray *)args;

// Typed variants
- (bycopy id)rootObjects;
- (bycopy id)detailsForObject:(NSString *)objID;
- (bycopy id)fullTreeForObject:(NSString *)objID;
- (bycopy id)invokeSelector:(NSString *)selectorName onObject:(NSString *)objID withArgs:(NSArray *)args;

- (bycopy NSArray *)listMenus;
// JSON string variant used by some server implementations
- (bycopy NSString *)listMenusJSON;
- (BOOL)invokeMenuItem:(NSString *)objID;

@end
