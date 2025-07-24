#import "StartupDiskController.h"

@implementation StartupDiskController

- (id)init
{
    NSLog(@"StartupDiskController: init called");
    self = [super init];
    if (self) {
        bootEntries = [[NSMutableArray alloc] init];
        bootButtons = [[NSMutableArray alloc] init];
        selectedBootEntry = -1;
        
        // Initialize helper process variables
        helperTask = nil;
        helperInput = nil;
        helperOutput = nil;
        helperInputHandle = nil;
        helperOutputHandle = nil;
        
        NSLog(@"StartupDiskController: init completed successfully");
        NSLog(@"StartupDiskController: bootEntries = %@", bootEntries);
        NSLog(@"StartupDiskController: bootButtons = %@", bootButtons);
    } else {
        NSLog(@"StartupDiskController: init failed - super init returned nil");
    }
    return self;
}

- (void)setMainView:(NSView *)view
{
    NSLog(@"StartupDiskController: setMainView called with view = %@", view);
    if (view) {
        NSLog(@"StartupDiskController: view frame = %@", NSStringFromRect([view frame]));
        NSLog(@"StartupDiskController: view bounds = %@", NSStringFromRect([view bounds]));
        NSLog(@"StartupDiskController: view subviews count = %lu", (unsigned long)[[view subviews] count]);
    } else {
        NSLog(@"StartupDiskController: WARNING - view is nil!");
        return;
    }
    
    mainView = view;
    NSLog(@"StartupDiskController: Set mainView, about to call setupUI");
    [self setupUI];
    NSLog(@"StartupDiskController: setMainView completed");
}

- (void)setupUI
{
    NSLog(@"StartupDiskController: setupUI called");
    
    if (!mainView) {
        NSLog(@"StartupDiskController: ERROR - mainView is nil in setupUI!");
        return;
    }
    
    NSRect frame = [mainView frame];
    NSLog(@"StartupDiskController: mainView frame in setupUI = %@", NSStringFromRect(frame));
    
    // Title label
    NSLog(@"StartupDiskController: Creating title label");
    titleLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, frame.size.height - 50, frame.size.width - 40, 24)];
    [titleLabel setStringValue:@"Select the system you want to use to start up your computer"];
    [titleLabel setBezeled:NO];
    [titleLabel setDrawsBackground:NO];
    [titleLabel setEditable:NO];
    [titleLabel setSelectable:NO];
    [titleLabel setFont:[NSFont systemFontOfSize:13]];
    NSLog(@"StartupDiskController: Adding title label to mainView");
    [mainView addSubview:titleLabel];
    NSLog(@"StartupDiskController: Title label added successfully");
    
    // Scroll view for boot entries
    NSLog(@"StartupDiskController: Creating scroll view");
    scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(20, 80, frame.size.width - 40, frame.size.height - 160)];
    [scrollView setHasVerticalScroller:YES];
    [scrollView setHasHorizontalScroller:NO];
    [scrollView setBorderType:NSBezelBorder];
    [scrollView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    NSLog(@"StartupDiskController: Scroll view frame = %@", NSStringFromRect([scrollView frame]));
    
    NSLog(@"StartupDiskController: Creating content view");
    contentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, frame.size.width - 60, 200)];
    NSLog(@"StartupDiskController: Content view frame = %@", NSStringFromRect([contentView frame]));
    [scrollView setDocumentView:contentView];
    NSLog(@"StartupDiskController: Adding scroll view to mainView");
    [mainView addSubview:scrollView];
    NSLog(@"StartupDiskController: Scroll view added successfully");
    
    // Selected boot entry label
    NSLog(@"StartupDiskController: Creating selected label");
    selectedLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 50, frame.size.width - 200, 20)];
    [selectedLabel setStringValue:@""];
    [selectedLabel setBezeled:NO];
    [selectedLabel setDrawsBackground:NO];
    [selectedLabel setEditable:NO];
    [selectedLabel setSelectable:NO];
    [selectedLabel setFont:[NSFont systemFontOfSize:11]];
    NSLog(@"StartupDiskController: Adding selected label to mainView");
    [mainView addSubview:selectedLabel];
    NSLog(@"StartupDiskController: Selected label added successfully");
    
    // Restart button
    NSLog(@"StartupDiskController: Creating restart button");
    restartButton = [[NSButton alloc] initWithFrame:NSMakeRect(frame.size.width - 160, 50, 120, 32)];
    [restartButton setTitle:@"Restart..."];
    [restartButton setTarget:self];
    [restartButton setAction:@selector(restartClicked:)];
    [restartButton setAutoresizingMask:NSViewMinXMargin];
    NSLog(@"StartupDiskController: Adding restart button to mainView");
    [mainView addSubview:restartButton];
    NSLog(@"StartupDiskController: Restart button added successfully");
    
    NSLog(@"StartupDiskController: setupUI completed - mainView now has %lu subviews", (unsigned long)[[mainView subviews] count]);
}

- (void)refreshBootEntries
{
    NSLog(@"StartupDiskController: refreshBootEntries called");
    [bootEntries removeAllObjects];
    NSLog(@"StartupDiskController: Cleared bootEntries array");
    
    // Run efibootmgr in a background thread to avoid blocking the UI
    [NSThread detachNewThreadSelector:@selector(fetchBootEntriesInBackground) 
                             toTarget:self 
                           withObject:nil];
}

- (void)fetchBootEntriesInBackground
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    // Start the helper process if not already running
    if (![self startHelperProcess]) {
        NSLog(@"StartupDiskController: Failed to start helper process");
        [self performSelectorOnMainThread:@selector(handleBootEntriesResult:) 
                               withObject:[NSDictionary dictionaryWithObjectsAndKeys:
                                          [NSNumber numberWithBool:NO], @"success",
                                          @"", @"output", 
                                          @"Failed to start helper process", @"error",
                                          nil]
                            waitUntilDone:NO];
        [pool release];
        return;
    }
    
    NSLog(@"StartupDiskController: Sending list command to helper");
    NSString *response = nil;
    NSString *error = nil;
    BOOL success = [self sendHelperCommand:@"list" withResponse:&response withError:&error];
    
    // Update UI on main thread
    [self performSelectorOnMainThread:@selector(handleBootEntriesResult:) 
                           withObject:[NSDictionary dictionaryWithObjectsAndKeys:
                                      [NSNumber numberWithBool:success], @"success",
                                      response ? response : @"", @"output", 
                                      error ? error : @"", @"error",
                                      nil]
                        waitUntilDone:NO];
    
    [pool release];
}
- (void)handleBootEntriesResult:(NSDictionary *)resultDict
{
    BOOL success = [[resultDict objectForKey:@"success"] boolValue];
    NSString *output = [resultDict objectForKey:@"output"];
    NSString *errorOutput = [resultDict objectForKey:@"error"];
    if (!success) {
        NSLog(@"StartupDiskController: efibootmgr failed: %@", errorOutput);
        
        // Show error panel instead of creating fake entries
        NSString *errorMessage;
        if ([errorOutput containsString:@"must be run as root"] || [errorOutput containsString:@"Permission denied"]) {
            errorMessage = @"Administrator privileges required to access boot entries";
        } else if ([errorOutput containsString:@"No such file or directory"]) {
            errorMessage = @"EFI boot manager not available on this system";
        } else if ([errorOutput containsString:@"No BootOrder"]) {
            errorMessage = @"No EFI boot entries found";
        } else {
            errorMessage = [NSString stringWithFormat:@"Boot manager error"];
        }
        
        // Show error panel
        [self showBootErrorAlert:[NSDictionary dictionaryWithObjectsAndKeys:
                                  @"Startup Disk Error", @"title",
                                  [NSString stringWithFormat:@"%@\n\nDetailed error: %@", errorMessage, errorOutput], @"message",
                                  nil]];
        
        [self updateBootEntriesDisplay];
        return;
    } else {
        NSLog(@"StartupDiskController: efibootmgr succeeded, parsing output");
        NSLog(@"StartupDiskController: efibootmgr output length = %lu", (unsigned long)[output length]);
        
        if ([output length] > 0) {
            NSLog(@"StartupDiskController: efibootmgr stdout: %@", output);
        }
        
        // Parse efibootmgr output
        NSArray *lines = [output componentsSeparatedByString:@"\n"];
        NSLog(@"StartupDiskController: Split output into %lu lines", (unsigned long)[lines count]);
        
        int lineIndex = 0;
        for (NSString *line in lines) {
            NSLog(@"StartupDiskController: Processing line %d: %@", lineIndex++, line);
            
            // Look for lines containing "Boot" followed by 4 digits and an asterisk
            // This handles formats like "+Boot0000*" and " Boot2001*"
            NSString *trimmedLine = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            NSRange bootRange = [trimmedLine rangeOfString:@"Boot"];
            
            if (bootRange.location != NSNotFound && [trimmedLine containsString:@"*"]) {
                NSLog(@"StartupDiskController: Found boot entry line: %@", line);
                
                // Find the position of "Boot" in the trimmed line
                NSString *bootPart = [trimmedLine substringFromIndex:bootRange.location];
                NSRange asteriskRange = [bootPart rangeOfString:@"*"];
                
                if (asteriskRange.location != NSNotFound && asteriskRange.location >= 8) { // "Boot" + 4 digits = 8 chars minimum
                    // Extract boot number (4 digits after "Boot")
                    NSString *bootNum = [bootPart substringWithRange:NSMakeRange(4, 4)];
                    NSString *description = [[bootPart substringFromIndex:asteriskRange.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    
                    NSLog(@"StartupDiskController: Extracted bootNum = %@, raw description = %@", bootNum, description);
                    
                    // Clean up description to remove device path info
                    NSRange hdRange = [description rangeOfString:@" HD("];
                    if (hdRange.location != NSNotFound) {
                        description = [description substringToIndex:hdRange.location];
                    }
                    NSRange pciRange = [description rangeOfString:@" PciRoot("];
                    if (pciRange.location != NSNotFound) {
                        description = [description substringToIndex:pciRange.location];
                    }
                    
                    // Further clean up common patterns
                    if ([description hasPrefix:@"EFI "]) {
                        description = [description substringFromIndex:4]; // Remove "EFI " prefix
                    }
                    description = [description stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    
                    // Skip empty descriptions
                    if ([description length] > 0) {
                        NSLog(@"StartupDiskController: Cleaned description = %@", description);
                        
                        NSDictionary *entry = [NSDictionary dictionaryWithObjectsAndKeys:
                                             bootNum, @"bootnum",
                                             description, @"description",
                                             [NSNumber numberWithBool:YES], @"active",
                                             nil];
                        [bootEntries addObject:entry];
                        NSLog(@"StartupDiskController: Added boot entry: %@", entry);
                    } else {
                        NSLog(@"StartupDiskController: Skipping entry with empty description");
                    }
                }
            }
        }
    }
    
    NSLog(@"StartupDiskController: bootEntries now contains %lu entries", (unsigned long)[bootEntries count]);
    for (int i = 0; i < [bootEntries count]; i++) {
        NSLog(@"StartupDiskController: bootEntries[%d] = %@", i, [bootEntries objectAtIndex:i]);
    }
    
    NSLog(@"StartupDiskController: About to call updateBootEntriesDisplay");
    [self updateBootEntriesDisplay];
    NSLog(@"StartupDiskController: refreshBootEntries completed");
}

- (void)updateBootEntriesDisplay
{
    NSLog(@"StartupDiskController: updateBootEntriesDisplay called");
    NSLog(@"StartupDiskController: bootEntries count = %lu", (unsigned long)[bootEntries count]);
    NSLog(@"StartupDiskController: bootButtons count = %lu", (unsigned long)[bootButtons count]);
    
    // Clear existing buttons
    NSLog(@"StartupDiskController: Removing existing buttons from contentView");
    for (NSButton *button in bootButtons) {
        NSLog(@"StartupDiskController: Removing button: %@", button);
        [button removeFromSuperview];
    }
    [bootButtons removeAllObjects];
    NSLog(@"StartupDiskController: Cleared bootButtons array");
    
    if (!contentView) {
        NSLog(@"StartupDiskController: ERROR - contentView is nil!");
        return;
    }
    
    // Calculate content height
    CGFloat contentHeight = [bootEntries count] * 80 + 20;
    NSLog(@"StartupDiskController: Calculated contentHeight = %f", contentHeight);
    
    NSRect contentFrame = [contentView frame];
    NSLog(@"StartupDiskController: Current contentView frame = %@", NSStringFromRect(contentFrame));
    contentFrame.size.height = MAX(contentHeight, contentFrame.size.height);
    [contentView setFrame:contentFrame];
    NSLog(@"StartupDiskController: Updated contentView frame = %@", NSStringFromRect(contentFrame));
    
    // Create buttons for each boot entry
    CGFloat yPos = contentHeight - 80;
    int index = 0;
    
    NSLog(@"StartupDiskController: Creating buttons for boot entries");
    for (NSDictionary *entry in bootEntries) {
        NSString *description = [entry objectForKey:@"description"];
        
        NSLog(@"StartupDiskController: Creating button %d for entry: %@", index, description);
        
        // Create a button for this boot entry
        NSButton *button = [[NSButton alloc] initWithFrame:NSMakeRect(10, yPos, contentFrame.size.width - 20, 60)];
        [button setTitle:description];
        [button setButtonType:NSRadioButton];
        [button setTarget:self];
        [button setAction:@selector(bootEntrySelected:)];
        [button setTag:index];
        
        NSLog(@"StartupDiskController: Button %d frame = %@", index, NSStringFromRect([button frame]));
        
        // Style the button to look like the macOS Startup Disk entries
        [button setImagePosition:NSImageLeft];
        [button setAlignment:NSLeftTextAlignment];
        
        // Try to set an appropriate icon based on the description
        NSImage *icon = nil;
        if ([description containsString:@"FreeBSD"] || [description containsString:@"BSD"]) {
            icon = [NSImage imageNamed:@"NSComputer"];
        } else if ([description containsString:@"Windows"] || [description containsString:@"Microsoft"]) {
            icon = [NSImage imageNamed:@"NSComputer"];
        } else {
            icon = [NSImage imageNamed:@"NSComputer"];
        }
        
        if (icon) {
            [icon setSize:NSMakeSize(32, 32)];
            [button setImage:icon];
            NSLog(@"StartupDiskController: Set icon for button %d", index);
        } else {
            NSLog(@"StartupDiskController: No icon found for button %d", index);
        }
        
        NSLog(@"StartupDiskController: Adding button %d to contentView", index);
        [contentView addSubview:button];
        [bootButtons addObject:button];
        NSLog(@"StartupDiskController: Added button %d successfully", index);
        
        yPos -= 80;
        index++;
    }
    
    NSLog(@"StartupDiskController: Created %d buttons", index);
    NSLog(@"StartupDiskController: contentView now has %lu subviews", (unsigned long)[[contentView subviews] count]);
    
    // Update selected entry display
    if (selectedBootEntry >= 0 && selectedBootEntry < [bootEntries count]) {
        NSDictionary *entry = [bootEntries objectAtIndex:selectedBootEntry];
        NSString *description = [entry objectForKey:@"description"];
        [selectedLabel setStringValue:[NSString stringWithFormat:@"You have selected %@ as the startup disk.", description]];
        NSLog(@"StartupDiskController: Updated selectedLabel to: %@", [selectedLabel stringValue]);
        
        // Select the corresponding button
        if (selectedBootEntry < [bootButtons count]) {
            NSButton *button = [bootButtons objectAtIndex:selectedBootEntry];
            [button setState:NSOnState];
            NSLog(@"StartupDiskController: Selected button %d", selectedBootEntry);
        }
    } else {
        [selectedLabel setStringValue:@""];
        NSLog(@"StartupDiskController: Cleared selectedLabel");
    }
    
    NSLog(@"StartupDiskController: updateBootEntriesDisplay completed");
}

- (void)bootEntrySelected:(id)sender
{
    NSButton *button = (NSButton *)sender;
    selectedBootEntry = [button tag];
    NSLog(@"StartupDiskController: bootEntrySelected called - selected entry %d", selectedBootEntry);
    
    // Unselect all other buttons
    for (NSButton *otherButton in bootButtons) {
        if (otherButton != button) {
            [otherButton setState:NSOffState];
        }
    }
    
    [self updateBootEntriesDisplay];
    NSLog(@"StartupDiskController: bootEntrySelected completed");
}

- (void)showBootErrorAlert:(NSDictionary *)alertInfo
{
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:[alertInfo objectForKey:@"title"]];
    [alert setInformativeText:[alertInfo objectForKey:@"message"]];
    [alert addButtonWithTitle:@"OK"];
    [alert setAlertStyle:NSWarningAlertStyle];
    [alert runModal];
    [alert release];
}

- (void)showSystemErrorAlert:(NSDictionary *)alertInfo
{
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:[alertInfo objectForKey:@"title"]];
    [alert setInformativeText:[alertInfo objectForKey:@"message"]];
    [alert addButtonWithTitle:@"OK"];
    [alert setAlertStyle:NSCriticalAlertStyle];
    [alert runModal];
    [alert release];
}

- (void)restartClicked:(id)sender
{
    if (selectedBootEntry >= 0 && selectedBootEntry < [bootEntries count]) {
        NSDictionary *entry = [bootEntries objectAtIndex:selectedBootEntry];
        NSString *bootnum = [entry objectForKey:@"bootnum"];
        NSString *description = [entry objectForKey:@"description"];
        BOOL isActive = [[entry objectForKey:@"active"] boolValue];
        
        // Check if this is an error entry - this should not happen anymore
        if (!isActive) {
            NSAlert *alert = [[NSAlert alloc] init];
            [alert setMessageText:@"Invalid Boot Entry"];
            [alert setInformativeText:@"The selected entry is not a valid boot option.\n\nPlease select a different boot entry."];
            [alert addButtonWithTitle:@"OK"];
            [alert setAlertStyle:NSWarningAlertStyle];
            [alert runModal];
            [alert release];
            return;
        }
        
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:@"Restart Computer"];
        [alert setInformativeText:[NSString stringWithFormat:@"Are you sure you want to restart your computer now?\n\nYour computer will restart using:\n%@\n\nAny unsaved work will be lost.", description]];
        [alert addButtonWithTitle:@"Restart"];
        [alert addButtonWithTitle:@"Cancel"];
        [alert setAlertStyle:NSCriticalAlertStyle];
        
        NSInteger result = [alert runModal];
        [alert release];
        
        if (result == NSAlertFirstButtonReturn) {
            // Set the next boot entry using the helper process
            NSString *command = [NSString stringWithFormat:@"set_next_boot %@", bootnum];
            NSString *response = nil;
            NSString *errorOutput = nil;
            
            BOOL setBootSuccess = [self sendHelperCommand:command withResponse:&response withError:&errorOutput];
            
            if (setBootSuccess) {
                // Now restart the system
                NSString *restartResponse = nil;
                NSString *restartError = nil;
                
                BOOL restartSuccess = [self sendHelperCommand:@"restart" withResponse:&restartResponse withError:&restartError];
                
                if (!restartSuccess) {
                    NSLog(@"Error restarting system: %@", restartError);
                    NSAlert *errorAlert = [[NSAlert alloc] init];
                    [errorAlert setMessageText:@"Restart Failed"];
                    [errorAlert setInformativeText:[NSString stringWithFormat:@"Boot entry was set successfully, but failed to restart the system.\n\nError: %@\n\nPlease restart manually.", restartError ? restartError : @"Unknown error"]];
                    [errorAlert addButtonWithTitle:@"OK"];
                    [errorAlert setAlertStyle:NSWarningAlertStyle];
                    [errorAlert runModal];
                    [errorAlert release];
                }
            } else {
                NSAlert *errorAlert = [[NSAlert alloc] init];
                [errorAlert setMessageText:@"Failed to Set Startup Disk"];
                [errorAlert setInformativeText:[NSString stringWithFormat:@"Could not set the next boot entry.\n\nError details: %@", errorOutput ? errorOutput : @"Unknown error"]];
                [errorAlert addButtonWithTitle:@"OK"];
                [errorAlert setAlertStyle:NSCriticalAlertStyle];
                [errorAlert runModal];
                [errorAlert release];
            }
        }
    } else {
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:@"No Startup Disk Selected"];
        [alert setInformativeText:@"Please select a startup disk from the list above before clicking Restart.\n\nTo select a startup disk, click on one of the available boot entries."];
        [alert addButtonWithTitle:@"OK"];
        [alert setAlertStyle:NSInformationalAlertStyle];
        [alert runModal];
        [alert release];
    }
}

- (BOOL)startHelperProcess
{
    if (helperTask && [helperTask isRunning]) {
        NSLog(@"StartupDiskController: Helper process already running");
        return YES;
    }
    
    NSLog(@"StartupDiskController: Starting helper process with sudo");
    
    helperTask = [[NSTask alloc] init];
    [helperTask setLaunchPath:@"/usr/local/bin/sudo"];
    [helperTask setArguments:[NSArray arrayWithObjects:@"-A", @"/usr/local/libexec/efiboot-helper", nil]];
    
    // Set up pipes
    helperInput = [NSPipe pipe];
    helperOutput = [NSPipe pipe];
    
    [helperTask setStandardInput:helperInput];
    [helperTask setStandardOutput:helperOutput];
    [helperTask setStandardError:helperOutput]; // Combine stderr with stdout
    
    helperInputHandle = [helperInput fileHandleForWriting];
    helperOutputHandle = [helperOutput fileHandleForReading];
    
    // Set environment
    NSMutableDictionary *environment = [[[NSProcessInfo processInfo] environment] mutableCopy];
    [helperTask setEnvironment:environment];
    [environment release];
    
    @try {
        [helperTask launch];
        
        // Wait for the "READY" message
        NSData *readyData = [helperOutputHandle availableData];
        NSString *readyMessage = [[NSString alloc] initWithData:readyData encoding:NSUTF8StringEncoding];
        
        // Give it a moment to start up properly
        sleep(1);
        
        // Try reading the ready message again if we didn't get it
        if (![readyMessage containsString:@"READY"]) {
            readyData = [helperOutputHandle availableData];
            [readyMessage release];
            readyMessage = [[NSString alloc] initWithData:readyData encoding:NSUTF8StringEncoding];
        }
        
        NSLog(@"StartupDiskController: Helper process started, ready message: %@", readyMessage);
        [readyMessage release];
        
        return YES;
    }
    @catch (NSException *exception) {
        NSLog(@"StartupDiskController: Failed to start helper process: %@", exception);
        [self stopHelperProcess];
        return NO;
    }
}

- (void)stopHelperProcess
{
    if (helperInputHandle) {
        @try {
            NSString *quitCommand = @"quit\n";
            NSData *quitData = [quitCommand dataUsingEncoding:NSUTF8StringEncoding];
            [helperInputHandle writeData:quitData];
        }
        @catch (NSException *exception) {
            NSLog(@"StartupDiskController: Exception sending quit command: %@", exception);
        }
    }
    
    if (helperTask && [helperTask isRunning]) {
        [helperTask terminate];
        [helperTask waitUntilExit];
    }
    
    [helperTask release];
    helperTask = nil;
    helperInput = nil;
    helperOutput = nil;
    helperInputHandle = nil;
    helperOutputHandle = nil;
}

- (BOOL)sendHelperCommand:(NSString *)command withResponse:(NSString **)response withError:(NSString **)error
{
    if (!helperTask || ![helperTask isRunning]) {
        if (error) {
            *error = @"Helper process not running";
        }
        return NO;
    }
    
    NSLog(@"StartupDiskController: Sending command to helper: %@", command);
    
    @try {
        // Send command
        NSString *commandWithNewline = [command stringByAppendingString:@"\n"];
        NSData *commandData = [commandWithNewline dataUsingEncoding:NSUTF8StringEncoding];
        [helperInputHandle writeData:commandData];
        
        // Read response
        NSMutableString *responseBuffer = [NSMutableString string];
        NSMutableString *errorBuffer = [NSMutableString string];
        BOOL inOutput = NO;
        BOOL inError = NO;
        BOOL commandComplete = NO;
        int result = -1;
        
        // Set a timeout
        NSDate *timeout = [NSDate dateWithTimeIntervalSinceNow:30.0];
        
        while ([[NSDate date] compare:timeout] == NSOrderedAscending && !commandComplete) {
            NSData *data = [helperOutputHandle availableData];
            if ([data length] > 0) {
                NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                NSArray *lines = [output componentsSeparatedByString:@"\n"];
                
                for (NSString *line in lines) {
                    if ([line hasPrefix:@"RESULT:"]) {
                        result = [[line substringFromIndex:7] intValue];
                    } else if ([line isEqualToString:@"OUTPUT_START"]) {
                        inOutput = YES;
                        inError = NO;
                    } else if ([line isEqualToString:@"OUTPUT_END"]) {
                        inOutput = NO;
                    } else if ([line isEqualToString:@"ERROR_START"]) {
                        inError = YES;
                        inOutput = NO;
                    } else if ([line isEqualToString:@"ERROR_END"]) {
                        inError = NO;
                    } else if ([line isEqualToString:@"COMMAND_END"]) {
                        commandComplete = YES;
                        break;
                    } else if (inOutput && [line length] > 0) {
                        [responseBuffer appendString:line];
                        [responseBuffer appendString:@"\n"];
                    } else if (inError && [line length] > 0) {
                        [errorBuffer appendString:line];
                        [errorBuffer appendString:@"\n"];
                    }
                }
                
                [output release];
            } else {
                // Small delay to prevent busy waiting
                usleep(50000); // 50ms
            }
        }
        
        if (response) {
            *response = [NSString stringWithString:responseBuffer];
        }
        if (error) {
            *error = [NSString stringWithString:errorBuffer];
        }
        
        NSLog(@"StartupDiskController: Command completed with result: %d", result);
        return (result == 0);
    }
    @catch (NSException *exception) {
        NSLog(@"StartupDiskController: Exception sending command to helper: %@", exception);
        if (error) {
            *error = [exception reason];
        }
        return NO;
    }
}

- (BOOL)runSudoCommand:(NSArray *)arguments withOutput:(NSString **)output withError:(NSString **)error interactive:(BOOL)allowInteractive
{
    NSLog(@"StartupDiskController: runSudoCommand called with arguments: %@ (interactive: %@)", arguments, allowInteractive ? @"YES" : @"NO");
    
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"/usr/local/bin/sudo"];  // Use full path for FreeBSD
    
    // Build arguments - use -A only for interactive commands, -n for non-interactive
    NSMutableArray *finalArgs = [NSMutableArray array];
    if (allowInteractive) {
        [finalArgs addObject:@"-A"];  // Use askpass for interactive commands
    } else {
        [finalArgs addObject:@"-n"];  // Non-interactive mode for cached credentials
    }
    [finalArgs addObjectsFromArray:arguments];
    [task setArguments:finalArgs];
    
    // Set environment
    NSMutableDictionary *environment = [[[NSProcessInfo processInfo] environment] mutableCopy];
    [task setEnvironment:environment];
    [environment release];
    
    NSPipe *pipe = [NSPipe pipe];
    NSPipe *errorPipe = [NSPipe pipe];
    [task setStandardOutput:pipe];
    [task setStandardError:errorPipe];
    
    NSFileHandle *file = [pipe fileHandleForReading];
    NSFileHandle *errorFile = [errorPipe fileHandleForReading];
    
    BOOL success = NO;
    
    @try {
        NSLog(@"StartupDiskController: Launching sudo with arguments: %@", finalArgs);
        [task launch];
        [task waitUntilExit];
        
        NSData *data = [file readDataToEndOfFile];
        NSData *errorData = [errorFile readDataToEndOfFile];
        
        if (output) {
            *output = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
        }
        if (error) {
            *error = [[[NSString alloc] initWithData:errorData encoding:NSUTF8StringEncoding] autorelease];
        }
        
        int exitStatus = [task terminationStatus];
        NSLog(@"StartupDiskController: sudo command completed with exit status: %d", exitStatus);
        
        success = (exitStatus == 0);
        
        if (!success && error && *error) {
            NSLog(@"StartupDiskController: sudo command failed with error: %@", *error);
        }
    }
    @catch (NSException *exception) {
        NSLog(@"StartupDiskController: Exception running sudo command: %@", exception);
        if (error) {
            *error = [exception reason];
        }
        success = NO;
    }
    
    [task release];
    return success;
}

- (void)dealloc
{
    [self stopHelperProcess];
    [bootEntries release];
    [bootButtons release];
    [titleLabel release];
    [selectedLabel release];
    [restartButton release];
    [scrollView release];
    [contentView release];
    [super dealloc];
}

@end
