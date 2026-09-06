/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "ProfilerController.h"

@implementation ProfilerController
{
    NSTask *_task;
    BOOL _running;
}

- (BOOL)running { return _running; }

- (void)startTaskWithLaunchPath:(NSString *)path
                      arguments:(NSArray *)arguments
{
    [self stop];

    _task = [[NSTask alloc] init];
    _task.launchPath = path;
    _task.arguments = arguments;

    NSPipe *pipe = [NSPipe pipe];
    _task.standardOutput = pipe;
    _task.standardError = pipe;

    @try {
        [_task launch];
        _running = YES;
    } @catch (NSException *e) {
        NSLog(@"Unable to launch %@: %@", path, e);
        [_task release];
        _task = nil;
    }
}

- (void)startPerfForExecutable:(NSString *)executable
{
    NSString *output = [NSTemporaryDirectory() stringByAppendingPathComponent:@"gnustep-profiler-perf.data"];
    [self startTaskWithLaunchPath:@"/usr/bin/perf"
                         arguments:@[@"record", @"-F", @"99",
                                     @"--call-graph", @"dwarf",
                                     @"-o", output, @"--", executable]];
}

- (void)startHeaptrackForPID:(pid_t)pid
{
    NSString *output = [NSTemporaryDirectory() stringByAppendingPathComponent:@"gnustep-profiler-heaptrack.data"];
    [self startTaskWithLaunchPath:@"/usr/bin/heaptrack"
                          arguments:@[@"-p", [NSString stringWithFormat:@"%d", pid],
                                      @"-o", output]];
}

- (void)stop
{
    if (_task && [_task isRunning])
        [_task terminate];
    [_task release];
    _task = nil;
    _running = NO;
}

- (void)dealloc
{
    [self stop];
    [super dealloc];
}

@end
