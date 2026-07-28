/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "RAMExtra.h"
#import "GSMenuExtraContext.h"
#import <stdio.h>
#import <string.h>
#import <stdlib.h>

@implementation RAMExtra
{
    NSTimer *_timer;
    int _percent;
    unsigned long long _totalMB;
    unsigned long long _usedMB;
    GSMenuExtraContext *_context;
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

    NSString *detail = [NSString stringWithFormat:@"%llu MB / %llu MB used",
                         _usedMB, _totalMB];
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:detail action:nil keyEquivalent:@""];
    [item setEnabled:NO];
    [m addItem:item];

    return m;
}

- (NSImage *)image
{
    return nil;
}

- (NSString *)title
{
    if (_percent >= 0)
        return [NSString stringWithFormat:@"RAM %d%%", _percent];
    return @"RAM --%";
}

- (void)setContext:(GSMenuExtraContext *)context
{
    _context = context;
}

- (void)menuExtraDidLoad
{
    _percent = -1;
    [self readRAM];
    _timer = [NSTimer scheduledTimerWithTimeInterval:5.0
                                              target:self
                                            selector:@selector(refresh:)
                                            userInfo:nil
                                             repeats:YES];
}

- (void)menuExtraWillUnload
{
    [_timer invalidate];
    _timer = nil;
}

- (void)refresh:(NSTimer *)timer
{
    (void)timer;
    [self readRAM];
    [_context invalidatePresentation];
}

- (void)readRAM
{
#ifdef __linux__
    FILE *fp = fopen("/proc/meminfo", "r");
    if (!fp) return;

    unsigned long long total = 0, free = 0, buffers = 0, cached = 0;
    char line[256];

    while (fgets(line, sizeof(line), fp)) {
        if (strncmp(line, "MemTotal:", 9) == 0)
            sscanf(line, "MemTotal: %llu", &total);
        else if (strncmp(line, "MemFree:", 8) == 0)
            sscanf(line, "MemFree: %llu", &free);
        else if (strncmp(line, "Buffers:", 8) == 0)
            sscanf(line, "Buffers: %llu", &buffers);
        else if (strncmp(line, "Cached:", 7) == 0)
            sscanf(line, "Cached: %llu", &cached);
    }
    fclose(fp);

    if (total > 0) {
        unsigned long long available = free + buffers + cached;
        if (available > total)
            available = total;
        _percent = (int)((total - available) * 100 / total);
        _totalMB = total / 1024;
        _usedMB = (total - available) / 1024;
    }
#else
    // BSD: use sysctl
    _percent = 0;
#endif
}

@end
