/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

#import "DUOperation.h"
#import "DUStorageBackend.h"

@class DUStorageObject;

// Blanks (erases) a rewritable optical disc so it can be reused.
@interface DUBlankDiscOperation : DUOperation

- (instancetype)initWithBackend:(id<DUStorageBackend>)backend
                    opticalDrive:(DUStorageObject *)opticalDrive
                         options:(NSDictionary *)options
    NS_DESIGNATED_INITIALIZER;

@end
