/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "ClockExtra.h"
#import "GSMenuExtraContext.h"
#import <time.h>


@implementation ClockExtra
{
    char _timeStr[64];
    NSDateFormatter *_timeFormatter;
    NSDateFormatter *_dateFormatter;
    NSMenuItem *_dateItem;
    GSMenuExtraContext *_context;
    BOOL _running;
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
    NSMenu *m = [[NSMenu alloc] initWithTitle:@"Clock"];

    _dateItem = [[NSMenuItem alloc] initWithTitle:[_dateFormatter stringFromDate:[NSDate date]]
                                           action:nil keyEquivalent:@""];
    [_dateItem setEnabled:NO];
    [m addItem:_dateItem];

    return m;
}

- (NSImage *)image
{
    return nil;
}

- (NSString *)title
{
    time_t now = time(NULL);
    struct tm *lt = localtime(&now);
    if (lt) {
        strftime(_timeStr, sizeof(_timeStr), "%H:%M", lt);
    } else {
        strncpy(_timeStr, "??:??", sizeof(_timeStr) - 1);
        _timeStr[sizeof(_timeStr) - 1] = '\0';
    }
    return [NSString stringWithUTF8String:_timeStr];
}

- (void)setContext:(GSMenuExtraContext *)context
{
    _context = context;
}

- (void)menuExtraWillOpenMenu
{
    [_dateItem setTitle:[_dateFormatter stringFromDate:[NSDate date]]];
}

- (void)menuExtraDidLoad
{
    @try {
        _running = YES;
        _timeFormatter = [[NSDateFormatter alloc] init];
        [_timeFormatter setTimeStyle:NSDateFormatterShortStyle];
        [_timeFormatter setDateStyle:NSDateFormatterNoStyle];

        _dateFormatter = [[NSDateFormatter alloc] init];
        [_dateFormatter setTimeStyle:NSDateFormatterNoStyle];
        [_dateFormatter setDateStyle:NSDateFormatterFullStyle];
    } @catch (NSException *e) {
        NSLog(@"ClockExtra: exception in menuExtraDidLoad: %@", e);
        _running = NO;
        _timeFormatter = nil;
        _dateFormatter = nil;
        _dateItem = nil;
        _context = nil;
    }
}

- (void)menuExtraWillUnload
{
    _running = NO;
}

- (void)refresh:(NSTimer *)timer
{
    @try {
        if (!_running) return;
        (void)timer;
        [_context invalidatePresentation];
    } @catch (NSException *e) {
        NSLog(@"ClockExtra: exception in refresh:: %@", e);
    }
}

- (void)refreshMenuItems:(NSMenu *)submenu
{
    if ([submenu numberOfItems] > 0) {
        NSMenuItem *item = [submenu itemAtIndex:0];
        [item setTitle:[_dateFormatter stringFromDate:[NSDate date]]];
    }
}

@end
