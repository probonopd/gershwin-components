/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Result keys for +identifyPath:.
extern NSString * const kDUArchiveFormat;
extern NSString * const kDUArchiveEntryCount;

// Upper bound on entries counted during identification; keeps the read-only
// scan bounded for huge archives.
extern const NSUInteger kDUArchiveEntryCountCap;

// Thin read-only Foundation wrapper around libarchive format identification
// (BSD-style licensing, direct-link approved per LIBRARIES.md sections 1-2
// and 25). No archive types leak through this interface.
//
// Availability: when the build lacks HAVE_LIBARCHIVE (headers absent at
// compile time), every method returns an explicit unavailable result - nil
// from identification and NO from +isAvailable. This is a definite "not
// compiled in" state, never a guess about the runtime environment.
@interface DUArchiveLibrary : NSObject

// YES only when this build was linked against libarchive.
+ (BOOL)isAvailable;

// Identifies the archive/image format at |path| (regular files only; opened
// strictly read-only). Returns kDUArchiveFormat ("iso9660", "zip", "tar",
// "cpio", "7zip", ...) as reported by libarchive, and kDUArchiveEntryCount
// (NSNumber) counting leading entries up to kDUArchiveEntryCountCap.
//
// Returns nil when unavailable, when |path| is missing/empty, or when the
// content is not a recognized archive format.
+ (nullable NSDictionary *)identifyPath:(NSString *)path;

@end

NS_ASSUME_NONNULL_END
