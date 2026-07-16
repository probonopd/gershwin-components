/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "BatteryExtra.h"
#import <stdio.h>
#import <stdlib.h>
#import <string.h>

@implementation BatteryExtra
{
    NSTimer *_timer;
    int _percent;
    NSString *_status;
    NSString *_source;
    BOOL _showPercentage;
}

- (void)dealloc
{
    [self menuExtraWillUnload];
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

#if defined(__linux__)
    NSString *acOnline = [self readFile:@"/sys/class/power_supply/AC/online"];
    NSString *battCap = [self readFile:@"/sys/class/power_supply/BAT0/capacity"];
    NSString *battStatus = [self readFile:@"/sys/class/power_supply/BAT0/status"];

    _source = [acOnline isEqualToString:@"1"] ? @"AC" : @"Battery";
    if ([battCap length] > 0) _percent = [battCap intValue];
    if ([battStatus length] > 0) _status = [battStatus capitalizedString];

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
#endif
}

- (void)toggleShowPercentage:(id)sender
{
    (void)sender;
    _showPercentage = !_showPercentage;
}

- (void)openBatteryPrefs:(id)sender
{
    NSString *app = @"SystemPreferences";
    if (![[NSWorkspace sharedWorkspace] launchApplication:app]) {
        NSString *path = @"/Developer/Library/Sources/gershwin-systempreferences/SystemPreferences/SystemPreferences.app";
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
            [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:path]];
        }
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

    [m addItem:[NSMenuItem separatorItem]];

    NSMenuItem *pctItem = [[NSMenuItem alloc] initWithTitle:@"Show Percentage"
                                                     action:@selector(toggleShowPercentage:)
                                              keyEquivalent:@""];
    [pctItem setTarget:self];
    [pctItem setState:_showPercentage ? NSOnState : NSOffState];
    [m addItem:pctItem];

    [m addItem:[NSMenuItem separatorItem]];

    NSMenuItem *prefs = [[NSMenuItem alloc] initWithTitle:@"Open Battery Preferences…"
                                                   action:@selector(openBatteryPrefs:)
                                            keyEquivalent:@""];
    [prefs setTarget:self];
    [m addItem:prefs];

    return m;
}

- (NSImage *)image
{
    return nil;
}

- (NSString *)title
{
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
