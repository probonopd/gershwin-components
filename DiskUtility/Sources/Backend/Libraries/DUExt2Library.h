/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Keys used by the dictionary returned from +statsForPath:.
extern NSString * const kDUExt2TotalBytes;
extern NSString * const kDUExt2FreeBytes;
extern NSString * const kDUExt2VolumeLabel;
extern NSString * const kDUExt2Uuid;

// Thin read-only Foundation wrapper around libext2fs superblock access
// (LGPL / GNU Library GPL v2 library licensing, direct-link approved per
// LIBRARIES.md sections 1-2 and 25). Opens filesystems strictly read-only:
// ext2fs_open() is called without EXT2_FLAG_RW, so no write path exists.
// No ext2fs types leak through this interface.
//
// Availability: when the build lacks HAVE_LIBEXT2FS (ext2fs headers absent
// at compile time), every method returns an explicit unavailable result -
// nil stats, NO detection, NO availability. This is a definite "not
// compiled in" state, never a guess about the runtime environment.
@interface DUExt2Library : NSObject

// YES only when this build was linked against libext2fs, which is what
// provides the ability to open ext filesystems at all. Per-path failures
// are reported by the individual methods instead.
+ (BOOL)isAvailable;

// YES when an ext2/ext3/ext4 signature can be opened at |path| (regular
// file image or device node). Read-only probe; returns NO on any failure,
// including absence of the library in this build.
+ (BOOL)isExtFilesystemPath:(NSString *)path;

// Superblock statistics for the ext filesystem at |path|: total/free bytes
// (NSNumber), volume label and formatted UUID (NSString, keys absent when
// empty). Returns nil on any open/read failure or without the library.
+ (nullable NSDictionary *)statsForPath:(NSString *)path;

@end

NS_ASSUME_NONNULL_END
