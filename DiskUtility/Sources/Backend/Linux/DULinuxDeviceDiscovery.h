/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#if defined(__linux__)

#import <Foundation/Foundation.h>

@class DUStorageObject;

// Cached executable lookup shared by every Linux backend adapter. Presence
// checks hit the filesystem once per tool name and then serve from a lock-
// guarded dictionary, so capability filling stays cheap across rescans.
// No GCD: a plain NSLock serializes the rare cache misses.
@interface DULinuxToolCache : NSObject

// Absolute path of the tool resolved from the process PATH (see DUProcessRunner), or nil when
// absent. Negative results are cached too.
+ (NSString *)pathForTool:(NSString *)toolName;

+ (BOOL)haveTool:(NSString *)toolName;

@end

// Builds the storage object tree from Linux tool output (ARCHITECTURE.md
// section 19). Prefers machine-readable lsblk pairs; falls back to a
// minimal /sys/block scan when lsblk is not installed so the app still
// shows the disk inventory on stripped-down systems.
//
// Threading: discovery BLOCKS while tools run and must be called from a
// background thread (ARCHITECTURE.md 53).
@interface DULinuxDeviceDiscovery : NSObject

// Returns root objects (devices and optical drives); empty array on a
// machine without disks, nil + error only when no information source was
// reachable at all.
- (NSArray<DUStorageObject *> *)discoverObjects:(NSError **)error;

@end

#endif /* defined(__linux__) */
