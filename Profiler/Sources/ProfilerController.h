/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

@interface ProfilerController : NSObject
@property (nonatomic, readonly) BOOL running;
- (void)startPerfForExecutable:(NSString *)executable;
- (void)startHeaptrackForPID:(pid_t)pid;
- (void)stop;
@end
