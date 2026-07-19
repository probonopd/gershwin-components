/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "BrightnessExtra.h"
#import "GSMenuExtraContext.h"
#import "SysfsBacklightBackend.h"

static const BOOL kShowTextInMenuBar = NO;

@implementation BrightnessExtra
{
    NSTimer *_timer;
    SysfsBacklightBackend *_backend;
    int _current;
    int _maximum;
    GSMenuExtraContext *_context;
}

- (void)dealloc
{
    [self menuExtraWillUnload];
#if !__has_feature(objc_arc)
    [super dealloc];
#endif
}

- (void)updateBrightness
{
    _current = [_backend current];
    _maximum = [_backend maximum];
}

- (void)refreshBrightnessPresentation
{
    int oldCurrent = _current;
    int oldMaximum = _maximum;

    [self updateBrightness];
    if (oldCurrent != _current || oldMaximum != _maximum) {
        [_context invalidatePresentation];
    }
}

- (int)percent
{
    if (_maximum <= 0) return 0;
    return (int)((float)_current / (float)_maximum * 100.0f);
}

#pragma mark - GSMenuExtra

- (NSMenu *)menu
{
    NSMenu *m = [[NSMenu alloc] initWithTitle:@"Brightness"];

    int pct = [self percent];
    NSString *label = [NSString stringWithFormat:@"Brightness %d%%", pct];
    NSMenuItem *labelItem = [[NSMenuItem alloc] initWithTitle:label
                                                       action:NULL
                                                keyEquivalent:@""];
    [labelItem setEnabled:NO];
    [m addItem:labelItem];

    [m addItem:[NSMenuItem separatorItem]];

    NSMenuItem *up = [[NSMenuItem alloc] initWithTitle:@"Increase"
                                                action:@selector(brightnessUp:)
                                         keyEquivalent:@""];
    [up setTarget:self];
    [m addItem:up];

    NSMenuItem *dn = [[NSMenuItem alloc] initWithTitle:@"Decrease"
                                                action:@selector(brightnessDown:)
                                         keyEquivalent:@""];
    [dn setTarget:self];
    [m addItem:dn];

    return m;
}

- (NSImage *)image
{
    return [NSImage imageNamed:@"brightness"];
}

- (NSString *)title
{
    if (!kShowTextInMenuBar) return @"";
    return [NSString stringWithFormat:@"%d%%", [self percent]];
}

- (void)setContext:(GSMenuExtraContext *)context
{
    _context = context;
}

- (void)brightnessChanged:(NSNotification *)n
{
    (void)n;
    [self refreshBrightnessPresentation];
}

- (void)menuExtraDidLoad
{
    _backend = [[SysfsBacklightBackend alloc] init];
    [self refreshBrightnessPresentation];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                            selector:@selector(brightnessChanged:)
                                                 name:@"BrightnessChanged"
                                               object:nil];
    _timer = [NSTimer scheduledTimerWithTimeInterval:5.0
                                             target:self
                                            selector:@selector(refreshTimerFired:)
                                            userInfo:nil
                                            repeats:YES];
}

- (void)menuExtraWillOpenMenu
{
    [self refreshBrightnessPresentation];
}

- (void)menuExtraWillUnload
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_timer invalidate];
    _timer = nil;
    _backend = nil;
}

- (void)refreshTimerFired:(NSTimer *)timer
{
    (void)timer;
    [self refreshBrightnessPresentation];
}

- (void)refreshMenuItems:(NSMenu *)submenu
{
    if ([submenu numberOfItems] > 0) {
        NSMenuItem *item = [submenu itemAtIndex:0];
        [item setTitle:[NSString stringWithFormat:@"Brightness %d%%", [self percent]]];
    }
}

#pragma mark - Actions

- (void)brightnessUp:(id)sender
{
    (void)sender;
    int step = (_maximum > 20) ? (_maximum / 20) : 1;
    [_backend set:(_current + step)];
    [self refreshBrightnessPresentation];
}

- (void)brightnessDown:(id)sender
{
    (void)sender;
    int step = (_maximum > 20) ? (_maximum / 20) : 1;
    [_backend set:(_current - step)];
    [self refreshBrightnessPresentation];
}

@end
