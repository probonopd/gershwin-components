/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUOperation.h"

#import "DUStorageBackend.h"

// Destructive erase of an object. The options dictionary carries the new
// volume name, the kDUFormatIdentifierKey format and optionally a
// kDUEraseSecurityMethodKey; it is copied at init so later UI edits cannot
// alter what actually runs.
@interface DUEraseOperation : DUOperation

@property (nonatomic, strong, readonly) DUStorageObject *object;
@property (nonatomic, copy, readonly) NSDictionary *options;

- (instancetype)initWithBackend:(id<DUStorageBackend>)backend
                         object:(DUStorageObject *)object
                        options:(NSDictionary *)options;

@end
