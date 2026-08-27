/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

#import "DUOperation.h"
#import "DUStorageBackend.h"

@class DUStorageObject;

// Verifies a burned optical disc by reading its data back and comparing it
// against the source image it was burned from.
@interface DUVerifyDiscOperation : DUOperation

- (instancetype)initWithBackend:(id<DUStorageBackend>)backend
                    opticalDrive:(DUStorageObject *)opticalDrive
                           image:(DUStorageObject *)image
    NS_DESIGNATED_INITIALIZER;

@end
