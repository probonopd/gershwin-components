/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "ColorPrefPane.h"
#import "DisplayManager.h"
#import "ProfileParser.h"
#import "ProfileApplier.h"

@implementation ColorPrefPane

+ (BOOL)isCompatible
{
    DisplayManager *mgr = [[DisplayManager alloc] init];
    BOOL avail = [mgr isAvailable];
    [mgr release];
    return avail;
}

+ (NSString *)compatibilityReason
{
    return @"X11 RANDR extension is required for display color management";
}

- (id)initWithBundle:(NSBundle *)bundle
{
    self = [super initWithBundle:bundle];
    if (self) {
        _displayManager = [[DisplayManager alloc] init];
        _profileParser = [[ProfileParser alloc] init];
        _profileApplier = [[ProfileApplier alloc] init];
        _profilePaths = [[NSMutableDictionary alloc] init];
    }
    return self;
}

- (void)dealloc
{
    [_displayManager release];
    [_profileParser release];
    [_profileApplier release];
    [_displayPopup release];
    [_profileNameField release];
    [_deviceClassField release];
    [_copyrightField release];
    [_vcgtField release];
    [_selectProfileButton release];
    [_applyButton release];
    [_revertButton release];
    [_selectedDisplayName release];
    [_selectedProfilePath release];
    [_profilePaths release];
    [super dealloc];
}

- (NSView *)loadMainView
{
    if (_mainView) return _mainView;

    CGFloat w = 500;
    CGFloat h = 300;
    _mainView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, w, h)];

    const CGFloat MARGIN_SIDE = 24.0;
    const CGFloat MARGIN_TOP = 15.0;
    const CGFloat LABEL_W = 100.0;
    const CGFloat SPACE_8 = 8.0;
    const CGFloat SPACE_16 = 16.0;
    const CGFloat SPACE_20 = 20.0;
    const CGFloat SPACE_10 = 10.0;
    const CGFloat FIELD_W = w - MARGIN_SIDE * 2 - LABEL_W - SPACE_8;
    const CGFloat FIELD_X = MARGIN_SIDE + LABEL_W + SPACE_8;
    const CGFloat LH = 22.0;
    const CGFloat BH = 20.0;
    const CGFloat BTN_MIN_W = 100.0;

    CGFloat y = h - MARGIN_TOP - LH;

    NSTextField *displayLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(MARGIN_SIDE, y, LABEL_W, LH)];
    [displayLabel setStringValue:@"Display:"];
    [displayLabel setBezeled:NO];
    [displayLabel setDrawsBackground:NO];
    [displayLabel setEditable:NO];
    [displayLabel setSelectable:NO];
    [displayLabel setFont:[NSFont systemFontOfSize:13]];
    [_mainView addSubview:displayLabel];
    [displayLabel release];

    _displayPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(FIELD_X, y, MIN(FIELD_W, 200), LH)];
    [_displayPopup setTarget:self];
    [_displayPopup setAction:@selector(displaySelectionChanged:)];
    [_mainView addSubview:_displayPopup];

    _selectProfileButton = [[NSButton alloc] initWithFrame:NSMakeRect(FIELD_X + 204, y, 0, BH)];
    [_selectProfileButton setTitle:@"Select Profile..."];
    [_selectProfileButton setButtonType:NSMomentaryPushInButton];
    [_selectProfileButton setBezelStyle:NSRoundedBezelStyle];
    [_selectProfileButton setTarget:self];
    [_selectProfileButton setAction:@selector(selectProfile:)];
    [_selectProfileButton sizeToFit];
    {
        NSRect f = [_selectProfileButton frame];
        f.size.width = MAX(f.size.width, BTN_MIN_W);
        [_selectProfileButton setFrame:f];
    }
    [_mainView addSubview:_selectProfileButton];

    y -= SPACE_16 + LH;

    NSTextField *nameLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(MARGIN_SIDE, y, LABEL_W, LH)];
    [nameLabel setStringValue:@"Profile Name:"];
    [nameLabel setBezeled:NO];
    [nameLabel setDrawsBackground:NO];
    [nameLabel setEditable:NO];
    [nameLabel setSelectable:NO];
    [nameLabel setFont:[NSFont systemFontOfSize:13]];
    [_mainView addSubview:nameLabel];
    [nameLabel release];

    _profileNameField = [[NSTextField alloc] initWithFrame:NSMakeRect(FIELD_X, y, FIELD_W, LH)];
    [_profileNameField setBezeled:NO];
    [_profileNameField setDrawsBackground:NO];
    [_profileNameField setEditable:NO];
    [_profileNameField setSelectable:YES];
    [_profileNameField setFont:[NSFont systemFontOfSize:13]];
    [_profileNameField setStringValue:@"None selected"];
    [_mainView addSubview:_profileNameField];

    y -= SPACE_16 + LH;

    NSTextField *classLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(MARGIN_SIDE, y, LABEL_W, LH)];
    [classLabel setStringValue:@"Device Class:"];
    [classLabel setBezeled:NO];
    [classLabel setDrawsBackground:NO];
    [classLabel setEditable:NO];
    [classLabel setSelectable:NO];
    [classLabel setFont:[NSFont systemFontOfSize:13]];
    [_mainView addSubview:classLabel];
    [classLabel release];

    _deviceClassField = [[NSTextField alloc] initWithFrame:NSMakeRect(FIELD_X, y, FIELD_W, LH)];
    [_deviceClassField setBezeled:NO];
    [_deviceClassField setDrawsBackground:NO];
    [_deviceClassField setEditable:NO];
    [_deviceClassField setSelectable:YES];
    [_deviceClassField setFont:[NSFont systemFontOfSize:13]];
    [_deviceClassField setStringValue:@""];
    [_mainView addSubview:_deviceClassField];

    y -= SPACE_16 + LH;

    NSTextField *copyrightLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(MARGIN_SIDE, y, LABEL_W, LH)];
    [copyrightLabel setStringValue:@"Copyright:"];
    [copyrightLabel setBezeled:NO];
    [copyrightLabel setDrawsBackground:NO];
    [copyrightLabel setEditable:NO];
    [copyrightLabel setSelectable:NO];
    [copyrightLabel setFont:[NSFont systemFontOfSize:13]];
    [_mainView addSubview:copyrightLabel];
    [copyrightLabel release];

    _copyrightField = [[NSTextField alloc] initWithFrame:NSMakeRect(FIELD_X, y, FIELD_W, LH)];
    [_copyrightField setBezeled:NO];
    [_copyrightField setDrawsBackground:NO];
    [_copyrightField setEditable:NO];
    [_copyrightField setSelectable:YES];
    [_copyrightField setFont:[NSFont systemFontOfSize:13]];
    [_copyrightField setStringValue:@""];
    [_mainView addSubview:_copyrightField];

    y -= SPACE_16 + LH;

    NSTextField *vcgtLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(MARGIN_SIDE, y, LABEL_W, LH)];
    [vcgtLabel setStringValue:@"Contains VCGT:"];
    [vcgtLabel setBezeled:NO];
    [vcgtLabel setDrawsBackground:NO];
    [vcgtLabel setEditable:NO];
    [vcgtLabel setSelectable:NO];
    [vcgtLabel setFont:[NSFont systemFontOfSize:13]];
    [_mainView addSubview:vcgtLabel];
    [vcgtLabel release];

    _vcgtField = [[NSTextField alloc] initWithFrame:NSMakeRect(FIELD_X, y, FIELD_W, LH)];
    [_vcgtField setBezeled:NO];
    [_vcgtField setDrawsBackground:NO];
    [_vcgtField setEditable:NO];
    [_vcgtField setSelectable:YES];
    [_vcgtField setFont:[NSFont systemFontOfSize:13]];
    [_vcgtField setStringValue:@""];
    [_mainView addSubview:_vcgtField];

    y -= SPACE_20 + BH;

    _applyButton = [[NSButton alloc] initWithFrame:NSMakeRect(MARGIN_SIDE, y, BTN_MIN_W, BH)];
    [_applyButton setTitle:@"Apply"];
    [_applyButton setButtonType:NSMomentaryPushInButton];
    [_applyButton setBezelStyle:NSRoundedBezelStyle];
    [_applyButton setTarget:self];
    [_applyButton setAction:@selector(applyProfile:)];
    [_applyButton setEnabled:NO];
    [_mainView addSubview:_applyButton];

    _revertButton = [[NSButton alloc] initWithFrame:NSMakeRect(MARGIN_SIDE + BTN_MIN_W + SPACE_10, y, BTN_MIN_W, BH)];
    [_revertButton setTitle:@"Revert"];
    [_revertButton setButtonType:NSMomentaryPushInButton];
    [_revertButton setBezelStyle:NSRoundedBezelStyle];
    [_revertButton setTarget:self];
    [_revertButton setAction:@selector(revertProfile:)];
    [_revertButton setEnabled:NO];
    [_mainView addSubview:_revertButton];

    y -= SPACE_16 + BH;

    _calibrateButton = [[NSButton alloc] initWithFrame:NSMakeRect(MARGIN_SIDE, y, 0, BH)];
    [_calibrateButton setTitle:@"Calibrate..."];
    [_calibrateButton setButtonType:NSMomentaryPushInButton];
    [_calibrateButton setBezelStyle:NSRoundedBezelStyle];
    [_calibrateButton setTarget:self];
    [_calibrateButton setAction:@selector(openCalibrator:)];
    [_calibrateButton sizeToFit];
    {
        NSRect f = [_calibrateButton frame];
        f.size.width = MAX(f.size.width, BTN_MIN_W);
        [_calibrateButton setFrame:f];
    }
    [_mainView addSubview:_calibrateButton];

    return _mainView;
}

- (NSString *)mainNibName
{
    return nil;
}

- (void)mainViewDidLoad
{
    [self refreshDisplayList];
    [self setInitialKeyView:nil];
}

- (void)didSelect
{
    [super didSelect];
    [self refreshDisplayList];
    [self setInitialKeyView:nil];
}

- (void)didUnselect
{
    [super didUnselect];
}

- (NSPreferencePaneUnselectReply)shouldUnselect
{
    return NSUnselectNow;
}

- (void)refreshDisplayList
{
    [_displayPopup removeAllItems];

    NSArray *displays = [_displayManager listDisplays];
    if ([displays count] == 0) {
        [_displayPopup addItemWithTitle:@"No displays found"];
        [_displayPopup setEnabled:NO];
        [_selectProfileButton setEnabled:NO];
        return;
    }

    [_displayPopup setEnabled:YES];
    [_selectProfileButton setEnabled:YES];

    NSString *previousSelection = [[_selectedDisplayName retain] autorelease];
    [_selectedDisplayName release];
    _selectedDisplayName = nil;

    for (NSString *name in displays) {
        [_displayPopup addItemWithTitle:name];
    }

    if (previousSelection && [_displayPopup itemWithTitle:previousSelection]) {
        [_displayPopup selectItemWithTitle:previousSelection];
        _selectedDisplayName = [previousSelection retain];
    } else {
        [_displayPopup selectItemAtIndex:0];
        _selectedDisplayName = [[[_displayPopup titleOfSelectedItem] retain] retain];
    }

    [self displaySelectionChanged:nil];
}

- (void)displaySelectionChanged:(id)sender
{
    NSString *name = [_displayPopup titleOfSelectedItem];
    if (!name) return;
    [_selectedDisplayName release];
    _selectedDisplayName = [name retain];
    _selectedProfilePath = [[_profilePaths objectForKey:name] retain];
    if (!_selectedProfilePath) {
        _selectedProfilePath = [[_displayManager savedProfileForDisplay:name] retain];
        if (_selectedProfilePath) {
            [_profilePaths setObject:_selectedProfilePath forKey:name];
        }
    }
    [self updateProfileMetadata];
    [self updateButtonStates];
}

- (void)selectProfile:(id)sender
{
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    [panel setCanChooseFiles:YES];
    [panel setCanChooseDirectories:NO];
    [panel setAllowsMultipleSelection:NO];
    [panel setAllowedFileTypes:@[@"icc", @"icm"]];
    [panel setTitle:@"Select ICC Profile"];

    if ([panel runModal] == NSFileHandlingPanelOKButton) {
        NSURL *url = [[panel URLs] lastObject];
        if (url) {
            NSString *path = [url path];
            NSString *name = [_displayPopup titleOfSelectedItem];
            if (name && path) {
                [_profilePaths setObject:path forKey:name];
                [_selectedProfilePath release];
                _selectedProfilePath = [path retain];
                [self updateProfileMetadata];
                [self updateButtonStates];
            }
        }
    }
}

- (void)applyProfile:(id)sender
{
    NSString *name = [_displayPopup titleOfSelectedItem];
    NSString *path = [_profilePaths objectForKey:name];
    if (!name || !path) return;

    BOOL ok = [_profileApplier applyProfile:path forDisplay:name];
    if (ok) {
        [_displayManager saveProfile:path forDisplay:name];
        [self updateButtonStates];
    }
}

- (void)revertProfile:(id)sender
{
    NSString *name = [_displayPopup titleOfSelectedItem];
    if (!name) return;

    BOOL ok = [_profileApplier revertForDisplay:name];
    if (ok) {
        [_profilePaths removeObjectForKey:name];
        [_displayManager saveProfile:nil forDisplay:name];
        [_selectedProfilePath release];
        _selectedProfilePath = nil;
        [self updateProfileMetadata];
        [self updateButtonStates];
    }
}

- (void)updateProfileMetadata
{
    NSString *path = _selectedProfilePath;

    if (!path) {
        [_profileNameField setStringValue:@"None selected"];
        [_deviceClassField setStringValue:@""];
        [_copyrightField setStringValue:@""];
        [_vcgtField setStringValue:@""];
        return;
    }

    NSDictionary *info = [_profileParser parseProfileAtPath:path];
    if (info) {
        [_profileNameField setStringValue:[info objectForKey:@"description"] ?: @"Unknown"];
        [_deviceClassField setStringValue:[info objectForKey:@"deviceClass"] ?: @""];
        [_copyrightField setStringValue:[info objectForKey:@"copyright"] ?: @""];
        BOOL hasVCGT = [[info objectForKey:@"hasVCGT"] boolValue];
        [_vcgtField setStringValue:hasVCGT ? @"Yes" : @"No"];
    } else {
        [_profileNameField setStringValue:@"Error reading profile"];
        [_deviceClassField setStringValue:@""];
        [_copyrightField setStringValue:@""];
        [_vcgtField setStringValue:@""];
    }
}

- (void)updateButtonStates
{
    NSString *name = [_displayPopup titleOfSelectedItem];
    NSString *path = [_profilePaths objectForKey:name];
    BOOL hasProfile = (path != nil);
    BOOL hasActive = ([_profileApplier activeProfileForDisplay:name] != nil);

    [_applyButton setEnabled:hasProfile];
    [_revertButton setEnabled:hasActive];
}

- (void)openCalibrator:(id)sender
{
    NSString *path = @"/System/Applications/Utilities/ColorAssistant.app";
    [[NSWorkspace sharedWorkspace] launchApplication:path];
}

@end
