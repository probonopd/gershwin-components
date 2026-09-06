/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#if defined(__FreeBSD__)

#import <Foundation/Foundation.h>

#import "DUStorageBackend.h"

@class DUStorageObject;

// FreeBSD implementation of the storage abstraction. Discovery is delegated
// to DUFreeBSDDeviceDiscovery; filesystem, partition, mount and image work
// runs the stock tools (fsck_ffs, fsck_msdosfs, newfs, newfs_msdos, gpart,
// mount, umount, cdcontrol, camcontrol, dd, gmirror/gstripe/gconcat)
// through DUProcessRunner on private worker threads.
//
// Privilege note: the tools are executed directly, like everywhere else in
// this app; gaining root is the authorization layer's concern, not the
// backend's.
@interface DUFreeBSDStorageBackend : NSObject <DUStorageBackend>

// Labels a gmirror ("mirror"), gstripe ("stripe") or gconcat ("concat") set
// over at least two whole devices. Blocks until the tool exits, so callers
// must invoke it from a background thread (ARCHITECTURE.md section 53).
// Destroying sets is deliberately not offered: the pinned backend protocol
// has no such verb.
- (NSError *)createRAIDWithName:(NSString *)name
                          level:(NSString *)level
                        members:(NSArray<DUStorageObject *> *)members;

@end

#endif /* defined(__FreeBSD__) */
