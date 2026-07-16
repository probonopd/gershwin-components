/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "RAMProvider.h"
#import <stdio.h>
#import <stdlib.h>
#import <string.h>

#ifdef __FreeBSD__
#include <sys/types.h>
#include <sys/sysctl.h>
#endif

@implementation RAMProvider

- (instancetype)init
{
    self = [super init];
    if (self) {
        _ramUsage = 0.0;
        _memTotal = 0;
        _memUsed = 0;
        _cachedFixedWidth = 0.0;
    }
    return self;
}

- (NSString *)identifier
{
    return @"org.gershwin.menu.statusitem.ram";
}

- (NSString *)title
{
    return [NSString stringWithFormat:@"%.0f%%", _ramUsage];
}

- (CGFloat)width
{
    return _cachedFixedWidth;
}

- (NSInteger)displayPriority
{
    return 2;
}

- (NSTimeInterval)updateInterval
{
    return 2.0;
}

- (NSImage *)icon
{
    return [NSImage imageNamed:@"ram"];
}

- (void)loadWithManager:(id)manager
{
    (void)manager;
    _detailMenu = [[NSMenu alloc] initWithTitle:@"RAM"];
    [_detailMenu setAutoenablesItems:NO];

    NSFont *font = [NSFont menuBarFontOfSize:0];
    NSDictionary *attrs = @{ NSFontAttributeName: font };
    NSSize size = [@"100%" sizeWithAttributes:attrs];
    _cachedFixedWidth = ceil(size.width) + 16.0;

    [self updateRAMUsage];
    [self updateDetailMenu];

    _timer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                              target:self
                                            selector:@selector(tick)
                                            userInfo:nil
                                             repeats:YES];
}

- (void)tick
{
    [self updateRAMUsage];
    [self updateDetailMenu];
}

- (void)handleClick {}
- (NSMenu *)menu { return _detailMenu; }

- (void)unload
{
    [_timer invalidate];
    _timer = nil;
    _detailMenu = nil;
}

#pragma mark - Platform-specific

#ifdef __linux__

- (void)updateRAMUsage
{
    FILE *fp = fopen("/proc/meminfo", "r");
    if (!fp) return;

    char line[256];
    unsigned long long memTotal = 0, memAvailable = 0;

    while (fgets(line, sizeof(line), fp)) {
        if (sscanf(line, "MemTotal: %llu kB", &memTotal) == 1) continue;
        if (sscanf(line, "MemAvailable: %llu kB", &memAvailable) == 1) break;
    }

    fclose(fp);

    if (memTotal > 0) {
        _memTotal = memTotal;
        _memUsed = memTotal - memAvailable;
        _ramUsage = 100.0 * _memUsed / memTotal;
    }
}

#elif defined(__FreeBSD__)

- (void)updateRAMUsage
{
    size_t size;

    unsigned long memTotal = 0;
    size = sizeof(memTotal);
    if (sysctlbyname("hw.physmem", &memTotal, &size, NULL, 0) != 0) return;

    unsigned int pageSize = 0;
    size = sizeof(pageSize);
    if (sysctlbyname("hw.pagesize", &pageSize, &size, NULL, 0) != 0) return;

    unsigned int freePages = 0;
    size = sizeof(freePages);
    if (sysctlbyname("vm.stats.vm.v_free_count", &freePages, &size, NULL, 0) != 0) return;

    unsigned long memFree = (unsigned long)freePages * pageSize;
    _memTotal = memTotal;
    _memUsed = memTotal - memFree;

    if (_memTotal > 0) {
        _ramUsage = 100.0 * _memUsed / _memTotal;
    }
}

#else

- (void)updateRAMUsage
{
    _ramUsage = 0.0;
}

#endif

- (void)updateDetailMenu
{
    [_detailMenu removeAllItems];

    NSString *label = [NSString stringWithFormat:@"RAM: %.0f%%", _ramUsage];
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:label action:nil keyEquivalent:@""];
    [item setEnabled:NO];
    [_detailMenu addItem:item];

    if (_memTotal > 0) {
        NSString *detail;
        if (_memTotal > 1024 * 1024) {
            detail = [NSString stringWithFormat:@"%.1f / %.1f GB",
                       (double)_memUsed / (1024 * 1024),
                       (double)_memTotal / (1024 * 1024)];
        } else {
            detail = [NSString stringWithFormat:@"%.0f / %.0f MB",
                       (double)_memUsed / 1024,
                       (double)_memTotal / 1024];
        }
        NSMenuItem *detailItem = [[NSMenuItem alloc] initWithTitle:detail action:nil keyEquivalent:@""];
        [detailItem setEnabled:NO];
        [_detailMenu addItem:detailItem];
    }
}

@end
