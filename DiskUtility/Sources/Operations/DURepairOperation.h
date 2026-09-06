/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUOperation.h"

#import "DUStorageBackend.h"

@interface DURepairOperation : DUOperation

@property (nonatomic, strong, readonly) DUStorageObject *object;

- (instancetype)initWithBackend:(id<DUStorageBackend>)backend
                         object:(DUStorageObject *)object;

@end
