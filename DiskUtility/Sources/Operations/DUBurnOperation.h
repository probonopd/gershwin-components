/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUOperation.h"
#import "DUStorageBackend.h"

// Burn an image file onto an optical disc through the backend's optional
// burnImage verb.
@interface DUBurnOperation : DUOperation

@property (nonatomic, strong, readonly) DUStorageObject *image;
@property (nonatomic, strong, readonly) DUStorageObject *opticalDrive;

- (instancetype)initWithBackend:(id<DUStorageBackend>)backend
                          image:(DUStorageObject *)image
                    opticalDrive:(DUStorageObject *)opticalDrive;

@end
