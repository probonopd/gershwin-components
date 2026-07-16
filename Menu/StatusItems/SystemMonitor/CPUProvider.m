/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "CPUProvider.h"
#import <stdio.h>
#import <stdlib.h>
#import <string.h>

#ifdef __linux__
#include <unistd.h>
#endif

#ifdef __FreeBSD__
#include <sys/types.h>
#include <sys/sysctl.h>
#include <sys/resource.h>
#include <vm/vm_param.h>
#endif

@implementation CPUProvider

- (instancetype)init
{
    self = [super init];
    if (self) {
        _cpuUsage = 0.0;
        _perCoreCPU = [NSMutableArray array];
        _lastTotalTicks = 0;
        _lastIdleTicks = 0;
        _cachedFixedWidth = 0.0;
    }
    return self;
}

- (NSString *)identifier
{
    return @"org.gershwin.menu.statusitem.cpu";
}

- (NSString *)title
{
    return [NSString stringWithFormat:@"%.0f%%", _cpuUsage];
}

- (CGFloat)width
{
    return _cachedFixedWidth;
}

- (NSInteger)displayPriority
{
    return 1;
}

- (NSTimeInterval)updateInterval
{
    return 1.0;
}

- (NSImage *)icon
{
    return [NSImage imageNamed:@"cpu"];
}

- (void)loadWithManager:(id)manager
{
    (void)manager;
    _detailMenu = [[NSMenu alloc] initWithTitle:@"CPU"];
    [_detailMenu setAutoenablesItems:NO];

    NSFont *font = [NSFont menuBarFontOfSize:0];
    NSDictionary *attrs = @{ NSFontAttributeName: font };
    NSSize size = [@"100%" sizeWithAttributes:attrs];
    _cachedFixedWidth = ceil(size.width) + 16.0;

    [self updateCPUUsage];
    [self updateDetailMenu];

    _timer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                              target:self
                                            selector:@selector(tick)
                                            userInfo:nil
                                             repeats:YES];
}

- (void)tick
{
    [self updateCPUUsage];
    [self updateDetailMenu];
}

- (void)handleClick {}
- (NSMenu *)menu { return _detailMenu; }

- (void)unload
{
    [_timer invalidate];
    _timer = nil;
    _detailMenu = nil;
    _perCoreCPU = nil;
}

#pragma mark - Platform-specific

#ifdef __linux__

- (void)updateCPUUsage
{
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
    _cpuUsage = 0.0;
}

#endif

- (void)updateDetailMenu
{
    [_detailMenu removeAllItems];

    NSMenuItem *total = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"CPU: %.0f%%", _cpuUsage]
                                                   action:nil keyEquivalent:@""];
    [total setEnabled:NO];
    [_detailMenu addItem:total];

    for (NSUInteger i = 0; i < [_perCoreCPU count]; i++) {
        double usage = [[_perCoreCPU objectAtIndex:i] doubleValue];
        NSMenuItem *core = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"Core %lu: %.0f%%", (unsigned long)i, usage]
                                                      action:nil keyEquivalent:@""];
        [core setEnabled:NO];
        [_detailMenu addItem:core];
    }
}

@end
