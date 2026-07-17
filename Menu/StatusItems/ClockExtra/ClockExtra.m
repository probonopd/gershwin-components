/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "ClockExtra.h"

@implementation ClockExtra
{
    NSTimer *_timer;
    NSDateFormatter *_timeFormatter;
    NSDateFormatter *_dateFormatter;
    NSMenuItem *_dateItem;
}

- (void)dealloc
{
    [self menuExtraWillUnload];
}

- (NSMenu *)menu
{
    NSMenu *m = [[NSMenu alloc] initWithTitle:@"Clock"];

    _dateItem = [[NSMenuItem alloc] initWithTitle:[_dateFormatter stringFromDate:[NSDate date]]
                                           action:nil keyEquivalent:@""];
    [_dateItem setEnabled:NO];
    [m addItem:_dateItem];

    return m;
}

- (NSImage *)image
{
    return [NSImage imageNamed:@"clock"];
}

- (NSString *)title
{
    return [_timeFormatter stringFromDate:[NSDate date]];
}

- (void)menuExtraWillOpenMenu
{
    [_dateItem setTitle:[_dateFormatter stringFromDate:[NSDate date]]];
}

- (void)menuExtraDidLoad
{
    _timeFormatter = [[NSDateFormatter alloc] init];
    [_timeFormatter setTimeStyle:NSDateFormatterShortStyle];
    [_timeFormatter setDateStyle:NSDateFormatterNoStyle];

    _dateFormatter = [[NSDateFormatter alloc] init];
    [_dateFormatter setTimeStyle:NSDateFormatterNoStyle];
    [_dateFormatter setDateStyle:NSDateFormatterShortStyle];

    _timer = [NSTimer scheduledTimerWithTimeInterval:60.0
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
}

@end
