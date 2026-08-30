/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

@class ProcessInfo;

@interface ProcessMonitor : NSObject
- (NSArray *)processes;
- (ProcessInfo *)sampleProcess:(pid_t)pid;
- (void)refreshProcessList;
@end
