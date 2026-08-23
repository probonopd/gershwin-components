/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

extern NSString *const DUStorageErrorDomain;

typedef NS_ENUM(NSInteger, DUStorageErrorCode) { DUErrorUnknown=0, DUErrorDiscoveryFailed, DUErrorPermissionDenied, DUErrorDeviceBusy, DUErrorUnsupportedOperation, DUErrorInvalidArgument, DUErrorDeviceNotFound, DUErrorFilesystemError, DUErrorPartitionError, DUErrorMountError, DUErrorUnmountError, DUErrorVerificationFailed, DUErrorRepairFailed, DUErrorEraseFailed, DUErrorRestoreFailed, DUErrorCancelled, DUErrorBackendUnavailable };

static inline NSError* DUErrorMake(DUStorageErrorCode code, NSString *msg)
{
    return [NSError errorWithDomain:DUStorageErrorDomain
                               code:code
                           userInfo:@{ NSLocalizedDescriptionKey : msg ?: @"" }];
}
