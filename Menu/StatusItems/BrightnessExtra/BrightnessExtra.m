/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "BrightnessExtra.h"
#import "SysfsBacklightBackend.h"

@implementation BrightnessExtra
{
    NSTimer *_timer;
    SysfsBacklightBackend *_backend;
    int _current;
    int _maximum;
}

- (void)dealloc
{
    [self menuExtraWillUnload];
}

- (void)updateBrightness
{
    _current = [_backend current];
    _maximum = [_backend maximum];
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
    return nil;
}

- (NSString *)title
{
    return [NSString stringWithFormat:@"Br %d%%", [self percent]];
}

- (void)brightnessChanged:(NSNotification *)n
{
    (void)n;
    [self updateBrightness];
}

- (void)menuExtraDidLoad
{
    _backend = [[SysfsBacklightBackend alloc] init];
    [self updateBrightness];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(brightnessChanged:)
                                                 name:@"BrightnessChanged"
                                               object:nil];
    _timer = [NSTimer scheduledTimerWithTimeInterval:5.0
                                              target:self
                                            selector:@selector(updateBrightness)
                                            userInfo:nil
                                             repeats:YES];
}

- (void)menuExtraWillUnload
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_timer invalidate];
    _timer = nil;
    _backend = nil;
}

#pragma mark - Actions

- (void)brightnessUp:(id)sender
{
    (void)sender;
    int step = (_maximum > 20) ? (_maximum / 20) : 1;
    [_backend set:(_current + step)];
    [self updateBrightness];
}

- (void)brightnessDown:(id)sender
{
    (void)sender;
    int step = (_maximum > 20) ? (_maximum / 20) : 1;
    [_backend set:(_current - step)];
    [self updateBrightness];
}

@end
