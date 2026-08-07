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
    SysfsBacklightBackend *_backend;
    int _current;
    int _maximum;
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

- (void)updateBrightness
{
    if (!_running) return;
    _current = [_backend current];
    _maximum = [_backend maximum];
}

- (void)refreshBrightnessPresentation
{
    @try {
        if (!_running) return;
        int oldCurrent = _current;
        int oldMaximum = _maximum;

        [self updateBrightness];
        if (oldCurrent != _current || oldMaximum != _maximum) {
            [_context invalidatePresentation];
        }
    } @catch (NSException *e) {
        NSLog(@"BrightnessExtra: exception in refreshBrightnessPresentation: %@", e);
    }
}

- (int)percent
{
    if (_maximum <= 0) return 0;
    return (int)((float)_current / (float)_maximum * 100.0f);
}

#pragma mark - System compatibility

- (BOOL)isCompatibleWithSystem
{
    SysfsBacklightBackend *backend = [[SysfsBacklightBackend alloc] init];
    BOOL compatible = ([backend maximum] > 0);
    return compatible;
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

    [m addItem:[NSMenuItem separatorItem]];

    NSMenuItem *prefs = [[NSMenuItem alloc] initWithTitle:@"Preferences"
                                                    action:@selector(openDisplayPrefs:)
                                             keyEquivalent:@""];
    [prefs setTarget:self];
    [m addItem:prefs];

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
    @try {
        _running = YES;
        _backend = [[SysfsBacklightBackend alloc] init];
        [self refreshBrightnessPresentation];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(brightnessChanged:)
                                                      name:@"BrightnessChanged"
                                                    object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(brightnessUp:)
                                                     name:@"GSMenuExtraBrightnessUp"
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(brightnessDown:)
                                                     name:@"GSMenuExtraBrightnessDown"
                                                   object:nil];
    } @catch (NSException *e) {
        NSLog(@"BrightnessExtra: exception in menuExtraDidLoad: %@", e);
        _running = NO;
        _backend = nil;
        _context = nil;
    }
}

- (void)menuExtraWillOpenMenu
{
    [self refreshBrightnessPresentation];
}

- (void)menuExtraWillUnload
{
    _running = NO;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    _backend = nil;
}

- (void)refreshTimerFired:(NSTimer *)timer
{
    @try {
        if (!_running) return;
        (void)timer;
        [self refreshBrightnessPresentation];
    } @catch (NSException *e) {
        NSLog(@"BrightnessExtra: exception in refreshTimerFired:: %@", e);
    }
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
    @try {
        (void)sender;
        int step = (_maximum - MAX(_maximum / 100, 1)) / 7;
        if (step < 1) step = 1;
        int newVal = _current + step;
        if (newVal > _maximum) newVal = _maximum;
        [_backend set:newVal];
        [self refreshBrightnessPresentation];
    } @catch (NSException *e) {
        NSLog(@"BrightnessExtra: exception in brightnessUp: %@", e);
    }
}

- (void)brightnessDown:(id)sender
{
    @try {
        (void)sender;
        int step = (_maximum - MAX(_maximum / 100, 1)) / 7;
        if (step < 1) step = 1;
        int newVal = _current - step;
        if (newVal < MAX(_maximum / 100, 1)) newVal = MAX(_maximum / 100, 1);
        [_backend set:newVal];
        [self refreshBrightnessPresentation];
    } @catch (NSException *e) {
        NSLog(@"BrightnessExtra: exception in brightnessDown: %@", e);
    }
}

- (void)openDisplayPrefs:(id)sender
{
    (void)sender;
    NSString *prefPaneID = @"Display";
    NSString *appPath = [[NSWorkspace sharedWorkspace] fullPathForApplication:@"SystemPreferences"];
    if (!appPath) {
        appPath = @"/Developer/Library/Sources/gershwin-systempreferences/SystemPreferences/SystemPreferences.app";
    }
    NSString *execPath = nil;
    if (appPath) {
        execPath = [appPath stringByAppendingPathComponent:@"SystemPreferences"];
        if (![[NSFileManager defaultManager] isExecutableFileAtPath:execPath]) {
            execPath = [[NSBundle bundleWithPath:appPath] executablePath];
        }
    }
    if (execPath) {
        NSTask *task = [[NSTask alloc] init];
        [task setLaunchPath:execPath];
        [task setArguments:@[prefPaneID]];
        @try {
            [task launch];
            return;
        } @catch (NSException *e) {
            // Fall through to fallback
        }
    }
    /* launchApplication: connects to the app via DO (blocking).  Keep it off
       the main thread so the menu never freezes during the launch. */
    [NSThread detachNewThreadWithBlock: ^{
        [[NSWorkspace sharedWorkspace] launchApplication:@"SystemPreferences"];
    }];
}

@end
