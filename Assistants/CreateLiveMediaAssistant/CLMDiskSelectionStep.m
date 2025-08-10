//
// CLMDiskSelectionStep.m
// Create Live Media Assistant - Disk Selection Step
//

#import "CLMDiskSelectionStep.h"
#import "CLMController.h"
#import <GSDiskUtilities.h>

@implementation CLMDiskSelectionStep

@synthesize controller = _controller;

- (id)init
{
    if (self = [super init]) {
        NSLog(@"CLMDiskSelectionStep: init");
        _availableDisks = [[NSMutableArray alloc] init];
        [self setupView];
    }
    return self;
}

- (void)dealloc
{
    NSLog(@"CLMDiskSelectionStep: dealloc");
    [self stopRefreshTimer];
    [_stepView release];
    [_availableDisks release];
    [_diskArrayController release];
    [super dealloc];
}

- (void)setupView
{
    NSLog(@"CLMDiskSelectionStep: setupView");
    
    // Fit step view to installer card inner area
    _stepView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 354, 204)];
    
    // Info label
    _infoLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(8, 176, 338, 28)];
    [_infoLabel setStringValue:@"Select the destination disk for the Live medium."];
    [_infoLabel setBezeled:NO];
    [_infoLabel setDrawsBackground:NO];
    [_infoLabel setEditable:NO];
    [_infoLabel setSelectable:NO];
    [_infoLabel setFont:[NSFont systemFontOfSize:11]];
    [[_infoLabel cell] setWraps:YES];
    [_stepView addSubview:_infoLabel];
    [_infoLabel release];
    
    // Disk table (compact)
    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(8, 56, 338, 116)];
    [scrollView setHasVerticalScroller:YES];
    [scrollView setHasHorizontalScroller:NO];
    [scrollView setBorderType:NSBezelBorder];
    
    _diskTableView = [[NSTableView alloc] init];
    [_diskTableView setAllowsMultipleSelection:NO];
    [_diskTableView setAllowsEmptySelection:YES];
    
    // Add columns
    NSTableColumn *deviceColumn = [[NSTableColumn alloc] initWithIdentifier:@"deviceName"];
    [[deviceColumn headerCell] setStringValue:@"Device"];
    [deviceColumn setWidth:80];
    [_diskTableView addTableColumn:deviceColumn];
    [deviceColumn release];
    
    NSTableColumn *descColumn = [[NSTableColumn alloc] initWithIdentifier:@"description"];
    [[descColumn headerCell] setStringValue:@"Description"];
    [descColumn setWidth:180];
    [_diskTableView addTableColumn:descColumn];
    [descColumn release];
    
    NSTableColumn *sizeColumn = [[NSTableColumn alloc] initWithIdentifier:@"sizeFormatted"];
    [[sizeColumn headerCell] setStringValue:@"Size"];
    [sizeColumn setWidth:70];
    [_diskTableView addTableColumn:sizeColumn];
    [sizeColumn release];
    
    [scrollView setDocumentView:_diskTableView];
    [_stepView addSubview:scrollView];
    [scrollView release];
    
    // Array controller for table data
    _diskArrayController = [[NSArrayController alloc] init];
    [_diskArrayController setContent:_availableDisks];
    
    [deviceColumn bind:@"value" toObject:_diskArrayController withKeyPath:@"arrangedObjects.deviceName" options:nil];
    [descColumn bind:@"value" toObject:_diskArrayController withKeyPath:@"arrangedObjects.description" options:nil];
    [sizeColumn bind:@"value" toObject:_diskArrayController withKeyPath:@"arrangedObjects.sizeFormatted" options:nil];
    
    [_diskTableView bind:@"selectionIndexes" toObject:_diskArrayController withKeyPath:@"selectionIndexes" options:nil];
    
    // Selection change notification
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(tableSelectionChanged:)
                                                 name:NSTableViewSelectionDidChangeNotification
                                               object:_diskTableView];
    
    // Warning label (compact)
    _warningLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(8, 8, 338, 40)];
    [_warningLabel setStringValue:@"WARNING: All data on the selected disk will be permanently erased!\nOnly removable drives are shown for safety."];
    [_warningLabel setBezeled:NO];
    [_warningLabel setDrawsBackground:NO];
    [_warningLabel setEditable:NO];
    [_warningLabel setSelectable:NO];
    [_warningLabel setFont:[NSFont boldSystemFontOfSize:10]];
    [_warningLabel setTextColor:[NSColor redColor]];
    [[_warningLabel cell] setWraps:YES];
    [_stepView addSubview:_warningLabel];
    [_warningLabel release];
}

- (void)startRefreshTimer
{
    NSLog(@"CLMDiskSelectionStep: startRefreshTimer");
    [self refreshDiskList];
    
    _refreshTimer = [NSTimer scheduledTimerWithTimeInterval:3.0
                                                     target:self
                                                   selector:@selector(refreshDiskList)
                                                   userInfo:nil
                                                    repeats:YES];
    [_refreshTimer retain];
}

- (void)stopRefreshTimer
{
    NSLog(@"CLMDiskSelectionStep: stopRefreshTimer - timer=%@", _refreshTimer);
    if (_refreshTimer) {
        NSLog(@"CLMDiskSelectionStep: Invalidating and releasing refresh timer");
        [_refreshTimer invalidate];
        [_refreshTimer release];
        _refreshTimer = nil;
        NSLog(@"CLMDiskSelectionStep: Refresh timer stopped successfully");
    } else {
        NSLog(@"CLMDiskSelectionStep: No refresh timer to stop");
    }
}

- (void)refreshDiskList
{
    NSLog(@"CLMDiskSelectionStep: refreshDiskList");
    
    NSArray *newDisks = [GSDiskUtilities getAvailableDisks];
    NSMutableArray *filteredDisks = [NSMutableArray array];
    
    long long requiredSize = _controller.selectedImageSize;
    
    for (GSDisk *disk in newDisks) {
        // Only show removable drives and drives large enough
        if (disk.isRemovable && disk.size >= requiredSize) {
            // Add formatted size for display
            NSMutableDictionary *diskInfo = [NSMutableDictionary dictionary];
            [diskInfo setObject:disk.deviceName forKey:@"deviceName"];
            [diskInfo setObject:disk.description forKey:@"description"];
            [diskInfo setObject:[NSNumber numberWithLongLong:disk.size] forKey:@"size"];
            [diskInfo setObject:[GSDiskUtilities formatSize:disk.size] forKey:@"sizeFormatted"];
            [diskInfo setObject:disk.geomName forKey:@"geomName"];
            [diskInfo setObject:[NSNumber numberWithBool:disk.isRemovable] forKey:@"isRemovable"];
            [diskInfo setObject:[NSNumber numberWithBool:disk.isWritable] forKey:@"isWritable"];
            
            [filteredDisks addObject:diskInfo];
        }
    }
    
    // Only update if the list has changed to avoid disrupting selection
    if (![filteredDisks isEqualToArray:_availableDisks]) {
        [_availableDisks removeAllObjects];
        [_availableDisks addObjectsFromArray:filteredDisks];
        [_diskArrayController rearrangeObjects];
    }
    
    // Update info label with disk space requirement
    long long requiredMiB = requiredSize / (1024 * 1024);
    [_infoLabel setStringValue:[NSString stringWithFormat:@"Select the destination disk for the Live medium.\nRequired space: %lld MiB (%@)", 
                               requiredMiB, [GSDiskUtilities formatSize:requiredSize]]];
}

- (void)tableSelectionChanged:(NSNotification *)notification
{
    NSLog(@"CLMDiskSelectionStep: tableSelectionChanged");
    
    NSInteger selectedRow = [_diskTableView selectedRow];
    
    if (selectedRow >= 0 && selectedRow < (NSInteger)[_availableDisks count]) {
        NSDictionary *selectedDisk = [_availableDisks objectAtIndex:selectedRow];
        
        // Show confirmation dialog
        NSString *deviceName = [selectedDisk objectForKey:@"deviceName"];
        NSString *description = [selectedDisk objectForKey:@"description"];
        NSString *sizeFormatted = [selectedDisk objectForKey:@"sizeFormatted"];
        
        NSAlert *alert = [NSAlert alertWithMessageText:@"Confirm Disk Selection"
                                        defaultButton:@"Continue"
                                      alternateButton:@"Cancel"
                                          otherButton:nil
                            informativeTextWithFormat:@"This will erase ALL data on:\n\n%@ (%@)\n%@\n\nAre you sure you want to continue?", 
                                                      deviceName, sizeFormatted, description];
        
        [alert setIcon:[NSImage imageNamed:@"NSCaution"]];
        
        NSInteger response = [alert runModal];
        if (response == NSAlertDefaultReturn) {
            // User confirmed
            _controller.selectedDiskDevice = deviceName;
            _controller.userAgreedToErase = YES;
            
            NSLog(@"CLMDiskSelectionStep: User agreed to erase disk %@", deviceName);
            
            // Update navigation buttons to enable Continue
            [self requestNavigationUpdate];
        } else {
            // User cancelled, clear selection
            [_diskTableView deselectAll:nil];
            _controller.selectedDiskDevice = @"";
            _controller.userAgreedToErase = NO;
            
            // Update navigation buttons to disable Continue
            [self requestNavigationUpdate];
        }
    } else {
        // Clear selection
        _controller.selectedDiskDevice = @"";
        _controller.userAgreedToErase = NO;
        
        // Update navigation buttons to disable Continue
        [self requestNavigationUpdate];
    }
}

#pragma mark - GSAssistantStepProtocol

- (NSString *)stepTitle
{
    return @"Select Destination Disk";
}

- (NSString *)stepDescription  
{
    return @"Choose the disk to write the Live image to";
}

- (NSView *)stepView
{
    return _stepView;
}

- (BOOL)canContinue
{
    return ([_controller.selectedDiskDevice length] > 0 && _controller.userAgreedToErase);
}

- (void)requestNavigationUpdate
{
    NSWindow *window = [[self stepView] window];
    if (!window) {
        window = [NSApp keyWindow];
    }
    NSWindowController *wc = [window windowController];
    if ([wc isKindOfClass:[GSAssistantWindow class]]) {
        NSLog(@"CLMDiskSelectionStep: requesting navigation button update");
        GSAssistantWindow *assistantWindow = (GSAssistantWindow *)wc;
        [assistantWindow updateNavigationButtons];
    } else {
        NSLog(@"CLMDiskSelectionStep: could not find GSAssistantWindow to update navigation (wc=%@)", wc);
    }
}

- (void)stepWillAppear
{
    NSLog(@"CLMDiskSelectionStep: stepWillAppear");
    [self startRefreshTimer];
}

- (void)stepDidAppear
{
    NSLog(@"CLMDiskSelectionStep: stepDidAppear");
}

- (void)stepWillDisappear
{
    NSLog(@"CLMDiskSelectionStep: stepWillDisappear");
    [self stopRefreshTimer];
}

@end
