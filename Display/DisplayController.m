/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */


#import "DisplayController.h"
#import "DisplayView.h"
#import "X11DisplayManager.h"
#import <dispatch/dispatch.h>

@implementation DisplayInfo

@synthesize name, frame, resolution, isPrimary, isConnected, output, currentResolutionString, availableResolutions;

- (id)init
{
    self = [super init];
    if (self) {
        name = nil;
        frame = NSZeroRect;
        resolution = NSZeroSize;
        isPrimary = NO;
        isConnected = NO;
        output = nil;
        currentResolutionString = nil;
        availableResolutions = nil;
    }
    return self;
}

- (void)dealloc
{
    [name release];
    [output release];
    [currentResolutionString release];
    [availableResolutions release];
    [super dealloc];
}

@end

static NSInteger dialogIDCounter = 0;
static NSMutableDictionary *activeDialogsByID = nil;

@implementation DisplayController

- (id)init
{
    self = [super init];
    if (self) {
        displays = [[NSMutableArray alloc] init];
        selectedDisplay = nil;
        isRefreshing = NO;
        x11 = [[X11DisplayManager alloc] init];
        
        if ([x11 isAvailable]) {
            NSDebugLog(@"DisplayController: X11 backend ready");
        } else {
            NSDebugLog(@"DisplayController: X11 backend not available");
        }
    }
    return self;
}

- (void)dealloc
{
    [displays release];
    [displayView release];
    [mainView release];
    [resolutionPopup release];
    [scaleSlider release];
    [scaleValueLabel release];
    [scaleFactorHintLabel release];
    [mirrorDisplaysCheckbox release];
    [x11 release];
    [saveButton release];
    [savedStateSnapshot release];
    [lastDisplaySnapshot release];
    [super dealloc];
}

- (NSView *)createMainView
{
    if (mainView) {
        return mainView;
    }
    
    // Check if X11 RANDR is available before creating the view
    if (![x11 isAvailable]) {
        NSDebugLog(@"DisplayController: Cannot create main view - X11 not available");
        
        // Create a simple error view
        mainView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 500, 320)];
        
        NSTextField *errorLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 140, 460, 40)];
        [errorLabel setStringValue:@"Display configuration is not available.\nThe X11 RANDR extension is required."];
        [errorLabel setBezeled:NO];
        [errorLabel setDrawsBackground:NO];
        [errorLabel setEditable:NO];
        [errorLabel setSelectable:NO];
        [errorLabel setFont:[NSFont systemFontOfSize:14]];
        [errorLabel setAlignment:NSCenterTextAlignment];
        [mainView addSubview:errorLabel];
        [errorLabel release];
        
        return mainView;
    }
    
    NSDebugLog(@"DisplayController: Creating main view with X11 RANDR available");
    
    // Get available width from SystemPreferences window if possible
    float availableWidth = 500; // Default fallback
    float availableHeight = 320; // Default fallback
    
    // Try to get the actual SystemPreferences window size
    NSArray *windows = [NSApp windows];
    for (NSWindow *window in windows) {
        if ([[window title] containsString:@"System Preferences"] || 
            [[window className] containsString:@"PreferencePane"]) {
            NSRect windowFrame = [window frame];
            NSRect contentRect = [window contentRectForFrameRect:windowFrame];
            // Use most of the content area, leaving margins
            availableWidth = contentRect.size.width - 40; // 20px margin on each side
            availableHeight = contentRect.size.height - 80; // Space for title and controls
            NSDebugLog(@"DisplayController: Found SystemPreferences window, using size: %.0fx%.0f", availableWidth, availableHeight);
            break;
        }
    }
    
    // Ensure reasonable minimums
    if (availableWidth < 400) availableWidth = 500;
    if (availableHeight < 250) availableHeight = 320;
    
    mainView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, availableWidth, availableHeight)];
    
    NSTextField *instructLabel1 = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 115, availableWidth - 22, 20)];
    [instructLabel1 setStringValue:@"Drag displays to arrange them. Drag menu bar to set the main display."];
    [instructLabel1 setBezeled:NO];
    [instructLabel1 setDrawsBackground:NO];
    [instructLabel1 setEditable:NO];
    [instructLabel1 setSelectable:NO];
    [instructLabel1 setFont:[NSFont systemFontOfSize:11]];
    [mainView addSubview:instructLabel1];
    [instructLabel1 release];
    
    // Create a display arrangement view that uses most of the available space
    float displayAreaHeight = availableHeight - 160; // Leave space for controls below
    displayView = [[DisplayView alloc] initWithFrame:NSMakeRect(20, 140, availableWidth - 22, displayAreaHeight)];
    [displayView setController:self];
    [mainView addSubview:displayView];

    
    // Mirror displays checkbox
    mirrorDisplaysCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(20, 90, 200, 20)];
    [mirrorDisplaysCheckbox setButtonType:NSSwitchButton];
    [mirrorDisplaysCheckbox setTitle:@"Mirror Displays"];
    [mirrorDisplaysCheckbox setTarget:self];
    [mirrorDisplaysCheckbox setAction:@selector(mirrorDisplaysChanged:)];
    [mainView addSubview:mirrorDisplaysCheckbox];
    
    // Resolution popup
    NSTextField *resLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 54, 80, 20)];
    [resLabel setStringValue:@"Resolution:"];
    [resLabel setBezeled:NO];
    [resLabel setDrawsBackground:NO];
    [resLabel setEditable:NO];
    [resLabel setSelectable:NO];
    [mainView addSubview:resLabel];
    [resLabel release];
    
    resolutionPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(110, 51, 180, 25)];
    [resolutionPopup setTarget:self];
    [resolutionPopup setAction:@selector(resolutionChanged:)];
    [mainView addSubview:resolutionPopup];

    // Save Settings button
    saveButton = [[NSButton alloc] initWithFrame:NSMakeRect(availableWidth - 120, 51, 100, 25)];
    [saveButton setTitle:@"Save Settings"];
    [saveButton setButtonType:NSMomentaryPushInButton];
    [saveButton setBezelStyle:NSRoundedBezelStyle];
    [saveButton setTarget:self];
    [saveButton setAction:@selector(saveSettings:)];
    [saveButton setEnabled:NO];
    [mainView addSubview:saveButton];

    // Scale factor slider at the bottom of the pane (sets GSScaleFactor, 0.8 - 2.0, default 1.0)
    double currentScaleFactor = 1.0;
    NSDictionary *domain = [[NSUserDefaults standardUserDefaults] persistentDomainForName:NSGlobalDomain];
    NSNumber *storedFactor = [domain objectForKey:@"GSScaleFactor"];
    if (storedFactor) {
        currentScaleFactor = [storedFactor doubleValue];
        if (currentScaleFactor < 0.8) currentScaleFactor = 0.8;
        if (currentScaleFactor > 2.0) currentScaleFactor = 2.0;
    }
    
    NSTextField *scaleLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 26, 100, 20)];
    [scaleLabel setStringValue:@"Scale Factor:"];
    [scaleLabel setBezeled:NO];
    [scaleLabel setDrawsBackground:NO];
    [scaleLabel setEditable:NO];
    [scaleLabel setSelectable:NO];
    [mainView addSubview:scaleLabel];
    [scaleLabel release];
    
    scaleSlider = [[NSSlider alloc] initWithFrame:NSMakeRect(130, 23, 200, 25)];
    [scaleSlider setMinValue:0.8];
    [scaleSlider setMaxValue:2.0];
    [scaleSlider setDoubleValue:currentScaleFactor];
    [scaleSlider setContinuous:YES];
    [scaleSlider setTarget:self];
    [scaleSlider setAction:@selector(scaleFactorChanged:)];
    [mainView addSubview:scaleSlider];
    
    scaleValueLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(335, 26, 45, 20)];
    [scaleValueLabel setStringValue:[NSString stringWithFormat:@"%.2fx", currentScaleFactor]];
    [scaleValueLabel setBezeled:NO];
    [scaleValueLabel setDrawsBackground:NO];
    [scaleValueLabel setEditable:NO];
    [scaleValueLabel setSelectable:NO];
    [mainView addSubview:scaleValueLabel];
    
    scaleFactorHintLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 2, availableWidth - 40, 20)];
    [scaleFactorHintLabel setStringValue:@"Changes will take effect for newly started applications"];
    [scaleFactorHintLabel setBezeled:NO];
    [scaleFactorHintLabel setDrawsBackground:NO];
    [scaleFactorHintLabel setEditable:NO];
    [scaleFactorHintLabel setSelectable:NO];
    [scaleFactorHintLabel setFont:[NSFont systemFontOfSize:11]];
    [scaleFactorHintLabel setTextColor:[NSColor grayColor]];
    [scaleFactorHintLabel setHidden:YES];
    [mainView addSubview:scaleFactorHintLabel];

    // Do not call refreshDisplays: here — the DisplayPane's didSelect
    // will trigger it once the view is in the window hierarchy.
    // Calling it here races with didSelect and causes double async loads.

    return mainView;
}

- (void)refreshDisplays:(NSTimer *)timer
{
    if (![x11 isAvailable]) {
        NSDebugLog(@"DisplayController: Cannot refresh displays - X11 not available");
        return;
    }

    // Prevent concurrent refreshes.
    if (isRefreshing) {
        NSDebugLog(@"DisplayController: Refresh already in progress, skipping");
        return;
    }
    isRefreshing = YES;

    NSDebugLog(@"DisplayController: Refreshing displays");

    // Store the currently selected display to preserve selection
    NSString *previouslySelectedOutput = nil;
    if (selectedDisplay) {
        previouslySelectedOutput = [[selectedDisplay output] retain];
        NSDebugLog(@"DisplayController: Preserving selection for display: %@", previouslySelectedOutput);
    }

    // Query the X server directly — X11 calls on the main thread are fine
    // since we always XSync after writes.
    NSArray *newDisplays = [x11 listOutputs];

    isRefreshing = NO;

    if (newDisplays) {
        [displays setArray:newDisplays];
    } else {
        NSDebugLog(@"DisplayController: listOutputs returned nil");
    }

    // Restore the previously selected display if it still exists
    if (previouslySelectedOutput) {
        selectedDisplay = nil;
        for (DisplayInfo *display in displays) {
            if ([[display output] isEqualToString:previouslySelectedOutput]) {
                selectedDisplay = display;
                NSDebugLog(@"DisplayController: Restored selection for display: %@", [display name]);
                break;
            }
        }
        [previouslySelectedOutput release];
    }

    // Only rebuild views if configuration actually changed
    if (displayView) {
        NSString *currentSnap = [self currentStateSnapshot];
        if (![currentSnap isEqualToString:lastDisplaySnapshot]) {
            [lastDisplaySnapshot release];
            lastDisplaySnapshot = [currentSnap copy];
            [displayView updateDisplayRects];
        }
        [displayView setNeedsDisplay:YES];
    }

    // Detect mirroring: all connected displays share the same position,
    // but only treat as mirrored if the user has explicitly saved a
    // mirror configuration.
    NSUInteger currentCount = [displays count];
    BOOL wasMirrored = [mirrorDisplaysCheckbox state] == NSOnState;
    if (mirrorDisplaysCheckbox) {
        if (currentCount > 1) {
            [mirrorDisplaysCheckbox setEnabled:YES];
            BOOL positionsMatch = YES;
            NSPoint firstPos = [[displays objectAtIndex:0] frame].origin;
            for (NSUInteger i = 1; i < currentCount; i++) {
                NSPoint pos = [[displays objectAtIndex:i] frame].origin;
                if (pos.x != firstPos.x || pos.y != firstPos.y) {
                    positionsMatch = NO;
                    break;
                }
            }
            BOOL mirrored = positionsMatch && (wasMirrored || [self hasSavedMirrorConfig]);
            [mirrorDisplaysCheckbox setState:mirrored ? NSOnState : NSOffState];

            if (positionsMatch && !mirrored) {
                NSDebugLog(@"DisplayController: Displays at same position without saved mirror config \u2014 auto-extending");
                CGFloat xOffset = 0;
                for (DisplayInfo *display in displays) {
                    NSRect f = [display frame];
                    f.origin.x = xOffset;
                    f.origin.y = 0;
                    [display setFrame:f];
                    xOffset += f.size.width;
                }
                previousDisplayCount = currentCount;
                if (displayView) {
                    [displayView updateDisplayRects];
                    [displayView setNeedsDisplay:YES];
                }
                [self updateResolutionPopup];
                // Apply positions to X server directly without triggering a
                // full refresh cycle (which would cascade back into this method)
                NSMutableDictionary *placements = [NSMutableDictionary dictionary];
                for (DisplayInfo *display in displays) {
                    [placements setObject:[NSValue valueWithPoint:[display frame].origin]
                                  forKey:[display output]];
                }
                [x11 applyPositions:placements];
                [lastDisplaySnapshot release];
                lastDisplaySnapshot = [[self currentStateSnapshot] copy];
                [savedStateSnapshot release];
                savedStateSnapshot = [lastDisplaySnapshot copy];
                [self updateSaveButtonState];
                return;
            }
        } else {
            [mirrorDisplaysCheckbox setState:NSOffState];
            [mirrorDisplaysCheckbox setEnabled:NO];
        }
    }

    BOOL isMirrored = [mirrorDisplaysCheckbox state] == NSOnState;
    if (wasMirrored && isMirrored && currentCount > previousDisplayCount && currentCount > 1) {
        NSDebugLog(@"DisplayController: New display detected while mirroring \u2014 auto-applying mirror");
        previousDisplayCount = currentCount;
        [self mirrorDisplaysChanged:nil];
        return;
    }
    if (currentCount != previousDisplayCount) {
        [savedStateSnapshot release];
        savedStateSnapshot = [[self currentStateSnapshot] copy];
    }
    previousDisplayCount = currentCount;

    [self updateResolutionPopup];
    [self updateSaveButtonState];
}



- (void)updateResolutionPopup
{
    [resolutionPopup removeAllItems];
    
    DisplayInfo *targetDisplay = selectedDisplay;
    
    if (!targetDisplay) {
        for (DisplayInfo *display in displays) {
            if ([display isPrimary]) {
                targetDisplay = display;
                selectedDisplay = display;
                break;
            }
        }
    }
    
    if (!targetDisplay && [displays count] > 0) {
        targetDisplay = [displays objectAtIndex:0];
        selectedDisplay = targetDisplay;
        [targetDisplay setIsPrimary:YES];
    }
    
    if (targetDisplay) {
        NSArray *avail = [targetDisplay availableResolutions];
        if (!avail) avail = @[];
        
        NSString *currentRes = [targetDisplay currentResolutionString];
        if (!currentRes) {
            currentRes = [NSString stringWithFormat:@"%.0fx%.0f",
                                     [targetDisplay resolution].width,
                                     [targetDisplay resolution].height];
        }
        
        BOOL hasCurrent = NO;
        for (NSString *res in avail) {
            [resolutionPopup addItemWithTitle:res];
            if ([res isEqualToString:currentRes]) hasCurrent = YES;
        }
        if (!hasCurrent) {
            [resolutionPopup addItemWithTitle:currentRes];
        }
        
        [resolutionPopup selectItemWithTitle:currentRes];
    }
}

- (void)mirrorDisplaysChanged:(id)sender
{
    BOOL mirror = [mirrorDisplaysCheckbox state] == NSOnState;
    NSDebugLog(@"DisplayController: Mirror displays changed to: %@", mirror ? @"ON" : @"OFF");
    
    if (mirror && [displays count] > 1) {
        DisplayInfo *primary = nil;
        for (DisplayInfo *display in displays) {
            if ([display isPrimary]) { primary = display; break; }
        }
        if (!primary && [displays count] > 0) {
            primary = [displays objectAtIndex:0];
        }
        
        if (primary) {
            NSDebugLog(@"DisplayController: Enabling mirroring with primary display: %@", [primary name]);
            
            // Mark primary in the X server
            if ([x11 respondsToSelector:@selector(setPrimary:)]) {
                // Use XRRSetOutputPrimary via X11DisplayManager
            }
            
            // Move each secondary to the primary's position atomically
            NSPoint primaryPos = [primary frame].origin;
            NSMutableDictionary *placements = [NSMutableDictionary dictionary];
            for (DisplayInfo *display in displays) {
                NSRect f = [display frame];
                f.origin = primaryPos;
                [display setFrame:f];
                if (display != primary) {
                    [placements setObject:[NSValue valueWithPoint:primaryPos]
                                  forKey:[display output]];
                }
            }
            [x11 applyPositions:placements];
            [self refreshDisplays:nil];
        }
    } else {
        NSDebugLog(@"DisplayController: Disabling mirroring, arranging displays side by side");
        
        CGFloat xOffset = 0;
        NSMutableDictionary *placements = [NSMutableDictionary dictionary];
        for (DisplayInfo *display in displays) {
            NSRect f = [display frame];
            f.origin.x = xOffset;
            f.origin.y = 0;
            [display setFrame:f];
            [placements setObject:[NSValue valueWithPoint:f.origin]
                          forKey:[display output]];
            xOffset += f.size.width;
        }
        [x11 applyPositions:placements];
        [self refreshDisplays:nil];
    }
}

- (void)resolutionChanged:(id)sender
{
    NSString *selectedResolution = [resolutionPopup titleOfSelectedItem];
    
    DisplayInfo *targetDisplay = selectedDisplay;
    if (!targetDisplay) {
        NSDebugLog(@"DisplayController: No display selected for resolution change");
        return;
    }
    
    if (targetDisplay && selectedResolution) {
        NSString *currentRes = [targetDisplay currentResolutionString];
        
        if ([selectedResolution isEqualToString:currentRes]) {
            return;
        }
        
        NSDebugLog(@"DisplayController: Changing resolution for %@ from %@ to %@",
              [targetDisplay name], currentRes, selectedResolution);
        
        [targetDisplay setCurrentResolutionString:selectedResolution];

        int x = (int)[targetDisplay frame].origin.x;
        [x11 setMode:[targetDisplay output] mode:selectedResolution positionX:x positionY:0];

        // Show dialog BEFORE refreshDisplays: so targetDisplay is still valid.
        // refreshDisplaces replaces all DisplayInfo objects.
        [self showResolutionConfirmationDialogWithOldResolution:currentRes
                                                 newResolution:selectedResolution
                                                       display:targetDisplay];
        [self refreshDisplays:nil];
    }
}

- (void)showResolutionConfirmationDialogWithOldResolution:(NSString *)oldRes 
                                           newResolution:(NSString *)newRes 
                                                 display:(DisplayInfo *)display
{
    NSDebugLog(@"DisplayController: Showing resolution confirmation dialog - old:%@ new:%@", oldRes, newRes);
    
    // Create a floating window for confirmation (non-modal to allow timer to work)
    NSWindow *confirmWindow = [[NSWindow alloc] 
        initWithContentRect:NSMakeRect(100, 100, 400, 150)
        styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
        backing:NSBackingStoreBuffered
        defer:NO];
    
    [confirmWindow setTitle:@"Display Resolution Changed"];
    [confirmWindow setLevel:NSFloatingWindowLevel];
    [confirmWindow setHidesOnDeactivate:NO];
    
    NSView *contentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 150)];
    [confirmWindow setContentView:contentView];
    
    // Message text
    NSTextField *messageLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 80, 360, 40)];
    [messageLabel setStringValue:[NSString stringWithFormat:@"Resolution changed to %@.\nKeep this resolution? Auto-revert in 15 seconds.", newRes]];
    [messageLabel setBezeled:NO];
    [messageLabel setDrawsBackground:NO];
    [messageLabel setEditable:NO];
    [messageLabel setSelectable:NO];
    [messageLabel setAlignment:NSCenterTextAlignment];
    [contentView addSubview:messageLabel];
    [messageLabel release];
    
    // Countdown label
    NSTextField *countdownLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 50, 360, 20)];
    [countdownLabel setStringValue:@"15"];
    [countdownLabel setBezeled:NO];
    [countdownLabel setDrawsBackground:NO];
    [countdownLabel setEditable:NO];
    [countdownLabel setSelectable:NO];
    [countdownLabel setAlignment:NSCenterTextAlignment];
    [countdownLabel setFont:[NSFont boldSystemFontOfSize:16]];
    [contentView addSubview:countdownLabel];
    
    // Buttons
    NSButton *revertButton = [[NSButton alloc] initWithFrame:NSMakeRect(220, 20, 80, 25)];
    [revertButton setTitle:@"Revert"];
    [revertButton setKeyEquivalent:@"\e"]; // ESC key
    [contentView addSubview:revertButton];
    
    NSButton *keepButton = [[NSButton alloc] initWithFrame:NSMakeRect(310, 20, 70, 25)];
    [keepButton setTitle:@"Keep"];
    [keepButton setKeyEquivalent:@"\r"]; // Enter key
    [contentView addSubview:keepButton];
    
    // Store data for timer and button actions
    NSMutableDictionary *dialogData = [[NSMutableDictionary alloc] init];
    [dialogData setObject:confirmWindow forKey:@"window"];
    [dialogData setObject:oldRes forKey:@"oldResolution"];
    [dialogData setObject:display forKey:@"display"];
    [dialogData setObject:countdownLabel forKey:@"countdownLabel"];
    [dialogData setObject:[NSNumber numberWithInt:15] forKey:@"countdown"];
    [dialogData setObject:@NO forKey:@"released"];
    
    // Assign unique ID and store in global registry
    if (!activeDialogsByID) {
        activeDialogsByID = [[NSMutableDictionary alloc] init];
    }
    NSInteger dialogID = ++dialogIDCounter;
    [dialogData setObject:@(dialogID) forKey:@"id"];
    [activeDialogsByID setObject:dialogData forKey:@(dialogID)];
    
    [revertButton setTarget:self];
    [revertButton setAction:@selector(resolutionRevertClicked:)];
    [revertButton setTag:dialogID];
    
    [keepButton setTarget:self];
    [keepButton setAction:@selector(resolutionKeepClicked:)];
    [keepButton setTag:dialogID];
    
    // Create countdown timer - Use NSRunLoop mainRunLoop to ensure it works
        NSTimer *countdownTimer = [NSTimer timerWithTimeInterval:1.0
                                                                                                            target:self
                                                                                                        selector:@selector(resolutionCountdownTimer:)
                                                                                                        userInfo:@(dialogID) // store ID to avoid retaining dialogData in timer
                                                                                                         repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:countdownTimer forMode:NSDefaultRunLoopMode];
    [dialogData setObject:countdownTimer forKey:@"timer"];
    
    [confirmWindow center];
    [confirmWindow makeKeyAndOrderFront:nil];
    [confirmWindow orderFrontRegardless]; // Ensure it appears on top
    
    [revertButton release];
    [keepButton release];
    [contentView release];
}

- (void)revertResolutionTimer:(NSTimer *)timer
{
    NSDictionary *userInfo = [timer userInfo];
    NSString *oldRes = [userInfo objectForKey:@"oldResolution"];
    DisplayInfo *display = [userInfo objectForKey:@"display"];
    
    NSDebugLog(@"Auto-reverting resolution to %@", oldRes);
    [self revertToResolution:oldRes forDisplay:display];
    
    // Show a brief notification
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:@"Resolution Reverted"];
    [alert setInformativeText:[NSString stringWithFormat:@"The display resolution has been automatically reverted to %@.", oldRes]];
    [alert addButtonWithTitle:@"OK"];
    [alert setAlertStyle:NSInformationalAlertStyle];
    [alert runModal];
    [alert release];
}

- (void)resolutionCountdownTimer:(NSTimer *)timer
{
    NSNumber *dialogIDNum = [timer userInfo];
    NSMutableDictionary *dialogData = [activeDialogsByID objectForKey:dialogIDNum];
    if (!dialogData) return;

    NSNumber *countdownNum = [dialogData objectForKey:@"countdown"];
    NSTextField *countdownLabel = [dialogData objectForKey:@"countdownLabel"];
    
    int countdown = [countdownNum intValue] - 1;
    [dialogData setObject:[NSNumber numberWithInt:countdown] forKey:@"countdown"];
    
    [countdownLabel setStringValue:[NSString stringWithFormat:@"%d", countdown]];
    
    if (countdown <= 0) {
        // Time's up - revert
        if ([[dialogData objectForKey:@"released"] boolValue]) return;
        [dialogData setObject:@YES forKey:@"released"];
        
        [timer invalidate];
        NSString *oldRes = [dialogData objectForKey:@"oldResolution"];
        DisplayInfo *display = [dialogData objectForKey:@"display"];
        NSWindow *window = [dialogData objectForKey:@"window"];
        
        NSNumber *dialogIDNum = [dialogData objectForKey:@"id"];
        NSTimer *timerFromData = [dialogData objectForKey:@"timer"];
        [timerFromData invalidate];
        [dialogData removeObjectForKey:@"timer"]; // release timer retained by dialogData
        [activeDialogsByID removeObjectForKey:dialogIDNum];
        
        NSDebugLog(@"DisplayController: Countdown reached 0, auto-reverting resolution");
        [self revertToResolution:oldRes forDisplay:display];
        [window close];
    }
}

- (void)resolutionRevertClicked:(id)sender
{
    NSButton *button = (NSButton *)sender;
    NSInteger dialogID = [button tag];
    NSMutableDictionary *dialogData = [activeDialogsByID objectForKey:@(dialogID)];
    
    if (!dialogData) return;
    
    if ([[dialogData objectForKey:@"released"] boolValue]) return;
    [dialogData setObject:@YES forKey:@"released"];
    
    NSTimer *timer = [dialogData objectForKey:@"timer"];
    NSString *oldRes = [dialogData objectForKey:@"oldResolution"];
    DisplayInfo *display = [dialogData objectForKey:@"display"];
    NSWindow *window = [dialogData objectForKey:@"window"];
    
    [timer invalidate];
    [dialogData removeObjectForKey:@"timer"]; // release timer retained by dialogData
    NSDebugLog(@"DisplayController: User clicked Revert button");
    [self revertToResolution:oldRes forDisplay:display];
    [window close];
    [activeDialogsByID removeObjectForKey:@(dialogID)];
}

- (void)resolutionKeepClicked:(id)sender
{
    NSButton *button = (NSButton *)sender;
    NSInteger dialogID = [button tag];
    NSMutableDictionary *dialogData = [activeDialogsByID objectForKey:@(dialogID)];
    
    if (!dialogData) return;
    
    if ([[dialogData objectForKey:@"released"] boolValue]) return;
    [dialogData setObject:@YES forKey:@"released"];
    
    NSTimer *timer = [dialogData objectForKey:@"timer"];
    NSWindow *window = [dialogData objectForKey:@"window"];
    
    [timer invalidate];
    [dialogData removeObjectForKey:@"timer"]; // release timer retained by dialogData
    NSDebugLog(@"DisplayController: User clicked Keep button - keeping new resolution");
    [window close];
    [activeDialogsByID removeObjectForKey:@(dialogID)];
}

- (void)revertToResolution:(NSString *)resolution forDisplay:(DisplayInfo *)display
{
    // Atomically set mode and position via the X11 RANDR API.
    int x = (int)[display frame].origin.x;
    [x11 setMode:[display output] mode:resolution positionX:x positionY:0];
    [self refreshDisplays:nil];
    
    [resolutionPopup selectItemWithTitle:resolution];
}

- (void)applyDisplayConfiguration
{
    if ([displays count] == 0) return;
    
    NSArray *sortedDisplays = [displays sortedArrayUsingComparator:^NSComparisonResult(DisplayInfo *obj1, DisplayInfo *obj2) {
        return [@([obj1 frame].origin.x) compare:@([obj2 frame].origin.x)];
    }];
    
    // Build position map: for the first display enforce Y=0, for the rest
    // use their current frame Y (which may be 0 in a side-by-side layout).
    NSMutableDictionary *placements = [NSMutableDictionary dictionary];
    for (int i = 0; i < [sortedDisplays count]; i++) {
        DisplayInfo *display = [sortedDisplays objectAtIndex:i];
        DisplayInfo *prevDisplay = nil;
        
        NSPoint pos;
        if (i == 0) {
            pos = NSMakePoint(0, 0);
        } else {
            prevDisplay = [sortedDisplays objectAtIndex:i-1];
            pos = NSMakePoint(
                prevDisplay.frame.origin.x + prevDisplay.frame.size.width,
                [display frame].origin.y);
        }
        
        NSRect f = [display frame];
        f.origin = pos;
        [display setFrame:f];
        
        [placements setObject:[NSValue valueWithPoint:pos]
                      forKey:[display output]];
    }
    
    [x11 applyPositions:placements];
    [self refreshDisplays:nil];
}

- (void)setPrimaryDisplay:(DisplayInfo *)display
{
    NSDebugLog(@"DisplayController: Setting primary display to: %@", [display name]);
    
    for (DisplayInfo *d in displays) {
        [d setIsPrimary:(d == display)];
    }
    
    [x11 setPrimaryOutput:[display output]];
}

- (NSArray *)displays
{
    return displays;
}

- (void)selectDisplay:(DisplayInfo *)display
{
    NSDebugLog(@"DisplayController: Selecting display: %@", [display name]);
    selectedDisplay = display;
    
    // Update resolution popup for selected display
    [self updateResolutionPopup];
    
    // Update the display view to show selection - update all display rectangles
    if (displayView) {
        NSArray *allRectViews = [displayView displayRects];
        for (DisplayRectView *rectView in allRectViews) {
            BOOL shouldBeSelected = ([rectView displayInfo] == display);
            [rectView setIsSelected:shouldBeSelected];
            [rectView setNeedsDisplay:YES];
        }
    }
}

- (DisplayInfo *)selectedDisplay
{
    return selectedDisplay;
}

- (NSString *)currentStateSnapshot
{
    NSMutableString *snap = [NSMutableString string];
    NSArray *sorted = [displays sortedArrayUsingComparator:^NSComparisonResult(DisplayInfo *a, DisplayInfo *b) {
        return [[a output] compare:[b output]];
    }];
    for (DisplayInfo *d in sorted) {
        if (![d isConnected]) continue;
        NSRect f = [d frame];
        [snap appendFormat:@"%@:%@:%.0f,%.0f:%d\n",
            [d output],
            [d currentResolutionString] ? [d currentResolutionString] : @"",
            f.origin.x, f.origin.y,
            [d isPrimary]];
    }
    return snap;
}

- (void)updateSaveButtonState
{
    if (!saveButton) return;

    if (!savedStateSnapshot) {
        // No saved snapshot yet — take one now (initial state)
        savedStateSnapshot = [[self currentStateSnapshot] copy];
        [saveButton setEnabled:NO];
        return;
    }

    NSString *current = [self currentStateSnapshot];
    BOOL changed = ![current isEqualToString:savedStateSnapshot];
    [saveButton setEnabled:changed];
}

// Marker comments used to identify our managed sections in xorg.conf
static NSString *const GERSHWIN_BEGIN = @"# BEGIN Gershwin Display Settings";
static NSString *const GERSHWIN_END   = @"# END Gershwin Display Settings";

- (BOOL)hasSavedMirrorConfig
{
    NSString *xorgConfPath = @"/etc/X11/xorg.conf";
    NSString *contents = [NSString stringWithContentsOfFile:xorgConfPath
                                                  encoding:NSUTF8StringEncoding
                                                     error:NULL];
    if (!contents) return NO;

    NSRange beginRange = [contents rangeOfString:GERSHWIN_BEGIN];
    NSRange endRange   = [contents rangeOfString:GERSHWIN_END];
    if (beginRange.location == NSNotFound || endRange.location == NSNotFound)
        return NO;

    NSString *block = [contents substringWithRange:
        NSMakeRange(beginRange.location,
                    endRange.location + endRange.length - beginRange.location)];

    // Collect all Position values from the saved block
    NSMutableArray *positions = [NSMutableArray array];
    NSArray *lines = [block componentsSeparatedByString:@"\n"];
    for (NSString *line in lines) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceCharacterSet]];
        // Match: Option "Position" "X Y"
        if ([trimmed hasPrefix:@"Option"] &&
            [trimmed rangeOfString:@"\"Position\""].location != NSNotFound) {
            // Extract the value between the last pair of quotes
            NSRange lastQuote = [trimmed rangeOfString:@"\"" options:NSBackwardsSearch];
            if (lastQuote.location != NSNotFound && lastQuote.location > 0) {
                NSRange secondLastQuote = [trimmed rangeOfString:@"\""
                                                        options:NSBackwardsSearch
                                                          range:NSMakeRange(0, lastQuote.location)];
                if (secondLastQuote.location != NSNotFound) {
                    NSString *pos = [trimmed substringWithRange:
                        NSMakeRange(secondLastQuote.location + 1,
                                    lastQuote.location - secondLastQuote.location - 1)];
                    [positions addObject:pos];
                }
            }
        }
    }

    if ([positions count] < 2) return NO;

    // All positions the same means mirrored was saved
    NSString *first = [positions objectAtIndex:0];
    for (NSUInteger i = 1; i < [positions count]; i++) {
        if (![[positions objectAtIndex:i] isEqualToString:first])
            return NO;
    }
    return YES;
}

- (NSString *)generateXorgConfSections
{
    NSMutableString *conf = [NSMutableString string];
    [conf appendString:GERSHWIN_BEGIN];
    [conf appendString:@"\n"];

    for (DisplayInfo *display in displays) {
        if (![display isConnected]) continue;

        NSString *identifier = [display output];

        [conf appendFormat:@"Section \"Monitor\"\n"];
        [conf appendFormat:@"    Identifier \"%@\"\n", identifier];
        if ([display currentResolutionString]) {
            [conf appendFormat:@"    Option \"PreferredMode\" \"%@\"\n", [display currentResolutionString]];
        }
        if ([display isPrimary]) {
            [conf appendFormat:@"    Option \"Primary\" \"true\"\n"];
        }
        NSRect f = [display frame];
        [conf appendFormat:@"    Option \"Position\" \"%.0f %.0f\"\n", f.origin.x, f.origin.y];
        [conf appendString:@"EndSection\n\n"];

        [conf appendFormat:@"Section \"Screen\"\n"];
        [conf appendFormat:@"    Identifier \"Screen-%@\"\n", [display output]];
        [conf appendFormat:@"    Monitor \"%@\"\n", identifier];
        if ([display currentResolutionString]) {
            [conf appendFormat:@"    DefaultDepth 24\n"];
            [conf appendFormat:@"    SubSection \"Display\"\n"];
            [conf appendFormat:@"        Depth 24\n"];
            [conf appendFormat:@"        Modes \"%@\"\n", [display currentResolutionString]];
            [conf appendFormat:@"    EndSubSection\n"];
        }
        [conf appendString:@"EndSection\n\n"];
    }

    [conf appendString:GERSHWIN_END];
    return conf;
}

- (void)scaleFactorChanged:(id)sender
{
    double factor = [sender doubleValue];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *domain = [NSMutableDictionary dictionaryWithDictionary:[defaults persistentDomainForName:NSGlobalDomain]];
    [domain setObject:[NSNumber numberWithDouble:factor] forKey:@"GSScaleFactor"];
    [defaults setPersistentDomain:domain forName:NSGlobalDomain];
    [defaults synchronize];
    [scaleValueLabel setStringValue:[NSString stringWithFormat:@"%.2fx", factor]];
    [scaleFactorHintLabel setHidden:NO];
}

- (void)saveSettings:(id)sender
{
    if ([displays count] == 0) {
        NSRunAlertPanel(@"Save Settings",
                       @"No displays detected to save.",
                       @"OK", nil, nil);
        return;
    }

    NSString *xorgConfPath = @"/etc/X11/xorg.conf";
    NSString *newSections = [self generateXorgConfSections];
    NSString *finalContent = nil;

    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:xorgConfPath]) {
        NSString *existing = [NSString stringWithContentsOfFile:xorgConfPath
                                                      encoding:NSUTF8StringEncoding
                                                         error:NULL];
        if (existing) {
            // Strip any previous Gershwin managed block
            NSRange beginRange = [existing rangeOfString:GERSHWIN_BEGIN];
            NSRange endRange = [existing rangeOfString:GERSHWIN_END];

            if (beginRange.location != NSNotFound && endRange.location != NSNotFound) {
                NSUInteger blockEnd = endRange.location + endRange.length;
                // Also consume a trailing newline if present
                if (blockEnd < [existing length] &&
                    [existing characterAtIndex:blockEnd] == '\n') {
                    blockEnd++;
                }
                NSMutableString *stripped = [NSMutableString stringWithString:existing];
                [stripped deleteCharactersInRange:NSMakeRange(beginRange.location,
                                                              blockEnd - beginRange.location)];
                existing = stripped;
            }

            // Trim trailing whitespace from existing content, then append our block
            existing = [existing stringByTrimmingCharactersInSet:
                        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if ([existing length] > 0) {
                finalContent = [NSString stringWithFormat:@"%@\n\n%@\n", existing, newSections];
            } else {
                finalContent = [NSString stringWithFormat:@"%@\n", newSections];
            }
        } else {
            finalContent = [NSString stringWithFormat:@"%@\n", newSections];
        }
    } else {
        finalContent = [NSString stringWithFormat:@"%@\n", newSections];
    }

    // Write via a temp file and sudo mv for atomic root-owned write
    NSString *tmpPath = @"/tmp/gershwin-xorg.conf.tmp";
    NSError *error = nil;
    BOOL wrote = [finalContent writeToFile:tmpPath
                                atomically:YES
                                  encoding:NSUTF8StringEncoding
                                     error:&error];
    if (!wrote) {
        NSRunAlertPanel(@"Save Settings",
                       @"Failed to write temporary file: %@",
                       @"OK", nil, nil, [error localizedDescription]);
        return;
    }

    // Ensure /etc/X11 directory exists, then move the file into place
    NSString *cmd = [NSString stringWithFormat:
        @"sudo -A -E /bin/sh -c 'mkdir -p /etc/X11 && mv %@ %@'",
        tmpPath, xorgConfPath];

    NSTask *task = [[NSTask alloc] init];
    NSPipe *errPipe = [NSPipe pipe];
    [task setLaunchPath:@"/bin/sh"];
    [task setArguments:@[@"-c", cmd]];
    [task setStandardError:errPipe];

    @try {
        [task launch];
        NSData *errData = [[errPipe fileHandleForReading] readDataToEndOfFile];
        [task waitUntilExit];

        if ([task terminationStatus] == 0) {
            [savedStateSnapshot release];
            savedStateSnapshot = [[self currentStateSnapshot] copy];
            [saveButton setEnabled:NO];

            NSRunAlertPanel(@"Save Settings",
                           @"Display settings saved to %@.\n"
                           @"They will take effect on next X server restart.",
                           @"OK", nil, nil, xorgConfPath);
        } else {
            NSString *errStr = [[[NSString alloc] initWithData:errData
                                                      encoding:NSUTF8StringEncoding] autorelease];
            NSRunAlertPanel(@"Save Settings",
                           @"Failed to save settings: %@",
                           @"OK", nil, nil, errStr);
        }
    } @catch (NSException *exception) {
        NSRunAlertPanel(@"Save Settings",
                       @"Failed to save settings: %@",
                       @"OK", nil, nil, [exception reason]);
    }
    [task release];
}

- (void)autoConfigureDisplays
{
    NSDebugLog(@"DisplayController: Auto-configuring displays...");
    
    if ([displays count] == 0) {
        return;
    }
    
    DisplayInfo *first = [displays objectAtIndex:0];
    
    for (DisplayInfo *display in displays) {
        if (![display isConnected]) continue;
        
        NSString *modeStr = [display currentResolutionString];
        if (!modeStr) {
            // Fallback to first available mode or default
            if ([[display availableResolutions] count] > 0) {
                modeStr = [[display availableResolutions] objectAtIndex:0];
            } else {
                modeStr = [NSString stringWithFormat:@"%.0fx%.0f",
                                     [display resolution].width,
                                     [display resolution].height];
            }
        }
        
        int x = 0, y = 0;
        if (display != first) {
            x = first.frame.origin.x + first.frame.size.width;
        }
        
        NSDebugLog(@"DisplayController: Auto-configuring %@ at %@ pos %d,%d",
              [display output], modeStr, x, y);
        [x11 setMode:[display output] mode:modeStr positionX:x positionY:y];
        
        if (display == first) {
            [display setIsPrimary:YES];
            [x11 setPrimaryOutput:[display output]];
        }
    }
    
    [self refreshDisplays:nil];
}

@end
