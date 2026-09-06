/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

@class DUStorageManager;

// Periodic topology poller (ARCHITECTURE.md section 64). Native event
// mechanisms differ per kernel and none is exposed uniformly to us yet, so
// the conservative fallback is a configurable, low-frequency refresh; each
// tick does its work on a background thread so the run loop never blocks.
@interface DUDeviceMonitor : NSObject

@property (nonatomic, strong, readonly) DUStorageManager *storageManager;
@property (nonatomic, readonly) NSTimeInterval interval;

- (instancetype)initWithStorageManager:(DUStorageManager *)storageManager
    NS_DESIGNATED_INITIALIZER;

// Starts polling. The timer lives on the calling thread's run loop, so call
// -start from a thread that runs one (the main thread in practice).
- (void)start;

- (void)stop;

@end
