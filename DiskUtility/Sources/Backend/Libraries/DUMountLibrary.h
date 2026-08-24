/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Result keys for +listMounts.
extern NSString * const kDUMountDevice;
extern NSString * const kDUMountPoint;
extern NSString * const kDUMountFstype;
extern NSString * const kDUMountReadOnly;

// Thin read-only Foundation wrapper around libmount mount-table reading
// (LGPL-2.1-or-later library licensing, direct-link approved per
// LIBRARIES.md sections 1-2 and 25). No libmount types leak through this
// interface. Purely observational: reads the system mount table, touches
// no devices and performs no mount operations.
//
// Availability: when the build lacks HAVE_LIBMOUNT (libmount headers
// absent at compile time), every method returns an explicit unavailable
// result - nil from listing and NO from +isAvailable. This is a definite
// "not compiled in" state, never a guess about the runtime environment.
@interface DUMountLibrary : NSObject

// YES only when this build was linked against libmount.
+ (BOOL)isAvailable;

// Snapshots the current kernel mount table through mnt_table_parse_mtab()
// so libmount resolves the right table source per platform. Each entry is
// a dictionary with kDUMountDevice, kDUMountPoint, kDUMountFstype and
// kDUMountReadOnly (NSNumber bool). Returns nil when unavailable or when
// the mount table cannot be read at all; an empty table yields an empty
// array.
+ (nullable NSArray<NSDictionary *> *)listMounts;

@end

NS_ASSUME_NONNULL_END
