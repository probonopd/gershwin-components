/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "CPUExtra.h"
#import "GSMenuExtraContext.h"

#import <stdio.h>
#import <stdlib.h>
#import <string.h>

#ifdef __FreeBSD__
#include <sys/types.h>
#include <sys/sysctl.h>
#include <sys/resource.h>
#include <vm/vm_param.h>
#endif

@implementation CPUExtra
{
    BOOL _running;
    double _cpuUsage;
    NSMutableArray *_perCoreCPU;
    unsigned long long _lastTotalTicks;
    unsigned long long _lastIdleTicks;
    GSMenuExtraContext *_context;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _running = NO;
        _cpuUsage = 0.0;
        _perCoreCPU = [NSMutableArray array];
        _lastTotalTicks = 0;
        _lastIdleTicks = 0;
    }
    return self;
}

- (void)dealloc
{
    [self menuExtraWillUnload];
#if !__has_feature(objc_arc)
    [super dealloc];
#endif
}

- (NSMenu *)menu
{
    NSMenu *m = [[NSMenu alloc] initWithTitle:@"CPU"];

    NSMenuItem *total = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"CPU: %.0f%%", _cpuUsage]
                                                   action:nil keyEquivalent:@""];
    [total setEnabled:NO];
    [m addItem:total];

    for (NSUInteger i = 0; i < [_perCoreCPU count]; i++) {
        double usage = [[_perCoreCPU objectAtIndex:i] doubleValue];
        NSMenuItem *core = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"Core %lu: %.0f%%", (unsigned long)i, usage]
                                                      action:nil keyEquivalent:@""];
        [core setEnabled:NO];
        [m addItem:core];
    }

    return m;
}

- (NSImage *)image
{
    return [NSImage imageNamed:@"cpu"];
}

- (NSString *)title
{
    return [NSString stringWithFormat:@"%.0f%%", _cpuUsage];
}

- (void)setContext:(GSMenuExtraContext *)context
{
    _context = context;
}

- (void)menuExtraDidLoad
{
    @try {
        _running = YES;
        if (!_perCoreCPU) _perCoreCPU = [NSMutableArray array];
        _lastTotalTicks = 0;
        _lastIdleTicks = 0;
        [self updateCPUUsage];
    } @catch (NSException *e) {
        NSLog(@"CPUExtra: exception in menuExtraDidLoad: %@", e);
        _running = NO;
    }
}

- (void)menuExtraWillUnload
{
    _running = NO;
    [_perCoreCPU removeAllObjects];
}

- (void)tick
{
    @try {
        if (!_running) return;
        [self updateCPUUsage];
        [_context invalidatePresentation];
    } @catch (NSException *e) {
        NSLog(@"CPUExtra: exception in tick: %@", e);
    }
}

#pragma mark - Platform-specific

#ifdef __linux__

- (void)updateCPUUsage
{
    if (!_running) return;
    FILE *fp = fopen("/proc/stat", "r");
    if (!fp) return;

    char line[256];
    unsigned long long user, nice, system, idle, iowait, irq, softirq, steal;

    if (fgets(line, sizeof(line), fp)) {
        int matches = sscanf(line, "cpu %llu %llu %llu %llu %llu %llu %llu %llu",
                            &user, &nice, &system, &idle, &iowait, &irq, &softirq, &steal);

        if (matches >= 4) {
            unsigned long long total = user + nice + system + idle + iowait + irq + softirq + steal;

            if (_lastTotalTicks > 0) {
                unsigned long long totalDelta = total - _lastTotalTicks;
                unsigned long long idleDelta = idle - _lastIdleTicks;

                if (totalDelta > 0) {
                    _cpuUsage = 100.0 * (1.0 - ((double)idleDelta / (double)totalDelta));
                }
            }

            _lastTotalTicks = total;
            _lastIdleTicks = idle;
        }
    }

    [_perCoreCPU removeAllObjects];
    rewind(fp);

    while (fgets(line, sizeof(line), fp)) {
        if (strncmp(line, "cpu", 3) == 0 && line[3] >= '0' && line[3] <= '9') {
            unsigned long long user, nice, system, idle, iowait, irq, softirq, steal;
            int matches = sscanf(line, "cpu%*d %llu %llu %llu %llu %llu %llu %llu %llu",
                                &user, &nice, &system, &idle, &iowait, &irq, &softirq, &steal);

            if (matches >= 4) {
                unsigned long long total = user + nice + system + idle + iowait + irq + softirq + steal;
                unsigned long long active = total - idle;
                double usage = total > 0 ? (100.0 * active / total) : 0.0;
                [_perCoreCPU addObject:@(usage)];
            }
        }
    }

    fclose(fp);
}

#elif defined(__FreeBSD__)

- (void)updateCPUUsage
{
    if (!_running) return;
    long cp_time[5];
    size_t size = sizeof(cp_time);

    if (sysctlbyname("kern.cp_time", &cp_time, &size, NULL, 0) == 0) {
        unsigned long long user = cp_time[0];
        unsigned long long nice = cp_time[1];
        unsigned long long system = cp_time[2];
        unsigned long long idle = cp_time[4];
        unsigned long long total = user + nice + system + idle;

        if (_lastTotalTicks > 0) {
            unsigned long long totalDelta = total - _lastTotalTicks;
            unsigned long long idleDelta = idle - _lastIdleTicks;

            if (totalDelta > 0) {
                _cpuUsage = 100.0 * (1.0 - ((double)idleDelta / (double)totalDelta));
            }
        }

        _lastTotalTicks = total;
        _lastIdleTicks = idle;
    }

    [_perCoreCPU removeAllObjects];
}

#else

- (void)updateCPUUsage
{
    if (!_running) return;
    _cpuUsage = 0.0;
}

#endif

@end
