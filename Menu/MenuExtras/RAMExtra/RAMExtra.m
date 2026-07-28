/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "RAMExtra.h"
#import "GSMenuExtraContext.h"

#import <stdio.h>
#import <stdlib.h>
#import <string.h>

#ifdef __FreeBSD__
#include <sys/types.h>
#include <sys/sysctl.h>
#endif

@implementation RAMExtra
{
    BOOL _running;
    double _ramUsage;
    unsigned long long _memTotal;
    unsigned long long _memUsed;
    GSMenuExtraContext *_context;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _running = NO;
        _ramUsage = 0.0;
        _memTotal = 0;
        _memUsed = 0;
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
    NSMenu *m = [[NSMenu alloc] initWithTitle:@"RAM"];

    NSString *label = [NSString stringWithFormat:@"RAM: %.0f%%", _ramUsage];
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:label action:nil keyEquivalent:@""];
    [item setEnabled:NO];
    [m addItem:item];

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
        [m addItem:detailItem];
    }

    return m;
}

- (NSImage *)image
{
    return [NSImage imageNamed:@"ram"];
}

- (NSString *)title
{
    return [NSString stringWithFormat:@"%.0f%%", _ramUsage];
}

- (CGFloat)preferredWidth
{
    NSFont *font = [NSFont menuBarFontOfSize:0];
    NSSize size = [@"00%" sizeWithAttributes:@{ NSFontAttributeName: font }];
    return (CGFloat)((int)(size.width + 0.999)) + 8.0;
}

- (void)setContext:(GSMenuExtraContext *)context
{
    _context = context;
}

- (void)menuExtraDidLoad
{
    @try {
        _running = YES;
        [self updateRAMUsage];
    } @catch (NSException *e) {
        NSLog(@"RAMExtra: exception in menuExtraDidLoad: %@", e);
        _running = NO;
    }
}

- (void)menuExtraWillUnload
{
    _running = NO;
}

- (void)tick
{
    @try {
        if (!_running) return;
        [self updateRAMUsage];
        [_context invalidatePresentation];
    } @catch (NSException *e) {
        NSLog(@"RAMExtra: exception in tick: %@", e);
    }
}

#pragma mark - Platform-specific

#ifdef __linux__

- (void)updateRAMUsage
{
    if (!_running) return;
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
    if (!_running) return;
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
    if (!_running) return;
    _ramUsage = 0.0;
}

#endif

@end
