/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "ColorAssistantPages.h"
#import "GSAssistantFramework.h"
#import "ColorAssistantDelegate.h"

#include <X11/Xlib.h>
#include <X11/extensions/Xrandr.h>

#pragma mark - Forward Declarations

@interface GammaController : NSObject
- (BOOL)selectDisplay:(NSString *)outputName;
- (void)applyGamma:(double)gamma whitePoint:(double)wp;
- (void)applyToneWithShadows:(double)s midtones:(double)m highlights:(double)h;
- (void)reset;
@end

@interface GammaPatternView : NSView
@end

#pragma mark - CADisplayPage

@interface CADisplayPage ()
{
    NSView *_pageView;
    NSPopUpButton *_popup;
    NSTextField *_infoLabel;
    NSMutableArray *_displayNames;
    NSMutableArray *_displayModes;
}
@end

@implementation CADisplayPage

- (instancetype)init
{
    self = [super init];
    if (self) {
        self.title = @"Select Display";
        self.stepDescription = @"Calibrate your display for accurate colors.";
        _displayNames = [[NSMutableArray alloc] init];
        _displayModes = [[NSMutableArray alloc] init];
    }
    return self;
}

- (NSView *)stepView
{
    if (!_pageView) {
        _pageView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 440, 180)];

        NSTextField *welcome = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 95, 440, 80)];
        [welcome setStringValue:@"Calibrate your display for accurate colors.\n"
         @"Adjust white point, gamma, and fine-tune the\n"
         @"tone response to match your preferences."];
        [welcome setBezeled:NO];
        [welcome setDrawsBackground:NO];
        [welcome setEditable:NO];
        [welcome setSelectable:NO];
        [welcome setFont:[NSFont systemFontOfSize:12]];
        [welcome setTextColor:[NSColor colorWithCalibratedWhite:0.3 alpha:1.0]];
        [[welcome cell] setWraps:YES];
        [[welcome cell] setScrollable:NO];
        [_pageView addSubview:welcome];

        NSTextField *label = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 72, 440, 20)];
        [label setStringValue:@"Select a display:"];
        [label setBezeled:NO];
        [label setDrawsBackground:NO];
        [label setEditable:NO];
        [label setSelectable:NO];
        [label setFont:[NSFont systemFontOfSize:13]];
        [_pageView addSubview:label];

        _popup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 42, 300, 24)];
        [_popup setTarget:self];
        [_popup setAction:@selector(displaySelected:)];
        [_pageView addSubview:_popup];

        _infoLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 15, 440, 20)];
        [_infoLabel setStringValue:@""];
        [_infoLabel setBezeled:NO];
        [_infoLabel setDrawsBackground:NO];
        [_infoLabel setEditable:NO];
        [_infoLabel setSelectable:NO];
        [_infoLabel setFont:[NSFont systemFontOfSize:11]];
        [_infoLabel setTextColor:[NSColor colorWithCalibratedWhite:0.4 alpha:1.0]];
        [_pageView addSubview:_infoLabel];
    }
    return _pageView;
}

- (void)stepWillAppear
{
    [_displayNames removeAllObjects];
    [_displayModes removeAllObjects];
    [_popup removeAllItems];

    Display *dpy = XOpenDisplay(NULL);
    if (dpy) {
        Window root = RootWindow(dpy, DefaultScreen(dpy));
        XRRScreenResources *res = XRRGetScreenResources(dpy, root);
        if (res) {
            for (int i = 0; i < res->noutput; i++) {
                XRROutputInfo *info = XRRGetOutputInfo(dpy, res, res->outputs[i]);
                if (info) {
                    NSString *name = [NSString stringWithUTF8String:info->name];
                    if (info->connection != RR_Disconnected) {
                        if (info->crtc) {
                            [_displayNames addObject:name];
                            XRRCrtcInfo *crtcInfo = XRRGetCrtcInfo(dpy, res, info->crtc);
                            if (crtcInfo) {
                                NSString *modeStr = [NSString stringWithFormat:@"%dx%d",
                                                              crtcInfo->width, crtcInfo->height];
                                [_displayModes addObject:modeStr];
                                XRRFreeCrtcInfo(crtcInfo);
                            } else {
                                [_displayModes addObject:@"Unknown"];
                            }
                        } else {
                            [_displayNames addObject:name];
                            [_displayModes addObject:@"Inactive"];
                        }
                    }
                    XRRFreeOutputInfo(info);
                }
            }
            XRRFreeScreenResources(res);
        }
        XCloseDisplay(dpy);
    }

    if ([_displayNames count] > 0) {
        for (NSString *name in _displayNames) {
            [_popup addItemWithTitle:name];
        }
        ColorAssistantDelegate *del = (ColorAssistantDelegate *)[self.assistantWindow delegate];
        NSString *saved = [del selectedDisplay];
        if (saved) {
            NSInteger idx = [_displayNames indexOfObject:saved];
            if (idx != NSNotFound) {
                [_popup selectItemAtIndex:idx];
            }
        }
        [self displaySelected:nil];
        [_popup setEnabled:YES];
    } else {
        [_popup addItemWithTitle:@"No displays found"];
        [_popup setEnabled:NO];
    }

    [self.assistantWindow updateNavigationButtons];
}

- (void)displaySelected:(id)sender
{
    NSInteger idx = [_popup indexOfSelectedItem];
    if (idx >= 0 && idx < (NSInteger)[_displayNames count]) {
        NSString *name = _displayNames[idx];
        NSString *mode = _displayModes[idx];
        ColorAssistantDelegate *del = (ColorAssistantDelegate *)[self.assistantWindow delegate];
        [del updateSelectedDisplay:name];
        [del.gammaCtrl selectDisplay:name];
        [_infoLabel setStringValue:[NSString stringWithFormat:@"%@, %@", name, mode]];
    }
    [self.assistantWindow updateNavigationButtons];
}

- (BOOL)canContinue
{
    return ([_displayNames count] > 0 &&
            [_popup indexOfSelectedItem] >= 0 &&
            [_popup indexOfSelectedItem] < (NSInteger)[_displayNames count]);
}

@end

#pragma mark - CAWhitePointPage

@interface CAWhitePointPage ()
{
    NSView *_pageView;
    NSSlider *_slider;
    NSTextField *_readout;
    double _currentWP;
}
@end

@implementation CAWhitePointPage

- (instancetype)init
{
    self = [super init];
    if (self) {
        self.title = @"Set White Point";
        self.stepDescription = @"Adjust the white point (color temperature) of your display.";
        _currentWP = 6500.0;
    }
    return self;
}

- (NSView *)stepView
{
    if (!_pageView) {
        _pageView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 440, 180)];

        NSTextField *label = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 150, 200, 20)];
        [label setStringValue:@"White Point (Color Temperature):"];
        [label setBezeled:NO];
        [label setDrawsBackground:NO];
        [label setEditable:NO];
        [label setSelectable:NO];
        [label setFont:[NSFont systemFontOfSize:13]];
        [_pageView addSubview:label];

        _readout = [[NSTextField alloc] initWithFrame:NSMakeRect(340, 150, 100, 20)];
        [_readout setStringValue:@"6500 K"];
        [_readout setBezeled:NO];
        [_readout setDrawsBackground:NO];
        [_readout setEditable:NO];
        [_readout setSelectable:NO];
        [_readout setFont:[NSFont boldSystemFontOfSize:13]];
        [_readout setAlignment:NSRightTextAlignment];
        [_pageView addSubview:_readout];

        _slider = [[NSSlider alloc] initWithFrame:NSMakeRect(0, 115, 440, 30)];
        [_slider setMinValue:5000];
        [_slider setMaxValue:7500];
        [_slider setDoubleValue:6500];
        [_slider setTarget:self];
        [_slider setAction:@selector(whitePointChanged:)];
        [_slider setNumberOfTickMarks:6];
        [_slider setAllowsTickMarkValuesOnly:NO];
        [_slider setContinuous:YES];
        [_pageView addSubview:_slider];

        NSArray *presets = @[
            @{@"title": @"D50", @"value": @5000},
            @{@"title": @"D65", @"value": @6500},
            @{@"title": @"Native", @"value": @0},
        ];
        CGFloat bx = 0;
        for (NSDictionary *preset in presets) {
            NSButton *btn = [[NSButton alloc] initWithFrame:NSMakeRect(bx, 75, 80, 24)];
            [btn setTitle:preset[@"title"]];
            [btn setButtonType:NSMomentaryPushInButton];
            [btn setBezelStyle:NSRoundedBezelStyle];
            [btn setTarget:self];
            [btn setAction:@selector(presetClicked:)];
            [btn setTag:[preset[@"value"] integerValue]];
            [_pageView addSubview:btn];
            bx += 88;
        }
    }
    return _pageView;
}

- (void)stepWillAppear
{
    ColorAssistantDelegate *del = (ColorAssistantDelegate *)[self.assistantWindow delegate];
    _currentWP = [del whitePoint];
    if (_currentWP < 5000) _currentWP = 6500;
    [_slider setDoubleValue:_currentWP];
    [_readout setStringValue:[NSString stringWithFormat:@"%.0f K", _currentWP]];
    double gamma = [del gammaValue];
    if (gamma < 0.1) gamma = 2.2;
    [del.gammaCtrl selectDisplay:[del selectedDisplay]];
    [del.gammaCtrl applyGamma:gamma whitePoint:_currentWP];
}

- (void)whitePointChanged:(id)sender
{
    _currentWP = [_slider doubleValue];
    [_readout setStringValue:[NSString stringWithFormat:@"%.0f K", _currentWP]];

    ColorAssistantDelegate *del = (ColorAssistantDelegate *)[self.assistantWindow delegate];
    [del setWhitePoint:_currentWP];
    [del.gammaCtrl applyGamma:[del gammaValue] whitePoint:_currentWP];
}

- (void)presetClicked:(id)sender
{
    NSInteger tag = [sender tag];
    double wp;
    if (tag == 0) {
        ColorAssistantDelegate *del = (ColorAssistantDelegate *)[self.assistantWindow delegate];
        [del.gammaCtrl selectDisplay:[del selectedDisplay]];
        wp = 6500;
    } else {
        wp = (double)tag;
    }
    [_slider setDoubleValue:wp];
    [self whitePointChanged:nil];
}

- (double)whitePoint
{
    return _currentWP;
}

- (void)setWhitePoint:(double)wp
{
    _currentWP = wp;
}

- (BOOL)canContinue
{
    return YES;
}

@end

#pragma mark - CAGammaPage

@interface CAGammaPage ()
{
    NSView *_pageView;
    NSSlider *_slider;
    NSTextField *_readout;
    double _currentGamma;
}
@end

@implementation CAGammaPage

- (instancetype)init
{
    self = [super init];
    if (self) {
        self.title = @"Set Gamma";
        self.stepDescription = @"Adjust the gamma (mid-tone contrast) of your display.";
        _currentGamma = 2.2;
    }
    return self;
}

- (NSView *)stepView
{
    if (!_pageView) {
        _pageView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 440, 280)];

        // Gamma reference pattern
        GammaPatternView *pattern = [[GammaPatternView alloc] initWithFrame:NSMakeRect(40, 190, 360, 80)];
        [_pageView addSubview:pattern];

        NSTextField *label = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 175, 200, 20)];
        [label setStringValue:@"Gamma:"];
        [label setBezeled:NO];
        [label setDrawsBackground:NO];
        [label setEditable:NO];
        [label setSelectable:NO];
        [label setFont:[NSFont systemFontOfSize:13]];
        [_pageView addSubview:label];

        _readout = [[NSTextField alloc] initWithFrame:NSMakeRect(340, 175, 100, 20)];
        [_readout setStringValue:@"2.2"];
        [_readout setBezeled:NO];
        [_readout setDrawsBackground:NO];
        [_readout setEditable:NO];
        [_readout setSelectable:NO];
        [_readout setFont:[NSFont boldSystemFontOfSize:13]];
        [_readout setAlignment:NSRightTextAlignment];
        [_pageView addSubview:_readout];

        _slider = [[NSSlider alloc] initWithFrame:NSMakeRect(0, 140, 440, 30)];
        [_slider setMinValue:1.0];
        [_slider setMaxValue:2.6];
        [_slider setDoubleValue:2.2];
        [_slider setTarget:self];
        [_slider setAction:@selector(gammaChanged:)];
        [_slider setNumberOfTickMarks:9];
        [_slider setAllowsTickMarkValuesOnly:NO];
        [_slider setContinuous:YES];
        [_pageView addSubview:_slider];

        NSArray *presets = @[
            @{@"title": @"1.8", @"value": @1.8},
            @{@"title": @"2.2", @"value": @2.2},
            @{@"title": @"Native", @"value": @0},
        ];
        CGFloat bx = 0;
        for (NSDictionary *preset in presets) {
            NSButton *btn = [[NSButton alloc] initWithFrame:NSMakeRect(bx, 100, 80, 24)];
            [btn setTitle:preset[@"title"]];
            [btn setButtonType:NSMomentaryPushInButton];
            [btn setBezelStyle:NSRoundedBezelStyle];
            [btn setTarget:self];
            [btn setAction:@selector(presetClicked:)];
            [btn setTag:(NSInteger)([preset[@"value"] doubleValue] * 10)];
            [_pageView addSubview:btn];
            bx += 88;
        }
    }
    return _pageView;
}

- (void)stepWillAppear
{
    ColorAssistantDelegate *del = (ColorAssistantDelegate *)[self.assistantWindow delegate];
    _currentGamma = [del gammaValue];
    if (_currentGamma < 0.1) _currentGamma = 2.2;
    [_slider setDoubleValue:_currentGamma];
    [_readout setStringValue:[NSString stringWithFormat:@"%.1f", _currentGamma]];

    [del.gammaCtrl selectDisplay:[del selectedDisplay]];
    [del.gammaCtrl applyGamma:_currentGamma whitePoint:[del whitePoint]];
}

- (void)gammaChanged:(id)sender
{
    _currentGamma = [_slider doubleValue];
    [_readout setStringValue:[NSString stringWithFormat:@"%.1f", _currentGamma]];

    ColorAssistantDelegate *del = (ColorAssistantDelegate *)[self.assistantWindow delegate];
    [del setGammaValue:_currentGamma];
    [del.gammaCtrl applyGamma:_currentGamma whitePoint:[del whitePoint]];
}

- (void)presetClicked:(id)sender
{
    NSInteger rawTag = [sender tag];
    double g;
    if (rawTag == 0) {
        g = 2.2;
    } else {
        g = (double)rawTag / 10.0;
    }
    [_slider setDoubleValue:g];
    [self gammaChanged:nil];
}

- (double)gammaValue
{
    return _currentGamma;
}

- (void)setGammaValue:(double)g
{
    _currentGamma = g;
}

- (BOOL)canContinue
{
    return YES;
}

@end

#pragma mark - CAResponsePage

@interface CAResponsePage ()
{
    NSView *_pageView;
    NSButton *_toggle;
    NSSlider *_shadowSlider;
    NSSlider *_midSlider;
    NSSlider *_highlightSlider;
    NSTextField *_shadowLabel;
    NSTextField *_midLabel;
    NSTextField *_highlightLabel;
    BOOL _enabled;
}
@end

@implementation CAResponsePage

@synthesize advancedEnabled = _enabled;

- (instancetype)init
{
    self = [super init];
    if (self) {
        self.title = @"Native Response";
        self.stepDescription = @"Fine-tune the tone response curve (advanced).";
        _enabled = NO;
    }
    return self;
}

- (NSView *)stepView
{
    if (!_pageView) {
        _pageView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 440, 180)];

        _toggle = [[NSButton alloc] initWithFrame:NSMakeRect(0, 150, 300, 24)];
        [_toggle setTitle:@"Enable advanced tone response adjustment"];
        [_toggle setButtonType:NSSwitchButton];
        [_toggle setTarget:self];
        [_toggle setAction:@selector(toggleChanged:)];
        [_pageView addSubview:_toggle];

        _shadowLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 115, 100, 20)];
        [_shadowLabel setStringValue:@"Shadows:"];
        [_shadowLabel setBezeled:NO];
        [_shadowLabel setDrawsBackground:NO];
        [_shadowLabel setEditable:NO];
        [_shadowLabel setSelectable:NO];
        [_shadowLabel setFont:[NSFont systemFontOfSize:11]];
        [_pageView addSubview:_shadowLabel];

        _shadowSlider = [[NSSlider alloc] initWithFrame:NSMakeRect(100, 115, 300, 20)];
        [_shadowSlider setMinValue:0.5];
        [_shadowSlider setMaxValue:1.5];
        [_shadowSlider setDoubleValue:1.0];
        [_shadowSlider setTarget:self];
        [_shadowSlider setAction:@selector(responseChanged:)];
        [_shadowSlider setContinuous:YES];
        [_shadowSlider setEnabled:NO];
        [_pageView addSubview:_shadowSlider];

        _midLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 85, 100, 20)];
        [_midLabel setStringValue:@"Midtones:"];
        [_midLabel setBezeled:NO];
        [_midLabel setDrawsBackground:NO];
        [_midLabel setEditable:NO];
        [_midLabel setSelectable:NO];
        [_midLabel setFont:[NSFont systemFontOfSize:11]];
        [_pageView addSubview:_midLabel];

        _midSlider = [[NSSlider alloc] initWithFrame:NSMakeRect(100, 85, 300, 20)];
        [_midSlider setMinValue:0.5];
        [_midSlider setMaxValue:1.5];
        [_midSlider setDoubleValue:1.0];
        [_midSlider setTarget:self];
        [_midSlider setAction:@selector(responseChanged:)];
        [_midSlider setContinuous:YES];
        [_midSlider setEnabled:NO];
        [_pageView addSubview:_midSlider];

        _highlightLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 55, 100, 20)];
        [_highlightLabel setStringValue:@"Highlights:"];
        [_highlightLabel setBezeled:NO];
        [_highlightLabel setDrawsBackground:NO];
        [_highlightLabel setEditable:NO];
        [_highlightLabel setSelectable:NO];
        [_highlightLabel setFont:[NSFont systemFontOfSize:11]];
        [_pageView addSubview:_highlightLabel];

        _highlightSlider = [[NSSlider alloc] initWithFrame:NSMakeRect(100, 55, 300, 20)];
        [_highlightSlider setMinValue:0.5];
        [_highlightSlider setMaxValue:1.5];
        [_highlightSlider setDoubleValue:1.0];
        [_highlightSlider setTarget:self];
        [_highlightSlider setAction:@selector(responseChanged:)];
        [_highlightSlider setContinuous:YES];
        [_highlightSlider setEnabled:NO];
        [_pageView addSubview:_highlightSlider];
    }
    return _pageView;
}

- (void)stepWillAppear
{
    ColorAssistantDelegate *del = (ColorAssistantDelegate *)[self.assistantWindow delegate];
    _enabled = [del advancedEnabled];
    [_toggle setState:_enabled ? NSOnState : NSOffState];
    [self updateSliderState];

    [_shadowSlider setDoubleValue:[del shadows]];
    [_midSlider setDoubleValue:[del midtones]];
    [_highlightSlider setDoubleValue:[del highlights]];

    if (_enabled && [del selectedDisplay]) {
        [del.gammaCtrl selectDisplay:[del selectedDisplay]];
        [del.gammaCtrl applyToneWithShadows:[del shadows]
                                   midtones:[del midtones]
                                 highlights:[del highlights]];
    }
}

- (void)toggleChanged:(id)sender
{
    _enabled = ([_toggle state] == NSOnState);
    ColorAssistantDelegate *del = (ColorAssistantDelegate *)[self.assistantWindow delegate];
    [del setAdvancedEnabled:_enabled];
    [self updateSliderState];

    if (!_enabled) {
        [del.gammaCtrl reset];
    } else if ([del selectedDisplay]) {
        [del.gammaCtrl selectDisplay:[del selectedDisplay]];
        [del.gammaCtrl applyGamma:[del gammaValue] whitePoint:[del whitePoint]];
    }
}

- (void)updateSliderState
{
    [_shadowSlider setEnabled:_enabled];
    [_midSlider setEnabled:_enabled];
    [_highlightSlider setEnabled:_enabled];
    [_shadowLabel setTextColor:_enabled ? [NSColor blackColor] : [NSColor grayColor]];
    [_midLabel setTextColor:_enabled ? [NSColor blackColor] : [NSColor grayColor]];
    [_highlightLabel setTextColor:_enabled ? [NSColor blackColor] : [NSColor grayColor]];
}

- (void)responseChanged:(id)sender
{
    ColorAssistantDelegate *del = (ColorAssistantDelegate *)[self.assistantWindow delegate];
    double s = [_shadowSlider doubleValue];
    double m = [_midSlider doubleValue];
    double h = [_highlightSlider doubleValue];
    [del setShadows:s];
    [del setMidtones:m];
    [del setHighlights:h];
    [del.gammaCtrl applyToneWithShadows:s midtones:m highlights:h];
}

- (void)setWhitePoint:(double)wp gamma:(double)g
{
}

- (BOOL)canContinue
{
    return YES;
}

@end

#pragma mark - CASavePage

@interface CASavePage ()
{
    NSView *_pageView;
    NSTextField *_nameField;
    NSTextField *_summaryLabel;
    NSButton *_allUsersCheck;
    NSString *_savedName;
}
@end

@implementation CASavePage

@synthesize forAllUsers = _forAllUsers;

- (instancetype)init
{
    self = [super init];
    if (self) {
        self.title = @"Name and Save";
        self.stepDescription = @"Name your profile and save it to the system.";
        _forAllUsers = NO;
    }
    return self;
}

- (NSString *)continueButtonTitle
{
    return @"Save";
}

- (NSView *)stepView
{
    if (!_pageView) {
        _pageView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 440, 180)];

        NSTextField *nameLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 150, 120, 20)];
        [nameLabel setStringValue:@"Profile Name:"];
        [nameLabel setBezeled:NO];
        [nameLabel setDrawsBackground:NO];
        [nameLabel setEditable:NO];
        [nameLabel setSelectable:NO];
        [nameLabel setFont:[NSFont systemFontOfSize:13]];
        [_pageView addSubview:nameLabel];

        _nameField = [[NSTextField alloc] initWithFrame:NSMakeRect(120, 148, 310, 24)];
        [_nameField setFont:[NSFont systemFontOfSize:13]];
        _savedName = nil;
        [_pageView addSubview:_nameField];

        _summaryLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 30, 440, 100)];
        [_summaryLabel setStringValue:@""];
        [_summaryLabel setBezeled:NO];
        [_summaryLabel setDrawsBackground:NO];
        [_summaryLabel setEditable:NO];
        [_summaryLabel setSelectable:NO];
        [_summaryLabel setFont:[NSFont systemFontOfSize:12]];
        [_summaryLabel setTextColor:[NSColor colorWithCalibratedWhite:0.3 alpha:1.0]];
        [[_summaryLabel cell] setWraps:YES];
        [[_summaryLabel cell] setScrollable:NO];
        [_pageView addSubview:_summaryLabel];

        _allUsersCheck = [[NSButton alloc] initWithFrame:NSMakeRect(0, 5, 300, 24)];
        [_allUsersCheck setTitle:@"Make available to all users"];
        [_allUsersCheck setButtonType:NSSwitchButton];
        [_allUsersCheck setTarget:self];
        [_allUsersCheck setAction:@selector(allUsersChanged:)];
        [_pageView addSubview:_allUsersCheck];
    }
    return _pageView;
}

- (void)stepWillAppear
{
    ColorAssistantDelegate *del = (ColorAssistantDelegate *)[self.assistantWindow delegate];

    if (!_savedName) {
        NSString *displayName = [del selectedDisplay];
        if ([displayName length] > 0) {
            _savedName = [NSString stringWithFormat:@"%@ \xe2\x80\x93 Calibrated", displayName];
        } else {
            _savedName = @"Display \xe2\x80\x93 Calibrated";
        }
    }
    [_nameField setStringValue:_savedName];

    NSString *wpStr = [NSString stringWithFormat:@"White Point: %.0f K", [del whitePoint]];
    NSString *gammaStr = [NSString stringWithFormat:@"Gamma: %.1f", [del gammaValue]];
    NSString *responseStr = @"";
    if ([del advancedEnabled]) {
        responseStr = [NSString stringWithFormat:@"\nResponse: Shadows %.1f, Midtones %.1f, Highlights %.1f",
                        [del shadows], [del midtones], [del highlights]];
    }
    [_summaryLabel setStringValue:[NSString stringWithFormat:@"%@\n%@%@", wpStr, gammaStr, responseStr]];

    [_allUsersCheck setState:_forAllUsers ? NSOnState : NSOffState];

    [del.gammaCtrl reset];
}

- (void)allUsersChanged:(id)sender
{
    _forAllUsers = ([_allUsersCheck state] == NSOnState);
}

- (NSString *)profileName
{
    NSString *text = [_nameField stringValue];
    if ([text length] > 0) {
        _savedName = text;
    }
    return _savedName;
}

- (void)setWhitePoint:(double)wp gamma:(double)g
{
}

- (BOOL)canContinue
{
    return ([[_nameField stringValue] length] > 0);
}

@end

#pragma mark - GammaPatternView

@implementation GammaPatternView

- (void)drawRect:(NSRect)dirtyRect
{
    NSRect bounds = self.bounds;
    if (NSWidth(bounds) < 2 || NSHeight(bounds) < 2) return;
    CGFloat midX = floor(NSWidth(bounds) / 2);

    // Left half: grey at ~73% (matches stripes at gamma 2.2)
    [[NSColor colorWithCalibratedWhite:0.73 alpha:1.0] set];
    NSRectFill(NSMakeRect(0, 0, midX, NSHeight(bounds)));

    // Right half: alternating 1px black and white vertical lines
    // Average luminance = 0.5 regardless of gamma, making it a stable reference
    for (int x = 0; x < (int)(NSWidth(bounds) - midX); x++) {
        if ((x & 1) == 0) {
            [[NSColor whiteColor] set];
        } else {
            [[NSColor blackColor] set];
        }
        NSRectFill(NSMakeRect(midX + x, 0, 1, NSHeight(bounds)));
    }

    // Border
    [[NSColor darkGrayColor] set];
    NSFrameRect(bounds);
}

@end
