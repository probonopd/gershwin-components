/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>
#import <AppKit/AppKit.h>
#import <PreferencePanes/PreferencePanes.h>

@class DisplayManager;
@class ProfileParser;
@class ProfileApplier;

@interface ColorPrefPane : NSPreferencePane
{
    DisplayManager *_displayManager;
    ProfileParser *_profileParser;
    ProfileApplier *_profileApplier;

    NSPopUpButton *_displayPopup;
    NSTextField *_profileNameField;
    NSTextField *_deviceClassField;
    NSTextField *_copyrightField;
    NSTextField *_vcgtField;
    NSButton *_selectProfileButton;
    NSButton *_applyButton;
    NSButton *_revertButton;
    NSButton *_calibrateButton;

    NSString *_selectedDisplayName;
    NSString *_selectedProfilePath;
    NSMutableDictionary *_profilePaths;
}

- (void)refreshDisplayList;
- (void)selectProfile:(id)sender;
- (void)applyProfile:(id)sender;
- (void)revertProfile:(id)sender;
- (void)displaySelectionChanged:(id)sender;
- (void)updateProfileMetadata;
- (void)updateButtonStates;

@end
