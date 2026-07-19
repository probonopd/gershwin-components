/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "EnergyController.h"
#import <dispatch/dispatch.h>

static NSString *const kEnergyDomain = @"EnergyPreferences";

@interface EnergyController ()
- (NSString *)readFile:(NSString *)path;
- (BOOL)writeSysfs:(NSString *)path value:(NSString *)value;
- (NSString *)runCommand:(NSString *)cmd args:(NSArray *)args;
- (NSDictionary *)readBatteryInfo;
- (NSString *)readGovernor;
- (NSArray *)availableGovernors;
- (BOOL)writeGovernor:(NSString *)gov;
- (int)readBrightnessPercent;
- (BOOL)writeBrightnessPercent:(int)pct;
- (BOOL)readPreventSleep;
- (BOOL)writePreventSleep:(BOOL)enable;
- (BOOL)readHddSleep;
- (BOOL)writeHddSleep:(BOOL)enable;
- (BOOL)readWakeNetwork;
- (BOOL)writeWakeNetwork:(BOOL)enable;
- (BOOL)readPowerFail;
- (BOOL)writePowerFail:(BOOL)enable;
- (void)applyAllSettings;
- (void)updateStatus:(NSString *)message;
@end

@implementation EnergyController

- (id)init
{
    self = [super init];
    if (self) {
        isRefreshing = YES;
        hddSleepState = NO;
        wakeNetworkState = NO;
        powerFailState = NO;
    }
    return self;
}

- (void)dealloc
{
    [mainView release];
    [sourceLabel release];
    [batteryPercentLabel release];
    [governorPopUp release];
    [brightnessSlider release];
    [brightnessLabel release];
    [blankPopUp release];
    [preventSleepCheckbox release];
    [hddSleepCheckbox release];
    [wakeNetworkCheckbox release];
    [powerFailCheckbox release];
    if (inhibitTask) {
        [inhibitTask terminate];
        [inhibitTask release];
    }
    [statusLabel release];
    [super dealloc];
}

#pragma mark - System Helpers

- (NSString *)readFile:(NSString *)path
{
    NSString *content = [[[NSString alloc] initWithContentsOfFile:path
                                                        encoding:NSUTF8StringEncoding
                                                           error:NULL] autorelease];
    return [content stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

- (BOOL)writeSysfs:(NSString *)path value:(NSString *)value
{
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"/bin/sh"];
    [task setArguments:[NSArray arrayWithObjects:
        @"-c",
        [NSString stringWithFormat:@"printf '%s' '%@' | /usr/bin/sudo tee '%@' > /dev/null",
            [value UTF8String], value, path],
        nil]];
    [task launch];
    [task waitUntilExit];
    int status = [task terminationStatus];
    [task release];
    return (status == 0);
}

- (NSString *)runCommand:(NSString *)cmd args:(NSArray *)args
{
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:cmd];
    [task setArguments:args];
    NSPipe *pipe = [NSPipe pipe];
    [task setStandardOutput:pipe];

    // Force C locale for consistent tool output
    NSMutableDictionary *env = [[[NSProcessInfo processInfo] environment] mutableCopy];
    [env setObject:@"C" forKey:@"LC_ALL"];
    [task setEnvironment:env];
    [env release];

    [task launch];
    NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
    [task waitUntilExit];
    [task release];
    NSString *output = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
    return [output stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

#pragma mark - UI

- (NSView *)createMainView
{
    if (mainView) {
        return mainView;
    }
    mainView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 560, 370)];
    CGFloat y = 352;
    CGFloat labelX = 20;
    CGFloat controlX = 160;
    CGFloat controlW = 260;
    CGFloat rowH = 22;

    // ---- Power Source Section ----
    NSTextField *powerSection = [[NSTextField alloc] initWithFrame:NSMakeRect(labelX, y, 200, 18)];
    [powerSection setBezeled:NO];
    [powerSection setEditable:NO];
    [powerSection setSelectable:NO];
    [powerSection setDrawsBackground:NO];
    [powerSection setStringValue:@"Power Source"];
    [powerSection setFont:[NSFont boldSystemFontOfSize:13]];
    [powerSection setAutoresizingMask:NSViewMaxYMargin];
    [mainView addSubview:powerSection];
    [powerSection release];
    y -= 20;

    // Source label
    sourceLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(labelX + 10, y, 300, rowH)];
    [sourceLabel setBezeled:NO];
    [sourceLabel setEditable:NO];
    [sourceLabel setSelectable:NO];
    [sourceLabel setDrawsBackground:NO];
    [sourceLabel setStringValue:@"Source: reading..."];
    [sourceLabel setFont:[NSFont systemFontOfSize:12]];
    [sourceLabel setAutoresizingMask:NSViewMaxYMargin];
    [mainView addSubview:sourceLabel];
    y -= 22;

    batteryPercentLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(labelX + 10, y, 120, rowH)];
    [batteryPercentLabel setBezeled:NO];
    [batteryPercentLabel setEditable:NO];
    [batteryPercentLabel setSelectable:NO];
    [batteryPercentLabel setDrawsBackground:NO];
    [batteryPercentLabel setStringValue:@"Battery: --%"];
    [batteryPercentLabel setFont:[NSFont systemFontOfSize:12]];
    [batteryPercentLabel setAutoresizingMask:NSViewMaxYMargin];
    [mainView addSubview:batteryPercentLabel];
    y -= 24;

    // ---- Separator ----
    NSBox *sep1 = [[NSBox alloc] initWithFrame:NSMakeRect(labelX, y - 2, 520, 1)];
    [sep1 setBoxType:NSBoxSeparator];
    [sep1 setAutoresizingMask:NSViewMaxYMargin | NSViewWidthSizable];
    [mainView addSubview:sep1];
    [sep1 release];
    y -= 16;

    // ---- CPU Performance Section ----
    NSTextField *cpuSection = [[NSTextField alloc] initWithFrame:NSMakeRect(labelX, y, 200, 18)];
    [cpuSection setBezeled:NO];
    [cpuSection setEditable:NO];
    [cpuSection setSelectable:NO];
    [cpuSection setDrawsBackground:NO];
    [cpuSection setStringValue:@"CPU Performance"];
    [cpuSection setFont:[NSFont boldSystemFontOfSize:13]];
    [cpuSection setAutoresizingMask:NSViewMaxYMargin];
    [mainView addSubview:cpuSection];
    [cpuSection release];
    y -= 20;

    // Governor label
    NSTextField *govText = [[NSTextField alloc] initWithFrame:NSMakeRect(labelX + 10, y, 120, rowH)];
    [govText setBezeled:NO];
    [govText setEditable:NO];
    [govText setSelectable:NO];
    [govText setDrawsBackground:NO];
    [govText setStringValue:@"Governor:"];
    [govText setAlignment:NSRightTextAlignment];
    [govText setFont:[NSFont systemFontOfSize:12]];
    [govText setAutoresizingMask:NSViewMaxYMargin];
    [mainView addSubview:govText];
    [govText release];

    governorPopUp = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(controlX, y, controlW, rowH)];
    [governorPopUp setTarget:self];
    [governorPopUp setAction:@selector(settingChanged:)];
    [governorPopUp setAutoresizingMask:NSViewMaxYMargin];
    [mainView addSubview:governorPopUp];
    y -= 28;

    // ---- Separator ----
    NSBox *sep2 = [[NSBox alloc] initWithFrame:NSMakeRect(labelX, y - 2, 520, 1)];
    [sep2 setBoxType:NSBoxSeparator];
    [sep2 setAutoresizingMask:NSViewMaxYMargin | NSViewWidthSizable];
    [mainView addSubview:sep2];
    [sep2 release];
    y -= 16;

    // ---- Display Section ----
    NSTextField *dispSection = [[NSTextField alloc] initWithFrame:NSMakeRect(labelX, y, 200, 18)];
    [dispSection setBezeled:NO];
    [dispSection setEditable:NO];
    [dispSection setSelectable:NO];
    [dispSection setDrawsBackground:NO];
    [dispSection setStringValue:@"Display"];
    [dispSection setFont:[NSFont boldSystemFontOfSize:13]];
    [dispSection setAutoresizingMask:NSViewMaxYMargin];
    [mainView addSubview:dispSection];
    [dispSection release];
    y -= 20;

    // Brightness slider
    NSTextField *brightText = [[NSTextField alloc] initWithFrame:NSMakeRect(labelX + 10, y, 120, rowH)];
    [brightText setBezeled:NO];
    [brightText setEditable:NO];
    [brightText setSelectable:NO];
    [brightText setDrawsBackground:NO];
    [brightText setStringValue:@"Brightness:"];
    [brightText setAlignment:NSRightTextAlignment];
    [brightText setFont:[NSFont systemFontOfSize:12]];
    [brightText setAutoresizingMask:NSViewMaxYMargin];
    [mainView addSubview:brightText];
    [brightText release];

    brightnessSlider = [[NSSlider alloc] initWithFrame:NSMakeRect(controlX, y + 2, controlW - 50, rowH)];
    [brightnessSlider setMinValue:1];
    [brightnessSlider setMaxValue:100];
    [brightnessSlider setFloatValue:100];
    [brightnessSlider setNumberOfTickMarks:11];
    [brightnessSlider setAllowsTickMarkValuesOnly:NO];
    [brightnessSlider setTarget:self];
    [brightnessSlider setAction:@selector(settingChanged:)];
    [brightnessSlider setAutoresizingMask:NSViewMaxYMargin];
    [mainView addSubview:brightnessSlider];

    brightnessLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(controlX + controlW - 40, y, 45, rowH)];
    [brightnessLabel setBezeled:NO];
    [brightnessLabel setEditable:NO];
    [brightnessLabel setSelectable:NO];
    [brightnessLabel setDrawsBackground:NO];
    [brightnessLabel setStringValue:@"100%"];
    [brightnessLabel setFont:[NSFont systemFontOfSize:11]];
    [brightnessLabel setAlignment:NSRightTextAlignment];
    [brightnessLabel setAutoresizingMask:NSViewMaxYMargin];
    [mainView addSubview:brightnessLabel];
    y -= 28;

    // Screen blank
    NSTextField *blankText = [[NSTextField alloc] initWithFrame:NSMakeRect(labelX + 10, y, 120, rowH)];
    [blankText setBezeled:NO];
    [blankText setEditable:NO];
    [blankText setSelectable:NO];
    [blankText setDrawsBackground:NO];
    [blankText setStringValue:@"Screen blanks:"];
    [blankText setAlignment:NSRightTextAlignment];
    [blankText setFont:[NSFont systemFontOfSize:12]];
    [blankText setAutoresizingMask:NSViewMaxYMargin];
    [mainView addSubview:blankText];
    [blankText release];

    blankPopUp = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(controlX, y, controlW, rowH)];
    [blankPopUp addItemWithTitle:@"Never"];
    [blankPopUp addItemWithTitle:@"1 minute"];
    [blankPopUp addItemWithTitle:@"5 minutes"];
    [blankPopUp addItemWithTitle:@"10 minutes"];
    [blankPopUp addItemWithTitle:@"15 minutes"];
    [blankPopUp addItemWithTitle:@"30 minutes"];
    [blankPopUp setTarget:self];
    [blankPopUp setAction:@selector(settingChanged:)];
    [blankPopUp setAutoresizingMask:NSViewMaxYMargin];
    [mainView addSubview:blankPopUp];

    // ---- Power Management Section ----
    NSBox *sep3 = [[NSBox alloc] initWithFrame:NSMakeRect(labelX, y - 2, 520, 1)];
    [sep3 setBoxType:NSBoxSeparator];
    [sep3 setAutoresizingMask:NSViewMaxYMargin | NSViewWidthSizable];
    [mainView addSubview:sep3];
    [sep3 release];
    y -= 16;

    NSTextField *pmSection = [[NSTextField alloc] initWithFrame:NSMakeRect(labelX, y, 200, 18)];
    [pmSection setBezeled:NO];
    [pmSection setEditable:NO];
    [pmSection setSelectable:NO];
    [pmSection setDrawsBackground:NO];
    [pmSection setStringValue:@"Power Management"];
    [pmSection setFont:[NSFont boldSystemFontOfSize:13]];
    [pmSection setAutoresizingMask:NSViewMaxYMargin];
    [mainView addSubview:pmSection];
    [pmSection release];
    y -= 20;

    preventSleepCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(labelX + 10, y, 510, rowH)];
    [preventSleepCheckbox setButtonType:NSSwitchButton];
    [preventSleepCheckbox setTitle:@"Prevent computer from sleeping when display is off"];
    [preventSleepCheckbox setTarget:self];
    [preventSleepCheckbox setAction:@selector(settingChanged:)];
    [preventSleepCheckbox setAutoresizingMask:NSViewMaxYMargin];
    [mainView addSubview:preventSleepCheckbox];
    y -= 26;

    hddSleepCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(labelX + 10, y, 510, rowH)];
    [hddSleepCheckbox setButtonType:NSSwitchButton];
    [hddSleepCheckbox setTitle:@"Put hard disks to sleep when possible"];
    [hddSleepCheckbox setTarget:self];
    [hddSleepCheckbox setAction:@selector(settingChanged:)];
    [hddSleepCheckbox setAutoresizingMask:NSViewMaxYMargin];
    [mainView addSubview:hddSleepCheckbox];
    y -= 26;

    wakeNetworkCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(labelX + 10, y, 510, rowH)];
    [wakeNetworkCheckbox setButtonType:NSSwitchButton];
    [wakeNetworkCheckbox setTitle:@"Wake for network access"];
    [wakeNetworkCheckbox setTarget:self];
    [wakeNetworkCheckbox setAction:@selector(settingChanged:)];
    [wakeNetworkCheckbox setAutoresizingMask:NSViewMaxYMargin];
    [mainView addSubview:wakeNetworkCheckbox];
    y -= 26;

    powerFailCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(labelX + 10, y, 510, rowH)];
    [powerFailCheckbox setButtonType:NSSwitchButton];
    [powerFailCheckbox setTitle:@"Start up automatically after a power failure"];
    [powerFailCheckbox setTarget:self];
    [powerFailCheckbox setAction:@selector(settingChanged:)];
    [powerFailCheckbox setAutoresizingMask:NSViewMaxYMargin];
    [mainView addSubview:powerFailCheckbox];

    // Status label at the bottom
    statusLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(labelX, 6, 520, 26)];
    [statusLabel setBezeled:NO];
    [statusLabel setEditable:NO];
    [statusLabel setSelectable:NO];
    [statusLabel setDrawsBackground:NO];
    [statusLabel setFont:[NSFont systemFontOfSize:10]];
    [statusLabel setAutoresizingMask:(NSViewWidthSizable | NSViewMaxYMargin)];
    [mainView addSubview:statusLabel];

    [self refreshFromSystem];
    return mainView;
}

#pragma mark - Actions

- (IBAction)settingChanged:(id)sender
{
    (void)sender;
    if (isRefreshing) {
        return;
    }
    [self applyAllSettings];
}

- (void)applyAllSettings
{
    if (isRefreshing) {
        return;
    }
    // -- CPU Governor --
    NSString *gov = [[governorPopUp selectedItem] title];
    if (![gov isEqualToString:[self readGovernor]]) {
        [self writeGovernor:gov];
    }

    // -- Brightness --
    int brightness = (int)[brightnessSlider intValue];
    [brightnessLabel setStringValue:[NSString stringWithFormat:@"%d%%", brightness]];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        [self writeBrightnessPercent:brightness];
    });

    // -- Screen blank --
    int blankSeconds = 0;
    NSString *blankTitle = [[blankPopUp selectedItem] title];
    if ([blankTitle isEqualToString:@"1 minute"]) {
        blankSeconds = 60;
    } else if ([blankTitle isEqualToString:@"5 minutes"]) {
        blankSeconds = 300;
    } else if ([blankTitle isEqualToString:@"10 minutes"]) {
        blankSeconds = 600;
    } else if ([blankTitle isEqualToString:@"15 minutes"]) {
        blankSeconds = 900;
    } else if ([blankTitle isEqualToString:@"30 minutes"]) {
        blankSeconds = 1800;
    }
    // DPMS: xset dpms <standby> <suspend> <off>
    NSString *blankStr = (blankSeconds > 0) ? [NSString stringWithFormat:@"%d", blankSeconds] : @"0";
    [self runCommand:@"/usr/bin/xset"
                args:[NSArray arrayWithObjects:@"dpms", blankStr, blankStr, blankStr, nil]];
    if (blankSeconds == 0) {
        [self runCommand:@"/usr/bin/xset" args:[NSArray arrayWithObjects:@"-dpms", nil]];
    } else {
        [self runCommand:@"/usr/bin/xset" args:[NSArray arrayWithObjects:@"+dpms", nil]];
    }

    // -- Prevent sleep --
    BOOL newPrevent = ([preventSleepCheckbox state] == NSControlStateValueOn);
    if (newPrevent != preventSleepState) {
        [self writePreventSleep:newPrevent];
        preventSleepState = newPrevent;
    }

    // -- Hard disk sleep --
    BOOL newHdd = ([hddSleepCheckbox state] == NSControlStateValueOn);
    if (newHdd != hddSleepState) {
        hddSleepState = newHdd;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
            [self writeHddSleep:newHdd];
        });
    }

    // -- Wake for network --
    BOOL newWake = ([wakeNetworkCheckbox state] == NSControlStateValueOn);
    if (newWake != wakeNetworkState) {
        wakeNetworkState = newWake;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
            [self writeWakeNetwork:newWake];
        });
    }

    // -- Power failure restart --
    BOOL newPower = ([powerFailCheckbox state] == NSControlStateValueOn);
    if (newPower != powerFailState) {
        powerFailState = newPower;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
            [self writePowerFail:newPower];
        });
    }

    // -- Persist --
    [self persistSettings];
    [self updateStatus:@"Applied"];
}

- (void)refreshFromSystem
{
    isRefreshing = YES;

    // -- Power source / battery --
    NSDictionary *batt = [self readBatteryInfo];
    NSString *source = [batt objectForKey:@"source"];
    NSString *status = [batt objectForKey:@"status"];

    if ([source isEqualToString:@"AC"]) {
        NSString *src = @"Source: AC Power";
        if ([status length] > 0) {
            src = [src stringByAppendingFormat:@" (%@)", status];
        }
        [sourceLabel setStringValue:src];
    } else if ([source isEqualToString:@"Battery"]) {
        [sourceLabel setStringValue:@"Source: Battery"];
    } else {
        [sourceLabel setStringValue:@"Source: Unknown"];
    }

    int battPct = [[batt objectForKey:@"percent"] intValue];
    if (battPct >= 0) {
        [batteryPercentLabel setStringValue:[NSString stringWithFormat:@"Battery: %d%%", battPct]];
    } else {
        [batteryPercentLabel setStringValue:@"Battery: N/A"];
    }

    // -- CPU Governor --
    [governorPopUp removeAllItems];
    NSArray *govs = [self availableGovernors];
    for (NSString *gov in govs) {
        if ([gov length] > 0) {
            [governorPopUp addItemWithTitle:gov];
        }
    }
    NSString *currentGov = [self readGovernor];
    if ([currentGov length] > 0) {
        [governorPopUp selectItemWithTitle:currentGov];
    }

    // -- Brightness --
    int pct = [self readBrightnessPercent];
    [brightnessSlider setIntValue:pct];
    [brightnessLabel setStringValue:[NSString stringWithFormat:@"%d%%", pct]];

    // -- Screen blank (read from xset) --
    NSString *xsetOut = [self runCommand:@"/usr/bin/xset" args:[NSArray arrayWithObjects:@"q", nil]];
    BOOL dpmsEnabled = ([xsetOut rangeOfString:@"DPMS is Enabled"].location != NSNotFound);
    if (dpmsEnabled) {
        NSScanner *scanner = [NSScanner scannerWithString:xsetOut];
        if ([scanner scanUpToString:@"Standby:" intoString:nil]) {
            int standby = 0;
            [scanner scanString:@"Standby:" intoString:nil];
            [scanner scanInt:&standby];
            if (standby <= 0) {
                [blankPopUp selectItemWithTitle:@"Never"];
            } else if (standby <= 60) {
                [blankPopUp selectItemWithTitle:@"1 minute"];
            } else if (standby <= 300) {
                [blankPopUp selectItemWithTitle:@"5 minutes"];
            } else if (standby <= 600) {
                [blankPopUp selectItemWithTitle:@"10 minutes"];
            } else if (standby <= 900) {
                [blankPopUp selectItemWithTitle:@"15 minutes"];
            } else {
                [blankPopUp selectItemWithTitle:@"30 minutes"];
            }
        }
    } else {
        [blankPopUp selectItemWithTitle:@"Never"];
    }

    // -- Power Management --
    preventSleepState = [self readPreventSleep];
    [preventSleepCheckbox setState:preventSleepState ? NSControlStateValueOn : NSControlStateValueOff];
    hddSleepState = NO;
    wakeNetworkState = NO;
    powerFailState = NO;
    [hddSleepCheckbox setState:NSControlStateValueOff];
    [wakeNetworkCheckbox setState:NSControlStateValueOff];
    [powerFailCheckbox setState:NSControlStateValueOff];

    // -- Override with persisted user defaults --
    {
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        NSDictionary *persisted = [defaults persistentDomainForName:kEnergyDomain];
        if (persisted) {
            NSNumber *val;

            val = [persisted objectForKey:@"brightness"];
            if (val) {
                [brightnessSlider setIntValue:[val intValue]];
                [brightnessLabel setStringValue:[NSString stringWithFormat:@"%d%%", [val intValue]]];
            }
            val = [persisted objectForKey:@"screenBlank"];
            if (val) {
                [blankPopUp selectItemAtIndex:[val intValue]];
            }

            val = [persisted objectForKey:@"preventSleep"];
            if (val) {
                BOOL on = [val boolValue];
                if (on != preventSleepState) {
                    preventSleepState = on;
                    [self writePreventSleep:on];
                }
                [preventSleepCheckbox setState:on ? NSControlStateValueOn : NSControlStateValueOff];
            }
            val = [persisted objectForKey:@"hddSleep"];
            if (val) {
                hddSleepState = [val boolValue];
                [hddSleepCheckbox setState:hddSleepState ? NSControlStateValueOn : NSControlStateValueOff];
            }
            val = [persisted objectForKey:@"wakeNetwork"];
            if (val) {
                wakeNetworkState = [val boolValue];
                [wakeNetworkCheckbox setState:wakeNetworkState ? NSControlStateValueOn : NSControlStateValueOff];
            }
            val = [persisted objectForKey:@"powerFail"];
            if (val) {
                powerFailState = [val boolValue];
                [powerFailCheckbox setState:powerFailState ? NSControlStateValueOn : NSControlStateValueOff];
            }
        }
    }

    isRefreshing = NO;
    [self updateStatus:@"Ready"];
}

- (void)persistSettings
{
    NSMutableDictionary *domain = [NSMutableDictionary dictionary];
    [domain setObject:[[governorPopUp selectedItem] title] forKey:@"governor"];
    [domain setObject:[NSNumber numberWithInt:[brightnessSlider intValue]] forKey:@"brightness"];
    [domain setObject:[NSNumber numberWithInt:[blankPopUp indexOfSelectedItem]] forKey:@"screenBlank"];
    [domain setObject:[NSNumber numberWithBool:([preventSleepCheckbox state] == NSControlStateValueOn)] forKey:@"preventSleep"];
    [domain setObject:[NSNumber numberWithBool:([hddSleepCheckbox state] == NSControlStateValueOn)] forKey:@"hddSleep"];
    [domain setObject:[NSNumber numberWithBool:([wakeNetworkCheckbox state] == NSControlStateValueOn)] forKey:@"wakeNetwork"];
    [domain setObject:[NSNumber numberWithBool:([powerFailCheckbox state] == NSControlStateValueOn)] forKey:@"powerFail"];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setPersistentDomain:domain forName:kEnergyDomain];
    [defaults synchronize];
}

- (void)updateStatus:(NSString *)message
{
    [statusLabel setStringValue:(message ? message : @"")];
}

#pragma mark - Platform Helpers

- (NSDictionary *)readBatteryInfo
{
    NSString *source = @"Unknown";
    int percent = -1;
    NSString *status = @"";

#if defined(__linux__)
    NSString *acOnline = [self readFile:@"/sys/class/power_supply/AC/online"];
    NSString *battCap = [self readFile:@"/sys/class/power_supply/BAT0/capacity"];
    NSString *battStatus = [self readFile:@"/sys/class/power_supply/BAT0/status"];

    source = [acOnline isEqualToString:@"1"] ? @"AC" : @"Battery";
    if ([battCap length] > 0) percent = [battCap intValue];
    if ([battStatus length] > 0) status = [battStatus capitalizedString];
#elif defined(__FreeBSD__)
    NSString *acline = [self runCommand:@"/sbin/sysctl" args:[NSArray arrayWithObjects:@"-n", @"hw.acpi.acline", nil]];
    NSString *life = [self runCommand:@"/sbin/sysctl" args:[NSArray arrayWithObjects:@"-n", @"hw.acpi.battery.life", nil]];
    NSString *state = [self runCommand:@"/sbin/sysctl" args:[NSArray arrayWithObjects:@"-n", @"hw.acpi.battery.state", nil]];

    source = [acline isEqualToString:@"1"] ? @"AC" : @"Battery";
    if ([life length] > 0) percent = [life intValue];
    if ([state length] > 0) {
        int s = [state intValue];
        status = (s == 1) ? @"Discharging" :
                 (s == 2) ? @"Charging" :
                 (s == 7) ? @"Charged" :
                 (s == 0) ? @"Idle" : state;
    }
#elif defined(__OpenBSD__)
    NSString *acline = [self runCommand:@"/usr/sbin/apm" args:[NSArray arrayWithObjects:@"-a", nil]];
    NSString *life = [self runCommand:@"/usr/sbin/apm" args:[NSArray arrayWithObjects:@"-l", nil]];
    NSString *bstate = [self runCommand:@"/usr/sbin/apm" args:[NSArray arrayWithObjects:@"-b", nil]];

    source = [acline isEqualToString:@"1"] ? @"AC" : @"Battery";
    if ([life length] > 0) percent = [life intValue];
    if ([bstate length] > 0) {
        int s = [bstate intValue];
        status = (s == 0) ? @"High" :
                 (s == 1) ? @"Low" :
                 (s == 2) ? @"Critical" :
                 (s == 3) ? @"Charging" : bstate;
    }
#elif defined(__NetBSD__)
    NSString *acline = [self runCommand:@"/sbin/sysctl" args:[NSArray arrayWithObjects:@"-n", @"hw.acpi.acline", nil]];
    NSString *life = [self runCommand:@"/sbin/sysctl" args:[NSArray arrayWithObjects:@"-n", @"hw.acpi.battery.life", nil]];
    NSString *state = [self runCommand:@"/sbin/sysctl" args:[NSArray arrayWithObjects:@"-n", @"hw.acpi.battery.state", nil]];

    source = [acline isEqualToString:@"1"] ? @"AC" : @"Battery";
    if ([life length] > 0) percent = [life intValue];
    if ([state length] > 0) {
        int s = [state intValue];
        status = (s == 1) ? @"Discharging" :
                 (s == 2) ? @"Charging" :
                 (s == 7) ? @"Charged" : state;
    }
#endif
    return [NSDictionary dictionaryWithObjectsAndKeys:
        source, @"source",
        [NSNumber numberWithInt:percent], @"percent",
        status, @"status", nil];
}

- (NSString *)readGovernor
{
#if defined(__linux__)
    return [self readFile:@"/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"];
#elif defined(__FreeBSD__)
    return [self runCommand:@"/sbin/sysctl" args:[NSArray arrayWithObjects:@"-n", @"dev.cpu.0.freq", nil]];
#elif defined(__OpenBSD__)
    return [self runCommand:@"/sbin/sysctl" args:[NSArray arrayWithObjects:@"-n", @"hw.setperf", nil]];
#elif defined(__NetBSD__)
    return [self runCommand:@"/sbin/sysctl" args:[NSArray arrayWithObjects:@"-n", @"machdep.cpu.frequency.current", nil]];
#else
    return @"";
#endif
}

- (NSArray *)availableGovernors
{
#if defined(__linux__)
    NSString *raw = [self readFile:@"/sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors"];
    if ([raw length] == 0) {
        return [NSArray arrayWithObjects:@"powersave", @"performance", nil];
    }
    return [raw componentsSeparatedByCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
#elif defined(__FreeBSD__)
    /* FreeBSD cpufreq: report common frequencies as "governors" */
    return [NSArray arrayWithObjects:@"Auto", @"Maximum", @"Minimum", nil];
#elif defined(__OpenBSD__)
    /* OpenBSD hw.setperf: 0..100 */
    return [NSArray arrayWithObjects:@"Power Save", @"Auto", @"Performance", nil];
#elif defined(__NetBSD__)
    return [NSArray arrayWithObjects:@"Auto", @"Maximum", @"Minimum", nil];
#else
    return [NSArray arrayWithObjects:@"Auto", nil];
#endif
}

- (BOOL)writeGovernor:(NSString *)gov
{
#if defined(__linux__)
    NSString *path = @"/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor";
    BOOL ok = [self writeSysfs:path value:gov];
    /* Apply to all online CPUs */
    [self runCommand:@"/bin/sh"
                args:[NSArray arrayWithObjects:@"-c",
                      @"for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do "
                       "printf '%s' \"$1\" | sudo tee \"$cpu\" > /dev/null; done",
                      @"sh", gov, nil]];
    return ok;
#elif defined(__FreeBSD__)
    int freq = 0;
    if ([gov isEqualToString:@"Maximum"]) freq = 100000;
    else if ([gov isEqualToString:@"Minimum"]) freq = 0;
    else freq = -1; /* Auto: let the system decide */
    if (freq >= 0) {
        [self runCommand:@"/sbin/sysctl"
                    args:[NSArray arrayWithObjects:@"dev.cpu.0.freq", [NSString stringWithFormat:@"%d", freq], nil]];
    }
    return YES;
#elif defined(__OpenBSD__)
    int perf = 50;
    if ([gov isEqualToString:@"Performance"]) perf = 100;
    else if ([gov isEqualToString:@"Power Save"]) perf = 0;
    [self runCommand:@"/sbin/sysctl"
                args:[NSArray arrayWithObjects:@"hw.setperf", [NSString stringWithFormat:@"%d", perf], nil]];
    return YES;
#elif defined(__NetBSD__)
    /* NetBSD: mostly read-only; just return YES */
    return YES;
#else
    return YES;
#endif
}

- (int)readBrightnessPercent
{
#if defined(__linux__)
    int maxBrightness = [[self readFile:@"/sys/class/backlight/intel_backlight/max_brightness"] intValue];
    int curBrightness = [[self readFile:@"/sys/class/backlight/intel_backlight/brightness"] intValue];
    if (maxBrightness > 0) {
        return (curBrightness * 100 / maxBrightness);
    }
    return 100;
#elif defined(__FreeBSD__) || defined(__NetBSD__)
    NSString *b = [self runCommand:@"/usr/local/bin/xbacklight"
                             args:[NSArray arrayWithObjects:@"-get", nil]];
    if ([b length] > 0) {
        return (int)([b doubleValue] + 0.5);
    }
    return 100;
#elif defined(__OpenBSD__)
    NSString *b = [self runCommand:@"/usr/sbin/wsconsctl"
                             args:[NSArray arrayWithObjects:@"brightness", nil]];
    if ([b length] == 0) {
        b = [self runCommand:@"/usr/local/bin/xbacklight"
                       args:[NSArray arrayWithObjects:@"-get", nil]];
    }
    if ([b length] > 0) {
        return (int)([b doubleValue] + 0.5);
    }
    return 100;
#else
    return 100;
#endif
}

- (BOOL)writeBrightnessPercent:(int)pct
{
    if (pct < 1) pct = 1;
#if defined(__linux__)
    int maxBrightness = [[self readFile:@"/sys/class/backlight/intel_backlight/max_brightness"] intValue];
    if (maxBrightness > 0) {
        int val = (pct * maxBrightness) / 100;
        return [self writeSysfs:@"/sys/class/backlight/intel_backlight/brightness"
                          value:[NSString stringWithFormat:@"%d", val]];
    }
    return NO;
#elif defined(__FreeBSD__) || defined(__NetBSD__) || defined(__OpenBSD__)
    /* xbacklight works on all BSDs with X11 */
    [self runCommand:@"/usr/local/bin/xbacklight"
                args:[NSArray arrayWithObjects:@"-set", [NSString stringWithFormat:@"%d", pct], nil]];
    /* On OpenBSD, also try wsconsctl */
#if defined(__OpenBSD__)
    [self runCommand:@"/usr/sbin/wsconsctl"
                args:[NSArray arrayWithObjects:@"brightness", [NSString stringWithFormat:@"%d", pct], nil]];
#endif
    return YES;
#else
    return YES;
#endif
}

#pragma mark - Power Management

- (BOOL)readPreventSleep
{
    return (inhibitTask != nil && [inhibitTask isRunning]);
}

- (BOOL)writePreventSleep:(BOOL)enable
{
#if defined(__linux__)
    if (enable) {
        if (inhibitTask && [inhibitTask isRunning]) return YES;
        if (inhibitTask) {
            [inhibitTask terminate];
            [inhibitTask release];
        }
        inhibitTask = [[NSTask alloc] init];
        [inhibitTask setLaunchPath:@"/usr/bin/systemd-inhibit"];
        [inhibitTask setArguments:[NSArray arrayWithObjects:
            @"--what=sleep",
            @"--who=EnergyPreferences",
            @"--why=User preference",
            @"sleep", @"infinity", nil]];
        [inhibitTask launch];
    } else {
        if (inhibitTask) {
            [inhibitTask terminate];
            [inhibitTask release];
            inhibitTask = nil;
        }
    }
    return YES;
#else
    return YES;
#endif
}

- (BOOL)readHddSleep
{
#if defined(__linux__)
    NSArray *disks = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:@"/sys/block" error:NULL];
    for (NSString *d in disks) {
        if ([d hasPrefix:@"sd"] || [d hasPrefix:@"nvme"]) {
            NSString *devPath = [NSString stringWithFormat:@"/dev/%@", d];
            NSString *out = [self runCommand:@"/usr/sbin/hdparm"
                                        args:[NSArray arrayWithObjects:@"-B", devPath, nil]];
            if ([out length] == 0) continue;
            NSScanner *scanner = [NSScanner scannerWithString:out];
            if ([scanner scanUpToString:@"APM_level" intoString:nil]) {
                int apm = 255;
                [scanner scanInt:&apm];
                if (apm >= 1 && apm <= 127) return YES;
            }
        }
    }
    return NO;
#else
    return NO;
#endif
}

- (BOOL)writeHddSleep:(BOOL)enable
{
#if defined(__linux__)
    NSArray *disks = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:@"/sys/block" error:NULL];
    for (NSString *d in disks) {
        if ([d hasPrefix:@"sd"] || [d hasPrefix:@"nvme"]) {
            NSString *devPath = [NSString stringWithFormat:@"/dev/%@", d];
            NSString *apmVal = enable ? @"1" : @"254";
            NSString *sdVal = enable ? @"120" : @"0";
            [self runCommand:@"/bin/sh"
                        args:[NSArray arrayWithObjects:@"-c",
                              [NSString stringWithFormat:@"/usr/bin/sudo /usr/sbin/hdparm -B %@ -S %@ '%@' > /dev/null 2>&1",
                               apmVal, sdVal, devPath], nil]];
        }
    }
    return YES;
#else
    return YES;
#endif
}

- (BOOL)readWakeNetwork
{
#if defined(__linux__)
    NSArray *interfaces = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:@"/sys/class/net" error:NULL];
    for (NSString *iface in interfaces) {
        if ([iface isEqualToString:@"lo"]) continue;
        NSString *out = [self runCommand:@"/usr/sbin/ethtool"
                                    args:[NSArray arrayWithObjects:iface, nil]];
        if ([out rangeOfString:@"Wake-on: g"].location != NSNotFound) return YES;
        if ([out rangeOfString:@"Wake-on: p"].location != NSNotFound) return YES;
    }
    return NO;
#else
    return NO;
#endif
}

- (BOOL)writeWakeNetwork:(BOOL)enable
{
#if defined(__linux__)
    NSArray *interfaces = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:@"/sys/class/net" error:NULL];
    for (NSString *iface in interfaces) {
        if ([iface isEqualToString:@"lo"]) continue;
        NSString *wol = enable ? @"g" : @"d";
        [self runCommand:@"/bin/sh"
                    args:[NSArray arrayWithObjects:@"-c",
                          [NSString stringWithFormat:@"/usr/bin/sudo /usr/sbin/ethtool -s '%@' wol %@ > /dev/null 2>&1",
                           iface, wol], nil]];
    }
    return YES;
#else
    return YES;
#endif
}

- (BOOL)readPowerFail
{
#if defined(__linux__)
    NSString *wakealarm = [self readFile:@"/sys/class/rtc/rtc0/wakealarm"];
    return ([wakealarm length] > 0 && ![wakealarm isEqualToString:@"0"]);
#else
    return NO;
#endif
}

- (BOOL)writePowerFail:(BOOL)enable
{
#if defined(__linux__)
    if (enable) {
        time_t now = time(NULL);
        time_t then = now + 86400;
        [self writeSysfs:@"/sys/class/rtc/rtc0/wakealarm" value:@"0"];
        [self writeSysfs:@"/sys/class/rtc/rtc0/wakealarm"
                   value:[NSString stringWithFormat:@"%ld", (long)then]];
    } else {
        [self writeSysfs:@"/sys/class/rtc/rtc0/wakealarm" value:@"0"];
    }
    return YES;
#else
    return YES;
#endif
}

#pragma mark - Polling

- (void)pollBattery
{
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        NSDictionary *batt = [self readBatteryInfo];
        NSString *source = [batt objectForKey:@"source"];
        int percent = [[batt objectForKey:@"percent"] intValue];
        NSString *status = [batt objectForKey:@"status"];

        dispatch_async(dispatch_get_main_queue(), ^{
            if ([source isEqualToString:@"AC"]) {
                NSString *src = @"Source: AC Power";
                if ([status length] > 0) {
                    src = [src stringByAppendingFormat:@" (%@)", status];
                }
                [sourceLabel setStringValue:src];
            } else if ([source isEqualToString:@"Battery"]) {
                [sourceLabel setStringValue:@"Source: Battery"];
            }

            if (percent >= 0) {
                [batteryPercentLabel setStringValue:[NSString stringWithFormat:@"Battery: %d%%", percent]];
            }
        });
    });
}

@end
