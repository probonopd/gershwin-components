/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "MouseController.h"
#import <dispatch/dispatch.h>

static NSString *const kMouseDomain = @"MousePreferences";

@interface MouseController ()
- (NSString *)findXinput;
- (NSArray *)xinputDeviceNamesMatching:(NSString *)pattern;
- (void)enumerateDevices;
- (NSDictionary *)getPropertiesForDevice:(NSString *)device;
- (NSString *)propertyValue:(NSDictionary *)props name:(NSString *)name;
- (void)setProperty:(NSString *)prop forDevice:(NSString *)device value:(NSString *)value;
- (void)setBoolProperty:(NSString *)prop forDevice:(NSString *)device value:(BOOL)value;
- (void)applyAllSettings;
- (void)updateStatus:(NSString *)message;
@end

@implementation MouseController

- (id)init
{
    self = [super init];
    if (self) {
        isRefreshing = YES;
        xinputPath = nil;
        touchpadName = nil;
        mouseName = nil;
        trackpointName = nil;
    }
    return self;
}

- (void)dealloc
{
    [mainView release];
    [mouseSpeedSlider release];
    [mouseSpeedLabel release];
    [trackpadSpeedSlider release];
    [trackpadSpeedLabel release];
    [trackpointSpeedSlider release];
    [trackpointSpeedLabel release];
    [naturalScrollingCheckbox release];
    [tapToClickCheckbox release];
    [twoFingerRightClickCheckbox release];
    [threeFingerMiddleClickCheckbox release];
    [disableWhileTypingCheckbox release];
    [leftHandedCheckbox release];
    [statusLabel release];
    [xinputPath release];
    [touchpadName release];
    [mouseName release];
    [trackpointName release];
    [super dealloc];
}

- (NSString *)findXinput
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *candidates = [NSArray arrayWithObjects:
        @"/usr/bin/xinput",
        @"/usr/local/bin/xinput",
        @"/opt/local/bin/xinput",
        @"/opt/bin/xinput",
        @"/usr/pkg/bin/xinput",
        @"/usr/X11R6/bin/xinput",
        nil];
    for (NSString *path in candidates) {
        if ([fm isExecutableFileAtPath:path]) {
            return path;
        }
    }
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"/usr/bin/which"];
    [task setArguments:[NSArray arrayWithObject:@"xinput"]];
    NSPipe *pipe = [NSPipe pipe];
    [task setStandardOutput:pipe];
    [task launch];
    NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
    [task waitUntilExit];
    NSString *output = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
    [task release];
    NSString *trim = [output stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([trim length] > 0 && [fm isExecutableFileAtPath:trim]) {
        return trim;
    }
    return nil;
}

- (BOOL)matchesAny:(NSString *)name patterns:(NSArray *)patterns
{
    for (NSString *p in patterns) {
        if ([name rangeOfString:p].location != NSNotFound) {
            return YES;
        }
    }
    return NO;
}

- (NSArray *)xinputDeviceNamesMatching:(NSString *)pattern
{
    if (!xinputPath) {
        return [NSArray array];
    }
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:xinputPath];
    [task setArguments:[NSArray arrayWithObjects:@"list", @"--name-only", nil]];
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
    NSString *output = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
    [task release];
    NSMutableArray *result = [NSMutableArray array];
    NSArray *lines = [output componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    for (NSString *line in lines) {
        if ([line rangeOfString:pattern].location != NSNotFound) {
            [result addObject:[[line copy] autorelease]];
        }
    }
    return result;
}

- (void)enumerateDevices
{
    [touchpadName release];
    [mouseName release];
    [trackpointName release];
    touchpadName = nil;
    mouseName = nil;
    trackpointName = nil;

    // Check for touchpad using multiple patterns
    NSArray *tpNames = [self xinputDeviceNamesMatching:@"Touchpad"];
    if ([tpNames count] == 0) tpNames = [self xinputDeviceNamesMatching:@"Synaptics"];
    if ([tpNames count] == 0) tpNames = [self xinputDeviceNamesMatching:@"ELAN"];
    if ([tpNames count] == 0) tpNames = [self xinputDeviceNamesMatching:@"Alps"];
    if ([tpNames count] == 0) tpNames = [self xinputDeviceNamesMatching:@"bcm5974"];
    if ([tpNames count] == 0) tpNames = [self xinputDeviceNamesMatching:@"appletouch"];
    if ([tpNames count] > 0) {
        touchpadName = [[tpNames objectAtIndex:0] copy];
    }

    // TrackPoint
    NSArray *tppNames = [self xinputDeviceNamesMatching:@"TrackPoint"];
    if ([tppNames count] == 0) tppNames = [self xinputDeviceNamesMatching:@"Trackpoint"];
    if ([tppNames count] > 0) {
        trackpointName = [[tppNames objectAtIndex:0] copy];
    }

    // Mouse: first non-excluded name that isn't already classified
    NSArray *all = [self xinputDeviceNamesMatching:@""];
    for (NSString *name in all) {
        if ([self matchesAny:name patterns:@[
            @"XTEST", @"Virtual", @"virtual",
            @"keyboard", @"Keyboard", @"Button",
            @"HID ", @"HID/", @"Power Button",
            @"Sleep Button", @"Lid Switch", @"Video Bus",
            @"ums", @"wsmouse", @"sysmouse", @"pms",
        ]]) {
            continue;
        }
        if (touchpadName && [name isEqualToString:touchpadName]) continue;
        if (trackpointName && [name isEqualToString:trackpointName]) continue;
        if (mouseName == nil) {
            mouseName = [name copy];
        }
    }
}

- (NSDictionary *)getPropertiesForDevice:(NSString *)device
{
    if (!xinputPath || !device) {
        return [NSDictionary dictionary];
    }
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:xinputPath];
    [task setArguments:[NSArray arrayWithObjects:@"list-props", device, nil]];
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
    NSString *output = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
    [task release];
    // xinput list-props output format:
    //   libprop Name (ID): value...
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    NSArray *lines = [output componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    for (NSString *line in lines) {
        NSScanner *scanner = [NSScanner scannerWithString:line];
        NSString *propName = nil;
        if (![scanner scanUpToString:@"(" intoString:&propName]) {
            continue;
        }
        propName = [propName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([propName length] == 0) {
            continue;
        }
        // skip the parenthesized ID
        [scanner scanUpToString:@"):" intoString:nil];
        if (![scanner scanString:@"):" intoString:nil]) {
            continue;
        }
        NSString *value = nil;
        [scanner scanUpToString:@"\n" intoString:&value];
        if (value) {
            value = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        }
        if ([value length] > 0) {
            [result setObject:value forKey:propName];
        }
    }
    return result;
}

- (NSString *)propertyValue:(NSDictionary *)props name:(NSString *)name
{
    for (NSString *key in props) {
        if ([key rangeOfString:name].location != NSNotFound) {
            return [props objectForKey:key];
        }
    }
    return nil;
}

- (void)setProperty:(NSString *)prop forDevice:(NSString *)device value:(NSString *)value
{
    if (!xinputPath || !device || !prop) {
        return;
    }
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:xinputPath];
    [task setArguments:[NSArray arrayWithObjects:
        @"set-prop", device, prop, value, nil]];
    [task launch];
    [task waitUntilExit];
    [task release];
}

- (void)setBoolProperty:(NSString *)prop forDevice:(NSString *)device value:(BOOL)value
{
    [self setProperty:prop forDevice:device value:(value ? @"1" : @"0")];
}

- (NSView *)createMainView
{
    if (mainView) {
        return mainView;
    }
    xinputPath = [[self findXinput] retain];
    [self enumerateDevices];
    mainView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 560, 370)];
    CGFloat y = 352;
    CGFloat labelX = 20;
    CGFloat controlX = 160;
    CGFloat controlW = 260;
    CGFloat rowH = 22;

    // ---- Mouse Section ----
    NSTextField *mouseSection = [[NSTextField alloc] initWithFrame:NSMakeRect(labelX, y, 200, 18)];
    [mouseSection setBezeled:NO];
    [mouseSection setEditable:NO];
    [mouseSection setSelectable:NO];
    [mouseSection setDrawsBackground:NO];
    [mouseSection setStringValue:@"Mouse"];
    [mouseSection setFont:[NSFont boldSystemFontOfSize:13]];
    [mouseSection setAutoresizingMask:NSViewMaxYMargin];
    [mainView addSubview:mouseSection];
    [mouseSection release];
    y -= 20;

    // Left handed
    leftHandedCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(labelX + 10, y, 300, rowH)];
    [leftHandedCheckbox setButtonType:NSSwitchButton];
    [leftHandedCheckbox setTitle:@"Swap left and right buttons"];
    [leftHandedCheckbox setTarget:self];
    [leftHandedCheckbox setAction:@selector(settingChanged:)];
    [leftHandedCheckbox setAutoresizingMask:NSViewMaxYMargin];
    [mainView addSubview:leftHandedCheckbox];
    y -= 22;

    // Mouse speed slider
    NSTextField *mouseSpeedText = [[NSTextField alloc] initWithFrame:NSMakeRect(labelX + 10, y, 120, rowH)];
    [mouseSpeedText setBezeled:NO];
    [mouseSpeedText setEditable:NO];
    [mouseSpeedText setSelectable:NO];
    [mouseSpeedText setDrawsBackground:NO];
    [mouseSpeedText setStringValue:@"Tracking speed:"];
    [mouseSpeedText setAlignment:NSRightTextAlignment];
    [mouseSpeedText setFont:[NSFont systemFontOfSize:12]];
    [mouseSpeedText setAutoresizingMask:NSViewMaxYMargin];
    [mainView addSubview:mouseSpeedText];
    [mouseSpeedText release];
    mouseSpeedSlider = [[NSSlider alloc] initWithFrame:NSMakeRect(controlX, y + 2, controlW, rowH)];
    [mouseSpeedSlider setMinValue:-1.0];
    [mouseSpeedSlider setMaxValue:1.0];
    [mouseSpeedSlider setFloatValue:0.0];
    [mouseSpeedSlider setNumberOfTickMarks:11];
    [mouseSpeedSlider setAllowsTickMarkValuesOnly:NO];
    [mouseSpeedSlider setContinuous:YES];
    [mouseSpeedSlider setTarget:self];
    [mouseSpeedSlider setAction:@selector(settingChanged:)];
    [mouseSpeedSlider setAutoresizingMask:NSViewMaxYMargin];
    [mainView addSubview:mouseSpeedSlider];
    mouseSpeedLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(controlX + controlW + 10, y, 60, rowH)];
    [mouseSpeedLabel setBezeled:NO];
    [mouseSpeedLabel setEditable:NO];
    [mouseSpeedLabel setSelectable:NO];
    [mouseSpeedLabel setDrawsBackground:NO];
    [mouseSpeedLabel setStringValue:@"0.00"];
    [mouseSpeedLabel setFont:[NSFont systemFontOfSize:11]];
    [mouseSpeedLabel setAutoresizingMask:NSViewMaxYMargin];
    [mainView addSubview:mouseSpeedLabel];
    y -= 28;

    // ---- Separator ----
    NSBox *sep1 = [[NSBox alloc] initWithFrame:NSMakeRect(labelX, y - 2, 520, 1)];
    [sep1 setBoxType:NSBoxSeparator];
    [sep1 setAutoresizingMask:NSViewMaxYMargin | NSViewWidthSizable];
    [mainView addSubview:sep1];
    [sep1 release];
    y -= 16;

    // ---- Trackpad Section ----
    NSTextField *trackpadSection = [[NSTextField alloc] initWithFrame:NSMakeRect(labelX, y, 200, 18)];
    [trackpadSection setBezeled:NO];
    [trackpadSection setEditable:NO];
    [trackpadSection setSelectable:NO];
    [trackpadSection setDrawsBackground:NO];
    [trackpadSection setStringValue:@"Trackpad"];
    [trackpadSection setFont:[NSFont boldSystemFontOfSize:13]];
    [trackpadSection setAutoresizingMask:NSViewMaxYMargin];
    [mainView addSubview:trackpadSection];
    [trackpadSection release];
    y -= 20;

    // Tap to click
    tapToClickCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(labelX + 10, y, 300, rowH)];
    [tapToClickCheckbox setButtonType:NSSwitchButton];
    [tapToClickCheckbox setTitle:@"Tap to click"];
    [tapToClickCheckbox setTarget:self];
    [tapToClickCheckbox setAction:@selector(settingChanged:)];
    [tapToClickCheckbox setAutoresizingMask:NSViewMaxYMargin];
    [mainView addSubview:tapToClickCheckbox];
    y -= 22;

    // Two-finger right click
    twoFingerRightClickCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(labelX + 10, y, 300, rowH)];
    [twoFingerRightClickCheckbox setButtonType:NSSwitchButton];
    [twoFingerRightClickCheckbox setTitle:@"Two-finger tap = right click"];
    [twoFingerRightClickCheckbox setTarget:self];
    [twoFingerRightClickCheckbox setAction:@selector(settingChanged:)];
    [twoFingerRightClickCheckbox setAutoresizingMask:NSViewMaxYMargin];
    [mainView addSubview:twoFingerRightClickCheckbox];
    y -= 22;

    // Three-finger middle click
    threeFingerMiddleClickCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(labelX + 10, y, 300, rowH)];
    [threeFingerMiddleClickCheckbox setButtonType:NSSwitchButton];
    [threeFingerMiddleClickCheckbox setTitle:@"Three-finger tap = middle click"];
    [threeFingerMiddleClickCheckbox setTarget:self];
    [threeFingerMiddleClickCheckbox setAction:@selector(settingChanged:)];
    [threeFingerMiddleClickCheckbox setAutoresizingMask:NSViewMaxYMargin];
    [mainView addSubview:threeFingerMiddleClickCheckbox];
    y -= 22;

    // Disable while typing
    disableWhileTypingCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(labelX + 10, y, 300, rowH)];
    [disableWhileTypingCheckbox setButtonType:NSSwitchButton];
    [disableWhileTypingCheckbox setTitle:@"Disable trackpad while typing"];
    [disableWhileTypingCheckbox setTarget:self];
    [disableWhileTypingCheckbox setAction:@selector(settingChanged:)];
    [disableWhileTypingCheckbox setAutoresizingMask:NSViewMaxYMargin];
    [mainView addSubview:disableWhileTypingCheckbox];
    y -= 22;

    // Reverse scrolling direction
    naturalScrollingCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(labelX + 10, y, 300, rowH)];
    [naturalScrollingCheckbox setButtonType:NSSwitchButton];
    [naturalScrollingCheckbox setTitle:@"Reverse scrolling direction"];
    [naturalScrollingCheckbox setTarget:self];
    [naturalScrollingCheckbox setAction:@selector(settingChanged:)];
    [naturalScrollingCheckbox setAutoresizingMask:NSViewMaxYMargin];
    [mainView addSubview:naturalScrollingCheckbox];
    y -= 22;

    // Trackpad speed slider
    NSTextField *trackpadSpeedText = [[NSTextField alloc] initWithFrame:NSMakeRect(labelX + 10, y, 120, rowH)];
    [trackpadSpeedText setBezeled:NO];
    [trackpadSpeedText setEditable:NO];
    [trackpadSpeedText setSelectable:NO];
    [trackpadSpeedText setDrawsBackground:NO];
    [trackpadSpeedText setStringValue:@"Tracking speed:"];
    [trackpadSpeedText setAlignment:NSRightTextAlignment];
    [trackpadSpeedText setFont:[NSFont systemFontOfSize:12]];
    [trackpadSpeedText setAutoresizingMask:NSViewMaxYMargin];
    [mainView addSubview:trackpadSpeedText];
    [trackpadSpeedText release];
    trackpadSpeedSlider = [[NSSlider alloc] initWithFrame:NSMakeRect(controlX, y + 2, controlW, rowH)];
    [trackpadSpeedSlider setMinValue:-1.0];
    [trackpadSpeedSlider setMaxValue:1.0];
    [trackpadSpeedSlider setFloatValue:0.0];
    [trackpadSpeedSlider setNumberOfTickMarks:11];
    [trackpadSpeedSlider setAllowsTickMarkValuesOnly:NO];
    [trackpadSpeedSlider setContinuous:YES];
    [trackpadSpeedSlider setTarget:self];
    [trackpadSpeedSlider setAction:@selector(settingChanged:)];
    [trackpadSpeedSlider setAutoresizingMask:NSViewMaxYMargin];
    [mainView addSubview:trackpadSpeedSlider];
    trackpadSpeedLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(controlX + controlW + 10, y, 60, rowH)];
    [trackpadSpeedLabel setBezeled:NO];
    [trackpadSpeedLabel setEditable:NO];
    [trackpadSpeedLabel setSelectable:NO];
    [trackpadSpeedLabel setDrawsBackground:NO];
    [trackpadSpeedLabel setStringValue:@"0.00"];
    [trackpadSpeedLabel setFont:[NSFont systemFontOfSize:11]];
    [trackpadSpeedLabel setAutoresizingMask:NSViewMaxYMargin];
    [mainView addSubview:trackpadSpeedLabel];
    y -= 28;

    // ---- Separator ----
    NSBox *sep2 = [[NSBox alloc] initWithFrame:NSMakeRect(labelX, y - 2, 520, 1)];
    [sep2 setBoxType:NSBoxSeparator];
    [sep2 setAutoresizingMask:NSViewMaxYMargin | NSViewWidthSizable];
    [mainView addSubview:sep2];
    [sep2 release];
    y -= 16;

    // ---- TrackPoint Section ----
    NSTextField *trackpointSection = [[NSTextField alloc] initWithFrame:NSMakeRect(labelX, y, 200, 18)];
    [trackpointSection setBezeled:NO];
    [trackpointSection setEditable:NO];
    [trackpointSection setSelectable:NO];
    [trackpointSection setDrawsBackground:NO];
    [trackpointSection setStringValue:@"TrackPoint"];
    [trackpointSection setFont:[NSFont boldSystemFontOfSize:13]];
    [trackpointSection setAutoresizingMask:NSViewMaxYMargin];
    [mainView addSubview:trackpointSection];
    [trackpointSection release];
    y -= 20;

    // TrackPoint speed slider
    NSTextField *trackpointSpeedText = [[NSTextField alloc] initWithFrame:NSMakeRect(labelX + 10, y, 120, rowH)];
    [trackpointSpeedText setBezeled:NO];
    [trackpointSpeedText setEditable:NO];
    [trackpointSpeedText setSelectable:NO];
    [trackpointSpeedText setDrawsBackground:NO];
    [trackpointSpeedText setStringValue:@"Tracking speed:"];
    [trackpointSpeedText setAlignment:NSRightTextAlignment];
    [trackpointSpeedText setFont:[NSFont systemFontOfSize:12]];
    [trackpointSpeedText setAutoresizingMask:NSViewMaxYMargin];
    [mainView addSubview:trackpointSpeedText];
    [trackpointSpeedText release];
    trackpointSpeedSlider = [[NSSlider alloc] initWithFrame:NSMakeRect(controlX, y + 2, controlW, rowH)];
    [trackpointSpeedSlider setMinValue:-1.0];
    [trackpointSpeedSlider setMaxValue:1.0];
    [trackpointSpeedSlider setFloatValue:0.0];
    [trackpointSpeedSlider setNumberOfTickMarks:11];
    [trackpointSpeedSlider setAllowsTickMarkValuesOnly:NO];
    [trackpointSpeedSlider setContinuous:YES];
    [trackpointSpeedSlider setTarget:self];
    [trackpointSpeedSlider setAction:@selector(settingChanged:)];
    [trackpointSpeedSlider setAutoresizingMask:NSViewMaxYMargin];
    [mainView addSubview:trackpointSpeedSlider];
    trackpointSpeedLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(controlX + controlW + 10, y, 60, rowH)];
    [trackpointSpeedLabel setBezeled:NO];
    [trackpointSpeedLabel setEditable:NO];
    [trackpointSpeedLabel setSelectable:NO];
    [trackpointSpeedLabel setDrawsBackground:NO];
    [trackpointSpeedLabel setStringValue:@"0.00"];
    [trackpointSpeedLabel setFont:[NSFont systemFontOfSize:11]];
    [trackpointSpeedLabel setAutoresizingMask:NSViewMaxYMargin];
    [mainView addSubview:trackpointSpeedLabel];
    // Update section title availability indicators
    [self updateSectionTitles];
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

- (void)updateSectionTitles
{
    BOOL hasTrackpoint = ([trackpointName length] > 0);
    [trackpointSpeedSlider setEnabled:hasTrackpoint];
}

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
    // -- Natural Scrolling --
    BOOL natural = ([naturalScrollingCheckbox state] == NSOnState);
    if (touchpadName) {
        [self setBoolProperty:@"libinput Natural Scrolling Enabled"
                    forDevice:touchpadName value:natural];
    }
    if (mouseName) {
        [self setBoolProperty:@"libinput Natural Scrolling Enabled"
                    forDevice:mouseName value:natural];
    }
    if (trackpointName) {
        [self setBoolProperty:@"libinput Natural Scrolling Enabled"
                    forDevice:trackpointName value:natural];
    }
    // -- Left Handed --
    BOOL lefty = ([leftHandedCheckbox state] == NSOnState);
    if (touchpadName) {
        [self setBoolProperty:@"libinput Left Handed Enabled"
                    forDevice:touchpadName value:lefty];
    }
    if (mouseName) {
        [self setBoolProperty:@"libinput Left Handed Enabled"
                    forDevice:mouseName value:lefty];
    }
    if (trackpointName) {
        [self setBoolProperty:@"libinput Left Handed Enabled"
                    forDevice:trackpointName value:lefty];
    }
    // -- Mouse Speed --
    float mSpeed = [mouseSpeedSlider floatValue];
    [mouseSpeedLabel setFloatValue:mSpeed];
    if (touchpadName) {
        [self setProperty:@"libinput Accel Speed" forDevice:touchpadName
                    value:[NSString stringWithFormat:@"%.3f", mSpeed]];
    }
    if (mouseName) {
        [self setProperty:@"libinput Accel Speed" forDevice:mouseName
                    value:[NSString stringWithFormat:@"%.3f", mSpeed]];
    }
    // -- Trackpad Speed --
    float tSpeed = [trackpadSpeedSlider floatValue];
    [trackpadSpeedLabel setFloatValue:tSpeed];
    if (touchpadName) {
        [self setProperty:@"libinput Accel Speed" forDevice:touchpadName
                    value:[NSString stringWithFormat:@"%.3f", tSpeed]];
    }
    // -- TrackPoint Speed --
    float tpSpeed = [trackpointSpeedSlider floatValue];
    [trackpointSpeedLabel setFloatValue:tpSpeed];
    if (trackpointName) {
        [self setProperty:@"libinput Accel Speed" forDevice:trackpointName
                    value:[NSString stringWithFormat:@"%.3f", tpSpeed]];
    }
    // -- Tap to Click --
    BOOL tap = ([tapToClickCheckbox state] == NSOnState);
    if (touchpadName) {
        [self setBoolProperty:@"libinput Tapping Enabled"
                    forDevice:touchpadName value:tap];
    }
    // -- Tap Button Mapping --
    if (touchpadName) {
        BOOL twoFingerRC = ([twoFingerRightClickCheckbox state] == NSOnState);
        BOOL threeFingerMC = ([threeFingerMiddleClickCheckbox state] == NSOnState);
        NSString *mapVal = @"1, 0";
        if (threeFingerMC && !twoFingerRC) {
            mapVal = @"0, 0";
        } else if (twoFingerRC && !threeFingerMC) {
            mapVal = @"1, 0";
        } else if (twoFingerRC && threeFingerMC) {
            mapVal = @"1, 0";
        }
        [self setProperty:@"libinput Tapping Button Mapping"
                forDevice:touchpadName value:mapVal];
        if (threeFingerMC) {
            [self setProperty:@"libinput Clickfinger Button Mapping"
                    forDevice:touchpadName value:@"1, 0"];
        } else {
            [self setProperty:@"libinput Clickfinger Button Mapping"
                    forDevice:touchpadName value:@"1, 0"];
        }
    }
    // -- Disable While Typing --
    BOOL dwts = ([disableWhileTypingCheckbox state] == NSOnState);
    if (touchpadName) {
        [self setBoolProperty:@"libinput Disable While Typing Enabled"
                    forDevice:touchpadName value:dwts];
    }
    // -- Persist --
    [self persistSettings];
}

- (void)refreshFromSystem
{
    isRefreshing = YES;
    if (!xinputPath) {
        [self updateStatus:@"xinput not found. Install xinput package."];
        isRefreshing = NO;
        return;
    }
    [self enumerateDevices];
    [self updateSectionTitles];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSDictionary *tpProps = nil;
        NSDictionary *mProps = nil;
        NSDictionary *tppProps = nil;
        if (touchpadName) {
            tpProps = [self getPropertiesForDevice:touchpadName];
        }
        if (mouseName) {
            mProps = [self getPropertiesForDevice:mouseName];
        }
        if (trackpointName) {
            tppProps = [self getPropertiesForDevice:trackpointName];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *tpSpeedStr = [self propertyValue:tpProps name:@"Accel Speed"];
            NSString *mSpeedStr = [self propertyValue:mProps name:@"Accel Speed"];
            NSString *tppSpeedStr = [self propertyValue:tppProps name:@"Accel Speed"];
            NSString *tpTapStr = [self propertyValue:tpProps name:@"Tapping Enabled"];
            NSString *tpNaturalStr = [self propertyValue:tpProps name:@"Natural Scrolling Enabled"];
            NSString *mNaturalStr = [self propertyValue:mProps name:@"Natural Scrolling Enabled"];
            NSString *tpLeftStr = [self propertyValue:tpProps name:@"Left Handed Enabled"];
            NSString *mLeftStr = [self propertyValue:mProps name:@"Left Handed Enabled"];
            NSString *tpDwtStr = [self propertyValue:tpProps name:@"Disable While Typing Enabled"];
            NSString *tpBtnMapStr = [self propertyValue:tpProps name:@"Tapping Button Mapping"];
            // Set mouse speed (affects both touchpad and mouse via same slider)
            if (mSpeedStr) {
                [mouseSpeedSlider setFloatValue:[mSpeedStr floatValue]];
                [mouseSpeedLabel setStringValue:[NSString stringWithFormat:@"%.2f", [mSpeedStr floatValue]]];
            } else if (tpSpeedStr) {
                [mouseSpeedSlider setFloatValue:[tpSpeedStr floatValue]];
                [mouseSpeedLabel setStringValue:[NSString stringWithFormat:@"%.2f", [tpSpeedStr floatValue]]];
            }
            // Set trackpad speed
            if (tpSpeedStr) {
                [trackpadSpeedSlider setFloatValue:[tpSpeedStr floatValue]];
                [trackpadSpeedLabel setStringValue:[NSString stringWithFormat:@"%.2f", [tpSpeedStr floatValue]]];
            }
            // Set TrackPoint speed
            if (tppSpeedStr) {
                [trackpointSpeedSlider setFloatValue:[tppSpeedStr floatValue]];
                [trackpointSpeedLabel setStringValue:[NSString stringWithFormat:@"%.2f", [tppSpeedStr floatValue]]];
            }
            // Natural scrolling
            if (tpNaturalStr) {
                [naturalScrollingCheckbox setState:([tpNaturalStr intValue] ? NSOnState : NSOffState)];
            } else if (mNaturalStr) {
                [naturalScrollingCheckbox setState:([mNaturalStr intValue] ? NSOnState : NSOffState)];
            }
            // Left handed
            if (tpLeftStr) {
                [leftHandedCheckbox setState:([tpLeftStr intValue] ? NSOnState : NSOffState)];
            } else if (mLeftStr) {
                [leftHandedCheckbox setState:([mLeftStr intValue] ? NSOnState : NSOffState)];
            }
            // Tap to click
            if (tpTapStr) {
                [tapToClickCheckbox setState:([tpTapStr intValue] ? NSOnState : NSOffState)];
            }
            // Tap button mapping
            if (tpBtnMapStr) {
                NSArray *parts = [tpBtnMapStr componentsSeparatedByString:@","];
                if ([parts count] >= 2) {
                    int v1 = [[parts objectAtIndex:0] intValue];
                    int v2 = [[parts objectAtIndex:1] intValue];
                    // Default mapping: 1,0 = left/right; 0,1 = right/left; 0,0 = 3-finger
                    [twoFingerRightClickCheckbox setState:(v1 != 0 ? NSOnState : NSOffState)];
                    [threeFingerMiddleClickCheckbox setState:(v1 == 0 && v2 == 0 ? NSOnState : NSOffState)];
                }
            }
            // Disable while typing
            if (tpDwtStr) {
                [disableWhileTypingCheckbox setState:([tpDwtStr intValue] ? NSOnState : NSOffState)];
            }
            // Override with persisted user defaults (xinput may not persist across reboots)
            {
                NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
                NSDictionary *persisted = [defaults persistentDomainForName:kMouseDomain];
                if (persisted) {
                    NSNumber *val;

                    val = [persisted objectForKey:@"naturalScrolling"];
                    if (val) {
                        [naturalScrollingCheckbox setState:[val boolValue] ? NSOnState : NSOffState];
                    }
                    val = [persisted objectForKey:@"leftHanded"];
                    if (val) {
                        [leftHandedCheckbox setState:[val boolValue] ? NSOnState : NSOffState];
                    }
                    val = [persisted objectForKey:@"tapToClick"];
                    if (val) {
                        [tapToClickCheckbox setState:[val boolValue] ? NSOnState : NSOffState];
                    }
                    val = [persisted objectForKey:@"twoFingerRightClick"];
                    if (val) {
                        [twoFingerRightClickCheckbox setState:[val boolValue] ? NSOnState : NSOffState];
                    }
                    val = [persisted objectForKey:@"threeFingerMiddleClick"];
                    if (val) {
                        [threeFingerMiddleClickCheckbox setState:[val boolValue] ? NSOnState : NSOffState];
                    }
                    val = [persisted objectForKey:@"disableWhileTyping"];
                    if (val) {
                        [disableWhileTypingCheckbox setState:[val boolValue] ? NSOnState : NSOffState];
                    }
                    val = [persisted objectForKey:@"mouseSpeed"];
                    if (val) {
                        [mouseSpeedSlider setFloatValue:[val floatValue]];
                        [mouseSpeedLabel setStringValue:[NSString stringWithFormat:@"%.2f", [val floatValue]]];
                    }
                    val = [persisted objectForKey:@"trackpadSpeed"];
                    if (val) {
                        [trackpadSpeedSlider setFloatValue:[val floatValue]];
                        [trackpadSpeedLabel setStringValue:[NSString stringWithFormat:@"%.2f", [val floatValue]]];
                    }
                    val = [persisted objectForKey:@"trackpointSpeed"];
                    if (val) {
                        [trackpointSpeedSlider setFloatValue:[val floatValue]];
                        [trackpointSpeedLabel setStringValue:[NSString stringWithFormat:@"%.2f", [val floatValue]]];
                    }
                }
            }
            // Don't push here — let the user's toggle trigger applyAllSettings
            isRefreshing = NO;
            // Status message
            NSMutableString *status = [NSMutableString stringWithFormat:@"Applied"];
            if (touchpadName) {
                [status appendFormat:@" | Trackpad: %@", touchpadName];
            }
            if (mouseName) {
                [status appendFormat:@" | Mouse: %@", mouseName];
            }
            if (trackpointName) {
                [status appendFormat:@" | TrackPoint: %@", trackpointName];
            }
            [self updateStatus:status];
        });
    });
}

- (void)persistSettings
{
    NSMutableDictionary *domain = [NSMutableDictionary dictionary];
    [domain setObject:[NSNumber numberWithFloat:[mouseSpeedSlider floatValue]] forKey:@"mouseSpeed"];
    [domain setObject:[NSNumber numberWithFloat:[trackpadSpeedSlider floatValue]] forKey:@"trackpadSpeed"];
    [domain setObject:[NSNumber numberWithFloat:[trackpointSpeedSlider floatValue]] forKey:@"trackpointSpeed"];
    [domain setObject:[NSNumber numberWithBool:([naturalScrollingCheckbox state] == NSOnState)] forKey:@"naturalScrolling"];
    [domain setObject:[NSNumber numberWithBool:([leftHandedCheckbox state] == NSOnState)] forKey:@"leftHanded"];
    [domain setObject:[NSNumber numberWithBool:([tapToClickCheckbox state] == NSOnState)] forKey:@"tapToClick"];
    [domain setObject:[NSNumber numberWithBool:([twoFingerRightClickCheckbox state] == NSOnState)] forKey:@"twoFingerRightClick"];
    [domain setObject:[NSNumber numberWithBool:([threeFingerMiddleClickCheckbox state] == NSOnState)] forKey:@"threeFingerMiddleClick"];
    [domain setObject:[NSNumber numberWithBool:([disableWhileTypingCheckbox state] == NSOnState)] forKey:@"disableWhileTyping"];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setPersistentDomain:domain forName:kMouseDomain];
    [defaults synchronize];
}

- (void)updateStatus:(NSString *)message
{
    [statusLabel setStringValue:(message ? message : @"")];
}

@end
