/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "SoundExtra.h"
#import "SoundVolume.h"

@implementation SoundExtra
{
    NSTimer *_timer;
    float _volume;
    BOOL _muted;
}

- (void)dealloc
{
    [self menuExtraWillUnload];
}

- (void)updateState
{
    _volume = [SoundVolume outputVolume];
    _muted = [SoundVolume isMuted];
}

static NSString *const SoundVolumeChangedNotification = @"SoundVolumeChanged";

- (void)volumeChanged:(NSNotification *)n
{
    (void)n;
    [self updateState];
}

- (NSString *)volumeLabel
{
    int pct = (int)(_volume * 100.0f);
    if (pct < 0) pct = 0;
    if (pct > 100) pct = 100;
    return [NSString stringWithFormat:@"Volume %d%%", pct];
}

#pragma mark - GSMenuExtra

- (NSMenu *)menu
{
    NSMenu *m = [[NSMenu alloc] initWithTitle:@"Sound"];

    NSMenuItem *volItem = [[NSMenuItem alloc] initWithTitle:[self volumeLabel]
                                                      action:NULL
                                               keyEquivalent:@""];
    [volItem setEnabled:NO];
    [m addItem:volItem];

    [m addItem:[NSMenuItem separatorItem]];

    NSMenuItem *muteItem = [[NSMenuItem alloc] initWithTitle:(_muted ? @"Unmute" : @"Mute")
                                                       action:@selector(toggleMute:)
                                                keyEquivalent:@""];
    [muteItem setTarget:self];
    [muteItem setState:_muted ? NSOnState : NSOffState];
    [m addItem:muteItem];

    NSMenuItem *up = [[NSMenuItem alloc] initWithTitle:@"Volume Up"
                                                action:@selector(volUp:)
                                         keyEquivalent:@""];
    [up setTarget:self];
    [m addItem:up];

    NSMenuItem *down = [[NSMenuItem alloc] initWithTitle:@"Volume Down"
                                                  action:@selector(volDown:)
                                           keyEquivalent:@""];
    [down setTarget:self];
    [m addItem:down];

    return m;
}

- (NSImage *)image
{
    return nil;
}

- (NSString *)title
{
    int pct = (int)(_volume * 100.0f);
    if (pct < 0) pct = 0;
    if (pct > 100) pct = 100;
    if (_muted) return [NSString stringWithFormat:@"Muted %d%%", pct];
    return [NSString stringWithFormat:@"Vol %d%%", pct];
}

- (void)menuExtraDidLoad
{
    [self updateState];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(volumeChanged:)
                                                 name:SoundVolumeChangedNotification
                                               object:nil];
    _timer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                              target:self
                                            selector:@selector(updateState)
                                            userInfo:nil
                                             repeats:YES];
}

- (void)menuExtraWillUnload
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_timer invalidate];
    _timer = nil;
}

#pragma mark - Actions

- (void)toggleMute:(id)sender
{
    (void)sender;
    [SoundVolume toggleMute];
    _muted = !_muted;
}

- (void)volUp:(id)sender
{
    (void)sender;
    [SoundVolume increaseVolume];
    [self updateState];
}

- (void)volDown:(id)sender
{
    (void)sender;
    [SoundVolume decreaseVolume];
    [self updateState];
}

@end
