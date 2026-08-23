/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

// Shared dictionary keys for the BSD disklabel parsers. DUOpenBSDDisklabelParser
// and DUNetBKSDisklabelParser both emit the exact same output contract so the
// backends can consume either one interchangeably.

// Total number of sectors on the unit (NSNumber, unsigned long long).
extern NSString * const kDisklabelKeyTotalSectors;
// Sector size in bytes (NSNumber); defaults to 512 when the label does not
// report a bytes/sector value.
extern NSString * const kDisklabelKeySectorSize;
// Array of partition dictionaries (NSArray<NSDictionary<NSString *, id> *>),
// one per defined partition letter, in label order.
extern NSString * const kDisklabelKeyPartitions;

// Keys inside each partition dictionary of kDisklabelKeyPartitions:

// Partition letter without the colon, e.g. "a" (NSString).
extern NSString * const kDisklabelKeyLetter;
// Partition extent in BYTES (NSNumber). The label reports sectors; the
// parsers multiply by the reported sector size before emitting.
extern NSString * const kDisklabelKeySizeBytes;
// Start offset in BYTES from the beginning of the device (NSNumber), also
// converted from sectors.
extern NSString * const kDisklabelKeyOffsetBytes;
// Raw fstype token as printed by disklabel, e.g. "4.2BSD", "swap",
// "unused", "MSDOS", "NTFS" (NSString). Not translated.
extern NSString * const kDisklabelKeyFstype;
// Mount point from the trailing "# /usr" comment if present (NSString);
// absent when the row has no mount point comment.
extern NSString * const kDisklabelKeyMountPoint;

// Maps raw partition-table scheme identifiers to display metadata.
// Pure translation helpers - never touch devices and never parse output.
@interface DUPartitionTableParser : NSObject

// Returns a human-readable scheme name: "gpt" -> "GUID Partition Table",
// "mbr" -> "Master Boot Record", "bsd" -> "BSD Disklabel". Unknown schemes
// come back unchanged (trimmed); nil returns nil.
+ (NSString *)displayNameForScheme:(NSString *)scheme;

// Normalizes scheme spelling to a stable token: any of "GPT", "gpt",
// "GUID Partition Table", "GUID_partition_table" -> "gpt"; "MBR", "mbr",
// "dos", "msdos" -> "mbr"; "BSD", "bsd", "disklabel", "BSD disklabel"
// -> "bsd". Unknown input is trimmed and lowercased; nil returns nil.
+ (NSString *)normalizeSchemeToken:(NSString *)token;

// Returns a human-readable name for a filesystem identifier:
// "ext4" -> "Extended filesystem (ext4)", "vfat" -> "FAT", "ufs" -> "UFS",
// "zfs" -> "ZFS", "ntfs" -> "NTFS", "iso9660"/"cd9660" -> "ISO 9660",
// "swap" -> "Swap". nil or empty input returns "-"; unknown tokens are
// returned trimmed so new identifiers stay visible until added to the table.
+ (NSString *)filesystemDisplayName:(NSString *)fstype;

@end
