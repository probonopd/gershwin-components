/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#if defined(__linux__)

#import <Foundation/Foundation.h>

@class DUPartitionPlan;

// Partitioning adapter (ARCHITECTURE.md section 88). Translates a validated
// DUPartitionPlan into sfdisk or parted invocations. All methods BLOCK;
// callers run them on background threads (ARCHITECTURE.md 53).
//
// Tool choice: execution prefers parted because it takes the whole layout as
// argument vectors, which fits the no-shell/no-stdin process policy. The
// sfdisk script rendering stays available (+sfdiskScriptForPlan:) for a
// future runner with stdin support and for unit tests; when only sfdisk is
// installed the script is handed over through a temporary script file.
@interface DULinuxPartitionTool : NSObject

// YES when at least one of parted/sfdisk is installed. Presence of both
// does not guarantee every operation; applyPlan reports precisely.
+ (BOOL)partitioningAvailable;

// Maps plan scheme vocabulary to table labels: "gpt" -> "gpt",
// "mbr"/"dos"/"msdos" -> "msdos" for parted, "dos" for sfdisk scripts.
// Returns nil for anything else so callers can reject early.
+ (NSString *)tableLabelForScheme:(NSString *)scheme;

// Pure text rendering of the plan as an sfdisk stdin-style script. Never
// touches devices; unit-testable without disks (ARCHITECTURE.md section 86).
+ (NSString *)sfdiskScriptForPlan:(DUPartitionPlan *)plan;

// Applies the plan to the device node, then rereads the table (partprobe,
// best-effort). Returns nil on success; failures carry raw tool output in
// the error's kDUBackendDetailKey user info entry.
- (NSError *)applyPlan:(DUPartitionPlan *)plan
          toDevicePath:(NSString *)devicePath
              progress:(void (^)(double progress,
                                 NSString *message))progress;

@end

#endif /* defined(__linux__) */
