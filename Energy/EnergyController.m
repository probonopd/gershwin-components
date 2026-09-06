/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "EnergyController.h"
#import "AppearanceMetrics.h"
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

/* Layout helpers (HIG group boxes and rows). */
- (NSBox *)groupBoxWithTitle:(NSString *)title frame:(NSRect)frame inView:(NSView *)parent;
- (NSTextField *)labelWithText:(NSString *)text frame:(NSRect)frame alignment:(NSTextAlignment)align;
- (void)addCheckbox:(NSButton *)checkbox toBox:(NSBox *)box y:(CGFloat)y width:(CGFloat)w;
- (NSTextField *)addInfoRowWithText:(NSString *)text toBox:(NSBox *)box y:(CGFloat)y width:(CGFloat)w;
- (void)addPopUpRowWithLabel:(NSString *)label
                      popup:(NSPopUpButton *)popup
                      toBox:(NSBox *)box
                          y:(CGFloat)y
                      width:(CGFloat)w;
- (void)addSliderRowWithLabel:(NSString *)label
                       slider:(NSSlider *)slider
                        value:(NSTextField *)value
                        toBox:(NSBox *)box
                            y:(CGFloat)y
                        width:(CGFloat)w;
@end

/* The pane view. When the host window gives us a width (which is not the
   560px base we built at), re-lay out the group boxes so the left/right
   margins to the window edge stay symmetric. */
@interface EnergyMainView : NSView
{
    EnergyController *_layoutOwner;
}
@end

@implementation EnergyMainView
- (void)setFrameSize:(NSSize)newSize
{
    [super setFrameSize:newSize];
    [_layoutOwner relayoutWithWidth:newSize.width];
}
- (void)viewDidMoveToWindow
{
    [super viewDidMoveToWindow];
    if ([self window] && [self superview]) {
        /* The host window does not necessarily size the pane view to its
           content area; make it fill the box content and re-lay out so the
           left/right margins stay symmetric.  GNUstep's setFrame: bypasses
           setFrameSize:, so re-lay out explicitly here. */
        [self setFrame:[[self superview] bounds]];
        [_layoutOwner relayoutWithWidth:[self bounds].size.width];
    }
}
- (void)setLayoutOwner:(EnergyController *)owner
{
    _layoutOwner = owner;
}
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
    const CGFloat winW = 560, winH = 440;
    const CGFloat sideMargin = METRICS_CONTENT_SIDE_MARGIN;      /* 24 */
    const CGFloat topMargin = METRICS_CONTENT_TOP_MARGIN;        /* 15 */
    const CGFloat bottomMargin = METRICS_SPACE_12;               /* under status line */
    const CGFloat boxGap = METRICS_SPACE_8;                      /* between group boxes */
    const CGFloat rowH = METRICS_TEXT_INPUT_FIELD_HEIGHT;        /* 22 */
    const CGFloat rowGap = METRICS_SPACE_8;
    const CGFloat checkboxRowH = METRICS_RADIO_BUTTON_LINE_SPACING; /* 20 */
    const CGFloat boxTitleInset = 14.0;
    /* Group-box heights sized to their content (title inset + rows +
       16px inner margin top and bottom). */
    const CGFloat powerBoxH = 128;      /* source, battery, governor */
    const CGFloat displayBoxH = 98;     /* brightness slider, blank popup */
    const CGFloat powerMgmtBoxH = 126;  /* 4 checkboxes */

    mainView = [[EnergyMainView alloc] initWithFrame:NSMakeRect(0, 0, winW, winH)];
    [(EnergyMainView *)mainView setLayoutOwner:self];
    [mainView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    CGFloat contentW = winW - 2 * sideMargin;
    CGFloat boxW = contentW;

    CGFloat y = winH - topMargin;

    /* ---- Power group box ---- */
    powerBox = [self groupBoxWithTitle:@"Power"
                                frame:NSMakeRect(sideMargin, y - powerBoxH, boxW, powerBoxH)
                               inView:mainView];
    {
        CGFloat by = powerBoxH - boxTitleInset - METRICS_SPACE_16 - rowH;
        sourceLabel = [self addInfoRowWithText:@"Source: reading..."
                                         toBox:powerBox y:by width:boxW];
        [sourceLabel retain];

        by -= rowGap + rowH;
        batteryPercentLabel = [self addInfoRowWithText:@"Battery: --%"
                                                 toBox:powerBox y:by width:boxW];
        [batteryPercentLabel retain];

        by -= rowGap + rowH;
        [self addPopUpRowWithLabel:@"Governor:"
                            popup:governorPopUp =
                            [[[NSPopUpButton alloc] initWithFrame:NSZeroRect] autorelease]
                            toBox:powerBox y:by width:boxW];
    }
    y -= powerBoxH + boxGap;

    /* ---- Display group box ---- */
    displayBox = [self groupBoxWithTitle:@"Display"
                                  frame:NSMakeRect(sideMargin, y - displayBoxH, boxW, displayBoxH)
                                 inView:mainView];
    {
        CGFloat by = displayBoxH - boxTitleInset - METRICS_SPACE_16 - rowH;
        [self addSliderRowWithLabel:@"Brightness:"
                             slider:brightnessSlider =
                             [[[NSSlider alloc] initWithFrame:NSZeroRect] autorelease]
                              value:brightnessLabel =
                             [[[NSTextField alloc] initWithFrame:NSZeroRect] autorelease]
                              toBox:displayBox y:by width:boxW];
        [brightnessSlider setMinValue:1];
        [brightnessSlider setMaxValue:100];
        [brightnessSlider setFloatValue:100];
        [brightnessSlider setNumberOfTickMarks:11];
        [brightnessSlider setAllowsTickMarkValuesOnly:NO];
        [brightnessSlider setContinuous:YES];
        [brightnessSlider setTarget:self];
        [brightnessSlider setAction:@selector(settingChanged:)];
        [brightnessLabel setStringValue:@"100%"];

        by -= rowGap + rowH;
        [self addPopUpRowWithLabel:@"Screen blanks:"
                            popup:blankPopUp =
                            [[[NSPopUpButton alloc] initWithFrame:NSZeroRect] autorelease]
                            toBox:displayBox y:by width:boxW];
        [blankPopUp addItemWithTitle:@"Never"];
        [blankPopUp addItemWithTitle:@"1 minute"];
        [blankPopUp addItemWithTitle:@"5 minutes"];
        [blankPopUp addItemWithTitle:@"10 minutes"];
        [blankPopUp addItemWithTitle:@"15 minutes"];
        [blankPopUp addItemWithTitle:@"30 minutes"];
    }
    y -= displayBoxH + boxGap;

    /* ---- Power Management group box ---- */
    powerMgmtBox = [self groupBoxWithTitle:@"Power Management"
                                    frame:NSMakeRect(sideMargin, y - powerMgmtBoxH, boxW, powerMgmtBoxH)
                                   inView:mainView];
    {
        CGFloat by = powerMgmtBoxH - boxTitleInset - METRICS_SPACE_16 - checkboxRowH;
        [self addCheckbox:preventSleepCheckbox =
                   [[[NSButton alloc] initWithFrame:NSZeroRect] autorelease]
                    toBox:powerMgmtBox y:by width:boxW];
        [preventSleepCheckbox setButtonType:NSSwitchButton];
        [preventSleepCheckbox setTitle:@"Prevent computer from sleeping when display is off"];
        by -= checkboxRowH;

        [self addCheckbox:hddSleepCheckbox =
                   [[[NSButton alloc] initWithFrame:NSZeroRect] autorelease]
                    toBox:powerMgmtBox y:by width:boxW];
        [hddSleepCheckbox setButtonType:NSSwitchButton];
        [hddSleepCheckbox setTitle:@"Put hard disks to sleep when possible"];
        by -= checkboxRowH;

        [self addCheckbox:wakeNetworkCheckbox =
                   [[[NSButton alloc] initWithFrame:NSZeroRect] autorelease]
                    toBox:powerMgmtBox y:by width:boxW];
        [wakeNetworkCheckbox setButtonType:NSSwitchButton];
        [wakeNetworkCheckbox setTitle:@"Wake for network access"];
        by -= checkboxRowH;

        [self addCheckbox:powerFailCheckbox =
                   [[[NSButton alloc] initWithFrame:NSZeroRect] autorelease]
                    toBox:powerMgmtBox y:by width:boxW];
        [powerFailCheckbox setButtonType:NSSwitchButton];
        [powerFailCheckbox setTitle:@"Start up automatically after a power failure"];
    }

    /* Status label at the bottom, bottom-anchored */
    statusLabel = [self labelWithText:@""
                                frame:NSMakeRect(sideMargin, bottomMargin,
                                                contentW, 18)
                              alignment:NSTextAlignmentLeft];
    [statusLabel setFont:[NSFont systemFontOfSize:10]];
    [statusLabel setAutoresizingMask:(NSViewWidthSizable | NSViewMaxYMargin)];
    [mainView addSubview:statusLabel];

    [self refreshFromSystem];
    return mainView;
}

/* Re-lay out the group boxes for the given view width, keeping the
   left and right margins equal. Called whenever the host resizes the
   pane view. */
- (void)relayoutWithWidth:(CGFloat)width
{
    const CGFloat sideMargin = METRICS_CONTENT_SIDE_MARGIN;  /* 24 */
    NSRect f;

    if (powerBox) {
        f = [powerBox frame];
        f.origin.x = sideMargin;
        f.size.width = width - 2 * sideMargin;
        [powerBox setFrame:f];
    }
    if (displayBox) {
        f = [displayBox frame];
        f.origin.x = sideMargin;
        f.size.width = width - 2 * sideMargin;
        [displayBox setFrame:f];
    }
    if (powerMgmtBox) {
        f = [powerMgmtBox frame];
        f.origin.x = sideMargin;
        f.size.width = width - 2 * sideMargin;
        [powerMgmtBox setFrame:f];
    }
    if (statusLabel) {
        f = [statusLabel frame];
        f.origin.x = sideMargin;
        f.size.width = width - 2 * sideMargin;
        [statusLabel setFrame:f];
    }
}

/* Build a titled group box, top-anchored. Width is managed by
   relayoutWithWidth: so margins stay symmetric. */
- (NSBox *)groupBoxWithTitle:(NSString *)title frame:(NSRect)frame inView:(NSView *)parent
{
    NSBox *box = [[NSBox alloc] initWithFrame:frame];
    [box setTitle:title];
    [box setBoxType:NSBoxPrimary];
    [box setTitlePosition:NSAtTop];
    [box setBorderType:NSBezelBorder];
    [box setAutoresizingMask:NSViewMinYMargin];
    [parent addSubview:box];
    return box;
}

/* A plain read-only label. */
- (NSTextField *)labelWithText:(NSString *)text frame:(NSRect)frame alignment:(NSTextAlignment)align
{
    NSTextField *label = [[NSTextField alloc] initWithFrame:frame];
    [label setStringValue:text ?: @""];
    [label setBezeled:NO];
    [label setEditable:NO];
    [label setSelectable:NO];
    [label setDrawsBackground:NO];
    [label setFont:[NSFont systemFontOfSize:11]];
    [label setAlignment:align];
    return label;
}

/* Position a checkbox in the top-left of a group box's content area.
   Width-flexible so it tracks the box. */
- (void)addCheckbox:(NSButton *)checkbox toBox:(NSBox *)box y:(CGFloat)y width:(CGFloat)w
{
    [checkbox setFrame:NSMakeRect(METRICS_SPACE_16, y, w - 2 * METRICS_SPACE_16, 18)];
    [checkbox setAutoresizingMask:NSViewWidthSizable];
    [box addSubview:checkbox];
}

/* A plain info row (source / battery status); returns the label. */
- (NSTextField *)addInfoRowWithText:(NSString *)text toBox:(NSBox *)box y:(CGFloat)y width:(CGFloat)w
{
    NSTextField *label = [self labelWithText:text
                                      frame:NSMakeRect(METRICS_SPACE_16, y + 1,
                                                      w - 2 * METRICS_SPACE_16, 20)
                                  alignment:NSTextAlignmentLeft];
    [label setFont:[NSFont systemFontOfSize:12]];
    [label setAutoresizingMask:NSViewWidthSizable];
    [box addSubview:label];
    return label;
}

/* A label + pop-up row: label on the left (right aligned), pop-up
   stretching to fill the rest of the row. */
- (void)addPopUpRowWithLabel:(NSString *)label
                      popup:(NSPopUpButton *)popup
                      toBox:(NSBox *)box
                          y:(CGFloat)y
                      width:(CGFloat)w
{
    const CGFloat pad = METRICS_SPACE_16;
    const CGFloat labelW = 110;
    const CGFloat gap = METRICS_SPACE_8;
    const CGFloat popupW = w - 2 * pad - labelW - gap;

    NSTextField *labelField = [self labelWithText:label
                                            frame:NSMakeRect(pad, y + 1, labelW, 20)
                                        alignment:NSTextAlignmentRight];
    [labelField setFont:[NSFont systemFontOfSize:11]];
    [labelField setAutoresizingMask:NSViewMaxXMargin];
    [box addSubview:labelField];
    [labelField release];

    [popup setFrame:NSMakeRect(pad + labelW + gap, y, popupW, 22)];
    [popup setAutoresizingMask:NSViewWidthSizable];
    [popup setTarget:self];
    [popup setAction:@selector(settingChanged:)];
    [box addSubview:popup];
}

/* A label + slider + value row in a group box: label on the left (right
   aligned), slider stretching, value label on the right. */
- (void)addSliderRowWithLabel:(NSString *)label
                       slider:(NSSlider *)slider
                        value:(NSTextField *)value
                        toBox:(NSBox *)box
                            y:(CGFloat)y
                        width:(CGFloat)w
{
    const CGFloat pad = METRICS_SPACE_16;
    const CGFloat labelW = 110;
    const CGFloat valueW = 50;
    const CGFloat gap = METRICS_SPACE_8;
    const CGFloat sliderW = w - 2 * pad - labelW - valueW - 2 * gap;

    NSTextField *labelField = [self labelWithText:label
                                            frame:NSMakeRect(pad, y + 1, labelW, 20)
                                        alignment:NSTextAlignmentRight];
    [labelField setFont:[NSFont systemFontOfSize:11]];
    [labelField setAutoresizingMask:NSViewMaxXMargin];
    [box addSubview:labelField];
    [labelField release];

    [slider setFrame:NSMakeRect(pad + labelW + gap, y, sliderW, 22)];
    [slider setAutoresizingMask:NSViewWidthSizable];
    [box addSubview:slider];

    [value setFrame:NSMakeRect(pad + labelW + gap + sliderW + gap, y, valueW, 20)];
    [value setAutoresizingMask:NSViewMinXMargin];
    [value setBezeled:NO];
    [value setEditable:NO];
    [value setSelectable:NO];
    [value setDrawsBackground:NO];
    [value setFont:[NSFont systemFontOfSize:11]];
    [value setAlignment:NSTextAlignmentRight];
    [box addSubview:value];
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
