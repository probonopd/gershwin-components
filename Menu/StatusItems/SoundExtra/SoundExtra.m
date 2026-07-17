/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "SoundExtra.h"
#import "ALSABackend.h"
#import "GSMenuExtraContext.h"

static const BOOL kShowTextInMenuBar = NO;

@implementation SoundExtra
{
    float _volume;
    BOOL _muted;
    GSMenuExtraContext *_context;
    ALSABackend *_backend;
}

- (void)dealloc
{
    [self menuExtraWillUnload];
}

- (void)setContext:(GSMenuExtraContext *)context
{
    _context = context;
}

- (void)updateState
{
    float oldVolume = _volume;
    BOOL oldMuted = _muted;
    _volume = [_backend outputVolume];
    _muted = [_backend isOutputMuted];
    NSLog(@"SoundExtra: updateState volume=%.2f muted=%d", _volume, _muted);
    if (oldVolume != _volume || oldMuted != _muted) {
        [_context invalidatePresentation];
    }
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
    NSLog(@"SoundExtra: LAZY LOAD — reading fresh state from backend");
    BOOL muted = [_backend isOutputMuted];
    float vol = [_backend outputVolume];
    NSLog(@"SoundExtra: menu building — backend muted=%d vol=%.2f cached muted=%d vol=%.2f", muted, vol, _muted, _volume);
    int pct = (int)(vol * 100.0f);
    if (pct < 0) pct = 0;
    if (pct > 100) pct = 100;
    NSLog(@"SoundExtra: menu muted=%d volume=%d%%", muted, pct);
    NSMenu *m = [[NSMenu alloc] initWithTitle:@"Sound"];

    NSMenuItem *volItem = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"Volume %d%%", pct]
                                                       action:NULL
                                                keyEquivalent:@""];
    [volItem setEnabled:NO];
    [m addItem:volItem];

    [m addItem:[NSMenuItem separatorItem]];

    NSMenuItem *muteItem = [[NSMenuItem alloc] initWithTitle:@"Mute"
                                                       action:@selector(toggleMute:)
                                                keyEquivalent:@""];
    [muteItem setTarget:self];
    [muteItem setState:muted ? NSOnState : NSOffState];
    [m addItem:muteItem];

    NSMenuItem *up = [[NSMenuItem alloc] initWithTitle:@"Volume Up"
                                                 action:@selector(volUp:)
                                          keyEquivalent:@""];
    [up setTarget:self];
    if (muted) [up setEnabled:NO];
    [m addItem:up];

    NSMenuItem *down = [[NSMenuItem alloc] initWithTitle:@"Volume Down"
                                                   action:@selector(volDown:)
                                            keyEquivalent:@""];
    [down setTarget:self];
    if (muted) [down setEnabled:NO];
    [m addItem:down];

    return m;
}

- (NSImage *)image
{
    NSString *name;
    if (_muted || _volume < 0.01) {
        name = @"volume-muted";
    } else if (_volume < 0.33) {
        name = @"volume-low";
    } else if (_volume < 0.66) {
        name = @"volume-medium";
    } else {
        name = @"volume-high";
    }
    return [NSImage imageNamed:name];
}

- (NSString *)title
{
    if (!kShowTextInMenuBar) return @"";
    int pct = (int)(_volume * 100.0f);
    if (pct < 0) pct = 0;
    if (pct > 100) pct = 100;
    return [NSString stringWithFormat:@"%d%%", pct];
}

- (void)menuExtraDidLoad
{
    _backend = [[ALSABackend alloc] init];
    [self updateState];
}

- (void)menuExtraWillOpenMenu
{
    [self updateState];
}

- (void)refreshMenuItems:(NSMenu *)submenu
{
    BOOL muted = [_backend isOutputMuted];
    for (NSMenuItem *item in [submenu itemArray]) {
        NSString *title = [item title];
        if ([title isEqualToString:@"Mute"]) {
            [item setState:muted ? NSOnState : NSOffState];
        } else if ([title isEqualToString:@"Volume Up"] || [title isEqualToString:@"Volume Down"]) {
            [item setEnabled:!muted];
        }
    }
}

- (void)menuExtraWillUnload
{
}

#pragma mark - Actions

- (void)toggleMute:(id)sender
{
    (void)sender;
    NSLog(@"SoundExtra: toggleMute");
    [_backend setOutputMuted:![_backend isOutputMuted]];
    [self updateState];
}

- (void)volUp:(id)sender
{
    (void)sender;
    NSLog(@"SoundExtra: volUp");
    float vol = [_backend outputVolume];
    vol += 0.05f;
    if (vol > 1.0f) vol = 1.0f;
    [_backend setOutputVolume:vol];
    [self updateState];
}

- (void)volDown:(id)sender
{
    (void)sender;
    NSLog(@"SoundExtra: volDown");
    float vol = [_backend outputVolume];
    vol -= 0.05f;
    if (vol < 0.0f) vol = 0.0f;
    [_backend setOutputVolume:vol];
    [self updateState];
}

@end
