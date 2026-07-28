/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "BatteryExtra.h"
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#if defined(__FreeBSD__) || defined(__NetBSD__)
#import <sys/sysctl.h>
#endif


static const BOOL kShowTextInMenuBar = NO;

@implementation BatteryExtra
{
    int _percent;
    char _status[256];
    char _source[64];
    BOOL _showPercentage;
    int _timeRemainingMinutes;
    BOOL _running;
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
    @try {
        if (!_running) return;
        strncpy(_source, "Unknown", sizeof(_source) - 1);
        _source[sizeof(_source) - 1] = '\0';
        _percent = -1;
        _status[0] = '\0';
        _timeRemainingMinutes = -1;

#if defined(__linux__)
        NSString *acOnline = [self readFile:@"/sys/class/power_supply/AC/online"];
        NSString *battCap = [self readFile:@"/sys/class/power_supply/BAT0/capacity"];
        NSString *battStatus = [self readFile:@"/sys/class/power_supply/BAT0/status"];

        {
            const char *src = [acOnline isEqualToString:@"1"] ? "AC" : "Battery";
            strncpy(_source, src, sizeof(_source) - 1);
            _source[sizeof(_source) - 1] = '\0';
        }
        if ([battCap length] > 0) _percent = [battCap intValue];
        if ([battStatus length] > 0) {
            const char *s = [[battStatus capitalizedString] UTF8String];
            if (s) {
                strncpy(_status, s, sizeof(_status) - 1);
                _status[sizeof(_status) - 1] = '\0';
            }
        }

        // Time remaining
        NSString *energyNow = [self readFile:@"/sys/class/power_supply/BAT0/energy_now"];
        NSString *powerNow = [self readFile:@"/sys/class/power_supply/BAT0/power_now"];
        if ([energyNow length] > 0 && [powerNow length] > 0) {
            int pNow = [powerNow intValue];
            if (pNow > 0) {
                float hours;
                if (strcmp(_status, "Charging") == 0) {
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
                    if (strcmp(_status, "Charging") == 0) {
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

        {
            const char *src = [acline isEqualToString:@"1"] ? "AC" : "Battery";
            strncpy(_source, src, sizeof(_source) - 1);
            _source[sizeof(_source) - 1] = '\0';
        }
        if ([life length] > 0) _percent = [life intValue];
        if ([state length] > 0) {
            int s = [state intValue];
            const char *st;
            if (s == 1) st = "Discharging";
            else if (s == 2) st = "Charging";
            else if (s == 7) st = "Charged";
            else if (s == 0) st = "Idle";
            else st = [state UTF8String];
            if (st) {
                strncpy(_status, st, sizeof(_status) - 1);
                _status[sizeof(_status) - 1] = '\0';
            }
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

        {
            const char *src = [acline isEqualToString:@"1"] ? "AC" : "Battery";
            strncpy(_source, src, sizeof(_source) - 1);
            _source[sizeof(_source) - 1] = '\0';
        }
        if ([life length] > 0) _percent = [life intValue];
        if ([bstate length] > 0) {
            int s = [bstate intValue];
            const char *st;
            if (s == 0) st = "High";
            else if (s == 1) st = "Low";
            else if (s == 2) st = "Critical";
            else if (s == 3) st = "Charging";
            else st = [bstate UTF8String];
            if (st) {
                strncpy(_status, st, sizeof(_status) - 1);
                _status[sizeof(_status) - 1] = '\0';
            }
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
        {
            const char *src = [acline isEqualToString:@"1"] ? "AC" : "Battery";
            strncpy(_source, src, sizeof(_source) - 1);
            _source[sizeof(_source) - 1] = '\0';
        }
        if ([life length] > 0) _percent = [life intValue];
        if ([state length] > 0) {
            int s = [state intValue];
            const char *st;
            if (s == 1) st = "Discharging";
            else if (s == 2) st = "Charging";
            else if (s == 7) st = "Charged";
            else st = [state UTF8String];
            if (st) {
                strncpy(_status, st, sizeof(_status) - 1);
                _status[sizeof(_status) - 1] = '\0';
            }
        }

        // Time remaining (NetBSD provides minutes via sysctl)
        NSString *battTime = [self runCommand:@"/sbin/sysctl"
                                         args:@[@"-n", @"hw.acpi.battery.time"]];
        if ([battTime length] > 0) {
            _timeRemainingMinutes = [battTime intValue];
        }
#endif
    } @catch (NSException *e) {
        NSLog(@"BatteryExtra: exception in updateBattery: %@", e);
    }
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

#pragma mark - System compatibility

- (BOOL)isCompatibleWithSystem
{
#if defined(__linux__)
    // Check if any power supply battery device exists
    static NSString *const batteryPaths[] = {
        @"/sys/class/power_supply/BAT0",
        @"/sys/class/power_supply/BAT1",
        @"/sys/class/power_supply/BAT2",
        nil
    };
    for (int i = 0; batteryPaths[i]; i++) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:batteryPaths[i]])
            return YES;
    }
    return NO;
#elif defined(__FreeBSD__) || defined(__NetBSD__)
    int battLife = -1;
    size_t len = sizeof(battLife);
    if (sysctlbyname("hw.acpi.battery.life", &battLife, &len, NULL, 0) == 0) {
        return (battLife >= 0 && battLife <= 100);
    }
    return NO;
#elif defined(__OpenBSD__)
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"/usr/sbin/apm"];
    [task setArguments:@[@"-l"]];
    NSPipe *pipe = [NSPipe pipe];
    [task setStandardOutput:pipe];
    [task setStandardError:[NSFileHandle fileHandleWithNullDevice]];
    @try {
        [task launch];
        [task waitUntilExit];
    } @catch (NSException *e) {
        return NO;
    }
    NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
    NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    int life = [s intValue];
    // apm -l returns 255 when no battery is present
    return (life >= 0 && life <= 100);
#else
    return NO;
#endif
}

#pragma mark - GSMenuExtra

- (NSMenu *)menu
{
    NSMenu *m = [[NSMenu alloc] initWithTitle:@"Battery"];
    NSString *pct = _percent >= 0 ? [NSString stringWithFormat:@"%d%%", _percent] : @"--";
    NSString *statusStr = [NSString stringWithUTF8String:_status];
    if (!statusStr) statusStr = @"";
    NSString *line = [NSString stringWithFormat:@"%@ (%@)", pct, statusStr];
    NSMenuItem *info = [[NSMenuItem alloc] initWithTitle:line action:NULL keyEquivalent:@""];
    [info setEnabled:NO];
    [m addItem:info];
    NSString *sourceStr = [NSString stringWithUTF8String:_source];
    if (!sourceStr) sourceStr = @"";
    [m addItemWithTitle:[NSString stringWithFormat:@"Source: %@", sourceStr] action:NULL keyEquivalent:@""];
    [[m itemAtIndex:1] setEnabled:NO];

    if (_timeRemainingMinutes >= 0) {
        NSString *timeStr = [self remainingTimeString];
        if (timeStr) {
            BOOL isCharging = (strcmp(_status, "Charging") == 0);
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
    if (_source[0] == '\0' || _status[0] == '\0') return nil;
    NSString *name;
    if (strcmp(_source, "AC") == 0) {
        name = (strcmp(_status, "Charging") == 0)
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
    @try {
        _running = YES;
        [self updateBattery];
    } @catch (NSException *e) {
        NSLog(@"BatteryExtra: exception in menuExtraDidLoad: %@", e);
        _running = NO;
        _status[0] = '\0';
        _source[0] = '\0';
    }
}

- (void)menuExtraWillUnload
{
    _running = NO;
}

@end
