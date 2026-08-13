/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "MouseController.h"
#import "AppearanceMetrics.h"
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

/* Layout helpers (HIG group boxes and rows). */
- (NSBox *)groupBoxWithTitle:(NSString *)title frame:(NSRect)frame inView:(NSView *)parent;
- (NSTextField *)labelWithText:(NSString *)text frame:(NSRect)frame alignment:(NSTextAlignment)align;
- (void)addCheckbox:(NSButton *)checkbox toBox:(NSBox *)box y:(CGFloat)y width:(CGFloat)w;
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
@interface MouseMainView : NSView
{
    MouseController *_layoutOwner;
}
@end

@implementation MouseMainView
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
- (void)setLayoutOwner:(MouseController *)owner
{
    _layoutOwner = owner;
}
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

    const CGFloat winW = 560, winH = 445;
    const CGFloat sideMargin = METRICS_CONTENT_SIDE_MARGIN;      /* 24 */
    const CGFloat topMargin = METRICS_CONTENT_TOP_MARGIN;        /* 15 */
    const CGFloat bottomMargin = METRICS_CONTENT_BOTTOM_MARGIN;  /* 20 */
    const CGFloat boxGap = METRICS_SPACE_12;                     /* between group boxes */
    const CGFloat rowGap = METRICS_SPACE_8;
    const CGFloat rowH = 20;                                     /* checkbox line spacing */
    const CGFloat sliderRowH = METRICS_TEXT_INPUT_FIELD_HEIGHT;  /* 22 */
    /* NSBox with NSAtTop title reserves ~14px for the title text before
       its content area starts.  The first control must clear that. */
    const CGFloat boxTitleInset = 14.0;
    /* Group-box heights sized to their content (title inset + rows +
       16px inner margin top and bottom), so the status line at the
       bottom does not overlap the last box. */
    const CGFloat mouseBoxH = 96;
    const CGFloat trackpadBoxH = 176;
    const CGFloat trackpointBoxH = 68;

    mainView = [[MouseMainView alloc] initWithFrame:NSMakeRect(0, 0, winW, winH)];
    [(MouseMainView *)mainView setLayoutOwner:self];
    [mainView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    CGFloat contentW = winW - 2 * sideMargin;
    CGFloat boxW = contentW;

    CGFloat y = winH - topMargin;

    /* ---- Mouse group box ---- */
    mouseBox = [self groupBoxWithTitle:@"Mouse"
                                frame:NSMakeRect(sideMargin, y - mouseBoxH, boxW, mouseBoxH)
                               inView:mainView];
    {
        CGFloat by = mouseBoxH - boxTitleInset - METRICS_SPACE_16 - rowH;
        [self addCheckbox:leftHandedCheckbox = [[[NSButton alloc]
                    initWithFrame:NSZeroRect] autorelease]
                    toBox:mouseBox y:by width:boxW];
        [leftHandedCheckbox setButtonType:NSSwitchButton];
        [leftHandedCheckbox setTitle:@"Swap left and right buttons"];
        [leftHandedCheckbox setTarget:self];
        [leftHandedCheckbox setAction:@selector(settingChanged:)];

        by -= rowGap + sliderRowH;
        [self addSliderRowWithLabel:@"Tracking speed:"
                             slider:mouseSpeedSlider =
                             [[[NSSlider alloc] initWithFrame:NSZeroRect] autorelease]
                              value:mouseSpeedLabel =
                             [[[NSTextField alloc] initWithFrame:NSZeroRect] autorelease]
                              toBox:mouseBox y:by width:boxW];
        [mouseSpeedSlider setMinValue:-1.0];
        [mouseSpeedSlider setMaxValue:1.0];
        [mouseSpeedSlider setFloatValue:0.0];
        [mouseSpeedSlider setNumberOfTickMarks:11];
        [mouseSpeedSlider setAllowsTickMarkValuesOnly:NO];
        [mouseSpeedSlider setContinuous:YES];
        [mouseSpeedSlider setTarget:self];
        [mouseSpeedSlider setAction:@selector(settingChanged:)];
        [mouseSpeedLabel setStringValue:@"0.00"];
    }
    y -= mouseBoxH + boxGap;

    /* ---- Trackpad group box ---- */
    trackpadBox = [self groupBoxWithTitle:@"Trackpad"
                                    frame:NSMakeRect(sideMargin, y - trackpadBoxH, boxW, trackpadBoxH)
                                   inView:mainView];
    {
        CGFloat by = trackpadBoxH - boxTitleInset - METRICS_SPACE_16 - rowH;
        [self addCheckbox:tapToClickCheckbox =
                   [[[NSButton alloc] initWithFrame:NSZeroRect] autorelease]
                    toBox:trackpadBox y:by width:boxW];
        [tapToClickCheckbox setButtonType:NSSwitchButton];
        [tapToClickCheckbox setTitle:@"Tap to click"];
        [tapToClickCheckbox setTarget:self];
        [tapToClickCheckbox setAction:@selector(settingChanged:)];
        by -= rowH;

        [self addCheckbox:twoFingerRightClickCheckbox =
                   [[[NSButton alloc] initWithFrame:NSZeroRect] autorelease]
                    toBox:trackpadBox y:by width:boxW];
        [twoFingerRightClickCheckbox setButtonType:NSSwitchButton];
        [twoFingerRightClickCheckbox setTitle:@"Two-finger tap = right click"];
        [twoFingerRightClickCheckbox setTarget:self];
        [twoFingerRightClickCheckbox setAction:@selector(settingChanged:)];
        by -= rowH;

        [self addCheckbox:threeFingerMiddleClickCheckbox =
                   [[[NSButton alloc] initWithFrame:NSZeroRect] autorelease]
                    toBox:trackpadBox y:by width:boxW];
        [threeFingerMiddleClickCheckbox setButtonType:NSSwitchButton];
        [threeFingerMiddleClickCheckbox setTitle:@"Three-finger tap = middle click"];
        [threeFingerMiddleClickCheckbox setTarget:self];
        [threeFingerMiddleClickCheckbox setAction:@selector(settingChanged:)];
        by -= rowH;

        [self addCheckbox:disableWhileTypingCheckbox =
                   [[[NSButton alloc] initWithFrame:NSZeroRect] autorelease]
                    toBox:trackpadBox y:by width:boxW];
        [disableWhileTypingCheckbox setButtonType:NSSwitchButton];
        [disableWhileTypingCheckbox setTitle:@"Disable trackpad while typing"];
        [disableWhileTypingCheckbox setTarget:self];
        [disableWhileTypingCheckbox setAction:@selector(settingChanged:)];
        by -= rowH;

        [self addCheckbox:naturalScrollingCheckbox =
                   [[[NSButton alloc] initWithFrame:NSZeroRect] autorelease]
                    toBox:trackpadBox y:by width:boxW];
        [naturalScrollingCheckbox setButtonType:NSSwitchButton];
        [naturalScrollingCheckbox setTitle:@"Reverse scrolling direction"];
        [naturalScrollingCheckbox setTarget:self];
        [naturalScrollingCheckbox setAction:@selector(settingChanged:)];
        by -= rowGap + sliderRowH;

        [self addSliderRowWithLabel:@"Tracking speed:"
                             slider:trackpadSpeedSlider =
                             [[[NSSlider alloc] initWithFrame:NSZeroRect] autorelease]
                              value:trackpadSpeedLabel =
                             [[[NSTextField alloc] initWithFrame:NSZeroRect] autorelease]
                              toBox:trackpadBox y:by width:boxW];
        [trackpadSpeedSlider setMinValue:-1.0];
        [trackpadSpeedSlider setMaxValue:1.0];
        [trackpadSpeedSlider setFloatValue:0.0];
        [trackpadSpeedSlider setNumberOfTickMarks:11];
        [trackpadSpeedSlider setAllowsTickMarkValuesOnly:NO];
        [trackpadSpeedSlider setContinuous:YES];
        [trackpadSpeedSlider setTarget:self];
        [trackpadSpeedSlider setAction:@selector(settingChanged:)];
        [trackpadSpeedLabel setStringValue:@"0.00"];
    }
    y -= trackpadBoxH + boxGap;

    /* ---- TrackPoint group box ---- */
    trackpointBox = [self groupBoxWithTitle:@"TrackPoint"
                                      frame:NSMakeRect(sideMargin, y - trackpointBoxH, boxW, trackpointBoxH)
                                     inView:mainView];
    {
        CGFloat by = trackpointBoxH - boxTitleInset - METRICS_SPACE_16 - sliderRowH;
        [self addSliderRowWithLabel:@"Tracking speed:"
                             slider:trackpointSpeedSlider =
                             [[[NSSlider alloc] initWithFrame:NSZeroRect] autorelease]
                              value:trackpointSpeedLabel =
                             [[[NSTextField alloc] initWithFrame:NSZeroRect] autorelease]
                              toBox:trackpointBox y:by width:boxW];
        [trackpointSpeedSlider setMinValue:-1.0];
        [trackpointSpeedSlider setMaxValue:1.0];
        [trackpointSpeedSlider setFloatValue:0.0];
        [trackpointSpeedSlider setNumberOfTickMarks:11];
        [trackpointSpeedSlider setAllowsTickMarkValuesOnly:NO];
        [trackpointSpeedSlider setContinuous:YES];
        [trackpointSpeedSlider setTarget:self];
        [trackpointSpeedSlider setAction:@selector(settingChanged:)];
        [trackpointSpeedLabel setStringValue:@"0.00"];
    }

    // Status label at the bottom, bottom-anchored
    statusLabel = [self labelWithText:@""
                                frame:NSMakeRect(sideMargin, bottomMargin,
                                                contentW, 20)
                              alignment:NSTextAlignmentLeft];
    [statusLabel setFont:[NSFont systemFontOfSize:10]];
    [statusLabel setAutoresizingMask:(NSViewWidthSizable | NSViewMaxYMargin)];
    [mainView addSubview:statusLabel];

    [self updateSectionTitles];
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

    if (mouseBox) {
        f = [mouseBox frame];
        f.origin.x = sideMargin;
        f.size.width = width - 2 * sideMargin;
        [mouseBox setFrame:f];
    }
    if (trackpadBox) {
        f = [trackpadBox frame];
        f.origin.x = sideMargin;
        f.size.width = width - 2 * sideMargin;
        [trackpadBox setFrame:f];
    }
    if (trackpointBox) {
        f = [trackpointBox frame];
        f.origin.x = sideMargin;
        f.size.width = width - 2 * sideMargin;
        [trackpointBox setFrame:f];
    }
    if (statusLabel) {
        f = [statusLabel frame];
        f.origin.x = sideMargin;
        f.size.width = width - 2 * sideMargin;
        [statusLabel setFrame:f];
    }
}

/* Build a titled group box, top-anchored and width-flexible. */
- (NSBox *)groupBoxWithTitle:(NSString *)title frame:(NSRect)frame inView:(NSView *)parent
{
    NSBox *box = [[NSBox alloc] initWithFrame:frame];
    [box setTitle:title];
    [box setBoxType:NSBoxPrimary];
    [box setTitlePosition:NSAtTop];
    /* Bezel border: Eau draws bezel boxes with rounded corners
       (drawDarkBezel:), a plain line border stays square. */
    [box setBorderType:NSBezelBorder];
    /* Width is managed by relayoutWithWidth: so margins stay symmetric;
       keep vertical position only. */
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
   Width-flexible so it tracks the box when the pane is wider than the
   560px base layout the Mouse pane was designed for. */
- (void)addCheckbox:(NSButton *)checkbox toBox:(NSBox *)box y:(CGFloat)y width:(CGFloat)w
{
    [checkbox setFrame:NSMakeRect(METRICS_SPACE_16, y, w - 2 * METRICS_SPACE_16, 18)];
    [checkbox setAutoresizingMask:NSViewWidthSizable];
    [box addSubview:checkbox];
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
    [box addSubview:value];
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
