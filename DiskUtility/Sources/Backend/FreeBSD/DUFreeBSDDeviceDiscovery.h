/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#if defined(__FreeBSD__)

#import <Foundation/Foundation.h>

@class DUStorageObject;

// Cached executable lookup shared by every FreeBSD backend class. Presence
// checks hit the filesystem once per tool name and then serve from a
// lock-guarded dictionary, so capability filling stays cheap across rescans.
// No GCD: an NSLock serializes the rare cache misses.
@interface DUFreeBSDToolCache : NSObject

// Absolute path of the tool in the fixed search directories, or nil when
// absent. Negative results are cached too.
+ (NSString *)pathForTool:(NSString *)toolName;

+ (BOOL)haveTool:(NSString *)toolName;

// YES when at least one of the named tools resolves; nil-safe on empty
// input. Capabilities that accept alternative tools probe through this so
// every advertised flag still rests on a runtime-verified binary.
+ (BOOL)haveAnyTool:(NSArray<NSString *> *)toolNames;

@end

// Builds the storage object tree from FreeBSD geom(8) output:
// `geom disk list` for the device roots, `geom part list <disk>` for the
// partition children of each disk, the mount(8) table plus statvfs for live
// volume state, and `geom cd list` (or /dev/cd0 presence) for optical drives.
//
// Threading: discovery BLOCKS while tools run and must be called from a
// background thread (ARCHITECTURE.md section 53).
@interface DUFreeBSDDeviceDiscovery : NSObject

// Returns root objects (disks and optical drives); empty array on a machine
// without disks. Returns nil + error only when geom itself is unusable.
- (NSArray<DUStorageObject *> *)discoverObjects:(NSError **)error;

@end

#endif /* defined(__FreeBSD__) */
