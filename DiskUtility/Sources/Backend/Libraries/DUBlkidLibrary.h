/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Keys used by the dictionary returned from +probeDevicePath:.
extern NSString * const kDUBlkidFstype;
extern NSString * const kDUBlkidUuid;
extern NSString * const kDUBlkidLabel;
extern NSString * const kDUBlkidUsage;

// Thin read-only Foundation wrapper around libblkid superblock probing
// (LGPL-2.1-or-later library licensing, direct-link approved per
// LIBRARIES.md sections 1-2 and 25). No blkid types leak through this
// interface. The wrapper is read-only by nature: blkid probing never
// writes to the probed file, and |path| may be a regular file (loop-style
// image) or a device node alike.
//
// Availability: when the build lacks HAVE_LIBBLKID (blkid headers absent
// at compile time), every method returns an explicit unavailable result -
// nil from probing and NO from +isAvailable. This is a definite "not
// compiled in" state, never a guess about the runtime environment.
@interface DUBlkidLibrary : NSObject

// YES only when this build was linked against libblkid.
+ (BOOL)isAvailable;

// Probes the filesystem/partition signature at |path| and returns keys
// kDUBlkidFstype, kDUBlkidUuid, kDUBlkidLabel and kDUBlkidUsage with
// NSString values; a key is absent when the probe did not yield that
// property. Returns nil when unavailable, on invalid input or when no
// signature is found (e.g. all-zero content).
+ (nullable NSDictionary *)probeDevicePath:(NSString *)path;

@end

NS_ASSUME_NONNULL_END
