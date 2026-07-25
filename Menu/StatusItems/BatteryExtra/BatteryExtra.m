/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "BatteryExtra.h"
#import <stdio.h>
#import <stdlib.h>
#import <string.h>

static const BOOL kShowTextInMenuBar = NO;

@implementation BatteryExtra
{
    NSTimer *_timer;
    int _percent;
    NSString *_status;
    NSString *_source;
    BOOL _showPercentage;
    int _timeRemainingMinutes;
}

- (void)dealloc
{
    [self menuExtraWillUnload];
#if !__has_feature(objc_arc)
    [super dealloc];
#endif
}

#pragma mark - Battery info (reused from EnergyController)

- (NSString *)readFile:(NSString *)path
{
    FILE *f = fopen([path UTF8String], "r");
    if (!f) return nil;
    char buf[64];
    if (!fgets(buf, sizeof(buf), f)) { fclose(f); return nil; }
    fclose(f);
    size_t len = strlen(buf);
    while (len > 0 && (buf[len-1] == '\n' || buf[len-1] == ' ')) buf[--len] = '\0';
    return [NSString stringWithUTF8String:buf];
}

- (NSString *)runCommand:(NSString *)cmd args:(NSArray *)args
{
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:cmd];
    if (args) [task setArguments:args];
    NSPipe *pipe = [NSPipe pipe];
    [task setStandardOutput:pipe];
    [task setStandardError:[NSFileHandle fileHandleWithNullDevice]];
    @try {
        [task launch];
        [task waitUntilExit];
    } @catch (NSException *e) {
        return nil;
    }
    NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
    NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

- (void)updateBattery
{
    _source = @"Unknown";
    _percent = -1;
    _status = @"";
    _timeRemainingMinutes = -1;

#if defined(__linux__)
    NSString *acOnline = [self readFile:@"/sys/class/power_supply/AC/online"];
    NSString *battCap = [self readFile:@"/sys/class/power_supply/BAT0/capacity"];
    NSString *battStatus = [self readFile:@"/sys/class/power_supply/BAT0/status"];

    _source = [acOnline isEqualToString:@"1"] ? @"AC" : @"Battery";
    if ([battCap length] > 0) _percent = [battCap intValue];
    if ([battStatus length] > 0) _status = [battStatus capitalizedString];

    // Time remaining
    NSString *energyNow = [self readFile:@"/sys/class/power_supply/BAT0/energy_now"];
    NSString *powerNow = [self readFile:@"/sys/class/power_supply/BAT0/power_now"];
    if ([energyNow length] > 0 && [powerNow length] > 0) {
        int pNow = [powerNow intValue];
        if (pNow > 0) {
            float hours;
            if ([_status isEqualToString:@"Charging"]) {
                NSString *energyFull = [self readFile:@"/sys/class/power_supply/BAT0/energy_full"];
                hours = ([energyFull length] > 0)
                    ? (float)([energyFull intValue] - [energyNow intValue]) / (float)pNow
                    : -1;
            } else {
                hours = (float)[energyNow intValue] / (float)pNow;
            }
            if (hours >= 0) _timeRemainingMinutes = (int)(hours * 60.0f + 0.5f);
        }
    } else {
        NSString *chargeNow = [self readFile:@"/sys/class/power_supply/BAT0/charge_now"];
        NSString *currentNow = [self readFile:@"/sys/class/power_supply/BAT0/current_now"];
        if ([chargeNow length] > 0 && [currentNow length] > 0) {
            int iNow = [currentNow intValue];
            if (iNow > 0) {
                float hours;
                if ([_status isEqualToString:@"Charging"]) {
                    NSString *chargeFull = [self readFile:@"/sys/class/power_supply/BAT0/charge_full"];
                    hours = ([chargeFull length] > 0)
                        ? (float)([chargeFull intValue] - [chargeNow intValue]) / (float)iNow
                        : -1;
                } else {
                    hours = (float)[chargeNow intValue] / (float)iNow;
                }
                if (hours >= 0) _timeRemainingMinutes = (int)(hours * 60.0f + 0.5f);
            }
        }
    }

#elif defined(__FreeBSD__)
    NSString *acline = [self runCommand:@"/sbin/sysctl"
                                  args:@[@"-n", @"hw.acpi.acline"]];
    NSString *life  = [self runCommand:@"/sbin/sysctl"
                                  args:@[@"-n", @"hw.acpi.battery.life"]];
    NSString *state = [self runCommand:@"/sbin/sysctl"
                                  args:@[@"-n", @"hw.acpi.battery.state"]];

    _source = [acline isEqualToString:@"1"] ? @"AC" : @"Battery";
    if ([life length] > 0) _percent = [life intValue];
    if ([state length] > 0) {
        int s = [state intValue];
        _status = (s == 1) ? @"Discharging" :
                  (s == 2) ? @"Charging" :
                  (s == 7) ? @"Charged" :
                  (s == 0) ? @"Idle" : state;
    }

    // Time remaining (FreeBSD provides minutes directly)
    NSString *battTime = [self runCommand:@"/sbin/sysctl"
                                     args:@[@"-n", @"hw.acpi.battery.time"]];
    if ([battTime length] > 0) {
        _timeRemainingMinutes = [battTime intValue];
    }

#elif defined(__OpenBSD__)
    NSString *acline = [self runCommand:@"/usr/sbin/apm" args:@[@"-a"]];
    NSString *life   = [self runCommand:@"/usr/sbin/apm" args:@[@"-l"]];
    NSString *bstate = [self runCommand:@"/usr/sbin/apm" args:@[@"-b"]];

    _source = [acline isEqualToString:@"1"] ? @"AC" : @"Battery";
    if ([life length] > 0) _percent = [life intValue];
    if ([bstate length] > 0) {
        int s = [bstate intValue];
        _status = (s == 0) ? @"High" :
                  (s == 1) ? @"Low" :
                  (s == 2) ? @"Critical" :
                  (s == 3) ? @"Charging" : bstate;
    }

    // Time remaining (OpenBSD apm provides minutes)
    NSString *apmMinutes = [self runCommand:@"/usr/sbin/apm" args:@[@"-m"]];
    if ([apmMinutes length] > 0) {
        _timeRemainingMinutes = [apmMinutes intValue];
    }

#elif defined(__NetBSD__)
    NSString *acline = [self runCommand:@"/sbin/sysctl"
                                  args:@[@"-n", @"hw.acpi.acline"]];
    NSString *life  = [self runCommand:@"/sbin/sysctl"
                                  args:@[@"-n", @"hw.acpi.battery.life"]];
    NSString *state = [self runCommand:@"/sbin/sysctl"
                                  args:@[@"-n", @"hw.acpi.battery.state"]];
    _source = [acline isEqualToString:@"1"] ? @"AC" : @"Battery";
    if ([life length] > 0) _percent = [life intValue];
    if ([state length] > 0) {
        int s = [state intValue];
        _status = (s == 1) ? @"Discharging" :
                  (s == 2) ? @"Charging" :
                  (s == 7) ? @"Charged" : state;
    }

    // Time remaining (NetBSD provides minutes via sysctl)
    NSString *battTime = [self runCommand:@"/sbin/sysctl"
                                     args:@[@"-n", @"hw.acpi.battery.time"]];
    if ([battTime length] > 0) {
        _timeRemainingMinutes = [battTime intValue];
    }
#endif
}

- (void)toggleShowPercentage:(id)sender
{
    (void)sender;
    _showPercentage = !_showPercentage;
}

- (void)openBatteryPrefs:(id)sender
{
    (void)sender;
    NSString *prefPaneID = @"Energy";
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
        }
    }
    [[NSWorkspace sharedWorkspace] launchApplication:@"SystemPreferences"];
}

- (NSString *)remainingTimeString
{
    if (_timeRemainingMinutes < 0) return nil;
    int hours = _timeRemainingMinutes / 60;
    int mins = _timeRemainingMinutes % 60;
    if (hours > 0 && mins > 0) {
        return [NSString stringWithFormat:@"%dh %dm", hours, mins];
    } else if (hours > 0) {
        return [NSString stringWithFormat:@"%dh", hours];
    } else {
        return [NSString stringWithFormat:@"%d min", mins];
    }
}

#pragma mark - GSMenuExtra

- (NSMenu *)menu
{
    NSMenu *m = [[NSMenu alloc] initWithTitle:@"Battery"];
    NSString *pct = _percent >= 0 ? [NSString stringWithFormat:@"%d%%", _percent] : @"--";
    NSString *line = [NSString stringWithFormat:@"%@ (%@)", pct, _status];
    NSMenuItem *info = [[NSMenuItem alloc] initWithTitle:line action:NULL keyEquivalent:@""];
    [info setEnabled:NO];
    [m addItem:info];
    [m addItemWithTitle:[NSString stringWithFormat:@"Source: %@", _source] action:NULL keyEquivalent:@""];
    [[m itemAtIndex:1] setEnabled:NO];

    if (_timeRemainingMinutes >= 0) {
        NSString *timeStr = [self remainingTimeString];
        if (timeStr) {
            BOOL isCharging = [_status isEqualToString:@"Charging"];
            NSString *timeLabel = isCharging
                ? [NSString stringWithFormat:@"%@ until full", timeStr]
                : [NSString stringWithFormat:@"%@ remaining", timeStr];
            NSMenuItem *timeItem = [[NSMenuItem alloc] initWithTitle:timeLabel
                                                              action:NULL
                                                       keyEquivalent:@""];
            [timeItem setEnabled:NO];
            [m addItem:timeItem];
        }
    }

    [m addItem:[NSMenuItem separatorItem]];

    NSMenuItem *pctItem = [[NSMenuItem alloc] initWithTitle:@"Show Percentage"
                                                     action:@selector(toggleShowPercentage:)
                                              keyEquivalent:@""];
    [pctItem setTarget:self];
    [pctItem setState:_showPercentage ? NSOnState : NSOffState];
    [m addItem:pctItem];

    [m addItem:[NSMenuItem separatorItem]];

    NSMenuItem *prefs = [[NSMenuItem alloc] initWithTitle:@"Preferences"
                                                    action:@selector(openBatteryPrefs:)
                                             keyEquivalent:@""];
    [prefs setTarget:self];
    [m addItem:prefs];

    return m;
}

- (NSImage *)image
{
    if (_percent < 0) return nil;
    NSString *name;
    if ([_source isEqualToString:@"AC"]) {
        name = [_status isEqualToString:@"Charging"]
            ? @"battery-charging" : @"battery-charged";
    } else if (_percent >= 90) {
        name = @"battery";
    } else if (_percent >= 40) {
        name = @"battery-medium";
    } else {
        name = @"battery-low";
    }
    return [NSImage imageNamed:name];
}

- (NSString *)title
{
    if (!kShowTextInMenuBar) return @"";
    if (_percent < 0) return @"--%";
    return [NSString stringWithFormat:@"%d%%", _percent];
}

- (void)menuExtraDidLoad
{
    [self updateBattery];
    _timer = [NSTimer scheduledTimerWithTimeInterval:10.0
                                              target:self
                                            selector:@selector(updateBattery)
                                            userInfo:nil
                                             repeats:YES];
}

- (void)menuExtraWillUnload
{
    [_timer invalidate];
    _timer = nil;
}

@end
