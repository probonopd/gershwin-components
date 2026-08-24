/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Keys used by the dictionary returned from +inspectPath:.
extern NSString * const kDUFdiskScheme;
extern NSString * const kDUFdiskPartitions;
extern NSString * const kDUFdiskIndex;
extern NSString * const kDUFdiskStartBytes;
extern NSString * const kDUFdiskSizeBytes;
extern NSString * const kDUFdiskType;
extern NSString * const kDUFdiskName;
extern NSString * const kDUFdiskUuid;

// Thin read-only Foundation wrapper around libfdisk partition-table
// inspection (LGPL-2.1-or-later library licensing, direct-link approved
// per LIBRARIES.md sections 6.2, 19 and 25). No libfdisk types leak
// through this interface: plain Foundation objects only. Inspection never
// writes - the device/file is assigned strictly read-only, and |path| may
// be a regular file (loop-style image) or a device node alike.
//
// Availability: when the build lacks HAVE_LIBFDISK (libfdisk headers
// absent at compile time), every method returns an explicit unavailable
// result - nil from inspection and NO from +isAvailable. This is a
// definite "not compiled in" state, never a guess about the runtime
// environment.
@interface DUFdiskLibrary : NSObject

// YES only when this build was linked against libfdisk.
+ (BOOL)isAvailable;

// Inspects the partition table at |path| and returns kDUFdiskScheme plus
// kDUFdiskPartitions (an NSArray of per-partition dictionaries keyed by
// kDUFdiskIndex/kDUFdiskStartBytes/kDUFdiskSizeBytes and, where present,
// kDUFdiskType/kDUFdiskName/kDUFdiskUuid). Returns nil when unavailable,
// on invalid input, or when the target carries no recognizable partition
// table.
+ (nullable NSDictionary *)inspectPath:(NSString *)path;

@end

NS_ASSUME_NONNULL_END
