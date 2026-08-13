/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Sound Controller
 *
 * Main controller for the Sound preference pane UI.
 * Provides a classic interface for managing audio devices and settings.
 */

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <dispatch/dispatch.h>
#import "SoundBackend.h"

@interface SoundController : NSObject <NSTableViewDataSource, NSTableViewDelegate, SoundBackendDelegate>
{
    // Backend
    id<SoundBackend> backend;
    
    // Main view
    NSView *mainView;
    NSTabView *mainTabView;
    
    // ============ Sound Effects Tab ============
    NSView *effectsView;
    
    // Alert sounds list
    NSScrollView *alertSoundsScrollView;
    NSTableView *alertSoundsTable;
    
    // Alert volume
    NSSlider *alertVolumeSlider;
    NSTextField *alertVolumeLabel;
    
    // Checkboxes
    NSButton *playUIEffectsCheckbox;
    NSButton *playVolumeFeedbackCheckbox;
    
    // ============ Output Tab ============
    NSView *outputView;
    
    // Output device list
    NSScrollView *outputDevicesScrollView;
    NSTableView *outputDevicesTable;
    NSTextField *outputDeviceSettingsLabel;
    
    // Selected output device info
    NSTextField *outputDeviceNameLabel;
    NSTextField *outputDeviceTypeLabel;
    
    // Output volume slider
    NSSlider *outputVolumeSlider;
    NSTextField *outputVolumeLabel;
    NSButton *outputMuteCheckbox;
    
    // Balance slider
    NSSlider *outputBalanceSlider;
    NSTextField *outputBalanceLabel;
    NSTextField *outputBalanceLeftLabel;
    NSTextField *outputBalanceRightLabel;
    
    // ============ Input Tab ============
    NSView *inputView;
    
    // Input device list
    NSScrollView *inputDevicesScrollView;
    NSTableView *inputDevicesTable;
    NSTextField *inputDeviceSettingsLabel;
    
    // Selected input device info
    NSTextField *inputDeviceNameLabel;
    NSTextField *inputDeviceTypeLabel;
    
    // Input volume slider
    NSSlider *inputVolumeSlider;
    NSTextField *inputVolumeLabel;
    NSButton *inputMuteCheckbox;
    
    // Input level meter
    NSLevelIndicator *inputLevelMeter;
    NSTextField *inputLevelLabel;
    
    // No devices placeholder labels
    NSTextField *noOutputDevicesLabel;
    NSTextField *noInputDevicesLabel;
    
    // ============ Data ============
    NSMutableArray *outputDevices;
    NSMutableArray *inputDevices;
    NSMutableArray *alertSounds;
    
    AudioDevice *selectedOutputDevice;
    AudioDevice *selectedInputDevice;
    AlertSound *selectedAlertSound;
    
    // State
    BOOL isUpdatingUI;
    BOOL isInitializing;
    BOOL isRefreshing;

    // Background queue for backend operations
    dispatch_queue_t backendQueue;

    // Volume change coalescing to prevent flooding the backend queue
    dispatch_source_t outputVolumeTimer;
    float pendingOutputVolume;
    dispatch_source_t alertVolumeTimer;
    float pendingAlertVolume;
    dispatch_source_t inputVolumeTimer;
    float pendingInputVolume;
}

// View creation
- (NSView *)createMainView;
- (void)relayoutWithWidth:(CGFloat)width;
- (void)createSoundEffectsTab:(NSTabViewItem *)tab;
- (void)createOutputTab:(NSTabViewItem *)tab;
- (void)createInputTab:(NSTabViewItem *)tab;
- (void)createUnavailableView;

// Refresh
- (void)refreshDevices;
- (void)updateOutputDeviceList;
- (void)updateInputDeviceList;
- (void)updateAlertSoundsList;
- (void)updateOutputControls;
- (void)updateInputControls;
- (void)updateOutputControlsWithVolume:(float)volume muted:(BOOL)muted balance:(float)balance;
- (void)updateInputControlsWithVolume:(float)volume muted:(BOOL)muted;
- (BOOL)selectOutputDevice:(AudioDevice *)device;
- (BOOL)selectInputDevice:(AudioDevice *)device;

// Input level monitoring
- (void)startInputLevelMonitoring;
- (void)stopInputLevelMonitoring;

// Actions - Sound Effects
- (IBAction)alertSoundSelected:(id)sender;
- (IBAction)alertVolumeChanged:(id)sender;
- (IBAction)playUIEffectsChanged:(id)sender;
- (IBAction)playVolumeFeedbackChanged:(id)sender;

// Actions - Output
- (IBAction)outputDeviceSelected:(id)sender;
- (IBAction)outputVolumeChanged:(id)sender;
- (IBAction)outputMuteChanged:(id)sender;
- (IBAction)outputBalanceChanged:(id)sender;

// Actions - Input
- (IBAction)inputDeviceSelected:(id)sender;
- (IBAction)inputVolumeChanged:(id)sender;
- (IBAction)inputMuteChanged:(id)sender;

// Double-click actions
- (void)alertSoundsTableDoubleClicked:(id)sender;

// Delegate helpers
- (void)handleUpdatedOutputDevices:(NSArray *)devices;
- (void)handleUpdatedInputDevices:(NSArray *)devices;
- (void)handleVolumeChange:(float)volume isOutput:(BOOL)isOutput;
- (void)handleMuteChange:(BOOL)muted isOutput:(BOOL)isOutput;
- (void)handleInputLevelChange:(float)level;

// Helpers
- (NSImage *)iconForDeviceType:(AudioDeviceType)type isOutput:(BOOL)isOutput;
- (void)showErrorAlert:(NSString *)message informativeText:(NSString *)info;

@end
