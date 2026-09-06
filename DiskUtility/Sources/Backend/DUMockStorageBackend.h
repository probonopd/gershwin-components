/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

#import "DUStorageBackend.h"

// Fully functional in-memory backend over the artificial hierarchy of
// ARCHITECTURE.md section 56. Simulated delays are short (<=50 ms per step)
// so contract tests stay fast. -restoreHierarchy rebuilds the pristine tree;
// refresh flows call it to bring back ejected objects.
@interface DUMockStorageBackend : NSObject <DUStorageBackend>

- (instancetype)init;

// Stand-in for platforms without a real backend: discovery fails with a
// clear error, capabilitiesReport is all NO, every operation reports
// unsupported (ARCHITECTURE.md 65/66).
+ (instancetype)degradedBackend;

// Current roots; a snapshot copy, safe to read from any thread.
@property (nonatomic, copy, readonly) NSArray<DUStorageObject *> *rootObjects;

- (void)restoreHierarchy;

@end
