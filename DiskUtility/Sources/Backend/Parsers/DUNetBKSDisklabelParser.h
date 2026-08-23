/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import "DUPartitionTableParser.h"

// Parses NetBSD `disklabel <disk>` output (LC_ALL=C).
//
// NetBSD's printed label uses the same grammar as the OpenBSD one: geometry
// attributes ("bytes/sector:", "sectors/unit:" / "total sectors:") followed
// by a "<N> partitions:" marker and rows "[letter]: size offset fstype
// [fsize bsize cpg/sgs] # /mountpoint". The output contract is therefore
// identical to DUOpenBSDDisklabelParser (same kDisklabelKey* keys from
// DUPartitionTableParser.h), and parsing delegates to that shared engine so
// grammar fixes land in exactly one place.
//
// Returns nil when the input contains no partition table section.
@interface DUNetBKSDisklabelParser : NSObject

+ (NSDictionary<NSString *, id> *)parseDisklabelOutput:(NSString *)output;

@end
