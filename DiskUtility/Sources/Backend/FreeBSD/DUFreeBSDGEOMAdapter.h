/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#if defined(__FreeBSD__)

#import <Foundation/Foundation.h>

// Shared detail key for error dictionaries produced by the FreeBSD backend.
// Carries a trimmed tail of the failing tool's stderr so error sheets can
// show why a command failed without dumping full transcripts.
extern NSString *const DUFreeBSDBackendDetailKey;

@class DUPartitionPlan;
@class DUStorageObject;

// GEOM(8) adapter shared by discovery and the storage backend. Every method
// is pure output interpretation or a single blocking tool run; no object
// state, so everything lives on class methods.
//
// Threading: all tool-running methods BLOCK; callers must be on background
// threads (ARCHITECTURE.md section 53).
@interface DUFreeBSDGEOMAdapter : NSObject

// Leading byte count of geom size strings such as "536870912 (512M)";
// 0 when the token carries no leading integer.
+ (unsigned long long)bytesFromGeomSizeToken:(NSString *)token;

// Runs `geom <class> list [name]` and parses it into one provider
// dictionary per block (DUFreeBSDGEOMParser contract). Returns nil with
// *error set when geom is missing or the run fails; an empty array means
// the class simply has no providers.
+ (NSArray<NSDictionary<NSString *, id> *> *)listClass:(NSString *)className
                                                 name:(NSString *)providerName
                                                error:(NSError **)error;

// Parses mount(8) table output into dictionaries keyed by device node
// ("/dev/ada0p2"), each holding "mountPoint" and "fstype" strings.
+ (NSDictionary<NSString *, NSDictionary *> *)mountedVolumesFromOutput:
        (NSString *)output;

// Live mount table via the mount(8) tool; nil when mount is missing.
+ (NSDictionary<NSString *, NSDictionary *> *)currentMountTable;

// Maps a raw gpart type token ("freebsd-ufs", "fat32", "!11", ...) to the
// filesystem identifier the rest of the app speaks ("ufs", "msdosfs",
// "swap"); nil when the type names no inspectable filesystem.
+ (NSString *)filesystemTokenForPartitionType:(NSString *)rawType;

@end

#endif /* defined(__FreeBSD__) */
