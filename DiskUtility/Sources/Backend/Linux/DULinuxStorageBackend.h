/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#if defined(__linux__)

#import "DUStorageBackend.h"

// Linux implementation of the storage backend contract (ARCHITECTURE.md
// section 19). All platform specifics stay here: the UI only ever sees
// domain objects and structured errors.
//
// Threading: every protocol method with a completion block runs its work on
// a dedicated worker thread and invokes progress/completion there; callers
// marshal to the main thread themselves. Synchronous methods (discovery)
// block the calling thread and must be called from a background context.
@interface DULinuxStorageBackend : NSObject <DUStorageBackend>

// mdadm-based set creation; returns nil on success. Exposed directly because
// the pinned protocol carries no RAID verb (see PLAN.md deviations note).
- (NSError *)createRAIDSetNamed:(NSString *)name
                          level:(NSString *)level
                        members:(NSArray<NSString *> *)memberPaths;

@end

#endif /* defined(__linux__) */
