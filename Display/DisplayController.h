/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

@class DisplayView;
@class X11DisplayManager;

// Represents a single display configuration
@interface DisplayInfo : NSObject
{
    NSString *name;
    NSRect frame;
    NSSize resolution;
    BOOL isPrimary;
    BOOL isConnected;
    NSString *output; // xrandr output name
    NSString *currentResolutionString; // e.g., "1920x1080" or "1920x1080i"
    NSArray *availableResolutions; // all modes for this display
}

@property (retain) NSString *name;
@property NSRect frame;
@property NSSize resolution;
@property BOOL isPrimary;
@property BOOL isConnected;
@property (retain) NSString *output;
@property (retain) NSString *currentResolutionString;
@property (retain) NSArray *availableResolutions;

@end

@interface DisplayController : NSObject
{
    NSMutableArray *displays;
    DisplayView *displayView;
    NSView *mainView;
    NSPopUpButton *resolutionPopup;
    NSSlider *scaleSlider;
    NSTextField *scaleValueLabel;
    NSButton *mirrorDisplaysCheckbox;
    X11DisplayManager *x11;
    DisplayInfo *selectedDisplay; // Currently selected display for resolution changes
    BOOL isRefreshing; // Guards against concurrent refreshDisplays: calls
    NSButton *saveButton;
    NSString *savedStateSnapshot; // Snapshot of display state at last save/load
    NSString *lastDisplaySnapshot; // Snapshot from last view rebuild
    NSUInteger previousDisplayCount; // Track display count to detect hot-plug
}

- (NSView *)createMainView;
- (void)refreshDisplays:(NSTimer *)timer;
- (void)applyDisplayConfiguration;
- (void)setPrimaryDisplay:(DisplayInfo *)display;
- (NSArray *)displays;
- (void)showResolutionConfirmationDialogWithOldResolution:(NSString *)oldRes 
                                           newResolution:(NSString *)newRes 
                                                 display:(DisplayInfo *)display;
- (void)revertResolutionTimer:(NSTimer *)timer;
- (void)revertToResolution:(NSString *)resolution forDisplay:(DisplayInfo *)display;
- (void)resolutionCountdownTimer:(NSTimer *)timer;
- (void)resolutionRevertClicked:(id)sender;
- (void)resolutionKeepClicked:(id)sender;
- (void)selectDisplay:(DisplayInfo *)display;
- (DisplayInfo *)selectedDisplay;
- (void)scaleFactorChanged:(id)sender;
- (void)autoConfigureDisplays;
- (void)saveSettings:(id)sender;
- (void)updateSaveButtonState;
- (BOOL)hasSavedMirrorConfig;

@end
