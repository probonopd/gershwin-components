/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */


#import "DisplayController.h"
#import "DisplayView.h"
#import "X11DisplayManager.h"
#import "AppearanceMetrics.h"
#import <dispatch/dispatch.h>

@class DisplayController;

/* The pane view. When the host window gives us a width (which is not the
   560px base we built at), re-lay out the group boxes so the left/right
   margins to the window edge stay symmetric. */
@interface DisplayMainView : NSView
{
    DisplayController *_layoutOwner;
}
@end

@implementation DisplayMainView
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
- (void)setLayoutOwner:(DisplayController *)owner
{
    _layoutOwner = owner;
}
@end

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

@interface DisplayController ()
/* Layout helpers (HIG group boxes and rows). */
- (NSBox *)groupBoxWithTitle:(NSString *)title frame:(NSRect)frame inView:(NSView *)parent;
- (NSTextField *)labelWithText:(NSString *)text frame:(NSRect)frame alignment:(NSTextAlignment)align;
- (void)addCheckbox:(NSButton *)checkbox toBox:(NSBox *)box y:(CGFloat)y width:(CGFloat)w;
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
    
    const CGFloat winW = 560, winH = 440;
    const CGFloat sideMargin = METRICS_CONTENT_SIDE_MARGIN;      /* 24 */
    const CGFloat topMargin = METRICS_CONTENT_TOP_MARGIN;        /* 15 */
    const CGFloat bottomMargin = METRICS_SPACE_12;               /* under bottom controls */
    const CGFloat boxGap = METRICS_SPACE_8;                      /* between group boxes */
    const CGFloat rowH = METRICS_TEXT_INPUT_FIELD_HEIGHT;        /* 22 */
    const CGFloat checkboxRowH = METRICS_RADIO_BUTTON_LINE_SPACING; /* 20 */
    const CGFloat boxTitleInset = 14.0;
    const CGFloat arrangeBoxH = 230;      /* arrangement view */
    const CGFloat settingsBoxH = 126;     /* mirror, resolution, scale */

    mainView = [[DisplayMainView alloc] initWithFrame:NSMakeRect(0, 0, winW, winH)];
    [(DisplayMainView *)mainView setLayoutOwner:self];
    [mainView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    CGFloat contentW = winW - 2 * sideMargin;
    CGFloat boxW = contentW;

    CGFloat y = winH - topMargin;

    /* ---- Arrangement view directly on the pane (single item, no box) ---- */
    {
        /* No autoresizing mask: GNUstep's +5px contentView quirk would otherwise
           make this view track the inflated size and misalign its right edge
           with the box below. relayoutWithWidth: sets its width explicitly. */
        displayView = [[DisplayView alloc] initWithFrame:
            NSMakeRect(sideMargin, y - arrangeBoxH, boxW, arrangeBoxH)];
        [displayView setController:self];
        [mainView addSubview:displayView];
    }
    y -= arrangeBoxH + boxGap;

    /* ---- Display Settings group box ---- */
    settingsBox = [self groupBoxWithTitle:@"Display Settings"
                                   frame:NSMakeRect(sideMargin, y - settingsBoxH, boxW, settingsBoxH)
                                  inView:mainView];
    {
        CGFloat by = settingsBoxH - boxTitleInset - METRICS_SPACE_16 - checkboxRowH;
        [self addCheckbox:mirrorDisplaysCheckbox =
                   [[[NSButton alloc] initWithFrame:NSZeroRect] autorelease]
                    toBox:settingsBox y:by width:boxW];
        [mirrorDisplaysCheckbox setButtonType:NSSwitchButton];
        [mirrorDisplaysCheckbox setTitle:@"Mirror Displays"];
        by -= METRICS_SPACE_8 + rowH;

        [self addPopUpRowWithLabel:@"Resolution:"
                            popup:resolutionPopup =
                            [[[NSPopUpButton alloc] initWithFrame:NSZeroRect] autorelease]
                            toBox:settingsBox y:by width:boxW];
        [resolutionPopup setTarget:self];
        [resolutionPopup setAction:@selector(resolutionChanged:)];

        by -= METRICS_SPACE_8 + rowH;
        [self addSliderRowWithLabel:@"Scale Factor:"
                             slider:scaleSlider =
                             [[[NSSlider alloc] initWithFrame:NSZeroRect] autorelease]
                              value:scaleValueLabel =
                             [[[NSTextField alloc] initWithFrame:NSZeroRect] autorelease]
                              toBox:settingsBox y:by width:boxW];
        [scaleSlider setMinValue:0.8];
        [scaleSlider setMaxValue:2.0];
        [scaleSlider setNumberOfTickMarks:13];
        [scaleSlider setAllowsTickMarkValuesOnly:YES];
        [scaleSlider setContinuous:YES];
        [scaleSlider setTarget:self];
        [scaleSlider setAction:@selector(scaleFactorChanged:)];
        [scaleValueLabel setStringValue:@"1.0x"];

        double currentScaleFactor = 1.0;
        NSDictionary *domain = [[NSUserDefaults standardUserDefaults] persistentDomainForName:NSGlobalDomain];
        NSNumber *storedFactor = [domain objectForKey:@"GSScaleFactor"];
        if (storedFactor) {
            currentScaleFactor = [storedFactor doubleValue];
            if (currentScaleFactor < 0.8) currentScaleFactor = 0.8;
            if (currentScaleFactor > 2.0) currentScaleFactor = 2.0;
        }
        currentScaleFactor = round(currentScaleFactor * 10.0) / 10.0;
        [scaleSlider setDoubleValue:currentScaleFactor];
        [scaleValueLabel setStringValue:[NSString stringWithFormat:@"%.1fx", currentScaleFactor]];
    }
    y -= settingsBoxH + boxGap;

    /* ---- Bottom hint (settings apply automatically) ---- */
    scaleFactorHintLabel = [self labelWithText:@"Changes will take effect for newly started applications"
                                         frame:NSMakeRect(sideMargin, bottomMargin,
                                                         contentW, 20)
                                      alignment:NSTextAlignmentLeft];
    [scaleFactorHintLabel setFont:[NSFont systemFontOfSize:11]];
    [scaleFactorHintLabel setTextColor:[NSColor grayColor]];
    [scaleFactorHintLabel setHidden:YES];
    [scaleFactorHintLabel setAutoresizingMask:NSViewWidthSizable | NSViewMaxYMargin];
    [mainView addSubview:scaleFactorHintLabel];

    // Do not call refreshDisplays: here — the DisplayPane's didSelect
    // will trigger it once the view is in the window hierarchy.
    // Calling it here races with didSelect and causes double async loads.

    return mainView;
}

/* Re-lay out the pane for the given width. Positions are computed
   bottom-up and explicitly (the arrangement view fills whatever vertical
   space remains), so nothing relies on autoresizing quirks. */
- (void)relayoutWithWidth:(CGFloat)width
{
    const CGFloat sideMargin = METRICS_CONTENT_SIDE_MARGIN;  /* 24 */
    const CGFloat topMargin = METRICS_CONTENT_TOP_MARGIN;    /* 15 */
    const CGFloat bottomMargin = METRICS_SPACE_12;
    const CGFloat boxGap = METRICS_SPACE_8;
    const CGFloat hintH = 20;
    const CGFloat settingsBoxH = 126;
    CGFloat height = [mainView bounds].size.height;
    NSRect f;

    if (scaleFactorHintLabel) {
        f = [scaleFactorHintLabel frame];
        f.origin.x = sideMargin;
        f.size.width = width - 2 * sideMargin;
        f.origin.y = bottomMargin;
        f.size.height = hintH;
        [scaleFactorHintLabel setFrame:f];
    }

    if (settingsBox) {
        f = [settingsBox frame];
        f.origin.x = sideMargin;
        f.size.width = width - 2 * sideMargin;
        f.origin.y = bottomMargin + hintH + boxGap;
        f.size.height = settingsBoxH;
        [settingsBox setFrame:f];
    }

    if (displayView) {
        CGFloat arrangeY = bottomMargin + hintH + boxGap + settingsBoxH + boxGap;
        CGFloat arrangeH = height - topMargin - arrangeY;
        if (arrangeH < 100) arrangeH = 100;
        f = [displayView frame];
        f.origin.x = sideMargin;
        f.size.width = width - 2 * sideMargin;
        f.origin.y = arrangeY;
        f.size.height = arrangeH;
        [displayView setFrame:f];
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
    /* Snap to one decimal place. */
    factor = round(factor * 10.0) / 10.0;
    [sender setDoubleValue:factor];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *domain = [NSMutableDictionary dictionaryWithDictionary:[defaults persistentDomainForName:NSGlobalDomain]];
    [domain setObject:[NSNumber numberWithDouble:factor] forKey:@"GSScaleFactor"];
    [defaults setPersistentDomain:domain forName:NSGlobalDomain];
    [defaults synchronize];
    [scaleValueLabel setStringValue:[NSString stringWithFormat:@"%.1fx", factor]];
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
