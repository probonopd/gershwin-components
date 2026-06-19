/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Sound Controller Implementation
 */

#import "SoundController.h"
#import "ALSABackend.h"
#import "OSSBackend.h"

// UI Constants
static const CGFloat kPaneWidth = 595.0;
static const CGFloat kPaneHeight = 390.0;
static const CGFloat kTabContentWidth = 575.0;  // Tab content area width
static const CGFloat kTabContentHeight = 340.0; // Tab content area height (minus tab bar)
static const CGFloat kMargin = 20.0;
static const CGFloat kSmallMargin = 10.0;
static const CGFloat kLabelHeight = 17.0;
static const CGFloat kSliderHeight = 21.0;
static const CGFloat kCheckboxHeight = 18.0;
static const CGFloat kTableRowHeight = 18.0;

@implementation SoundController

#pragma mark - Initialization

- (id)init
{
    self = [super init];
    if (self) {
        outputDevices = [[NSMutableArray alloc] init];
        inputDevices = [[NSMutableArray alloc] init];
        alertSounds = [[NSMutableArray alloc] init];
        selectedOutputDevice = nil;
        selectedInputDevice = nil;
        selectedAlertSound = nil;
        isUpdatingUI = NO;
        isInitializing = YES;
        isRefreshing = NO;

        // Create serial background queue for backend operations (amixer, aplay, etc.)
        backendQueue = dispatch_queue_create("org.gershwin.sound.backend", DISPATCH_QUEUE_SERIAL);

        // Initialize backend - try OSS first (FreeBSD), then ALSA (Linux)
        backend = nil;

#if defined(__FreeBSD__) || defined(__DragonFly__)
        // On FreeBSD/DragonFly, prefer OSS
        OSSBackend *ossBackend = [[OSSBackend alloc] init];
        if ([ossBackend isAvailable]) {
            backend = ossBackend;
            backend.delegate = self;
            NSDebugLLog(@"gwcomp", @"SoundController: Using OSS backend version %@",
                  [backend backendVersion]);
        } else {
            [ossBackend release];
        }
#endif

        // If no backend yet, try ALSA (Linux)
        if (backend == nil) {
            ALSABackend *alsaBackend = [[ALSABackend alloc] init];
            if ([alsaBackend isAvailable]) {
                backend = alsaBackend;
                backend.delegate = self;
                NSDebugLLog(@"gwcomp", @"SoundController: Using ALSA backend version %@",
                      [backend backendVersion]);
            } else {
                [alsaBackend release];
            }
        }

#if !defined(__FreeBSD__) && !defined(__DragonFly__) && !defined(__OpenBSD__)
        // On non-BSD systems, also try OSS as fallback (e.g., OSS4 on Linux)
        // (OpenBSD excluded: no OSS there; sndio backend is a future addition.)
        if (backend == nil) {
            OSSBackend *ossBackend = [[OSSBackend alloc] init];
            if ([ossBackend isAvailable]) {
                backend = ossBackend;
                backend.delegate = self;
                NSDebugLLog(@"gwcomp", @"SoundController: Using OSS backend version %@",
                      [backend backendVersion]);
            } else {
                [ossBackend release];
            }
        }
#endif

        if (backend == nil) {
            NSDebugLLog(@"gwcomp", @"SoundController: No audio backend available");
        }
    }
    return self;
}

- (void)dealloc
{
    [self stopInputLevelMonitoring];
    if (outputVolumeTimer) {
        dispatch_source_cancel(outputVolumeTimer);
        dispatch_release(outputVolumeTimer);
        outputVolumeTimer = nil;
    }
    if (alertVolumeTimer) {
        dispatch_source_cancel(alertVolumeTimer);
        dispatch_release(alertVolumeTimer);
        alertVolumeTimer = nil;
    }
    if (inputVolumeTimer) {
        dispatch_source_cancel(inputVolumeTimer);
        dispatch_release(inputVolumeTimer);
        inputVolumeTimer = nil;
    }
    if (backendQueue) {
        dispatch_release(backendQueue);
        backendQueue = nil;
    }
    [outputDevices release];
    [inputDevices release];
    [alertSounds release];
    [selectedOutputDevice release];
    [selectedInputDevice release];
    [selectedAlertSound release];
    [(id)backend release];
    [super dealloc];
}

#pragma mark - View Creation

- (NSView *)createMainView
{
    if (backend == nil) {
        [self createUnavailableView];
        return mainView;
    }
    
    // Mark that we're in initialization phase - don't modify audio settings
    isInitializing = YES;
    
    mainView = [[NSView alloc] initWithFrame:
                NSMakeRect(0, 0, kPaneWidth, kPaneHeight)];
    [mainView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    
    // Create tab view
    mainTabView = [[NSTabView alloc] initWithFrame:
                   NSMakeRect(0, 0, kPaneWidth, kPaneHeight)];
    [mainTabView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [mainTabView setTabViewType:NSTopTabsBezelBorder];
    
    // Create Output tab
    NSTabViewItem *outputTab = [[NSTabViewItem alloc] initWithIdentifier:@"output"];
    [outputTab setLabel:@"Output"];
    [self createOutputTab:outputTab];
    [mainTabView addTabViewItem:outputTab];
    [outputTab release];
    
    // Create Input tab
    NSTabViewItem *inputTab = [[NSTabViewItem alloc] initWithIdentifier:@"input"];
    [inputTab setLabel:@"Input"];
    [self createInputTab:inputTab];
    [mainTabView addTabViewItem:inputTab];
    [inputTab release];
    
    // Create Sound Effects tab
    NSTabViewItem *effectsTab = [[NSTabViewItem alloc] initWithIdentifier:@"effects"];
    [effectsTab setLabel:@"Sound Effects"];
    [self createSoundEffectsTab:effectsTab];
    [mainTabView addTabViewItem:effectsTab];
    [effectsTab release];
    
    [mainView addSubview:mainTabView];
    [mainTabView release];
    
    return mainView;
}

- (void)createSoundEffectsTab:(NSTabViewItem *)tab
{
    // Use fixed dimensions since tab view bounds may not be set yet
    CGFloat contentWidth = kTabContentWidth;
    CGFloat contentHeight = kTabContentHeight;
    CGFloat yPos = contentHeight - kMargin - 10;
    
    // "Select an alert sound:" label
    NSTextField *alertLabel = [[NSTextField alloc] initWithFrame:
                               NSMakeRect(kMargin, yPos - kLabelHeight, 200, kLabelHeight)];
    [alertLabel setStringValue:@"Select an alert sound:"];
    [alertLabel setBezeled:NO];
    [alertLabel setEditable:NO];
    [alertLabel setSelectable:NO];
    [alertLabel setDrawsBackground:NO];
    [alertLabel setFont:[NSFont systemFontOfSize:13]];
    [[tab view] addSubview:alertLabel];
    [alertLabel release];
    
    yPos -= kLabelHeight + kSmallMargin;
    
    // Alert sounds list (left side)
    CGFloat listWidth = 250;
    CGFloat listHeight = 150;
    
    alertSoundsScrollView = [[NSScrollView alloc] initWithFrame:
                             NSMakeRect(kMargin, yPos - listHeight, listWidth, listHeight)];
    [alertSoundsScrollView setBorderType:NSBezelBorder];
    [alertSoundsScrollView setHasVerticalScroller:YES];
    [alertSoundsScrollView setHasHorizontalScroller:NO];
    [alertSoundsScrollView setAutohidesScrollers:YES];
    
    alertSoundsTable = [[NSTableView alloc] initWithFrame:
                        NSMakeRect(0, 0, listWidth - 20, listHeight)];
    [alertSoundsTable setRowHeight:kTableRowHeight];
    [alertSoundsTable setAllowsEmptySelection:NO];
    [alertSoundsTable setAllowsMultipleSelection:NO];
    [alertSoundsTable setDataSource:self];
    [alertSoundsTable setDelegate:self];
    [alertSoundsTable setHeaderView:nil];
    [alertSoundsTable setAction:@selector(alertSoundSelected:)];
    [alertSoundsTable setDoubleAction:@selector(alertSoundsTableDoubleClicked:)];
    [alertSoundsTable setTarget:self];
    
    NSTableColumn *alertNameColumn = [[NSTableColumn alloc] 
                                      initWithIdentifier:@"alertName"];
    [alertNameColumn setWidth:listWidth - 25];
    [alertNameColumn setEditable:NO];
    [[alertNameColumn headerCell] setStringValue:@""];
    [alertSoundsTable addTableColumn:alertNameColumn];
    [alertNameColumn release];
    
    [alertSoundsScrollView setDocumentView:alertSoundsTable];
    [[tab view] addSubview:alertSoundsScrollView];
    
    // Right side controls
    CGFloat rightX = kMargin + listWidth + kMargin;
    CGFloat rightWidth = contentWidth - rightX - kMargin;
    CGFloat rightY = yPos - kSmallMargin;
    
    // Alert volume label
    alertVolumeLabel = [[NSTextField alloc] initWithFrame:
                        NSMakeRect(rightX, rightY - kLabelHeight, rightWidth, kLabelHeight)];
    [alertVolumeLabel setStringValue:@"Alert volume:"];
    [alertVolumeLabel setBezeled:NO];
    [alertVolumeLabel setEditable:NO];
    [alertVolumeLabel setSelectable:NO];
    [alertVolumeLabel setDrawsBackground:NO];
    [alertVolumeLabel setFont:[NSFont systemFontOfSize:12]];
    [[tab view] addSubview:alertVolumeLabel];
    [alertVolumeLabel release];
    
    rightY -= kLabelHeight + 5;
    
    // Alert volume slider
    alertVolumeSlider = [[NSSlider alloc] initWithFrame:
                         NSMakeRect(rightX, rightY - kSliderHeight, rightWidth - 20, kSliderHeight)];
    [alertVolumeSlider setMinValue:0.0];
    [alertVolumeSlider setMaxValue:1.0];
    [alertVolumeSlider setFloatValue:1.0];
    [alertVolumeSlider setContinuous:YES];
    [alertVolumeSlider setTarget:self];
    [alertVolumeSlider setAction:@selector(alertVolumeChanged:)];
    [[tab view] addSubview:alertVolumeSlider];
    
    yPos -= listHeight + kMargin + kSmallMargin;
    
    // Separator line
    NSBox *separator = [[NSBox alloc] initWithFrame:
                        NSMakeRect(kMargin, yPos, contentWidth - 2 * kMargin, 1)];
    [separator setBoxType:NSBoxSeparator];
    [[tab view] addSubview:separator];
    [separator release];
    
    yPos -= kMargin;
    
    // Output volume label and slider at bottom
    NSTextField *outputVolLabel = [[NSTextField alloc] initWithFrame:
                                   NSMakeRect(kMargin, yPos - kLabelHeight, 120, kLabelHeight)];
    [outputVolLabel setStringValue:@"Output volume:"];
    [outputVolLabel setBezeled:NO];
    [outputVolLabel setEditable:NO];
    [outputVolLabel setSelectable:NO];
    [outputVolLabel setDrawsBackground:NO];
    [outputVolLabel setFont:[NSFont systemFontOfSize:12]];
    [[tab view] addSubview:outputVolLabel];
    [outputVolLabel release];
    
    CGFloat sliderWidth = contentWidth - 2 * kMargin - 130 - 80;
    NSSlider *mainVolumeSlider = [[NSSlider alloc] initWithFrame:
                                  NSMakeRect(kMargin + 120, yPos - kSliderHeight, sliderWidth, kSliderHeight)];
    [mainVolumeSlider setMinValue:0.0];
    [mainVolumeSlider setMaxValue:1.0];
    [mainVolumeSlider setFloatValue:[backend outputVolume]];
    [mainVolumeSlider setContinuous:YES];
    [mainVolumeSlider setTarget:self];
    [mainVolumeSlider setAction:@selector(outputVolumeChanged:)];
    [mainVolumeSlider setTag:100]; // Tag to identify main volume slider
    [[tab view] addSubview:mainVolumeSlider];
    [mainVolumeSlider release];
    
    // Mute checkbox
    NSButton *mainMuteCheckbox = [[NSButton alloc] initWithFrame:
                                  NSMakeRect(contentWidth - kMargin - 60, 
                                            yPos - kCheckboxHeight, 60, kCheckboxHeight)];
    [mainMuteCheckbox setButtonType:NSSwitchButton];
    [mainMuteCheckbox setTitle:@"Mute"];
    [mainMuteCheckbox setState:[backend isOutputMuted] ? NSOnState : NSOffState];
    [mainMuteCheckbox setTarget:self];
    [mainMuteCheckbox setAction:@selector(outputMuteChanged:)];
    [mainMuteCheckbox setTag:100];
    [[tab view] addSubview:mainMuteCheckbox];
    [mainMuteCheckbox release];
    
    yPos -= kSliderHeight + kSmallMargin + 5;
    
    // Checkboxes
    playUIEffectsCheckbox = [[NSButton alloc] initWithFrame:
                             NSMakeRect(kMargin, yPos - kCheckboxHeight, 
                                       contentWidth - 2 * kMargin, kCheckboxHeight)];
    [playUIEffectsCheckbox setButtonType:NSSwitchButton];
    [playUIEffectsCheckbox setTitle:@"Play user interface sound effects"];
    [playUIEffectsCheckbox setState:[backend playUserInterfaceSoundEffects] ? NSOnState : NSOffState];
    [playUIEffectsCheckbox setTarget:self];
    [playUIEffectsCheckbox setAction:@selector(playUIEffectsChanged:)];
    [[tab view] addSubview:playUIEffectsCheckbox];
    
    yPos -= kCheckboxHeight + 5;
    
    playVolumeFeedbackCheckbox = [[NSButton alloc] initWithFrame:
                                  NSMakeRect(kMargin, yPos - kCheckboxHeight, 
                                            contentWidth - 2 * kMargin, kCheckboxHeight)];
    [playVolumeFeedbackCheckbox setButtonType:NSSwitchButton];
    [playVolumeFeedbackCheckbox setTitle:@"Play feedback when volume is changed"];
    [playVolumeFeedbackCheckbox setState:[backend playFeedbackWhenVolumeIsChanged] ? NSOnState : NSOffState];
    [playVolumeFeedbackCheckbox setTarget:self];
    [playVolumeFeedbackCheckbox setAction:@selector(playVolumeFeedbackChanged:)];
    [[tab view] addSubview:playVolumeFeedbackCheckbox];
}

- (void)createOutputTab:(NSTabViewItem *)tab
{
    // Use fixed dimensions since tab view bounds may not be set yet
    CGFloat contentWidth = kTabContentWidth;
    CGFloat contentHeight = kTabContentHeight;
    CGFloat yPos = contentHeight - kMargin - 10;
    
    // "Select a device for sound output:" label
    NSTextField *selectLabel = [[NSTextField alloc] initWithFrame:
                                NSMakeRect(kMargin, yPos - kLabelHeight, 
                                          contentWidth - 2 * kMargin, kLabelHeight)];
    [selectLabel setStringValue:@"Select a device for sound output:"];
    [selectLabel setBezeled:NO];
    [selectLabel setEditable:NO];
    [selectLabel setSelectable:NO];
    [selectLabel setDrawsBackground:NO];
    [selectLabel setFont:[NSFont systemFontOfSize:13]];
    [[tab view] addSubview:selectLabel];
    [selectLabel release];
    
    yPos -= kLabelHeight + kSmallMargin;
    
    // Device table
    CGFloat tableHeight = 140;
    
    outputDevicesScrollView = [[NSScrollView alloc] initWithFrame:
                               NSMakeRect(kMargin, yPos - tableHeight, 
                                         contentWidth - 2 * kMargin, tableHeight)];
    [outputDevicesScrollView setBorderType:NSBezelBorder];
    [outputDevicesScrollView setHasVerticalScroller:YES];
    [outputDevicesScrollView setHasHorizontalScroller:NO];
    [outputDevicesScrollView setAutohidesScrollers:YES];
    
    outputDevicesTable = [[NSTableView alloc] initWithFrame:
                          NSMakeRect(0, 0, contentWidth - 2 * kMargin - 20, tableHeight)];
    [outputDevicesTable setRowHeight:36];
    [outputDevicesTable setAllowsEmptySelection:NO];
    [outputDevicesTable setAllowsMultipleSelection:NO];
    [outputDevicesTable setDataSource:self];
    [outputDevicesTable setDelegate:self];
    [outputDevicesTable setAction:@selector(outputDeviceSelected:)];
    [outputDevicesTable setTarget:self];
    
    // Name column
    NSTableColumn *nameColumn = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    [nameColumn setWidth:250];
    [nameColumn setEditable:NO];
    [[nameColumn headerCell] setStringValue:@"Name"];
    [outputDevicesTable addTableColumn:nameColumn];
    [nameColumn release];
    
    // Type column
    NSTableColumn *typeColumn = [[NSTableColumn alloc] initWithIdentifier:@"type"];
    [typeColumn setWidth:150];
    [typeColumn setEditable:NO];
    [[typeColumn headerCell] setStringValue:@"Type"];
    [outputDevicesTable addTableColumn:typeColumn];
    [typeColumn release];
    
    [outputDevicesScrollView setDocumentView:outputDevicesTable];
    [[tab view] addSubview:outputDevicesScrollView];
    
    // "No output devices found" placeholder (hidden by default)
    noOutputDevicesLabel = [[NSTextField alloc] initWithFrame:
                            NSMakeRect(kMargin + 10, yPos - tableHeight/2 - 10, 
                                      contentWidth - 2 * kMargin - 20, 40)];
    [noOutputDevicesLabel setStringValue:@"No output devices found.\n"
                                          @"Please check your audio hardware."];
    [noOutputDevicesLabel setBezeled:NO];
    [noOutputDevicesLabel setEditable:NO];
    [noOutputDevicesLabel setSelectable:NO];
    [noOutputDevicesLabel setDrawsBackground:NO];
    [noOutputDevicesLabel setAlignment:NSCenterTextAlignment];
    [noOutputDevicesLabel setFont:[NSFont systemFontOfSize:12]];
    [noOutputDevicesLabel setTextColor:[NSColor grayColor]];
    [noOutputDevicesLabel setHidden:YES];
    [[tab view] addSubview:noOutputDevicesLabel];
    
    yPos -= tableHeight + kMargin;
    
    // Settings label
    outputDeviceSettingsLabel = [[NSTextField alloc] initWithFrame:
                                 NSMakeRect(kMargin, yPos - kLabelHeight, 
                                           contentWidth - 2 * kMargin, kLabelHeight)];
    [outputDeviceSettingsLabel setStringValue:@"Settings for the selected device:"];
    [outputDeviceSettingsLabel setBezeled:NO];
    [outputDeviceSettingsLabel setEditable:NO];
    [outputDeviceSettingsLabel setSelectable:NO];
    [outputDeviceSettingsLabel setDrawsBackground:NO];
    [outputDeviceSettingsLabel setFont:[NSFont systemFontOfSize:12]];
    [outputDeviceSettingsLabel setTextColor:[NSColor grayColor]];
    [[tab view] addSubview:outputDeviceSettingsLabel];
    [outputDeviceSettingsLabel release];
    
    yPos -= kLabelHeight + kSmallMargin + 5;
    
    // Balance label
    outputBalanceLabel = [[NSTextField alloc] initWithFrame:
                          NSMakeRect(kMargin, yPos - kLabelHeight, 100, kLabelHeight)];
    [outputBalanceLabel setStringValue:@"Balance:"];
    [outputBalanceLabel setBezeled:NO];
    [outputBalanceLabel setEditable:NO];
    [outputBalanceLabel setSelectable:NO];
    [outputBalanceLabel setDrawsBackground:NO];
    [outputBalanceLabel setFont:[NSFont systemFontOfSize:12]];
    [[tab view] addSubview:outputBalanceLabel];
    [outputBalanceLabel release];
    
    // Left label
    outputBalanceLeftLabel = [[NSTextField alloc] initWithFrame:
                              NSMakeRect(kMargin + 80, yPos - kLabelHeight, 30, kLabelHeight)];
    [outputBalanceLeftLabel setStringValue:@"L"];
    [outputBalanceLeftLabel setBezeled:NO];
    [outputBalanceLeftLabel setEditable:NO];
    [outputBalanceLeftLabel setSelectable:NO];
    [outputBalanceLeftLabel setDrawsBackground:NO];
    [outputBalanceLeftLabel setAlignment:NSCenterTextAlignment];
    [[tab view] addSubview:outputBalanceLeftLabel];
    [outputBalanceLeftLabel release];
    
    // Balance slider
    CGFloat balanceSliderWidth = contentWidth - 2 * kMargin - 150;
    outputBalanceSlider = [[NSSlider alloc] initWithFrame:
                           NSMakeRect(kMargin + 110, yPos - kSliderHeight, 
                                     balanceSliderWidth, kSliderHeight)];
    [outputBalanceSlider setMinValue:0.0];
    [outputBalanceSlider setMaxValue:1.0];
    [outputBalanceSlider setFloatValue:0.5];
    [outputBalanceSlider setContinuous:YES];
    [outputBalanceSlider setTarget:self];
    [outputBalanceSlider setAction:@selector(outputBalanceChanged:)];
    [[tab view] addSubview:outputBalanceSlider];
    
    // Right label
    outputBalanceRightLabel = [[NSTextField alloc] initWithFrame:
                               NSMakeRect(kMargin + 110 + balanceSliderWidth + 5, 
                                         yPos - kLabelHeight, 30, kLabelHeight)];
    [outputBalanceRightLabel setStringValue:@"R"];
    [outputBalanceRightLabel setBezeled:NO];
    [outputBalanceRightLabel setEditable:NO];
    [outputBalanceRightLabel setSelectable:NO];
    [outputBalanceRightLabel setDrawsBackground:NO];
    [outputBalanceRightLabel setAlignment:NSCenterTextAlignment];
    [[tab view] addSubview:outputBalanceRightLabel];
    [outputBalanceRightLabel release];
    
    yPos -= kSliderHeight + kSmallMargin + 5;
    
    // Output volume
    outputVolumeLabel = [[NSTextField alloc] initWithFrame:
                         NSMakeRect(kMargin, yPos - kLabelHeight, 100, kLabelHeight)];
    [outputVolumeLabel setStringValue:@"Output volume:"];
    [outputVolumeLabel setBezeled:NO];
    [outputVolumeLabel setEditable:NO];
    [outputVolumeLabel setSelectable:NO];
    [outputVolumeLabel setDrawsBackground:NO];
    [outputVolumeLabel setFont:[NSFont systemFontOfSize:12]];
    [[tab view] addSubview:outputVolumeLabel];
    [outputVolumeLabel release];
    
    CGFloat volSliderWidth = contentWidth - 2 * kMargin - 120 - 80;
    outputVolumeSlider = [[NSSlider alloc] initWithFrame:
                          NSMakeRect(kMargin + 110, yPos - kSliderHeight, 
                                    volSliderWidth, kSliderHeight)];
    [outputVolumeSlider setMinValue:0.0];
    [outputVolumeSlider setMaxValue:1.0];
    [outputVolumeSlider setFloatValue:[backend outputVolume]];
    [outputVolumeSlider setContinuous:YES];
    [outputVolumeSlider setTarget:self];
    [outputVolumeSlider setAction:@selector(outputVolumeChanged:)];
    [[tab view] addSubview:outputVolumeSlider];
    
    // Mute checkbox
    outputMuteCheckbox = [[NSButton alloc] initWithFrame:
                          NSMakeRect(contentWidth - kMargin - 60, 
                                    yPos - kCheckboxHeight, 60, kCheckboxHeight)];
    [outputMuteCheckbox setButtonType:NSSwitchButton];
    [outputMuteCheckbox setTitle:@"Mute"];
    [outputMuteCheckbox setState:[backend isOutputMuted] ? NSOnState : NSOffState];
    [outputMuteCheckbox setTarget:self];
    [outputMuteCheckbox setAction:@selector(outputMuteChanged:)];
    [[tab view] addSubview:outputMuteCheckbox];
}

- (void)createInputTab:(NSTabViewItem *)tab
{
    // Use fixed dimensions since tab view bounds may not be set yet
    CGFloat contentWidth = kTabContentWidth;
    CGFloat contentHeight = kTabContentHeight;
    CGFloat yPos = contentHeight - kMargin - 10;
    
    // "Select a device for sound input:" label
    NSTextField *selectLabel = [[NSTextField alloc] initWithFrame:
                                NSMakeRect(kMargin, yPos - kLabelHeight, 
                                          contentWidth - 2 * kMargin, kLabelHeight)];
    [selectLabel setStringValue:@"Select a device for sound input:"];
    [selectLabel setBezeled:NO];
    [selectLabel setEditable:NO];
    [selectLabel setSelectable:NO];
    [selectLabel setDrawsBackground:NO];
    [selectLabel setFont:[NSFont systemFontOfSize:13]];
    [[tab view] addSubview:selectLabel];
    [selectLabel release];
    
    yPos -= kLabelHeight + kSmallMargin;
    
    // Device table
    CGFloat tableHeight = 140;
    
    inputDevicesScrollView = [[NSScrollView alloc] initWithFrame:
                              NSMakeRect(kMargin, yPos - tableHeight, 
                                        contentWidth - 2 * kMargin, tableHeight)];
    [inputDevicesScrollView setBorderType:NSBezelBorder];
    [inputDevicesScrollView setHasVerticalScroller:YES];
    [inputDevicesScrollView setHasHorizontalScroller:NO];
    [inputDevicesScrollView setAutohidesScrollers:YES];
    
    inputDevicesTable = [[NSTableView alloc] initWithFrame:
                         NSMakeRect(0, 0, contentWidth - 2 * kMargin - 20, tableHeight)];
    [inputDevicesTable setRowHeight:36];
    [inputDevicesTable setAllowsEmptySelection:NO];
    [inputDevicesTable setAllowsMultipleSelection:NO];
    [inputDevicesTable setDataSource:self];
    [inputDevicesTable setDelegate:self];
    [inputDevicesTable setAction:@selector(inputDeviceSelected:)];
    [inputDevicesTable setTarget:self];
    
    // Name column
    NSTableColumn *nameColumn = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    [nameColumn setWidth:250];
    [nameColumn setEditable:NO];
    [[nameColumn headerCell] setStringValue:@"Name"];
    [inputDevicesTable addTableColumn:nameColumn];
    [nameColumn release];
    
    // Type column
    NSTableColumn *typeColumn = [[NSTableColumn alloc] initWithIdentifier:@"type"];
    [typeColumn setWidth:150];
    [typeColumn setEditable:NO];
    [[typeColumn headerCell] setStringValue:@"Type"];
    [inputDevicesTable addTableColumn:typeColumn];
    [typeColumn release];
    
    [inputDevicesScrollView setDocumentView:inputDevicesTable];
    [[tab view] addSubview:inputDevicesScrollView];
    
    // "No input devices found" placeholder (hidden by default)
    noInputDevicesLabel = [[NSTextField alloc] initWithFrame:
                           NSMakeRect(kMargin + 10, yPos - tableHeight/2 - 10, 
                                     contentWidth - 2 * kMargin - 20, 40)];
    [noInputDevicesLabel setStringValue:@"No input devices found.\n"
                                         @"Please check your audio hardware."];
    [noInputDevicesLabel setBezeled:NO];
    [noInputDevicesLabel setEditable:NO];
    [noInputDevicesLabel setSelectable:NO];
    [noInputDevicesLabel setDrawsBackground:NO];
    [noInputDevicesLabel setAlignment:NSCenterTextAlignment];
    [noInputDevicesLabel setFont:[NSFont systemFontOfSize:12]];
    [noInputDevicesLabel setTextColor:[NSColor grayColor]];
    [noInputDevicesLabel setHidden:YES];
    [[tab view] addSubview:noInputDevicesLabel];
    
    yPos -= tableHeight + kMargin;
    
    // Settings label
    inputDeviceSettingsLabel = [[NSTextField alloc] initWithFrame:
                                NSMakeRect(kMargin, yPos - kLabelHeight, 
                                          contentWidth - 2 * kMargin, kLabelHeight)];
    [inputDeviceSettingsLabel setStringValue:@"Settings for the selected device:"];
    [inputDeviceSettingsLabel setBezeled:NO];
    [inputDeviceSettingsLabel setEditable:NO];
    [inputDeviceSettingsLabel setSelectable:NO];
    [inputDeviceSettingsLabel setDrawsBackground:NO];
    [inputDeviceSettingsLabel setFont:[NSFont systemFontOfSize:12]];
    [inputDeviceSettingsLabel setTextColor:[NSColor grayColor]];
    [[tab view] addSubview:inputDeviceSettingsLabel];
    [inputDeviceSettingsLabel release];
    
    yPos -= kLabelHeight + kSmallMargin + 5;
    
    // Input volume
    inputVolumeLabel = [[NSTextField alloc] initWithFrame:
                        NSMakeRect(kMargin, yPos - kLabelHeight, 100, kLabelHeight)];
    [inputVolumeLabel setStringValue:@"Input volume:"];
    [inputVolumeLabel setBezeled:NO];
    [inputVolumeLabel setEditable:NO];
    [inputVolumeLabel setSelectable:NO];
    [inputVolumeLabel setDrawsBackground:NO];
    [inputVolumeLabel setFont:[NSFont systemFontOfSize:12]];
    [[tab view] addSubview:inputVolumeLabel];
    [inputVolumeLabel release];
    
    CGFloat volSliderWidth = contentWidth - 2 * kMargin - 120 - 80;
    inputVolumeSlider = [[NSSlider alloc] initWithFrame:
                         NSMakeRect(kMargin + 110, yPos - kSliderHeight, 
                                   volSliderWidth, kSliderHeight)];
    [inputVolumeSlider setMinValue:0.0];
    [inputVolumeSlider setMaxValue:1.0];
    [inputVolumeSlider setFloatValue:[backend inputVolume]];
    [inputVolumeSlider setContinuous:YES];
    [inputVolumeSlider setTarget:self];
    [inputVolumeSlider setAction:@selector(inputVolumeChanged:)];
    [[tab view] addSubview:inputVolumeSlider];
    
    // Mute checkbox
    inputMuteCheckbox = [[NSButton alloc] initWithFrame:
                         NSMakeRect(contentWidth - kMargin - 60, 
                                   yPos - kCheckboxHeight, 60, kCheckboxHeight)];
    [inputMuteCheckbox setButtonType:NSSwitchButton];
    [inputMuteCheckbox setTitle:@"Mute"];
    [inputMuteCheckbox setState:[backend isInputMuted] ? NSOnState : NSOffState];
    [inputMuteCheckbox setTarget:self];
    [inputMuteCheckbox setAction:@selector(inputMuteChanged:)];
    [[tab view] addSubview:inputMuteCheckbox];
    
    yPos -= kSliderHeight + kSmallMargin + 10;
    
    // Input level label
    inputLevelLabel = [[NSTextField alloc] initWithFrame:
                       NSMakeRect(kMargin, yPos - kLabelHeight, 100, kLabelHeight)];
    [inputLevelLabel setStringValue:@"Input level:"];
    [inputLevelLabel setBezeled:NO];
    [inputLevelLabel setEditable:NO];
    [inputLevelLabel setSelectable:NO];
    [inputLevelLabel setDrawsBackground:NO];
    [inputLevelLabel setFont:[NSFont systemFontOfSize:12]];
    [[tab view] addSubview:inputLevelLabel];
    [inputLevelLabel release];
    
    // Input level meter
    inputLevelMeter = [[NSLevelIndicator alloc] initWithFrame:
                       NSMakeRect(kMargin + 110, yPos - 16, volSliderWidth, 16)];
    // Set level indicator style if available (may not be in all GNUstep versions)
    if ([inputLevelMeter respondsToSelector:@selector(setLevelIndicatorStyle:)]) {
        [inputLevelMeter performSelector:@selector(setLevelIndicatorStyle:) 
                              withObject:(id)NSContinuousCapacityLevelIndicatorStyle];
    }
    [inputLevelMeter setMinValue:0.0];
    [inputLevelMeter setMaxValue:1.0];
    [inputLevelMeter setWarningValue:0.8];
    [inputLevelMeter setCriticalValue:0.95];
    [inputLevelMeter setFloatValue:0.0];
    [[tab view] addSubview:inputLevelMeter];
}

- (void)createUnavailableView
{
    mainView = [[NSView alloc] initWithFrame:
                NSMakeRect(0, 0, kPaneWidth, kPaneHeight)];
    
    // Create centered message
    NSTextField *message = [[NSTextField alloc] initWithFrame:
                            NSMakeRect(50, kPaneHeight/2 - 30, kPaneWidth - 100, 60)];
    [message setStringValue:@"No audio system available.\n\n"
                            @"Please ensure ALSA is installed and configured."];
    [message setBezeled:NO];
    [message setEditable:NO];
    [message setSelectable:NO];
    [message setDrawsBackground:NO];
    [message setAlignment:NSCenterTextAlignment];
    [message setFont:[NSFont systemFontOfSize:14]];
    [message setTextColor:[NSColor grayColor]];
    [mainView addSubview:message];
    [message release];
}

#pragma mark - Refresh

- (void)refreshDevices
{
    if (!backend) return;

    // Skip if a refresh is already in progress to avoid queueing up stale work
    if (isRefreshing) {
        NSDebugLLog(@"gwcomp", @"SoundController: refreshDevices skipped - already in progress");
        return;
    }

    NSDebugLLog(@"gwcomp", @"SoundController: refreshDevices called");
    isRefreshing = YES;

    // Dispatch blocking backend operations to background queue
    dispatch_async(backendQueue, ^{
        @autoreleasepool {
        // Refresh backend data (calls amixer, aplay, etc. - blocking)
        [backend refresh];

        // Pre-fetch control values on background queue to avoid blocking main thread
        float outVol = [backend outputVolume];
        BOOL outMuted = [backend isOutputMuted];
        float outBalance = [backend outputBalance];
        float inVol = [backend inputVolume];
        BOOL inMuted = [backend isInputMuted];
        float alertVol = [backend alertVolume];

        // Dispatch UI updates back to the main thread
        dispatch_async(dispatch_get_main_queue(), ^{
            isUpdatingUI = YES;

            // Update device lists
            [self updateOutputDeviceList];
            [self updateInputDeviceList];
            // Alert sounds are now updated inside updateOutputDeviceList

            // Update controls with pre-fetched values (no blocking backend calls)
            [self updateOutputControlsWithVolume:outVol muted:outMuted balance:outBalance];
            [self updateInputControlsWithVolume:inVol muted:inMuted];
            [alertVolumeSlider setFloatValue:alertVol];

            isUpdatingUI = NO;
            isRefreshing = NO;

            // After first refresh during initialization, mark that we're done initializing
            // Subsequent device selections will now trigger actual device switches and audio changes
            if (isInitializing) {
                isInitializing = NO;
                NSDebugLLog(@"gwcomp", @"SoundController: refreshDevices completed initialization phase");
            }

            NSDebugLLog(@"gwcomp", @"SoundController: refreshDevices completed");
        });
        } // @autoreleasepool
    });
}

- (void)updateOutputDeviceList
{
    [outputDevices removeAllObjects];
    [outputDevices addObjectsFromArray:[backend outputDevices]];
    
    NSDebugLLog(@"gwcomp", @"SoundController: updateOutputDeviceList - found %lu output devices", 
          (unsigned long)[outputDevices count]);
    
    // Show/hide no devices placeholder
    BOOL hasDevices = ([outputDevices count] > 0);
    [noOutputDevicesLabel setHidden:hasDevices];
    [outputDevicesScrollView setHidden:!hasDevices];
    
    // Enable/disable controls based on device availability
    [outputVolumeSlider setEnabled:hasDevices];
    [outputMuteCheckbox setEnabled:hasDevices];
    [outputBalanceSlider setEnabled:hasDevices];
    
    // Find and select the current/active device
    AudioDevice *currentDevice = [backend defaultOutputDevice];
    [selectedOutputDevice release];
    selectedOutputDevice = [currentDevice retain];
    
    [outputDevicesTable reloadData];
    
    // Select the row for the current device (without triggering device switch during init)
    if (selectedOutputDevice) {
        NSUInteger index = [outputDevices indexOfObject:selectedOutputDevice];
        if (index != NSNotFound) {
            // Set the selection programmatically without triggering tableViewSelectionDidChange:
            // by temporarily setting a flag
            BOOL wasUpdatingUI = isUpdatingUI;
            isUpdatingUI = YES;
            [outputDevicesTable selectRowIndexes:[NSIndexSet indexSetWithIndex:index]
                            byExtendingSelection:NO];
            isUpdatingUI = wasUpdatingUI;
        }
    }
    
    // Update alert sounds list (done here because GNUstep/FreeBSD crashes
    // if this runs as a separate call in the dispatch block)
    [alertSounds removeAllObjects];
    NSMutableArray *uniqueSounds = [[NSMutableArray alloc] init];
    NSMutableSet *seenNames = [[NSMutableSet alloc] init];
    
    for (AlertSound *sound in [backend availableAlertSounds]) {
        if (![seenNames containsObject:sound.name]) {
            [uniqueSounds addObject:sound];
            [seenNames addObject:sound.name];
        }
    }
    [alertSounds addObjectsFromArray:uniqueSounds];
    [uniqueSounds release];
    [seenNames release];
    
    AlertSound *currentAlertSnd = [backend currentAlertSound];
    [selectedAlertSound release];
    selectedAlertSound = [currentAlertSnd retain];
    
    [alertSoundsTable reloadData];
    
    if (selectedAlertSound) {
        for (NSUInteger i = 0; i < [alertSounds count]; i++) {
            AlertSound *sound = [alertSounds objectAtIndex:i];
            if ([sound.name isEqualToString:selectedAlertSound.name]) {
                [alertSoundsTable selectRowIndexes:[NSIndexSet indexSetWithIndex:i]
                              byExtendingSelection:NO];
                break;
            }
        }
    }
    
    // Ensure alert sound device is set to current output device
    if (selectedOutputDevice) {
        dispatch_async(backendQueue, ^{
            [backend setAlertSoundDevice:selectedOutputDevice];
        });
    }
}

- (void)updateInputDeviceList
{
    [inputDevices removeAllObjects];
    [inputDevices addObjectsFromArray:[backend inputDevices]];
    
    NSDebugLLog(@"gwcomp", @"SoundController: updateInputDeviceList - found %lu input devices", 
          (unsigned long)[inputDevices count]);
    
    // Show/hide no devices placeholder
    BOOL hasDevices = ([inputDevices count] > 0);
    [noInputDevicesLabel setHidden:hasDevices];
    [inputDevicesScrollView setHidden:!hasDevices];
    
    // Enable/disable controls based on device availability
    [inputVolumeSlider setEnabled:hasDevices];
    [inputMuteCheckbox setEnabled:hasDevices];
    
    AudioDevice *currentDevice = [backend defaultInputDevice];
    [selectedInputDevice release];
    selectedInputDevice = [currentDevice retain];
    
    [inputDevicesTable reloadData];
    
    if (selectedInputDevice) {
        NSUInteger index = [inputDevices indexOfObject:selectedInputDevice];
        if (index != NSNotFound) {
            // Set the selection programmatically without triggering tableViewSelectionDidChange:
            // by temporarily setting a flag
            BOOL wasUpdatingUI = isUpdatingUI;
            isUpdatingUI = YES;
            [inputDevicesTable selectRowIndexes:[NSIndexSet indexSetWithIndex:index]
                           byExtendingSelection:NO];
            isUpdatingUI = wasUpdatingUI;
        }
    }
}

- (void)updateAlertSoundsList
{
    [alertSounds removeAllObjects];
    [alertSounds addObjectsFromArray:[backend availableAlertSounds]];
    
    AlertSound *current = [backend currentAlertSound];
    [selectedAlertSound release];
    selectedAlertSound = [current retain];
    
    [alertSoundsTable reloadData];
    
    if (selectedAlertSound) {
        for (NSUInteger i = 0; i < [alertSounds count]; i++) {
            AlertSound *sound = [alertSounds objectAtIndex:i];
            if ([sound.name isEqualToString:selectedAlertSound.name]) {
                [alertSoundsTable selectRowIndexes:[NSIndexSet indexSetWithIndex:i]
                              byExtendingSelection:NO];
                break;
            }
        }
    }
    
}

- (void)updateOutputControls
{
    float volume = [backend outputVolume];
    BOOL muted = [backend isOutputMuted];
    float balance = [backend outputBalance];
    
    [outputVolumeSlider setFloatValue:volume];
    [outputMuteCheckbox setState:muted ? NSOnState : NSOffState];
    [outputBalanceSlider setFloatValue:balance];
    
    // Update the main volume slider on effects tab too
    NSView *effectsTabView = [[mainTabView tabViewItemAtIndex:0] view];
    for (NSView *subview in [effectsTabView subviews]) {
        if ([subview isKindOfClass:[NSSlider class]] && 
            [(NSSlider *)subview tag] == 100) {
            [(NSSlider *)subview setFloatValue:volume];
        }
        if ([subview isKindOfClass:[NSButton class]] && 
            [(NSButton *)subview tag] == 100) {
            [(NSButton *)subview setState:muted ? NSOnState : NSOffState];
        }
    }
}

- (void)updateInputControls
{
    float volume = [backend inputVolume];
    BOOL muted = [backend isInputMuted];

    [inputVolumeSlider setFloatValue:volume];
    [inputMuteCheckbox setState:muted ? NSOnState : NSOffState];
}

// Non-blocking variants that use pre-fetched values (call from main thread only)
- (void)updateOutputControlsWithVolume:(float)volume muted:(BOOL)muted balance:(float)balance
{
    [outputVolumeSlider setFloatValue:volume];
    [outputMuteCheckbox setState:muted ? NSOnState : NSOffState];
    [outputBalanceSlider setFloatValue:balance];

    // Update the main volume slider on effects tab too
    NSView *effectsTabView = [[mainTabView tabViewItemAtIndex:0] view];
    for (NSView *subview in [effectsTabView subviews]) {
        if ([subview isKindOfClass:[NSSlider class]] &&
            [(NSSlider *)subview tag] == 100) {
            [(NSSlider *)subview setFloatValue:volume];
        }
        if ([subview isKindOfClass:[NSButton class]] &&
            [(NSButton *)subview tag] == 100) {
            [(NSButton *)subview setState:muted ? NSOnState : NSOffState];
        }
    }
}

- (void)updateInputControlsWithVolume:(float)volume muted:(BOOL)muted
{
    [inputVolumeSlider setFloatValue:volume];
    [inputMuteCheckbox setState:muted ? NSOnState : NSOffState];
}

- (BOOL)selectOutputDevice:(AudioDevice *)device
{
    if (!device) {
        NSDebugLLog(@"gwcomp", @"SoundController: selectOutputDevice: FAILED - device is nil");
        return NO;
    }

    NSDebugLLog(@"gwcomp", @"SoundController: selectOutputDevice: %@", device.name);
    [selectedOutputDevice release];
    selectedOutputDevice = [device retain];

    // During initialization, just read current state without switching devices
    if (!isInitializing) {
        AudioDevice *retained = [device retain];
        dispatch_async(backendQueue, ^{
            @autoreleasepool {
            BOOL success = [backend forceImmediateOutputDeviceSwitch:retained];
            NSDebugLLog(@"gwcomp", @"SoundController: forceImmediateOutputDeviceSwitch: %@", success ? @"SUCCESS" : @"FAILED");
            [retained release];
            // Fetch control values while still on background queue
            float vol = [backend outputVolume];
            BOOL muted = [backend isOutputMuted];
            float bal = [backend outputBalance];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self updateOutputControlsWithVolume:vol muted:muted balance:bal];
            });
            } // @autoreleasepool
        });
    }
    return YES;
}

- (BOOL)selectInputDevice:(AudioDevice *)device
{
    if (!device) {
        NSDebugLLog(@"gwcomp", @"SoundController: selectInputDevice: FAILED - device is nil");
        return NO;
    }

    NSDebugLLog(@"gwcomp", @"SoundController: selectInputDevice: %@", device.name);
    [selectedInputDevice release];
    selectedInputDevice = [device retain];

    // During initialization, just read current state without switching devices
    if (!isInitializing) {
        AudioDevice *retained = [device retain];
        dispatch_async(backendQueue, ^{
            @autoreleasepool {
            BOOL success = [backend forceImmediateInputDeviceSwitch:retained];
            NSDebugLLog(@"gwcomp", @"SoundController: forceImmediateInputDeviceSwitch: %@", success ? @"SUCCESS" : @"FAILED");
            [retained release];
            // Fetch control values while still on background queue
            float vol = [backend inputVolume];
            BOOL muted = [backend isInputMuted];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self updateInputControlsWithVolume:vol muted:muted];
            });
            } // @autoreleasepool
        });
    }
    return YES;
}

#pragma mark - Input Level Monitoring

- (void)startInputLevelMonitoring
{
    [backend startInputLevelMonitoring];
}

- (void)stopInputLevelMonitoring
{
    [backend stopInputLevelMonitoring];
}

#pragma mark - NSTableViewDataSource

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
    if (tableView == outputDevicesTable) {
        return [outputDevices count];
    } else if (tableView == inputDevicesTable) {
        return [inputDevices count];
    } else if (tableView == alertSoundsTable) {
        return [alertSounds count];
    }
    return 0;
}

- (id)tableView:(NSTableView *)tableView 
    objectValueForTableColumn:(NSTableColumn *)tableColumn 
                          row:(NSInteger)row
{
    NSString *columnId = [tableColumn identifier];
    
    if (tableView == outputDevicesTable) {
        if (row < 0 || row >= (NSInteger)[outputDevices count]) return nil;
        AudioDevice *device = [outputDevices objectAtIndex:row];
        
        if ([columnId isEqualToString:@"name"]) {
            return device.displayName ?: device.name;
        } else if ([columnId isEqualToString:@"type"]) {
            return [device typeString];
        }
    } else if (tableView == inputDevicesTable) {
        if (row < 0 || row >= (NSInteger)[inputDevices count]) return nil;
        AudioDevice *device = [inputDevices objectAtIndex:row];
        
        if ([columnId isEqualToString:@"name"]) {
            return device.displayName ?: device.name;
        } else if ([columnId isEqualToString:@"type"]) {
            return [device typeString];
        }
    } else if (tableView == alertSoundsTable) {
        if (row < 0 || row >= (NSInteger)[alertSounds count]) return nil;
        AlertSound *sound = [alertSounds objectAtIndex:row];
        
        if ([columnId isEqualToString:@"alertName"]) {
            return sound.displayName ?: sound.name;
        }
    }
    
    return nil;
}

#pragma mark - NSTableViewDelegate

- (void)tableViewSelectionDidChange:(NSNotification *)notification
{
    NSTableView *tableView = [notification object];
    NSDebugLLog(@"gwcomp", @"SoundController: tableViewSelectionDidChange:");
    
    if (tableView == outputDevicesTable) {
        NSDebugLLog(@"gwcomp", @"SoundController:   output devices table");
        NSInteger row = [tableView selectedRow];
        NSDebugLLog(@"gwcomp", @"SoundController:   selected row = %ld", (long)row);
        if (row >= 0 && row < (NSInteger)[outputDevices count]) {
            AudioDevice *device = [outputDevices objectAtIndex:row];
            NSDebugLLog(@"gwcomp", @"SoundController:   selecting device: %@", device.name);
            BOOL success = [self selectOutputDevice:device];
            NSDebugLLog(@"gwcomp", @"SoundController:   selectOutputDevice: %@", success ? @"SUCCESS" : @"FAILED");
            if (!success) {
                NSRunAlertPanel(@"Device Error", 
                              @"Could not select the output device. Please check your audio hardware and ALSA configuration.",
                              @"OK", nil, nil);
            }
        }
    } else if (tableView == inputDevicesTable) {
        NSDebugLLog(@"gwcomp", @"SoundController:   input devices table");
        NSInteger row = [tableView selectedRow];
        NSDebugLLog(@"gwcomp", @"SoundController:   selected row = %ld", (long)row);
        if (row >= 0 && row < (NSInteger)[inputDevices count]) {
            AudioDevice *device = [inputDevices objectAtIndex:row];
            NSDebugLLog(@"gwcomp", @"SoundController:   selecting device: %@", device.name);
            BOOL success = [self selectInputDevice:device];
            NSDebugLLog(@"gwcomp", @"SoundController:   selectInputDevice: %@", success ? @"SUCCESS" : @"FAILED");
            if (!success) {
                NSRunAlertPanel(@"Device Error", 
                              @"Could not select the input device. Please check your audio input hardware and ALSA configuration.",
                              @"OK", nil, nil);
            }
        }
    } else if (tableView == alertSoundsTable) {
        NSDebugLLog(@"gwcomp", @"SoundController:   alert sounds table (no auto-play)");
        // Don't auto-play on selection change, only on explicit action
    }
}

#pragma mark - Actions - Sound Effects

- (IBAction)alertSoundSelected:(id)sender
{
    NSDebugLLog(@"gwcomp", @"SoundController: UI ACTION - alertSoundSelected:");
    NSInteger row = [alertSoundsTable selectedRow];
    NSDebugLLog(@"gwcomp", @"SoundController:   selected row = %ld, alertSounds count = %lu",
          (long)row, (unsigned long)[alertSounds count]);
    if (row >= 0 && row < (NSInteger)[alertSounds count]) {
        AlertSound *sound = [alertSounds objectAtIndex:row];
        NSDebugLLog(@"gwcomp", @"SoundController:   sound name = %@, path = %@", sound.name, sound.path);
        [selectedAlertSound release];
        selectedAlertSound = [sound retain];

        // Dispatch playback and save to background queue
        AlertSound *retained = [sound retain];
        dispatch_async(backendQueue, ^{
            NSDebugLLog(@"gwcomp", @"SoundController:   calling playAlertSound:");
            BOOL success = [backend playAlertSound:retained];
            NSDebugLLog(@"gwcomp", @"SoundController:   playAlertSound: %@", success ? @"SUCCESS" : @"FAILED");

            BOOL saved = [backend setCurrentAlertSound:retained];
            NSDebugLLog(@"gwcomp", @"SoundController:   setCurrentAlertSound: %@", saved ? @"SUCCESS" : @"FAILED");
            [retained release];
            if (!success) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSRunAlertPanel(@"Sound Error",
                                  @"Could not play the selected alert sound. Please check your audio hardware and settings.",
                                  @"OK", nil, nil);
                });
            }
        });
    }
}

- (IBAction)alertVolumeChanged:(id)sender
{
    float volume = [alertVolumeSlider floatValue];

    // Coalesce rapid slider changes
    pendingAlertVolume = volume;

    if (alertVolumeTimer) {
        dispatch_source_cancel(alertVolumeTimer);
        dispatch_release(alertVolumeTimer);
        alertVolumeTimer = nil;
    }

    alertVolumeTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                              backendQueue);
    dispatch_source_set_timer(alertVolumeTimer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                              DISPATCH_TIME_FOREVER, 0);
    dispatch_source_set_event_handler(alertVolumeTimer, ^{
        float vol = pendingAlertVolume;
        BOOL success = [backend setAlertVolume:vol];
        NSDebugLLog(@"gwcomp", @"SoundController: setAlertVolume: %.2f %@", vol,
              success ? @"SUCCESS" : @"FAILED");
        if (!success) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSRunAlertPanel(@"Volume Error",
                              @"Could not change the alert volume. Please try again.",
                              @"OK", nil, nil);
            });
        }
    });
    dispatch_resume(alertVolumeTimer);
}

- (IBAction)playUIEffectsChanged:(id)sender
{
    NSDebugLLog(@"gwcomp", @"SoundController: UI ACTION - playUIEffectsChanged:");
    BOOL play = ([playUIEffectsCheckbox state] == NSOnState);
    NSDebugLLog(@"gwcomp", @"SoundController:   play = %@", play ? @"YES" : @"NO");
    dispatch_async(backendQueue, ^{
        BOOL success = [backend setPlayUserInterfaceSoundEffects:play];
        NSDebugLLog(@"gwcomp", @"SoundController:   setPlayUserInterfaceSoundEffects: %@", success ? @"SUCCESS" : @"FAILED");
        if (!success) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSRunAlertPanel(@"Settings Error",
                              @"Could not change the user interface sound effects setting.",
                              @"OK", nil, nil);
            });
        }
    });
}

- (IBAction)playVolumeFeedbackChanged:(id)sender
{
    NSDebugLLog(@"gwcomp", @"SoundController: UI ACTION - playVolumeFeedbackChanged:");
    BOOL play = ([playVolumeFeedbackCheckbox state] == NSOnState);
    NSDebugLLog(@"gwcomp", @"SoundController:   play = %@", play ? @"YES" : @"NO");
    dispatch_async(backendQueue, ^{
        BOOL success = [backend setPlayFeedbackWhenVolumeIsChanged:play];
        NSDebugLLog(@"gwcomp", @"SoundController:   setPlayFeedbackWhenVolumeIsChanged: %@", success ? @"SUCCESS" : @"FAILED");
        if (!success) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSRunAlertPanel(@"Settings Error",
                              @"Could not change the volume feedback setting.",
                              @"OK", nil, nil);
            });
        }
    });
}

- (void)alertSoundsTableDoubleClicked:(id)sender
{
    NSDebugLLog(@"gwcomp", @"SoundController: UI ACTION - alertSoundsTableDoubleClicked:");
    // Play the selected sound on double-click
    NSInteger row = [alertSoundsTable clickedRow];
    NSDebugLLog(@"gwcomp", @"SoundController:   clicked row = %ld", (long)row);
    if (row >= 0 && row < (NSInteger)[alertSounds count]) {
        AlertSound *sound = [[alertSounds objectAtIndex:row] retain];
        NSDebugLLog(@"gwcomp", @"SoundController:   sound name = %@, path = %@", sound.name, sound.path);
        dispatch_async(backendQueue, ^{
            BOOL success = [backend playAlertSound:sound];
            [sound release];
            NSDebugLLog(@"gwcomp", @"SoundController:   playAlertSound: %@", success ? @"SUCCESS" : @"FAILED");
            if (!success) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSRunAlertPanel(@"Sound Error",
                                  @"Could not play the alert sound. Please check your audio hardware and settings.",
                                  @"OK", nil, nil);
                });
            }
        });
    }
}

#pragma mark - Actions - Output

- (IBAction)outputDeviceSelected:(id)sender
{
    NSDebugLLog(@"gwcomp", @"SoundController: UI ACTION - outputDeviceSelected:");
    // Selection is handled in tableViewSelectionDidChange
}

- (IBAction)outputVolumeChanged:(id)sender
{
    if (isUpdatingUI) return;

    float volume = [(NSSlider *)sender floatValue];
    BOOL fromEffectsTab = ([sender tag] == 100);

    // Sync the other volume slider immediately for responsive UI
    if (!fromEffectsTab) {
        NSView *effectsTabView = [[mainTabView tabViewItemAtIndex:0] view];
        for (NSView *subview in [effectsTabView subviews]) {
            if ([subview isKindOfClass:[NSSlider class]] &&
                [(NSSlider *)subview tag] == 100) {
                [(NSSlider *)subview setFloatValue:volume];
            }
        }
    } else {
        [outputVolumeSlider setFloatValue:volume];
    }

    // Coalesce rapid slider changes: store the latest value and schedule
    // a single backend call after a short delay. This prevents flooding the
    // serial backend queue with amixer/aplay subprocess launches.
    pendingOutputVolume = volume;

    if (outputVolumeTimer) {
        dispatch_source_cancel(outputVolumeTimer);
        dispatch_release(outputVolumeTimer);
        outputVolumeTimer = nil;
    }

    outputVolumeTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                               backendQueue);
    dispatch_source_set_timer(outputVolumeTimer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                              DISPATCH_TIME_FOREVER, 0);
    dispatch_source_set_event_handler(outputVolumeTimer, ^{
        // Use the latest pending value in case the slider moved further
        // before this timer fired
        float vol = pendingOutputVolume;
        BOOL success = [backend setOutputVolume:vol];
        NSDebugLLog(@"gwcomp", @"SoundController: setOutputVolume: %.2f %@", vol,
              success ? @"SUCCESS" : @"FAILED");
        if (!success) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSRunAlertPanel(@"Volume Error",
                              @"Could not change the output volume. Please check your audio hardware and ALSA configuration.",
                              @"OK", nil, nil);
            });
        }
    });
    dispatch_resume(outputVolumeTimer);
}

- (IBAction)outputMuteChanged:(id)sender
{
    NSDebugLLog(@"gwcomp", @"SoundController: UI ACTION - outputMuteChanged: (tag=%ld)", (long)[sender tag]);
    if (isUpdatingUI) return;

    BOOL muted = ([(NSButton *)sender state] == NSOnState);
    BOOL fromEffectsTab = ([sender tag] == 100);
    NSDebugLLog(@"gwcomp", @"SoundController:   muted = %@", muted ? @"YES" : @"NO");

    // Sync the other mute checkbox immediately for responsive UI
    if (!fromEffectsTab) {
        NSView *effectsTabView = [[mainTabView tabViewItemAtIndex:0] view];
        for (NSView *subview in [effectsTabView subviews]) {
            if ([subview isKindOfClass:[NSButton class]] &&
                [(NSButton *)subview tag] == 100) {
                [(NSButton *)subview setState:muted ? NSOnState : NSOffState];
            }
        }
    } else {
        [outputMuteCheckbox setState:muted ? NSOnState : NSOffState];
    }

    dispatch_async(backendQueue, ^{
        BOOL success = [backend setOutputMuted:muted];
        NSDebugLLog(@"gwcomp", @"SoundController:   setOutputMuted: %@", success ? @"SUCCESS" : @"FAILED");
        if (!success) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSRunAlertPanel(@"Mute Error",
                              @"Could not change the mute setting. Please check your audio hardware and ALSA configuration.",
                              @"OK", nil, nil);
            });
        }
    });
}

- (IBAction)outputBalanceChanged:(id)sender
{
    NSDebugLLog(@"gwcomp", @"SoundController: UI ACTION - outputBalanceChanged:");
    if (isUpdatingUI) return;

    float balance = [outputBalanceSlider floatValue];
    NSDebugLLog(@"gwcomp", @"SoundController:   balance = %.2f", balance);
    dispatch_async(backendQueue, ^{
        BOOL success = [backend setOutputBalance:balance];
        NSDebugLLog(@"gwcomp", @"SoundController:   setOutputBalance: %@", success ? @"SUCCESS" : @"FAILED");
        if (!success) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSRunAlertPanel(@"Balance Error",
                              @"Could not change the audio balance. This feature may not be supported by your current audio device.",
                              @"OK", nil, nil);
            });
        }
    });
}

#pragma mark - Actions - Input

- (IBAction)inputDeviceSelected:(id)sender
{
    NSDebugLLog(@"gwcomp", @"SoundController: UI ACTION - inputDeviceSelected:");
    // Selection is handled in tableViewSelectionDidChange
}

- (IBAction)inputVolumeChanged:(id)sender
{
    if (isUpdatingUI) return;

    float volume = [inputVolumeSlider floatValue];

    // Coalesce rapid slider changes
    pendingInputVolume = volume;

    if (inputVolumeTimer) {
        dispatch_source_cancel(inputVolumeTimer);
        dispatch_release(inputVolumeTimer);
        inputVolumeTimer = nil;
    }

    inputVolumeTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                              backendQueue);
    dispatch_source_set_timer(inputVolumeTimer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                              DISPATCH_TIME_FOREVER, 0);
    dispatch_source_set_event_handler(inputVolumeTimer, ^{
        float vol = pendingInputVolume;
        BOOL success = [backend setInputVolume:vol];
        NSDebugLLog(@"gwcomp", @"SoundController: setInputVolume: %.2f %@", vol,
              success ? @"SUCCESS" : @"FAILED");
        if (!success) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSRunAlertPanel(@"Volume Error",
                              @"Could not change the input volume. Please check your audio input device and ALSA configuration.",
                              @"OK", nil, nil);
            });
        }
    });
    dispatch_resume(inputVolumeTimer);
}

- (IBAction)inputMuteChanged:(id)sender
{
    NSDebugLLog(@"gwcomp", @"SoundController: UI ACTION - inputMuteChanged:");
    if (isUpdatingUI) return;

    BOOL muted = ([inputMuteCheckbox state] == NSOnState);
    NSDebugLLog(@"gwcomp", @"SoundController:   muted = %@", muted ? @"YES" : @"NO");
    dispatch_async(backendQueue, ^{
        BOOL success = [backend setInputMuted:muted];
        NSDebugLLog(@"gwcomp", @"SoundController:   setInputMuted: %@", success ? @"SUCCESS" : @"FAILED");
        if (!success) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSRunAlertPanel(@"Mute Error",
                              @"Could not change the input mute setting. Please check your audio input device and ALSA configuration.",
                              @"OK", nil, nil);
            });
        }
    });
}

#pragma mark - SoundBackendDelegate

- (void)soundBackend:(id<SoundBackend>)aBackend didUpdateOutputDevices:(NSArray *)devices
{
    [self performSelectorOnMainThread:@selector(handleUpdatedOutputDevices:) 
                           withObject:devices 
                        waitUntilDone:NO];
}

- (void)soundBackend:(id<SoundBackend>)aBackend didUpdateInputDevices:(NSArray *)devices
{
    [self performSelectorOnMainThread:@selector(handleUpdatedInputDevices:) 
                           withObject:devices 
                        waitUntilDone:NO];
}

- (void)soundBackend:(id<SoundBackend>)aBackend outputVolumeDidChange:(float)volume
{
    NSNumber *volNum = [NSNumber numberWithFloat:volume];
    [self performSelectorOnMainThread:@selector(handleOutputVolumeChange:) 
                           withObject:volNum 
                        waitUntilDone:NO];
}

- (void)soundBackend:(id<SoundBackend>)aBackend inputVolumeDidChange:(float)volume
{
    NSNumber *volNum = [NSNumber numberWithFloat:volume];
    [self performSelectorOnMainThread:@selector(handleInputVolumeChange:) 
                           withObject:volNum 
                        waitUntilDone:NO];
}

- (void)soundBackend:(id<SoundBackend>)aBackend outputMuteDidChange:(BOOL)muted
{
    NSNumber *muteNum = [NSNumber numberWithBool:muted];
    [self performSelectorOnMainThread:@selector(handleOutputMuteChange:) 
                           withObject:muteNum 
                        waitUntilDone:NO];
}

- (void)soundBackend:(id<SoundBackend>)aBackend inputMuteDidChange:(BOOL)muted
{
    NSNumber *muteNum = [NSNumber numberWithBool:muted];
    [self performSelectorOnMainThread:@selector(handleInputMuteChange:) 
                           withObject:muteNum 
                        waitUntilDone:NO];
}

- (void)soundBackend:(id<SoundBackend>)aBackend inputLevelDidChange:(float)level
{
    [inputLevelMeter setFloatValue:level];
}

- (void)soundBackend:(id<SoundBackend>)aBackend didEncounterError:(NSError *)error
{
    NSDebugLLog(@"gwcomp", @"Sound backend error: %@", error);
}

#pragma mark - Delegate Helpers

- (void)handleUpdatedOutputDevices:(NSArray *)devices
{
    isUpdatingUI = YES;
    [self updateOutputDeviceList];
    isUpdatingUI = NO;
}

- (void)handleUpdatedInputDevices:(NSArray *)devices
{
    isUpdatingUI = YES;
    [self updateInputDeviceList];
    isUpdatingUI = NO;
}

- (void)handleOutputVolumeChange:(NSNumber *)volumeNum
{
    isUpdatingUI = YES;
    float volume = [volumeNum floatValue];
    [outputVolumeSlider setFloatValue:volume];
    
    NSView *effectsTabView = [[mainTabView tabViewItemAtIndex:0] view];
    for (NSView *subview in [effectsTabView subviews]) {
        if ([subview isKindOfClass:[NSSlider class]] && 
            [(NSSlider *)subview tag] == 100) {
            [(NSSlider *)subview setFloatValue:volume];
        }
    }
    isUpdatingUI = NO;
}

- (void)handleInputVolumeChange:(NSNumber *)volumeNum
{
    isUpdatingUI = YES;
    [inputVolumeSlider setFloatValue:[volumeNum floatValue]];
    isUpdatingUI = NO;
}

- (void)handleOutputMuteChange:(NSNumber *)muteNum
{
    isUpdatingUI = YES;
    BOOL muted = [muteNum boolValue];
    [outputMuteCheckbox setState:muted ? NSOnState : NSOffState];
    
    NSView *effectsTabView = [[mainTabView tabViewItemAtIndex:0] view];
    for (NSView *subview in [effectsTabView subviews]) {
        if ([subview isKindOfClass:[NSButton class]] && 
            [(NSButton *)subview tag] == 100) {
            [(NSButton *)subview setState:muted ? NSOnState : NSOffState];
        }
    }
    isUpdatingUI = NO;
}

- (void)handleInputMuteChange:(NSNumber *)muteNum
{
    isUpdatingUI = YES;
    [inputMuteCheckbox setState:[muteNum boolValue] ? NSOnState : NSOffState];
    isUpdatingUI = NO;
}

- (void)handleVolumeChange:(float)volume isOutput:(BOOL)isOutput
{
    if (isOutput) {
        [self handleOutputVolumeChange:[NSNumber numberWithFloat:volume]];
    } else {
        [self handleInputVolumeChange:[NSNumber numberWithFloat:volume]];
    }
}

- (void)handleMuteChange:(BOOL)muted isOutput:(BOOL)isOutput
{
    if (isOutput) {
        [self handleOutputMuteChange:[NSNumber numberWithBool:muted]];
    } else {
        [self handleInputMuteChange:[NSNumber numberWithBool:muted]];
    }
}

- (void)handleInputLevelChange:(float)level
{
    [inputLevelMeter setFloatValue:level];
}

#pragma mark - Helpers

- (NSImage *)iconForDeviceType:(AudioDeviceType)type isOutput:(BOOL)isOutput
{
    // Return appropriate icon based on device type
    NSString *iconName = nil;
    
    switch (type) {
        case AudioDeviceTypeHeadphones:
            iconName = @"NSHeadphones";
            break;
        case AudioDeviceTypeBuiltInSpeaker:
        case AudioDeviceTypeLineOut:
            iconName = @"NSSpeaker";
            break;
        case AudioDeviceTypeBuiltInMicrophone:
        case AudioDeviceTypeHeadsetMicrophone:
            iconName = @"NSMicrophone";
            break;
        case AudioDeviceTypeUSBAudio:
            iconName = @"NSUSBDevice";
            break;
        case AudioDeviceTypeHDMI:
        case AudioDeviceTypeDisplayPort:
            iconName = @"NSDisplay";
            break;
        default:
            iconName = isOutput ? @"NSSpeaker" : @"NSMicrophone";
            break;
    }
    
    NSImage *icon = [NSImage imageNamed:iconName];
    if (!icon) {
        icon = [NSImage imageNamed:NSImageNameComputer];
    }
    return icon;
}

- (void)showErrorAlert:(NSString *)message informativeText:(NSString *)info
{
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:message];
    [alert setInformativeText:info];
    [alert setAlertStyle:NSWarningAlertStyle];
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
    [alert release];
}

@end
