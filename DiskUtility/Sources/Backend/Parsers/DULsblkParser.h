/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

// Parses the output of:
//
//   lsblk -P -b -o NAME,PKNAME,PATH,TYPE,SIZE,FSTYPE,MOUNTPOINT,LABEL,
//             PARTUUID,UUID,MODEL,RO,RM,HOTPLUG,MAJ:MIN
//
// Input is one line of KEY="value" pairs per device; run under LC_ALL=C.
// lsblk emits empty strings ("") for columns that do not apply to a device;
// such values are dropped, so every key below is OPTIONAL in a result
// dictionary and never maps to an empty string.
//
// Result keys (values in parentheses):
//
//   kLsblkKeyName        Kernel device name without /dev prefix (NSString),
//                        e.g. "sda1".
//   kLsblkKeyParentName  Parent kernel name from PKNAME (NSString), e.g.
//                        "sda" for a partition. Absent for whole disks and
//                        other top-level devices.
//   kLsblkKeyPath        Preferred device path (NSString), e.g. "/dev/sda1".
//   kLsblkKeyType        Device kind as reported by lsblk (NSString):
//                        "disk", "part", "rom", "loop", ...
//   kLsblkKeySizeBytes   Device size in bytes (NSNumber). The SIZE column is
//                        plain bytes because of the -b flag.
//   kLsblkKeyFstype      Filesystem identifier (NSString), e.g. "ext4",
//                        "vfat", "swap". Absent when unformatted/unknown.
//   kLsblkKeyMountPoint  Current mount point (NSString). Absent when not
//                        mounted.
//   kLsblkKeyLabel       Filesystem label (NSString).
//   kLsblkKeyPartUUID    Partition UUID (NSString).
//   kLsblkKeyUUID        Filesystem UUID (NSString).
//   kLsblkKeyModel       Device model string (NSString).
//   kLsblkKeyReadOnly    Read-only flag from RO (NSNumber bool).
//   kLsblkKeyRemovable   Removable-media flag from RM (NSNumber bool).
//   kLsblkKeyHotplug     Hotplug flag from HOTPLUG (NSNumber bool).
//   kLsblkKeyMajorMinor  Raw "major:minor" pair from MAJ:MIN (NSString),
//                        e.g. "8:1".
// Stable dictionary keys emitted by parsePairsOutput: (see mapping table
// above); exported so backend code can consume rows without re-declaring.
extern NSString * const kLsblkKeyName;
extern NSString * const kLsblkKeyParentName;
extern NSString * const kLsblkKeyPath;
extern NSString * const kLsblkKeyType;
extern NSString * const kLsblkKeySizeBytes;
extern NSString * const kLsblkKeyFstype;
extern NSString * const kLsblkKeyMountPoint;
extern NSString * const kLsblkKeyLabel;
extern NSString * const kLsblkKeyPartUUID;
extern NSString * const kLsblkKeyUUID;
extern NSString * const kLsblkKeyModel;
extern NSString * const kLsblkKeyReadOnly;
extern NSString * const kLsblkKeyRemovable;
extern NSString * const kLsblkKeyHotplug;
extern NSString * const kLsblkKeyMajorMinor;

@interface DULsblkParser : NSObject

// Returns one dictionary per input line/device, in input order.
// Unrecognized lines are skipped; nil or empty input yields an empty array.
+ (NSArray<NSDictionary<NSString *, id> *> *)parsePairsOutput:(NSString *)output;

@end
