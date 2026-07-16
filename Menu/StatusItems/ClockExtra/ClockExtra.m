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
    BOOL _showDate;
}

+ (void)initialize
{
    if (self == [ClockExtra class]) {
        // Show date + time by default
        [[NSUserDefaults standardUserDefaults] registerDefaults:@{
            @"ClockExtraShowDate": @YES
        }];
    }
}

- (void)dealloc
{
    [self menuExtraWillUnload];
}

- (void)toggleShowDate:(id)sender
{
    (void)sender;
    _showDate = !_showDate;
    [[NSUserDefaults standardUserDefaults] setBool:_showDate forKey:@"ClockExtraShowDate"];
}

- (NSMenu *)menu
{
    NSMenu *m = [[NSMenu alloc] initWithTitle:@"Clock"];

    NSMenuItem *dateItem = [[NSMenuItem alloc] initWithTitle:@"Show Date"
                                                       action:@selector(toggleShowDate:)
                                                keyEquivalent:@""];
    [dateItem setTarget:self];
    [dateItem setState:_showDate ? NSOnState : NSOffState];
    [m addItem:dateItem];

    return m;
}

- (NSImage *)image
{
    return [NSImage imageNamed:@"clock"];
}

- (NSString *)title
{
    if (!_timeFormatter) {
        _timeFormatter = [[NSDateFormatter alloc] init];
        [_timeFormatter setTimeStyle:NSDateFormatterShortStyle];
        [_timeFormatter setDateStyle:NSDateFormatterNoStyle];
    }
    if (!_dateFormatter) {
        _dateFormatter = [[NSDateFormatter alloc] init];
        [_dateFormatter setTimeStyle:NSDateFormatterNoStyle];
        [_dateFormatter setDateStyle:NSDateFormatterShortStyle];
    }
    if (_showDate) {
        return [NSString stringWithFormat:@"%@ %@",
                [_dateFormatter stringFromDate:[NSDate date]],
                [_timeFormatter stringFromDate:[NSDate date]]];
    }
    return [_timeFormatter stringFromDate:[NSDate date]];
}

- (void)menuExtraDidLoad
{
    _showDate = [[NSUserDefaults standardUserDefaults] boolForKey:@"ClockExtraShowDate"];

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
