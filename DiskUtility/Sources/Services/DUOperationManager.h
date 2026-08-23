/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

@class DUOperation;

// Owns running operations (ARCHITECTURE.md section 32): starts them,
// tracks them, rejects conflicting work on the same target object and keeps
// a bounded history of finished operations.
@interface DUOperationManager : NSObject

@property (nonatomic, copy, readonly) NSArray<DUOperation *> *activeOperations;

- (instancetype)init NS_DESIGNATED_INITIALIZER;

// Starts the operation unless another active operation already targets the
// same primary object identifier; returns NO with *error set then. Takes
// ownership of the operation on success.
- (BOOL)startOperation:(DUOperation *)operation error:(NSError **)error;

// Looks in active operations first, then history.
- (DUOperation *)operationForIdentifier:(NSString *)identifier;

- (void)cancelOperation:(DUOperation *)operation;
- (void)cancelAllOperations;

@end
