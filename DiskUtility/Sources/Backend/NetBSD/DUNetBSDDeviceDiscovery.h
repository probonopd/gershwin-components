/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#if defined(__NetBSD__)

#import <Foundation/Foundation.h>

@class DUStorageObject;

// Cached executable lookup shared by every NetBSD backend class. Presence
// checks hit the filesystem once per tool name and then serve from a
// lock-guarded dictionary, so capability filling stays cheap across rescans.
// No GCD: an NSLock serializes the rare cache misses.
@interface DUNetBSDToolCache : NSObject

// Absolute path of the tool resolved from the process PATH (see DUProcessRunner), or nil when
// absent. Negative results are cached too.
+ (NSString *)pathForTool:(NSString *)toolName;

+ (BOOL)haveTool:(NSString *)toolName;

@end

// Builds the storage object tree from NetBSD tool output: boot dmesg lines
// ("wd0 at atabus0 drive ...", "sd0 at scsibus0 targ ...") plus
// `sysctl -n hw.disknames` enumerate the disk names, `disklabel <name>`
// provides geometry and partition rows for each of them, the mount(8) -p
// table plus statvfs carry live volume state, and /dev/cd0d node presence
// reports optical drives.
//
// Threading: discovery BLOCKS while tools run and must be called from a
// background thread (ARCHITECTURE.md section 53).
@interface DUNetBSDDeviceDiscovery : NSObject

// Returns root objects (disks and optical drives); empty array on a machine
// without disks. Returns nil + error only when neither sysctl nor dmesg is
// usable at all.
- (NSArray<DUStorageObject *> *)discoverObjects:(NSError **)error;

// One mount(8) -p snapshot: device path (and bare node name) mapped to a
// dictionary with "mountPoint" and "fstype". Entries mounted through a
// NAME=label or wedge form rather than /dev/<name><letter> are not listed
// under any letter node; their volumes show as unmounted instead of being
// guessed.
+ (NSDictionary<NSString *, NSDictionary *> *)currentMountTable;

@end

#endif /* defined(__NetBSD__) */
