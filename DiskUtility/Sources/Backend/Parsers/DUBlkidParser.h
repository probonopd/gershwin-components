/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

// Parses blkid output in "full" format:
//
//   /dev/sda1: UUID="5374-A3E8" BLOCK_SIZE="512" TYPE="vfat" PARTUUID="..."
//
// and the udev-style variant where the device is itself a token:
//
//   DEVICE="/dev/sda1" UUID="5374-A3E8" TYPE="vfat"
//
// Input is expected to come from a LC_ALL=C run. One input line describes one
// device; empty token values are dropped, so every key below is OPTIONAL.
//
// Result keys:
//
//   kBkidKeyDevice          Device path (NSString), e.g. "/dev/sda1". Comes
//                           from the text before ":" or from DEVICE=.
//   kBkidKeyUuid            Filesystem UUID (NSString).
//   kBkidKeyType            Filesystem identifier (NSString), e.g. "ext4".
//   kBkidKeyLabel           Filesystem label (NSString).
//   kBkidKeyPartUuid        Partition UUID (NSString).
//   kBkidKeyPartLabel       Partition label (NSString).
//   kBkidKeyPartEntryNumber Partition number within the table (NSString, raw).
//
// Tokens not listed above are passed through with their names normalized:
// underscore-separated uppercase words become camelCase starting lowercase,
// so BLOCK_SIZE -> "blockSize", PART_ENTRY_SCHEME -> "partEntryScheme",
// USAGE -> "usage", SEC_TYPE -> "secType". This keeps unknown tokens stable
// and inspectable without hard-coding every blkid version's vocabulary.

// Stable dictionary keys emitted by parseFullOutput: (see table above).
extern NSString * const kBkidKeyDevice;
extern NSString * const kBkidKeyUuid;
extern NSString * const kBkidKeyType;
extern NSString * const kBkidKeyLabel;
extern NSString * const kBkidKeyPartUuid;
extern NSString * const kBkidKeyPartLabel;
extern NSString * const kBkidKeyPartEntryNumber;

@interface DUBlkidParser : NSObject

// Returns one dictionary per device line, in input order. Lines that contain
// no device/pairs are skipped; nil or empty input yields an empty array.
+ (NSArray<NSDictionary<NSString *, id> *> *)parseFullOutput:(NSString *)output;

@end
