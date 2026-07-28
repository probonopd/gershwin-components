/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "CPUExtra.h"
#import "GSMenuExtraContext.h"
#import <stdio.h>
#import <string.h>
#import <stdlib.h>

@implementation CPUExtra
{
    NSTimer *_timer;
    unsigned long long _prevUser;
    unsigned long long _prevNice;
    unsigned long long _prevSystem;
    unsigned long long _prevIdle;
    int _percent;
    GSMenuExtraContext *_context;
}

- (NSMenu *)menu
{
    NSMenu *m = [[NSMenu alloc] initWithTitle:@"CPU"];

    NSString *detail = [NSString stringWithFormat:@"CPU Load: %d%%", _percent];
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
        return [NSString stringWithFormat:@"CPU %d%%", _percent];
    return @"CPU --%";
}

- (void)setContext:(GSMenuExtraContext *)context
{
    _context = context;
}

- (void)menuExtraDidLoad
{
    _percent = -1;
    [self readCPU];
    _timer = [NSTimer scheduledTimerWithTimeInterval:3.0
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
    [self readCPU];
    [_context invalidatePresentation];
}

- (void)readCPU
{
#ifdef __linux__
    FILE *fp = fopen("/proc/stat", "r");
    if (!fp) return;

    unsigned long long user, nice, system, idle;
    int ret = fscanf(fp, "cpu %llu %llu %llu %llu",
                     &user, &nice, &system, &idle);
    fclose(fp);

    if (ret != 4) return;

    if (_prevUser + _prevNice + _prevSystem + _prevIdle > 0) {
        unsigned long long prevTotal = _prevUser + _prevNice + _prevSystem + _prevIdle;
        unsigned long long currTotal = user + nice + system + idle;
        unsigned long long totalDelta = currTotal - prevTotal;
        unsigned long long idleDelta = idle - _prevIdle;

        if (totalDelta > 0) {
            _percent = (int)((totalDelta - idleDelta) * 100 / totalDelta);
        }
    }

    _prevUser = user;
    _prevNice = nice;
    _prevSystem = system;
    _prevIdle = idle;
#else
    // BSD: use sysctl for CPU load
    // For now, just return a static value
    _percent = 0;
#endif
}

@end
