#import "DisplayController.h"
#import "DisplayView.h"

@implementation DisplayInfo

@synthesize name, frame, resolution, isPrimary, isConnected, output;

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
    }
    return self;
}

- (void)dealloc
{
    [name release];
    [output release];
    [super dealloc];
}

@end

@implementation DisplayController

- (id)init
{
    self = [super init];
    if (self) {
        displays = [[NSMutableArray alloc] init];
        selectedDisplay = nil;
        xrandrPath = [[self findXrandrPath] retain];
        
        NSLog(@"DisplayController: Initializing with xrandr path: %@", xrandrPath);
        
        if (!xrandrPath) {
            NSLog(@"DisplayController: ERROR - xrandr not found in PATH");
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
    [mirrorDisplaysCheckbox release];
    [xrandrPath release];
    [super dealloc];
}

- (NSView *)createMainView
{
    if (mainView) {
        return mainView;
    }
    
    // Check if xrandr is available before creating the view
    if (![self isXrandrAvailable]) {
        NSLog(@"DisplayController: Cannot create main view - xrandr not available");
        
        // Create a simple error view
        mainView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 500, 320)];
        
        NSTextField *errorLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 140, 460, 40)];
        [errorLabel setStringValue:@"Display configuration is not available.\nThe xrandr tool is required but was not found."];
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
    
    NSLog(@"DisplayController: Creating main view with xrandr available");
    
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
            NSLog(@"DisplayController: Found SystemPreferences window, using size: %.0fx%.0f", availableWidth, availableHeight);
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
    mirrorDisplaysCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(20, 65, 200, 20)];
    [mirrorDisplaysCheckbox setButtonType:NSSwitchButton];
    [mirrorDisplaysCheckbox setTitle:@"Mirror Displays"];
    [mirrorDisplaysCheckbox setTarget:self];
    [mirrorDisplaysCheckbox setAction:@selector(mirrorDisplaysChanged:)];
    [mainView addSubview:mirrorDisplaysCheckbox];
    
    // Resolution popup
    NSTextField *resLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 35, 80, 20)];
    [resLabel setStringValue:@"Resolution:"];
    [resLabel setBezeled:NO];
    [resLabel setDrawsBackground:NO];
    [resLabel setEditable:NO];
    [resLabel setSelectable:NO];
    [mainView addSubview:resLabel];
    [resLabel release];
    
    resolutionPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(110, 32, 180, 25)];
    [resolutionPopup setTarget:self];
    [resolutionPopup setAction:@selector(resolutionChanged:)];
    [mainView addSubview:resolutionPopup];
    
    // Load initial display data only if we haven't already
    if ([displays count] == 0) {
        NSLog(@"DisplayController: Loading initial display data");
        [self refreshDisplays:nil];
    } else {
        NSLog(@"DisplayController: Displays already loaded, skipping initial refresh");
    }
    
    return mainView;
}

- (void)refreshDisplays:(NSTimer *)timer
{
    if (![self isXrandrAvailable]) {
        NSLog(@"DisplayController: Cannot refresh displays - xrandr not available");
        return;
    }
    
    NSLog(@"DisplayController: Refreshing displays using xrandr at: %@", xrandrPath);
    
    // Store the currently selected display to preserve selection
    DisplayInfo *previouslySelected = selectedDisplay;
    NSString *previouslySelectedOutput = nil;
    if (previouslySelected) {
        previouslySelectedOutput = [[previouslySelected output] retain];
        NSLog(@"DisplayController: Preserving selection for display: %@", previouslySelectedOutput);
    }
    
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:xrandrPath];
    [task setArguments:@[@"--query"]];
    
    NSPipe *pipe = [NSPipe pipe];
    [task setStandardOutput:pipe];
    
    NSFileHandle *file = [pipe fileHandleForReading];
    
    [task launch];
    [task waitUntilExit];
    
    NSData *data = [file readDataToEndOfFile];
    NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    
    [self parseXrandrOutput:output];
    
    [output release];
    [task release];
    
    // Restore the previously selected display if it still exists
    if (previouslySelectedOutput) {
        selectedDisplay = nil; // Reset first
        for (DisplayInfo *display in displays) {
            if ([[display output] isEqualToString:previouslySelectedOutput]) {
                selectedDisplay = display;
                NSLog(@"DisplayController: Restored selection for display: %@", [display name]);
                break;
            }
        }
        [previouslySelectedOutput release];
    }
    
    // Update the display view
    if (displayView) {
        [displayView setNeedsDisplay:YES];
    }
    
    // Update resolution popup
    [self updateResolutionPopup];
}

- (void)parseXrandrOutput:(NSString *)output
{
    [displays removeAllObjects];
    
    NSArray *lines = [output componentsSeparatedByString:@"\n"];
    DisplayInfo *currentDisplay = nil;
    
    NSLog(@"DisplayController: Parsing xrandr output...");
    
    for (NSString *line in lines) {
        NSString *trimmedLine = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        
        // Check for output line (display name)
        if ([trimmedLine rangeOfString:@" connected"].location != NSNotFound ||
            [trimmedLine rangeOfString:@" disconnected"].location != NSNotFound) {
            
            NSArray *parts = [trimmedLine componentsSeparatedByString:@" "];
            if ([parts count] >= 2) {
                currentDisplay = [[DisplayInfo alloc] init];
                [currentDisplay setOutput:[parts objectAtIndex:0]];
                [currentDisplay setName:[parts objectAtIndex:0]];
                [currentDisplay setIsConnected:[trimmedLine rangeOfString:@" connected"].location != NSNotFound];
                
                NSLog(@"Found display: %@ (connected: %d)", [currentDisplay name], [currentDisplay isConnected]);
                
                // Parse geometry if present
                if ([currentDisplay isConnected] && [parts count] >= 3) {
                    NSString *geomString = [parts objectAtIndex:2];
                    if ([geomString rangeOfString:@"x"].location != NSNotFound && 
                        [geomString rangeOfString:@"+"].location != NSNotFound) {
                        
                        // Parse resolution and position (e.g., "1920x1080+0+0")
                        NSArray *geomParts = [geomString componentsSeparatedByString:@"+"];
                        if ([geomParts count] >= 3) {
                            NSString *resPart = [geomParts objectAtIndex:0];
                            NSArray *resComponents = [resPart componentsSeparatedByString:@"x"];
                            if ([resComponents count] == 2) {
                                float width = [[resComponents objectAtIndex:0] floatValue];
                                float height = [[resComponents objectAtIndex:1] floatValue];
                                [currentDisplay setResolution:NSMakeSize(width, height)];
                                
                                float x = [[geomParts objectAtIndex:1] floatValue];
                                float y = [[geomParts objectAtIndex:2] floatValue];
                                [currentDisplay setFrame:NSMakeRect(x, y, width, height)];
                                
                                NSLog(@"Display %@ resolution: %.0fx%.0f at %.0f,%.0f", 
                                     [currentDisplay name], width, height, x, y);
                            }
                        }
                        
                        // Check if this is the primary display
                        [currentDisplay setIsPrimary:[trimmedLine rangeOfString:@" primary"].location != NSNotFound];
                        if ([currentDisplay isPrimary]) {
                            NSLog(@"Display %@ is primary", [currentDisplay name]);
                        }
                    } else {
                        // Display is connected but not configured - give it default values
                        NSLog(@"Display %@ is connected but not configured, using defaults", [currentDisplay name]);
                        [currentDisplay setResolution:NSMakeSize(1920, 1080)]; // Default resolution
                        [currentDisplay setFrame:NSMakeRect(0, 0, 1920, 1080)]; // Default position
                        [currentDisplay setIsPrimary:YES]; // Make it primary if it's the only one
                    }
                } else if ([currentDisplay isConnected]) {
                    // Display is connected but no geometry info at all - use defaults
                    NSLog(@"Display %@ is connected but has no geometry info, using defaults", [currentDisplay name]);
                    [currentDisplay setResolution:NSMakeSize(1920, 1080)]; // Default resolution
                    [currentDisplay setFrame:NSMakeRect(0, 0, 1920, 1080)]; // Default position
                    [currentDisplay setIsPrimary:YES]; // Make it primary if it's the only one
                }
                
                if ([currentDisplay isConnected]) {
                    [displays addObject:currentDisplay];
                    NSLog(@"Added display %@ to list", [currentDisplay name]);
                }
                [currentDisplay release];
                currentDisplay = nil;
            }
        }
    }
    
    NSLog(@"DisplayController: Found %lu connected displays", (unsigned long)[displays count]);
    
    // If we have displays but none seem to be properly configured, try to auto-configure them
    BOOL hasConfiguredDisplay = NO;
    for (DisplayInfo *display in displays) {
        if ([display frame].size.width > 0 && [display frame].size.height > 0) {
            hasConfiguredDisplay = YES;
            break;
        }
    }
    
    if ([displays count] > 0 && !hasConfiguredDisplay) {
        NSLog(@"DisplayController: No displays are properly configured, attempting auto-configuration");
        [self autoConfigureDisplays];
    }
}

- (void)updateResolutionPopup
{
    [resolutionPopup removeAllItems];
    
    // Get the selected display to show its available resolutions
    DisplayInfo *targetDisplay = selectedDisplay;
    
    // If no display is selected, default to primary display
    if (!targetDisplay) {
        for (DisplayInfo *display in displays) {
            if ([display isPrimary]) {
                targetDisplay = display;
                selectedDisplay = display; // Set as selected
                NSLog(@"DisplayController: Auto-selecting primary display: %@", [display name]);
                break;
            }
        }
    }
    
    // If still no display, use first available and make it primary
    if (!targetDisplay && [displays count] > 0) {
        targetDisplay = [displays objectAtIndex:0];
        selectedDisplay = targetDisplay;
        [targetDisplay setIsPrimary:YES]; // Make first display primary if none is set
        NSLog(@"DisplayController: Auto-selecting first display as primary: %@", [targetDisplay name]);
    }
    
    if (targetDisplay) {
        NSLog(@"DisplayController: Updating resolution popup for display: %@", [targetDisplay name]);
        NSArray *availableResolutions = [self getAvailableResolutionsForDisplay:targetDisplay];
        for (NSString *res in availableResolutions) {
            [resolutionPopup addItemWithTitle:res];
        }
        
        // Select current resolution
        NSString *currentRes = [NSString stringWithFormat:@"%.0fx%.0f", 
                               [targetDisplay resolution].width, 
                               [targetDisplay resolution].height];
        [resolutionPopup selectItemWithTitle:currentRes];
        NSLog(@"DisplayController: Set resolution popup to current resolution: %@", currentRes);
    }
}

- (NSArray *)getAvailableResolutionsForDisplay:(DisplayInfo *)display
{
    if (!display || ![self isXrandrAvailable]) {
        NSLog(@"DisplayController: Cannot get resolutions - display:%@ xrandr available:%d", display, [self isXrandrAvailable]);
        return @[];
    }
    
    NSLog(@"DisplayController: Getting available resolutions for display: %@", [display name]);
    
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:xrandrPath];
    [task setArguments:@[@"--query"]];
    
    NSPipe *pipe = [NSPipe pipe];
    [task setStandardOutput:pipe];
    
    NSFileHandle *file = [pipe fileHandleForReading];
    
    [task launch];
    [task waitUntilExit];
    
    NSData *data = [file readDataToEndOfFile];
    NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    
    NSMutableArray *resolutions = [NSMutableArray array];
    NSArray *lines = [output componentsSeparatedByString:@"\n"];
    BOOL foundDisplay = NO;
    
    for (NSString *line in lines) {
        NSString *trimmedLine = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        
        // Check if this is our display
        if ([trimmedLine hasPrefix:[display output]]) {
            foundDisplay = YES;
            NSLog(@"DisplayController: Found display section for %@", [display output]);
            continue;
        }
        
        // If we found our display, parse resolution lines until we hit another display
        if (foundDisplay) {
            // Stop if we hit another display line
            if ([trimmedLine rangeOfString:@" connected"].location != NSNotFound ||
                [trimmedLine rangeOfString:@" disconnected"].location != NSNotFound) {
                NSLog(@"DisplayController: End of display section reached");
                break;
            }
            
            // Parse resolution line (e.g., "   1920x1080     60.00*+  50.00    59.94")
            if ([trimmedLine rangeOfString:@"x"].location != NSNotFound) {
                NSArray *parts = [trimmedLine componentsSeparatedByString:@" "];
                // Filter out empty strings
                NSMutableArray *filteredParts = [NSMutableArray array];
                for (NSString *part in parts) {
                    NSString *trimmedPart = [part stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    if ([trimmedPart length] > 0) {
                        [filteredParts addObject:trimmedPart];
                    }
                }
                
                if ([filteredParts count] > 0) {
                    NSString *resPart = [filteredParts objectAtIndex:0];
                    if ([resPart rangeOfString:@"x"].location != NSNotFound) {
                        [resolutions addObject:resPart];
                        NSLog(@"DisplayController: Found resolution: %@", resPart);
                    }
                }
            }
        }
    }
    
    [output release];
    [task release];
    
    NSLog(@"DisplayController: Found %lu resolutions for display %@", (unsigned long)[resolutions count], [display name]);
    return resolutions;
}

- (void)mirrorDisplaysChanged:(id)sender
{
    // Implementation for mirror displays
    BOOL mirror = [mirrorDisplaysCheckbox state] == NSOnState;
    
    NSLog(@"DisplayController: Mirror displays changed to: %@", mirror ? @"ON" : @"OFF");
    
    if (mirror && [displays count] > 1) {
        // Enable mirroring
        NSMutableArray *args = [NSMutableArray array];
        DisplayInfo *primary = nil;
        
        // Find primary display
        for (DisplayInfo *display in displays) {
            if ([display isPrimary]) {
                primary = display;
                break;
            }
        }
        
        if (!primary && [displays count] > 0) {
            primary = [displays objectAtIndex:0];
        }
        
        if (primary) {
            NSLog(@"DisplayController: Enabling mirroring with primary display: %@", [primary name]);
            
            [args addObject:@"--output"];
            [args addObject:[primary output]];
            [args addObject:@"--auto"];
            [args addObject:@"--primary"];
            
            for (DisplayInfo *display in displays) {
                if (display != primary) {
                    [args addObject:@"--output"];
                    [args addObject:[display output]];
                    [args addObject:@"--same-as"];
                    [args addObject:[primary output]];
                    NSLog(@"DisplayController: Mirroring %@ to %@", [display name], [primary name]);
                }
            }
            
            [self runXrandrWithArgs:args];
        }
    } else {
        // Disable mirroring - arrange displays side by side
        NSLog(@"DisplayController: Disabling mirroring, arranging displays side by side");
        [self applyDisplayConfiguration];
    }
}

- (void)resolutionChanged:(id)sender
{
    NSString *selectedResolution = [resolutionPopup titleOfSelectedItem];
    
    // Apply resolution to selected display
    DisplayInfo *targetDisplay = selectedDisplay;
    if (!targetDisplay) {
        NSLog(@"DisplayController: No display selected for resolution change");
        return;
    }
    
    if (targetDisplay && selectedResolution) {
        // Store the current resolution for potential revert
        NSString *currentRes = [NSString stringWithFormat:@"%.0fx%.0f", 
                               [targetDisplay resolution].width, 
                               [targetDisplay resolution].height];
        
        if ([selectedResolution isEqualToString:currentRes]) {
            NSLog(@"DisplayController: Selected resolution same as current, no change needed");
            return; // No change needed
        }
        
        NSLog(@"DisplayController: Changing resolution for %@ from %@ to %@", [targetDisplay name], currentRes, selectedResolution);
        
        // Apply the new resolution
        NSArray *args = @[@"--output", [targetDisplay output], @"--mode", selectedResolution];
        [self runXrandrWithArgs:args];
        
        // Show confirmation dialog with auto-revert timer
        [self showResolutionConfirmationDialogWithOldResolution:currentRes 
                                                 newResolution:selectedResolution 
                                                       display:targetDisplay];
    }
}

- (void)showResolutionConfirmationDialogWithOldResolution:(NSString *)oldRes 
                                           newResolution:(NSString *)newRes 
                                                 display:(DisplayInfo *)display
{
    NSLog(@"DisplayController: Showing resolution confirmation dialog - old:%@ new:%@", oldRes, newRes);
    
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
    
    [revertButton setTarget:self];
    [revertButton setAction:@selector(resolutionRevertClicked:)];
    [revertButton setTag:(NSInteger)dialogData];
    
    [keepButton setTarget:self];
    [keepButton setAction:@selector(resolutionKeepClicked:)];
    [keepButton setTag:(NSInteger)dialogData];
    
    // Create countdown timer - Use NSRunLoop mainRunLoop to ensure it works
    NSTimer *countdownTimer = [NSTimer timerWithTimeInterval:1.0
                                                      target:self
                                                    selector:@selector(resolutionCountdownTimer:)
                                                    userInfo:dialogData
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
    
    NSLog(@"Auto-reverting resolution to %@", oldRes);
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
    NSMutableDictionary *dialogData = [timer userInfo];
    NSNumber *countdownNum = [dialogData objectForKey:@"countdown"];
    NSTextField *countdownLabel = [dialogData objectForKey:@"countdownLabel"];
    
    int countdown = [countdownNum intValue] - 1;
    [dialogData setObject:[NSNumber numberWithInt:countdown] forKey:@"countdown"];
    
    [countdownLabel setStringValue:[NSString stringWithFormat:@"%d", countdown]];
    
    if (countdown <= 0) {
        // Time's up - revert
        [timer invalidate];
        NSString *oldRes = [dialogData objectForKey:@"oldResolution"];
        DisplayInfo *display = [dialogData objectForKey:@"display"];
        NSWindow *window = [dialogData objectForKey:@"window"];
        
        NSLog(@"DisplayController: Countdown reached 0, auto-reverting resolution");
        [self revertToResolution:oldRes forDisplay:display];
        [window close];
        [dialogData release];
    }
}

- (void)resolutionRevertClicked:(id)sender
{
    NSButton *button = (NSButton *)sender;
    NSMutableDictionary *dialogData = (NSMutableDictionary *)[button tag];
    
    NSTimer *timer = [dialogData objectForKey:@"timer"];
    NSString *oldRes = [dialogData objectForKey:@"oldResolution"];
    DisplayInfo *display = [dialogData objectForKey:@"display"];
    NSWindow *window = [dialogData objectForKey:@"window"];
    
    [timer invalidate];
    NSLog(@"DisplayController: User clicked Revert button");
    [self revertToResolution:oldRes forDisplay:display];
    [window close];
    [dialogData release];
}

- (void)resolutionKeepClicked:(id)sender
{
    NSButton *button = (NSButton *)sender;
    NSMutableDictionary *dialogData = (NSMutableDictionary *)[button tag];
    
    NSTimer *timer = [dialogData objectForKey:@"timer"];
    NSWindow *window = [dialogData objectForKey:@"window"];
    
    [timer invalidate];
    NSLog(@"DisplayController: User clicked Keep button - keeping new resolution");
    [window close];
    [dialogData release];
}

- (void)revertToResolution:(NSString *)resolution forDisplay:(DisplayInfo *)display
{
    NSArray *args = @[@"--output", [display output], @"--mode", resolution];
    [self runXrandrWithArgs:args];
    
    // Update the popup to reflect the reverted resolution
    [resolutionPopup selectItemWithTitle:resolution];
}


- (void)runXrandrWithArgs:(NSArray *)args
{
    if (![self isXrandrAvailable]) {
        NSLog(@"DisplayController: Cannot run xrandr - not available");
        return;
    }
    
    NSLog(@"DisplayController: Running xrandr with args: %@", args);
    
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:xrandrPath];
    [task setArguments:args];
    
    [task launch];
    [task waitUntilExit];
    
    int exitStatus = [task terminationStatus];
    NSLog(@"DisplayController: xrandr command completed with exit status: %d", exitStatus);
    
    [task release];
    
    // Refresh displays after change
    [self performSelector:@selector(refreshDisplays:) withObject:nil afterDelay:0.5];
}

- (void)applyDisplayConfiguration
{
    if ([displays count] == 0) return;
    
    NSMutableArray *args = [NSMutableArray array];
    
    // Sort displays by X position for left-to-right arrangement
    NSArray *sortedDisplays = [displays sortedArrayUsingComparator:^NSComparisonResult(DisplayInfo *obj1, DisplayInfo *obj2) {
        return [@([obj1 frame].origin.x) compare:@([obj2 frame].origin.x)];
    }];
    
    for (int i = 0; i < [sortedDisplays count]; i++) {
        DisplayInfo *display = [sortedDisplays objectAtIndex:i];
        
        [args addObject:@"--output"];
        [args addObject:[display output]];
        [args addObject:@"--auto"];
        
        if ([display isPrimary]) {
            [args addObject:@"--primary"];
        }
        
        if (i == 0) {
            [args addObject:@"--pos"];
            [args addObject:[NSString stringWithFormat:@"%.0fx%.0f", [display frame].origin.x, [display frame].origin.y]];
        } else {
            DisplayInfo *prevDisplay = [sortedDisplays objectAtIndex:i-1];
            [args addObject:@"--right-of"];
            [args addObject:[prevDisplay output]];
        }
    }
    
    [self runXrandrWithArgs:args];
}

- (void)setPrimaryDisplay:(DisplayInfo *)display
{
    NSLog(@"DisplayController: Setting primary display to: %@", [display name]);
    
    // Update the isPrimary flag
    for (DisplayInfo *d in displays) {
        [d setIsPrimary:(d == display)];
    }
    
    // Apply the change via xrandr
    NSArray *args = @[@"--output", [display output], @"--primary"];
    [self runXrandrWithArgs:args];
}

- (NSString *)findXrandrPath
{
    NSLog(@"DisplayController: Looking for xrandr in PATH");
    
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"/usr/bin/which"];
    [task setArguments:@[@"xrandr"]];
    
    NSPipe *pipe = [NSPipe pipe];
    [task setStandardOutput:pipe];
    [task setStandardError:pipe];
    
    NSFileHandle *file = [pipe fileHandleForReading];
    
    [task launch];
    [task waitUntilExit];
    
    int exitStatus = [task terminationStatus];
    NSData *data = [file readDataToEndOfFile];
    NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    
    [task release];
    
    if (exitStatus == 0 && output && [output length] > 0) {
        NSString *path = [output stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]];
        NSLog(@"DisplayController: Found xrandr at: %@", path);
        [output release];
        return path;
    } else {
        NSLog(@"DisplayController: xrandr not found in PATH (exit status: %d)", exitStatus);
        [output release];
        return nil;
    }
}

- (BOOL)isXrandrAvailable
{
    return xrandrPath != nil;
}

- (NSArray *)displays
{
    return displays;
}

- (void)selectDisplay:(DisplayInfo *)display
{
    NSLog(@"DisplayController: Selecting display: %@", [display name]);
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

- (void)autoConfigureDisplays
{
    NSLog(@"DisplayController: Auto-configuring displays...");
    
    if ([displays count] == 0) {
        NSLog(@"DisplayController: No displays to configure");
        return;
    }
    
    // Try to auto-configure each connected display
    NSMutableArray *args = [NSMutableArray array];
    
    for (DisplayInfo *display in displays) {
        if ([display isConnected]) {
            NSLog(@"DisplayController: Auto-configuring display: %@", [display name]);
            [args addObject:@"--output"];
            [args addObject:[display output]];
            [args addObject:@"--auto"];
            
            // Make the first display primary
            if (display == [displays objectAtIndex:0]) {
                [args addObject:@"--primary"];
                [display setIsPrimary:YES];
                NSLog(@"DisplayController: Setting %@ as primary display", [display name]);
            }
        }
    }
    
    if ([args count] > 0) {
        NSLog(@"DisplayController: Running auto-configuration with args: %@", args);
        [self runXrandrWithArgs:args];
        
        // Note: runXrandrWithArgs already calls refreshDisplays with a delay
        // so we don't need to call it again here
    } else {
        NSLog(@"DisplayController: No auto-configuration needed");
    }
}

@end
