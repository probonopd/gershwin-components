/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#if defined(__NetBSD__)

#import <Foundation/Foundation.h>

#import "DUStorageBackend.h"

@class DUStorageObject;

// Raw tool output is surfaced to error sheets under this user info key.
extern NSString *const DUNetBSDBackendDetailKey;

// NetBSD implementation of the storage abstraction. Discovery is delegated
// to DUNetBSDDeviceDiscovery; filesystem, partition, mount and image work
// runs the stock tools (fsck_ffs, fsck_msdos, newfs, newfs_msdos, disklabel,
// fdisk, mount, umount, eject, dd) through DUProcessRunner on private worker
// threads.
//
// Privilege note: mutating operations run through DUAuthorizationManager so
// gaining root stays the authorization layer's concern; read-only tools run
// directly.
//
// Partitioning keeps to what these systems can drive honestly: BSD disklabel
// layouts are written from a template file via `disklabel -R`; scripted MBR
// editing (fdisk -e) needs stdin control the process runner does not offer
// and is refused rather than half-applied.
@interface DUNetBSDStorageBackend : NSObject <DUStorageBackend>

@end

#endif /* defined(__NetBSD__) */
