/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import "DUPartitionTableParser.h"

// Parses `disklabel <disk>` output (LC_ALL=C). The grammar is shared with
// NetBSD, so this class also serves as the common engine; see
// DUNetBKSDisklabelParser.
//
// Recognized geometry lines:
//
//   bytes/sector: 512        -> kDisklabelKeySectorSize (512 when absent)
//   total sectors: 78165360  -> kDisklabelKeyTotalSectors
//   sectors/unit: 78165360   -> kDisklabelKeyTotalSectors (NetBSD spelling)
//
// Partition rows appear after a "<N> partitions:" marker line:
//
//     a:          2104515             64  4.2BSD     2048 16384    1 # /
//     b:           838656          2104579    swap
//     i:         70960320          7137539   NTFS
//
// Row fields are [letter]: size offset fstype [bracket group] # mountpoint.
// Bracket groups ([fsize bsize cpg], [fsize bsize cpg/sgs]) are ignored;
// sizes and offsets are SECTOR counts and get converted to bytes with the
// reported sector size before being emitted.
//
// Output dictionary (keys from DUPartitionTableParser.h):
//
//   kDisklabelKeyTotalSectors : NSNumber - raw sector count
//   kDisklabelKeySectorSize   : NSNumber - bytes per sector, default 512
//   kDisklabelKeyPartitions   : NSArray of dictionaries with
//       kDisklabelKeyLetter      "a" ... (NSString)
//       kDisklabelKeySizeBytes   NSNumber (bytes)
//       kDisklabelKeyOffsetBytes NSNumber (bytes from device start)
//       kDisklabelKeyFstype      raw token, e.g. "4.2BSD", "swap" (NSString)
//       kDisklabelKeyMountPoint  from "# /usr" comment if present (NSString)
//
// Returns nil when no partition table section is found (i.e. input is not a
// disklabel listing); callers surface that as an error rather than guessing.
@interface DUOpenBSDDisklabelParser : NSObject

+ (NSDictionary<NSString *, id> *)parseDisklabelOutput:(NSString *)output;

@end
