/*
 * Copyright (c) 2005 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "StartupDiskController.h"

// Global timer for boot order changes
NSDate *bootOrderChangedTime = nil;

// Custom cell class for displaying icons with text
@interface BootEntryCell : NSTextFieldCell
{
    NSImage *cellImage;
}
- (void)setImage:(NSImage *)image;
- (NSImage *)image;
@end

@implementation BootEntryCell

- (id)init
{
    self = [super init];
    if (self) {
        cellImage = nil;
    }
    return self;
}

- (void)setImage:(NSImage *)image
{
    if (cellImage != image) {
        [cellImage release];
        cellImage = [image retain];
    }
}

- (NSImage *)image
{
    return cellImage;
}

- (void)drawWithFrame:(NSRect)cellFrame inView:(NSView *)controlView
{
    // First draw the background for selection if needed
    if ([self isHighlighted]) {
        [[NSColor selectedControlColor] set];
        NSRectFill(cellFrame);
    }
    
    // Calculate image and text rects
    NSRect imageRect = cellFrame;
    NSRect textRect = cellFrame;
    
    if (cellImage) {
        // Leave space for the icon (16x16 with some padding)
        imageRect.size.width = 16;
        imageRect.size.height = 16;
        imageRect.origin.y += (cellFrame.size.height - 16) / 2; // Center vertically
        imageRect.origin.x += 4; // Small left margin
        
        // Adjust text rect to start after the icon
        textRect.origin.x += 24; // Icon width + padding
        textRect.size.width -= 24;
        
        // Draw the image
        [cellImage drawInRect:imageRect 
                     fromRect:NSZeroRect 
                    operation:NSCompositeSourceOver 
                     fraction:1.0
                respectFlipped:YES
                         hints:nil];
    }
    
    // Draw the text in the remaining space
    NSString *stringValue = [self stringValue];
    if (stringValue && [stringValue length] > 0) {
        NSColor *textColor = [self isHighlighted] ? [NSColor selectedControlTextColor] : [NSColor controlTextColor];
        
        NSDictionary *attributes = [NSDictionary dictionaryWithObjectsAndKeys:
                                   [self font], NSFontAttributeName,
                                   textColor, NSForegroundColorAttributeName,
                                   nil];
        
        // Center the text vertically
        NSSize textSize = [stringValue sizeWithAttributes:attributes];
        textRect.origin.y += (textRect.size.height - textSize.height) / 2;
        textRect.size.height = textSize.height;
        
        [stringValue drawInRect:textRect withAttributes:attributes];
    }
}

- (id)copyWithZone:(NSZone *)zone
{
    BootEntryCell *copy = [super copyWithZone:zone];
    copy->cellImage = [cellImage retain];
    return copy;
}

- (void)dealloc
{
    [cellImage release];
    [super dealloc];
}

@end

// Custom table view class for easier dragging
@implementation EasyDragTableView

- (void)mouseDown:(NSEvent *)theEvent
{
    NSPoint point = [self convertPoint:[theEvent locationInWindow] fromView:nil];
    NSInteger row = [self rowAtPoint:point];
    
    if (row >= 0) {
        isDragging = NO;
        dragStartPoint = point;
        
        // Select the row first
        [self selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
        
        // Start tracking mouse movement immediately
        NSEvent *nextEvent;
        while ((nextEvent = [[self window] nextEventMatchingMask:NSLeftMouseDraggedMask | NSLeftMouseUpMask])) {
            if ([nextEvent type] == NSLeftMouseUp) {
                // Mouse released without dragging
                break;
            } else if ([nextEvent type] == NSLeftMouseDragged) {
                // Start drag immediately on any movement (no threshold)
                if (!isDragging) {
                    isDragging = YES;
                    
                    // Create drag pasteboard
                    NSPasteboard *pboard = [NSPasteboard pasteboardWithName:NSDragPboard];
                    NSIndexSet *rowIndexes = [NSIndexSet indexSetWithIndex:row];
                    
                    if ([self writeRowsWithIndexes:rowIndexes toPasteboard:pboard]) {
                        NSRect dragRect = [self rectOfRow:row];
                        dragRect.origin = dragStartPoint;
                        dragRect.size.width = 16;
                        dragRect.size.height = 16;
                        
                        // Create a simple drag image
                        NSImage *dragImage = [[NSImage alloc] initWithSize:dragRect.size];
                        [dragImage lockFocus];
                        [[NSColor systemBlueColor] set];
                        NSRectFill(NSMakeRect(0, 0, dragRect.size.width, dragRect.size.height));
                        [dragImage unlockFocus];
                        
                        [self dragImage:dragImage
                                     at:dragRect.origin
                                 offset:NSZeroSize
                                  event:theEvent
                             pasteboard:pboard
                                 source:self
                              slideBack:YES];
                        
                        [dragImage release];
                        return;
                    }
                }
            }
        }
    }
    
    [super mouseDown:theEvent];
}

- (BOOL)writeRowsWithIndexes:(NSIndexSet *)rowIndexes toPasteboard:(NSPasteboard *)pboard
{
    // Delegate to the data source
    if ([[self dataSource] respondsToSelector:@selector(tableView:writeRowsWithIndexes:toPasteboard:)]) {
        return [(id)[self dataSource] tableView:self writeRowsWithIndexes:rowIndexes toPasteboard:pboard];
    }
    return NO;
}

@end

@implementation StartupDiskController

- (id)init
{
    NSLog(@"StartupDiskController: init called");
    self = [super init];
    if (self) {
        bootEntries = [[NSMutableArray alloc] init];
        bootOrderChanged = NO;
        
        // Initialize helper process variables
        helperTask = nil;
        helperInput = nil;
        helperOutput = nil;
        helperInputHandle = nil;
        helperOutputHandle = nil;
        
        NSLog(@"StartupDiskController: init completed successfully");
        NSLog(@"StartupDiskController: bootEntries = %@", bootEntries);
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
    [titleLabel setStringValue:@"Drag boot entries to arrange their priority order"];
    [titleLabel setBezeled:NO];
    [titleLabel setDrawsBackground:NO];
    [titleLabel setEditable:NO];
    [titleLabel setSelectable:NO];
    [titleLabel setFont:[NSFont systemFontOfSize:13]];
    NSLog(@"StartupDiskController: Adding title label to mainView");
    [mainView addSubview:titleLabel];
    NSLog(@"StartupDiskController: Title label added successfully");
    
    // Instruction label
    NSLog(@"StartupDiskController: Creating instruction label");
    instructionLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, frame.size.height - 75, frame.size.width - 40, 20)];
    [instructionLabel setStringValue:@"The first entry in the list will be used as the default startup disk"];
    [instructionLabel setBezeled:NO];
    [instructionLabel setDrawsBackground:NO];
    [instructionLabel setEditable:NO];
    [instructionLabel setSelectable:NO];
    [instructionLabel setFont:[NSFont systemFontOfSize:11]];
    [instructionLabel setTextColor:[NSColor secondaryLabelColor]];
    NSLog(@"StartupDiskController: Adding instruction label to mainView");
    [mainView addSubview:instructionLabel];
    NSLog(@"StartupDiskController: Instruction label added successfully");
    
    // Scroll view and table view for boot entries
    NSLog(@"StartupDiskController: Creating scroll view and table view");
    scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(20, 100, frame.size.width - 40, frame.size.height - 200)];
    [scrollView setHasVerticalScroller:YES];
    [scrollView setHasHorizontalScroller:NO];
    [scrollView setBorderType:NSBezelBorder];
    [scrollView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    NSLog(@"StartupDiskController: Scroll view frame = %@", NSStringFromRect([scrollView frame]));
    
    NSRect tableFrame = NSMakeRect(0, 0, frame.size.width - 60, 200);
    tableView = [[EasyDragTableView alloc] initWithFrame:tableFrame];
    [tableView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [tableView setDataSource:self];
    [tableView setDelegate:self];
    [tableView setRowHeight:22];
    [tableView setIntercellSpacing:NSMakeSize(0, 1)];
    [tableView setSelectionHighlightStyle:NSTableViewSelectionHighlightStyleRegular];
    
    // Enable drag and drop
    [tableView registerForDraggedTypes:[NSArray arrayWithObject:@"BootEntryType"]];
    [tableView setDraggingSourceOperationMask:NSDragOperationMove forLocal:YES];
    
    // Add a single column
    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"BootEntry"];
    [column setTitle:@"Boot Entries"];
    [column setWidth:tableFrame.size.width - 20];
    [column setResizingMask:NSTableColumnAutoresizingMask];
    
    // Set up a custom data cell that supports both image and text
    BootEntryCell *dataCell = [[BootEntryCell alloc] init];
    [column setDataCell:dataCell];
    [dataCell release];
    
    [tableView addTableColumn:column];
    [column release];
    
    [scrollView setDocumentView:tableView];
    NSLog(@"StartupDiskController: Adding scroll view to mainView");
    [mainView addSubview:scrollView];
    NSLog(@"StartupDiskController: Scroll view added successfully");
    
    // Restart button
    NSLog(@"StartupDiskController: Creating restart button");
    restartButton = [[NSButton alloc] initWithFrame:NSMakeRect(frame.size.width - 160, 60, 120, 32)];
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
    
    // Don't refresh if the user has made changes that haven't been applied yet
    // But add a safety mechanism - if bootOrderChanged has been true for too long, reset it
    static NSDate *localBootOrderChangedTime = nil;
    if (bootOrderChanged) {
        if (!localBootOrderChangedTime) {
            localBootOrderChangedTime = [[NSDate date] retain];
        }
        
        // If it's been more than 10 seconds since the flag was set, reset it
        if ([[NSDate date] timeIntervalSinceDate:localBootOrderChangedTime] > 10.0) {
            NSLog(@"StartupDiskController: bootOrderChanged flag stuck for >10 seconds, resetting");
            bootOrderChanged = NO;
            [localBootOrderChangedTime release];
            localBootOrderChangedTime = nil;
        } else {
            NSLog(@"StartupDiskController: Skipping refresh because boot order has changed");
            return;
        }
    } else {
        // Reset the timer when bootOrderChanged becomes NO
        if (localBootOrderChangedTime) {
            [localBootOrderChangedTime release];
            localBootOrderChangedTime = nil;
        }
    }
    
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
    // Safely extract values with null checks
    if (!resultDict) {
        NSLog(@"StartupDiskController: handleBootEntriesResult called with nil resultDict");
        [self updateBootEntriesDisplay];
        return;
    }
    
    NSNumber *successNum = [resultDict objectForKey:@"success"];
    BOOL success = successNum ? [successNum boolValue] : NO;
    NSString *output = [resultDict objectForKey:@"output"];
    NSString *errorOutput = [resultDict objectForKey:@"error"];
    
    // Ensure we have valid strings
    if (!output) output = @"";
    if (!errorOutput) errorOutput = @"";
    
    NSLog(@"StartupDiskController: handleBootEntriesResult - success: %@, output length: %lu, error length: %lu", 
          success ? @"YES" : @"NO", 
          (unsigned long)[output length],
          (unsigned long)[errorOutput length]);
    
    if (!success) {
        // Stop the timer if the helper is not running
        if (bootOrderChangedTime) {
            [bootOrderChangedTime release];
            bootOrderChangedTime = nil;
        }
        NSLog(@"StartupDiskController: efibootmgr failed: %@", errorOutput);
        
        // Show error panel instead of creating fake entries
        NSString *errorMessage;
        NSString *detailedError = errorOutput;
        
        // If no specific error was captured, provide a generic message
        if (!detailedError || [detailedError length] == 0) {
            detailedError = @"Command failed with no error output (exit code 1)";
        }
        
        if ([detailedError containsString:@"must be run as root"] || [detailedError containsString:@"Permission denied"]) {
            errorMessage = @"Administrator privileges required to access boot entries";
        } else if ([detailedError containsString:@"No such file or directory"]) {
            errorMessage = @"EFI boot manager not available on this system";
        } else if ([detailedError containsString:@"No BootOrder"] || [detailedError containsString:@"No such variable"]) {
            errorMessage = @"No EFI boot entries found on this system";
        } else if ([detailedError containsString:@"exit code 1"]) {
            errorMessage = @"EFI boot manager is not supported or not available on this system";
        } else {
            errorMessage = @"Boot manager error occurred";
        }
        
        // Show error panel
        [self showBootErrorAlert:[NSDictionary dictionaryWithObjectsAndKeys:
                                  @"Startup Disk Error", @"title",
                                  [NSString stringWithFormat:@"%@\n\nDetailed error: %@", errorMessage, detailedError], @"message",
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
    
    if (!tableView) {
        NSLog(@"StartupDiskController: ERROR - tableView is nil!");
        return;
    }
    
    // Reload the table data
    [tableView reloadData];
    
    // Update the instruction label based on whether we have entries
    if ([bootEntries count] > 0) {
        NSDictionary *firstEntry = [bootEntries objectAtIndex:0];
        NSString *description = [firstEntry objectForKey:@"description"];
        [instructionLabel setStringValue:[NSString stringWithFormat:@"Default startup disk: %@", description]];
    } else {
        [instructionLabel setStringValue:@"No boot entries found"];
    }
    
    NSLog(@"StartupDiskController: updateBootEntriesDisplay completed");
}

- (void)applyBootOrder:(id)sender
{
    NSLog(@"StartupDiskController: applyBootOrder called");
    
    if ([bootEntries count] == 0) {
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:@"No Boot Entries"];
        [alert setInformativeText:@"There are no boot entries to configure."];
        [alert addButtonWithTitle:@"OK"];
        [alert setAlertStyle:NSInformationalAlertStyle];
        [alert runModal];
        [alert release];
        return;
    }
    
    // Build the new boot order from the current bootEntries array
    NSMutableArray *bootOrder = [NSMutableArray array];
    for (NSDictionary *entry in bootEntries) {
        NSString *bootnum = [entry objectForKey:@"bootnum"];
        if (bootnum) {
            [bootOrder addObject:bootnum];
        }
    }
    
    if ([bootOrder count] == 0) {
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:@"Invalid Boot Entries"];
        [alert setInformativeText:@"No valid boot numbers found in the boot entries."];
        [alert addButtonWithTitle:@"OK"];
        [alert setAlertStyle:NSWarningAlertStyle];
        [alert runModal];
        [alert release];
        return;
    }
    
    // Create the boot order command
    NSString *bootOrderString = [bootOrder componentsJoinedByString:@","];
    NSString *command = [NSString stringWithFormat:@"set_boot_order %@", bootOrderString];
    
    NSLog(@"StartupDiskController: Setting boot order: %@", bootOrderString);
    
    // Run in background thread
    [NSThread detachNewThreadSelector:@selector(applyBootOrderInBackground:) 
                             toTarget:self 
                           withObject:command];
}

- (void)applyBootOrderInBackground:(NSString *)command
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    // Start the helper process if not already running
    if (![self startHelperProcess]) {
        NSLog(@"StartupDiskController: Failed to start helper process for boot order");
        [self performSelectorOnMainThread:@selector(handleApplyBootOrderResult:) 
                               withObject:[NSDictionary dictionaryWithObjectsAndKeys:
                                          [NSNumber numberWithBool:NO], @"success",
                                          @"Failed to start helper process", @"error",
                                          nil]
                            waitUntilDone:NO];
        [pool release];
        return;
    }
    
    NSLog(@"StartupDiskController: Sending boot order command to helper: %@", command);
    NSString *response = nil;
    NSString *error = nil;
    BOOL success = [self sendHelperCommand:command withResponse:&response withError:&error];
    
    // Update UI on main thread
    [self performSelectorOnMainThread:@selector(handleApplyBootOrderResult:) 
                           withObject:[NSDictionary dictionaryWithObjectsAndKeys:
                                      [NSNumber numberWithBool:success], @"success",
                                      response ? response : @"", @"output", 
                                      error ? error : @"", @"error",
                                      nil]
                        waitUntilDone:NO];
    
    [pool release];
}

- (void)handleApplyBootOrderResult:(NSDictionary *)resultDict
{
    BOOL success = [[resultDict objectForKey:@"success"] boolValue];
    NSString *errorOutput = [resultDict objectForKey:@"error"];
    
    if (success) {
        NSLog(@"StartupDiskController: Boot order applied successfully");
        bootOrderChanged = NO;
        
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:@"Boot Order Applied"];
        [alert setInformativeText:@"The boot priority order has been successfully updated."];
        [alert addButtonWithTitle:@"OK"];
        [alert setAlertStyle:NSInformationalAlertStyle];
        [alert runModal];
        [alert release];
    } else {
        NSLog(@"StartupDiskController: Failed to apply boot order: %@", errorOutput);
        
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:@"Failed to Apply Boot Order"];
        [alert setInformativeText:[NSString stringWithFormat:@"Could not update the boot priority order.\n\nError: %@", errorOutput ? errorOutput : @"Unknown error"]];
        [alert addButtonWithTitle:@"OK"];
        [alert setAlertStyle:NSCriticalAlertStyle];
        [alert runModal];
        [alert release];
    }
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
    NSInteger selectedRow = [tableView selectedRow];
    
    // If no row is selected, use the first entry (highest priority)
    if (selectedRow < 0 && [bootEntries count] > 0) {
        selectedRow = 0;
    }
    
    if (selectedRow >= 0 && selectedRow < [bootEntries count]) {
        NSDictionary *entry = [bootEntries objectAtIndex:selectedRow];
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
        
        NSString *priorityInfo = @"";
        if (selectedRow == 0) {
            priorityInfo = @" (highest priority)";
        } else {
            priorityInfo = [NSString stringWithFormat:@" (priority %ld)", (long)(selectedRow + 1)];
        }
        
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:@"Restart Computer"];
        [alert setInformativeText:[NSString stringWithFormat:@"Are you sure you want to restart your computer now?\n\nYour computer will restart using:\n%@%@\n\nAny unsaved work will be lost.", description, priorityInfo]];
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
        [alert setMessageText:@"No Boot Entries Available"];
        [alert setInformativeText:@"No boot entries are available to restart with.\n\nPlease refresh the boot entries or check your system configuration."];
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
    
    // Get the helper path from our bundle
    NSBundle *bundle = [NSBundle bundleForClass:[self class]];
    NSLog(@"StartupDiskController: Bundle path = %@", [bundle bundlePath]);
    NSLog(@"StartupDiskController: Bundle resources path = %@", [bundle resourcePath]);
    
    NSString *helperPath = [bundle pathForResource:@"efiboot-helper" ofType:nil];
    
    if (!helperPath) {
        NSLog(@"StartupDiskController: Could not find efiboot-helper in bundle resources");
        // Also try looking in the bundle's main directory
        NSString *bundlePath = [bundle bundlePath];
        helperPath = [bundlePath stringByAppendingPathComponent:@"efiboot-helper"];
        
        // Check if it exists at that location
        if (![[NSFileManager defaultManager] fileExistsAtPath:helperPath]) {
            // Try Resources subdirectory
            helperPath = [[bundle resourcePath] stringByAppendingPathComponent:@"efiboot-helper"];
            if (![[NSFileManager defaultManager] fileExistsAtPath:helperPath]) {
                NSLog(@"StartupDiskController: Could not find efiboot-helper at any location");
                NSLog(@"StartupDiskController: Tried locations:");
                NSLog(@"  - %@", [bundle pathForResource:@"efiboot-helper" ofType:nil]);
                NSLog(@"  - %@", [bundlePath stringByAppendingPathComponent:@"efiboot-helper"]);
                NSLog(@"  - %@", [[bundle resourcePath] stringByAppendingPathComponent:@"efiboot-helper"]);
                return NO;
            }
        }
        NSLog(@"StartupDiskController: Found efiboot-helper at %@", helperPath);
    } else {
        NSLog(@"StartupDiskController: Found efiboot-helper in bundle resources at %@", helperPath);
    }
    
    helperTask = [[NSTask alloc] init];
    [helperTask setLaunchPath:@"/usr/local/bin/sudo"];
    
    // Pass our process ID to the helper for security
    NSString *parentPID = [NSString stringWithFormat:@"%d", getpid()];
    [helperTask setArguments:[NSArray arrayWithObjects:@"-A", helperPath, parentPID, nil]];
    
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
    
    // Check SUDO_ASKPASS environment variable
    NSString *sudoAskPass = [[[NSProcessInfo processInfo] environment] objectForKey:@"SUDO_ASKPASS"];
    BOOL askpassValid = NO;
    if (sudoAskPass && [sudoAskPass length] > 0) {
        askpassValid = [[NSFileManager defaultManager] isExecutableFileAtPath:sudoAskPass];
    }
    if (!askpassValid) {
        NSLog(@"StartupDiskController: SUDO_ASKPASS is not set or does not point to an executable: %@", sudoAskPass);
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:@"SUDO_ASKPASS Not Set or Invalid"];
        [alert setInformativeText:@"The SUDO_ASKPASS environment variable must be set and point to an existing executable binary.\n\nPlease set SUDO_ASKPASS to a valid askpass helper and try again."];
        [alert addButtonWithTitle:@"OK"];
        [alert setAlertStyle:NSCriticalAlertStyle];
        [alert runModal];
        [alert release];
        return NO;
    }
    
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
                    NSLog(@"StartupDiskController: Helper output line: %@", line);
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
        
        // Check if we timed out
        if (!commandComplete) {
            NSLog(@"StartupDiskController: Command timed out after 30 seconds");
            if (error) {
                *error = @"Command timed out after 30 seconds";
            }
            return NO;
        }
        
        if (response) {
            *response = [NSString stringWithString:responseBuffer];
        }
        if (error) {
            *error = [NSString stringWithString:errorBuffer];
        }
        
        NSLog(@"StartupDiskController: Command completed with result: %d", result);
        NSLog(@"StartupDiskController: Response buffer length: %lu", (unsigned long)[responseBuffer length]);
        NSLog(@"StartupDiskController: Error buffer length: %lu", (unsigned long)[errorBuffer length]);
        if ([errorBuffer length] > 0) {
            NSLog(@"StartupDiskController: Error buffer content: %@", errorBuffer);
        }
        
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

// MARK: - NSTableView Data Source and Delegate Methods

- (NSInteger)numberOfRowsInTableView:(NSTableView *)aTableView
{
    if (bootEntries == nil) {
        NSLog(@"StartupDiskController: numberOfRowsInTableView called with nil bootEntries");
        return 0;
    }
    return [bootEntries count];
}

- (id)tableView:(NSTableView *)aTableView objectValueForTableColumn:(NSTableColumn *)aTableColumn row:(NSInteger)rowIndex
{
    if (rowIndex >= 0 && rowIndex < [bootEntries count] && bootEntries != nil) {
        NSDictionary *entry = [bootEntries objectAtIndex:rowIndex];
        if (entry != nil) {
            NSString *description = [entry objectForKey:@"description"];
            if (description != nil) {
                // Add priority indicator
                NSString *priorityText = [NSString stringWithFormat:@"%ld. %@", (long)(rowIndex + 1), description];
                return priorityText;
            }
        }
    }
    return @"";
}

- (NSImage *)iconForBootEntry:(NSDictionary *)entry
{
    if (entry == nil) {
        NSLog(@"StartupDiskController: iconForBootEntry called with nil entry");
        return [NSImage imageNamed:@"NSFolder"];
    }
    
    NSString *description = [entry objectForKey:@"description"];
    if (description == nil) {
        description = @"";
    }
    
    NSImage *icon = nil;
    
    // Try to determine icon based on description
    if ([description rangeOfString:@"Windows" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        icon = [NSImage imageNamed:@"NSApplicationIcon"];
    } else if ([description rangeOfString:@"UEFI" options:NSCaseInsensitiveSearch].location != NSNotFound ||
               [description rangeOfString:@"EFI" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        icon = [NSImage imageNamed:@"NSAdvanced"];
    } else {
        // Default icon for other boot entries
        icon = [NSImage imageNamed:@"NSComputer"];
    }
    
    // If no icon found, use a generic folder icon
    if (!icon) {
        icon = [NSImage imageNamed:@"NSFolder"];
    }
    
    return icon;
}

- (void)tableView:(NSTableView *)aTableView willDisplayCell:(id)aCell forTableColumn:(NSTableColumn *)aTableColumn row:(NSInteger)rowIndex
{
    NSLog(@"StartupDiskController: willDisplayCell called for row %ld, cell class: %@", (long)rowIndex, [aCell class]);
    
    if (bootEntries == nil || rowIndex < 0 || rowIndex >= [bootEntries count]) {
        NSLog(@"StartupDiskController: Invalid row index or nil bootEntries in willDisplayCell");
        return;
    }
    
    NSDictionary *entry = [bootEntries objectAtIndex:rowIndex];
    if (entry == nil) {
        NSLog(@"StartupDiskController: Nil entry at row %ld", (long)rowIndex);
        return;
    }
    
    NSImage *icon = [self iconForBootEntry:entry];
    
    NSLog(@"StartupDiskController: Setting icon for entry: %@, icon: %@", [entry objectForKey:@"description"], icon);
    
    if ([aCell isKindOfClass:[BootEntryCell class]]) {
        BootEntryCell *bootCell = (BootEntryCell *)aCell;
        [bootCell setImage:icon];
        NSLog(@"StartupDiskController: Icon set on BootEntryCell successfully");
    } else {
        NSLog(@"StartupDiskController: WARNING - Cell is not BootEntryCell, it's %@", [aCell class]);
    }
}

// Remove the dataCellForTableColumn method as we're using willDisplayCell instead

// MARK: - Drag and Drop Support

- (BOOL)tableView:(NSTableView *)tv writeRowsWithIndexes:(NSIndexSet *)rowIndexes toPasteboard:(NSPasteboard *)pboard
{
    NSLog(@"StartupDiskController: Starting drag operation for rows: %@", rowIndexes);
    
    // Copy the row index to the pasteboard
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:rowIndexes];
    [pboard declareTypes:[NSArray arrayWithObject:@"BootEntryType"] owner:self];
    [pboard setData:data forType:@"BootEntryType"];
    
    return YES;
}

- (NSDragOperation)tableView:(NSTableView *)tv validateDrop:(id <NSDraggingInfo>)info proposedRow:(NSInteger)row proposedDropOperation:(NSTableViewDropOperation)op
{
    // Only allow drops between rows, not on rows
    if (op == NSTableViewDropAbove) {
        return NSDragOperationMove;
    }
    
    return NSDragOperationNone;
}

- (BOOL)tableView:(NSTableView *)tv acceptDrop:(id <NSDraggingInfo>)info row:(NSInteger)row dropOperation:(NSTableViewDropOperation)op
{
    NSLog(@"StartupDiskController: Accepting drop at row %ld", (long)row);
    
    NSPasteboard *pboard = [info draggingPasteboard];
    NSData *rowData = [pboard dataForType:@"BootEntryType"];
    NSIndexSet *rowIndexes = [NSKeyedUnarchiver unarchiveObjectWithData:rowData];
    
    NSInteger dragRow = [rowIndexes firstIndex];
    
    // Don't allow dropping on the same position
    if (dragRow == row || dragRow == row - 1) {
        return NO;
    }
    
    // Get the entry being moved
    NSDictionary *movingEntry = [[bootEntries objectAtIndex:dragRow] retain];
    
    // Remove from old position
    [bootEntries removeObjectAtIndex:dragRow];
    
    // Adjust insertion index if necessary
    NSInteger insertIndex = row;
    if (dragRow < row) {
        insertIndex--;
    }
    
    // Insert at new position
    [bootEntries insertObject:movingEntry atIndex:insertIndex];
    [movingEntry release];
    
    // Mark that the boot order has changed
    bootOrderChanged = YES;
    
    // Apply the boot order immediately and synchronously
    [self applyBootOrderSynchronously];
    
    // Reload the table
    [tableView reloadData];
    
    // Update the instruction label
    if ([bootEntries count] > 0) {
        NSDictionary *firstEntry = [bootEntries objectAtIndex:0];
        NSString *description = [firstEntry objectForKey:@"description"];
        [instructionLabel setStringValue:[NSString stringWithFormat:@"Default startup disk: %@", description]];
    }
    
    NSLog(@"StartupDiskController: Boot order changed and applied automatically");
    
    return YES;
}

- (void)applyBootOrderSynchronously
{
    NSLog(@"StartupDiskController: applyBootOrderSynchronously called");
    
    if ([bootEntries count] == 0) {
        NSLog(@"StartupDiskController: No boot entries to apply");
        bootOrderChanged = NO;
        return;
    }
    
    // Build the new boot order from the current bootEntries array
    NSMutableArray *bootOrder = [NSMutableArray array];
    for (NSDictionary *entry in bootEntries) {
        NSString *bootnum = [entry objectForKey:@"bootnum"];
        if (bootnum) {
            [bootOrder addObject:bootnum];
        }
    }
    
    if ([bootOrder count] == 0) {
        NSLog(@"StartupDiskController: No valid boot numbers found");
        bootOrderChanged = NO;
        return;
    }
    
    // Create the boot order command
    NSString *bootOrderString = [bootOrder componentsJoinedByString:@","];
    NSString *command = [NSString stringWithFormat:@"set_boot_order %@", bootOrderString];
    
    NSLog(@"StartupDiskController: Setting boot order synchronously: %@", bootOrderString);
    
    // Start the helper process if not already running
    if (![self startHelperProcess]) {
        NSLog(@"StartupDiskController: Failed to start helper process for boot order");
        bootOrderChanged = NO;
        
        // Show error alert on main thread
        [self performSelectorOnMainThread:@selector(showBootOrderErrorAlert:)
                               withObject:@"Failed to start helper process for applying boot order"
                            waitUntilDone:NO];
        return;
    }
    
    // Send command synchronously
    NSString *response = nil;
    NSString *error = nil;
    BOOL success = [self sendHelperCommand:command withResponse:&response withError:&error];
    
    if (success) {
        NSLog(@"StartupDiskController: Boot order applied successfully and synchronously");
        bootOrderChanged = NO;  // Reset flag to allow refreshes
    } else {
        NSLog(@"StartupDiskController: Failed to apply boot order synchronously: %@", error);
        bootOrderChanged = NO;  // Reset flag even on failure to prevent permanent blocking
        
        // Show error alert on main thread
        NSString *errorMessage = error ? error : @"Unknown error occurred while applying boot order";
        [self performSelectorOnMainThread:@selector(showBootOrderErrorAlert:)
                               withObject:errorMessage
                            waitUntilDone:NO];
    }
}

- (void)showBootOrderErrorAlert:(NSString *)errorMessage
{
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:@"Failed to Apply Boot Order"];
    [alert setInformativeText:[NSString stringWithFormat:@"Could not update the boot priority order.\n\nError: %@", errorMessage]];
    [alert addButtonWithTitle:@"OK"];
    [alert setAlertStyle:NSCriticalAlertStyle];
    [alert runModal];
    [alert release];
}

- (void)dealloc
{
    [self stopHelperProcess];
    [bootEntries release];
    [titleLabel release];
    [instructionLabel release];
    [restartButton release];
    [scrollView release];
    [tableView release];
    [super dealloc];
}

@end
