/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#if defined(__OpenBSD__)

#import <Foundation/Foundation.h>

@class DUStorageObject;

// Cached executable lookup shared by every OpenBSD backend class. Presence
// checks hit the filesystem once per tool name and then serve from a
// lock-guarded dictionary, so capability filling stays cheap across rescans.
// No GCD: an NSLock serializes the rare cache misses.
@interface DUOpenBSDToolCache : NSObject

// Absolute path of the tool in the fixed search directories, or nil when
// absent. Negative results are cached too.
+ (NSString *)pathForTool:(NSString *)toolName;

+ (BOOL)haveTool:(NSString *)toolName;

@end

// Builds the storage object tree from OpenBSD tool output: boot dmesg lines
// ("sd0 at scsibus0 targ ...") plus `sysctl -n hw.disknames` enumerate the
// disk names, `disklabel <name>` provides geometry and partition rows for
// each of them, the mount(8) -p table plus statvfs carry live volume state,
// and /dev/cd0* node presence reports optical drives.
//
// Threading: discovery BLOCKS while tools run and must be called from a
// background thread (ARCHITECTURE.md section 53).
@interface DUOpenBSDDeviceDiscovery : NSObject

// Returns root objects (disks and optical drives); empty array on a machine
// without disks. Returns nil + error only when neither sysctl nor dmesg is
// usable at all.
- (NSArray<DUStorageObject *> *)discoverObjects:(NSError **)error;

// One mount(8) -p snapshot: device path (and bare node name) mapped to a
// dictionary with "mountPoint" and "fstype". Entries mounted through a DUID
// rather than a /dev/<name><letter> path are not listed under any letter
// node; their volumes show as unmounted instead of being guessed.
+ (NSDictionary<NSString *, NSDictionary *> *)currentMountTable;

@end

#endif /* defined(__OpenBSD__) */
