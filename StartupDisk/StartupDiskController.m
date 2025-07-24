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
    
    // Use efibootmgr to get boot entries
    NSLog(@"StartupDiskController: Creating NSTask for efibootmgr");
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"/usr/local/bin/sudo"];
    [task setArguments:[NSArray arrayWithObjects:@"-A", @"/usr/sbin/efibootmgr", @"-v", nil]];
    NSLog(@"StartupDiskController: Task launch path = %@", [task launchPath]);
    NSLog(@"StartupDiskController: Task arguments = %@", [task arguments]);
    
    NSPipe *pipe = [NSPipe pipe];
    NSPipe *errorPipe = [NSPipe pipe];
    [task setStandardOutput:pipe];
    [task setStandardError:errorPipe];
    
    NSFileHandle *file = [pipe fileHandleForReading];
    NSFileHandle *errorFile = [errorPipe fileHandleForReading];
    
    @try {
        NSLog(@"StartupDiskController: Launching efibootmgr task");
        [task launch];
        NSLog(@"StartupDiskController: Task launched, waiting for completion");
        [task waitUntilExit];
        NSLog(@"StartupDiskController: Task completed with status = %d", [task terminationStatus]);
        
        NSData *data = [file readDataToEndOfFile];
        NSData *errorData = [errorFile readDataToEndOfFile];
        NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        NSString *errorOutput = [[NSString alloc] initWithData:errorData encoding:NSUTF8StringEncoding];
        
        NSLog(@"StartupDiskController: efibootmgr output length = %lu", (unsigned long)[output length]);
        NSLog(@"StartupDiskController: efibootmgr error output length = %lu", (unsigned long)[errorOutput length]);
        
        if ([output length] > 0) {
            NSLog(@"StartupDiskController: efibootmgr stdout: %@", output);
        }
        if ([errorOutput length] > 0) {
            NSLog(@"StartupDiskController: efibootmgr stderr: %@", errorOutput);
        }
        
        if ([task terminationStatus] != 0) {
            NSLog(@"StartupDiskController: efibootmgr failed with status %d: %@", [task terminationStatus], errorOutput);
            
            // Create a user-friendly error entry and show alert
            NSString *errorMessage;
            if ([errorOutput containsString:@"must be run as root"] || [errorOutput containsString:@"Permission denied"]) {
                errorMessage = @"Administrator privileges required to access boot entries";
            } else if ([errorOutput containsString:@"No such file or directory"]) {
                errorMessage = @"EFI boot manager not available on this system";
            } else if ([task terminationStatus] == 1) {
                errorMessage = @"No EFI boot entries found";
            } else {
                errorMessage = [NSString stringWithFormat:@"Boot manager error (exit code %d)", [task terminationStatus]];
            }
            
            NSDictionary *errorEntry = [NSDictionary dictionaryWithObjectsAndKeys:
                                      @"0000", @"bootnum",
                                      errorMessage, @"description",
                                      [NSNumber numberWithBool:NO], @"active",
                                      nil];
            [bootEntries addObject:errorEntry];
            NSLog(@"StartupDiskController: Added error entry to bootEntries");
            
            // Show error alert on main thread using performSelectorOnMainThread
            [self performSelectorOnMainThread:@selector(showBootErrorAlert:) 
                                   withObject:[NSDictionary dictionaryWithObjectsAndKeys:
                                              @"Startup Disk Error", @"title",
                                              [NSString stringWithFormat:@"%@\n\nDetailed error: %@", errorMessage, errorOutput], @"message",
                                              nil]
                                waitUntilDone:NO];
        } else {
            NSLog(@"StartupDiskController: efibootmgr succeeded, parsing output");
            // Parse efibootmgr output
            NSArray *lines = [output componentsSeparatedByString:@"\n"];
            NSLog(@"StartupDiskController: Split output into %lu lines", (unsigned long)[lines count]);
            
            int lineIndex = 0;
            for (NSString *line in lines) {
                NSLog(@"StartupDiskController: Processing line %d: %@", lineIndex++, line);
                if ([line hasPrefix:@"Boot"] && [line containsString:@"*"]) {
                    NSLog(@"StartupDiskController: Found boot entry line: %@", line);
                    // Parse boot entry line format: Boot0001* FreeBSD HD(1,GPT,...)
                    NSRange asteriskRange = [line rangeOfString:@"*"];
                    if (asteriskRange.location != NSNotFound) {
                        NSString *bootNum = [line substringWithRange:NSMakeRange(4, 4)]; // Extract boot number
                        NSString *description = [[line substringFromIndex:asteriskRange.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                        
                        NSLog(@"StartupDiskController: Extracted bootNum = %@, raw description = %@", bootNum, description);
                        
                        // Clean up description to remove device path info
                        NSRange hdRange = [description rangeOfString:@" HD("];
                        if (hdRange.location != NSNotFound) {
                            description = [description substringToIndex:hdRange.location];
                        }
                        
                        NSLog(@"StartupDiskController: Cleaned description = %@", description);
                        
                        NSDictionary *entry = [NSDictionary dictionaryWithObjectsAndKeys:
                                             bootNum, @"bootnum",
                                             description, @"description",
                                             [NSNumber numberWithBool:YES], @"active",
                                             nil];
                        [bootEntries addObject:entry];
                        NSLog(@"StartupDiskController: Added boot entry: %@", entry);
                    }
                }
            }
        }
        
        [output release];
        [errorOutput release];
    }
    @catch (NSException *exception) {
        NSLog(@"StartupDiskController: Exception running efibootmgr: %@", exception);
        NSLog(@"StartupDiskController: Exception reason: %@", [exception reason]);
        NSLog(@"StartupDiskController: Exception userInfo: %@", [exception userInfo]);
        
        // Determine error type and create user-friendly message
        NSString *errorMessage;
        NSString *reason = [exception reason];
        if ([reason containsString:@"invalid launch path"]) {
            errorMessage = @"System tools not found. Please check your installation.";
        } else if ([reason containsString:@"Operation not permitted"]) {
            errorMessage = @"Permission denied. Administrator privileges required.";
        } else {
            errorMessage = [NSString stringWithFormat:@"System error: %@", reason];
        }
        
        // Add an error entry
        NSDictionary *errorEntry = [NSDictionary dictionaryWithObjectsAndKeys:
                                  @"0000", @"bootnum",
                                  errorMessage, @"description",
                                  [NSNumber numberWithBool:NO], @"active",
                                  nil];
        [bootEntries addObject:errorEntry];
        
        // Show error alert on main thread using performSelectorOnMainThread
        [self performSelectorOnMainThread:@selector(showSystemErrorAlert:) 
                               withObject:[NSDictionary dictionaryWithObjectsAndKeys:
                                          @"Startup Disk System Error", @"title",
                                          [NSString stringWithFormat:@"%@\n\nTechnical details: %@", errorMessage, reason], @"message",
                                          nil]
                            waitUntilDone:NO];
    }
    
    [task release];
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
        
        // Check if this is an error entry
        if (!isActive || [bootnum isEqualToString:@"0000"]) {
            NSAlert *alert = [[NSAlert alloc] init];
            [alert setMessageText:@"Invalid Boot Entry"];
            [alert setInformativeText:@"The selected entry is an error message, not a valid boot option.\n\nPlease resolve any system issues and try again, or select a different boot entry."];
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
            // Set the next boot entry and restart
            NSTask *task = [[NSTask alloc] init];
            [task setLaunchPath:@"/usr/local/bin/sudo"];
            [task setArguments:[NSArray arrayWithObjects:@"-A", @"/usr/sbin/efibootmgr", @"-n", @"-b", bootnum, nil]];
            
            @try {
                [task launch];
                [task waitUntilExit];
                
                if ([task terminationStatus] == 0) {
                    // Now restart the system
                    NSTask *restartTask = [[NSTask alloc] init];
                    [restartTask setLaunchPath:@"/usr/local/bin/sudo"];
                    [restartTask setArguments:[NSArray arrayWithObjects:@"-A", @"/sbin/shutdown", @"-r", @"now", nil]];
                    
                    @try {
                        [restartTask launch];
                        [restartTask release];
                    }
                    @catch (NSException *restartException) {
                        NSLog(@"Error restarting system: %@", restartException);
                        NSAlert *errorAlert = [[NSAlert alloc] init];
                        [errorAlert setMessageText:@"Restart Failed"];
                        [errorAlert setInformativeText:[NSString stringWithFormat:@"Boot entry was set successfully, but failed to restart the system.\n\nError: %@\n\nPlease restart manually.", [restartException reason]]];
                        [errorAlert addButtonWithTitle:@"OK"];
                        [errorAlert setAlertStyle:NSWarningAlertStyle];
                        [errorAlert runModal];
                        [errorAlert release];
                        [restartTask release];
                    }
                } else {
                    // Get error output from the failed efibootmgr command
                    NSPipe *errorPipe = [NSPipe pipe];
                    [task setStandardError:errorPipe];
                    NSData *errorData = [[errorPipe fileHandleForReading] readDataToEndOfFile];
                    NSString *errorOutput = [[NSString alloc] initWithData:errorData encoding:NSUTF8StringEncoding];
                    
                    NSAlert *errorAlert = [[NSAlert alloc] init];
                    [errorAlert setMessageText:@"Failed to Set Startup Disk"];
                    [errorAlert setInformativeText:[NSString stringWithFormat:@"Could not set the next boot entry.\n\nError details: %@\n\nExit code: %d", errorOutput ? errorOutput : @"Unknown error", [task terminationStatus]]];
                    [errorAlert addButtonWithTitle:@"OK"];
                    [errorAlert setAlertStyle:NSCriticalAlertStyle];
                    [errorAlert runModal];
                    [errorAlert release];
                    
                    [errorOutput release];
                }
            }
            @catch (NSException *exception) {
                NSLog(@"Error setting boot entry: %@", exception);
                
                NSAlert *errorAlert = [[NSAlert alloc] init];
                [errorAlert setMessageText:@"System Error"];
                [errorAlert setInformativeText:[NSString stringWithFormat:@"Failed to execute boot manager command.\n\nError: %@\n\nPlease ensure you have administrator privileges and try again.", [exception reason]]];
                [errorAlert addButtonWithTitle:@"OK"];
                [errorAlert setAlertStyle:NSCriticalAlertStyle];
                [errorAlert runModal];
                [errorAlert release];
            }
            
            [task release];
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

- (void)dealloc
{
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
