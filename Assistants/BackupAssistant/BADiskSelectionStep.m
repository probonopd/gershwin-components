//
// BADiskSelectionStep.m
// Backup Assistant - Disk Selection Step Implementation
//

#import "BADiskSelectionStep.h"
#import "BAController.h"
#import "BAZFSUtility.h"
#import <GSDiskUtilities.h>

// Class-level timer tracking to prevent multiple timers
static NSTimer *g_activeDiskTimer = nil;
static id g_timerOwner = nil;

@implementation BADiskSelectionStep

@synthesize controller = _controller;

- (id)initWithController:(BAController *)controller
{
    NSView *diskView = [self createDiskSelectionView];
    
    self = [super initWithTitle:NSLocalizedString(@"Select Backup Disk", @"Disk selection step title")
                    description:NSLocalizedString(@"Choose a removable disk for backup operations", @"Disk selection step description")
                           view:diskView];
    
    if (self) {
        _controller = controller;
        _availableDisks = [[NSMutableArray alloc] init];
        _diskSpaceCache = [[NSMutableDictionary alloc] init];
        self.stepType = GSAssistantStepTypeConfiguration;
        self.canProceed = NO;
        self.canReturn = YES;
        
        // Listen for timer stop notifications
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(stopTimerNotification:)
                                                     name:@"BAStopDiskRefreshTimers" 
                                                   object:nil];
        
        [self refreshDiskList];
    }
    
    return self;
}

- (void)dealloc
{
    NSLog(@"BADiskSelectionStep: dealloc called");
    
    // Remove notification observer
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    
    if (_refreshTimer) {
        NSLog(@"BADiskSelectionStep: Cleaning up timer in dealloc");
        [_refreshTimer invalidate];
        _refreshTimer = nil;
    }
    
    // Clear global tracking if we own it
    if (g_activeDiskTimer && g_timerOwner == self) {
        NSLog(@"BADiskSelectionStep: Clearing global timer in dealloc");
        g_activeDiskTimer = nil;
        g_timerOwner = nil;
    }
    
    [_availableDisks release];
    [_diskSpaceCache release];
    [super dealloc];
}

- (NSView *)createDiskSelectionView
{
    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 390, 240)];
    
    // Instructions
    NSTextField *instructionLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 200, 390, 40)];
    [instructionLabel setStringValue:NSLocalizedString(@"Select a removable disk to use for backup. The assistant will analyze the disk and determine the available operations.", @"Disk selection instructions")];
    [instructionLabel setBezeled:NO];
    [instructionLabel setDrawsBackground:NO];
    [instructionLabel setEditable:NO];
    [instructionLabel setSelectable:NO];
    [instructionLabel setFont:[NSFont systemFontOfSize:13]];
    [instructionLabel setAlignment:NSTextAlignmentLeft];
    [[instructionLabel cell] setWraps:YES];
    [view addSubview:instructionLabel];
    [instructionLabel release];
    
    // Disk list table
    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 60, 390, 130)];
    [scrollView setHasVerticalScroller:YES];
    [scrollView setHasHorizontalScroller:NO];
    [scrollView setBorderType:NSBezelBorder];
    [view addSubview:scrollView];
    
    _diskTableView = [[NSTableView alloc] initWithFrame:[[scrollView contentView] frame]];
    [_diskTableView setDelegate:(id<NSTableViewDelegate>)self];
    [_diskTableView setDataSource:(id<NSTableViewDataSource>)self];
    [_diskTableView setAllowsEmptySelection:YES];
    [_diskTableView setAllowsMultipleSelection:NO];
    
    // Create columns
    NSTableColumn *deviceColumn = [[NSTableColumn alloc] initWithIdentifier:@"device"];
    [[deviceColumn headerCell] setStringValue:NSLocalizedString(@"Device", @"Device column header")];
    [deviceColumn setWidth:80];
    [_diskTableView addTableColumn:deviceColumn];
    [deviceColumn release];
    
    NSTableColumn *descColumn = [[NSTableColumn alloc] initWithIdentifier:@"description"];
    [[descColumn headerCell] setStringValue:NSLocalizedString(@"Description", @"Description column header")];
    [descColumn setWidth:200];
    [_diskTableView addTableColumn:descColumn];
    [descColumn release];
    
    NSTableColumn *sizeColumn = [[NSTableColumn alloc] initWithIdentifier:@"size"];
    [[sizeColumn headerCell] setStringValue:NSLocalizedString(@"Available", @"Available space column header")];
    [sizeColumn setWidth:100];
    [_diskTableView addTableColumn:sizeColumn];
    [sizeColumn release];
    
    [scrollView setDocumentView:_diskTableView];
    [scrollView release];
    
    // Status label
    _statusLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 35, 390, 20)];
    [_statusLabel setStringValue:NSLocalizedString(@"Scanning for removable disks...", @"Disk scan status")];
    [_statusLabel setBezeled:NO];
    [_statusLabel setDrawsBackground:NO];
    [_statusLabel setEditable:NO];
    [_statusLabel setSelectable:NO];
    [_statusLabel setFont:[NSFont systemFontOfSize:12]];
    [_statusLabel setTextColor:[NSColor secondaryLabelColor]];
    [view addSubview:_statusLabel];
    
    // Selected disk info
    _selectedDiskInfo = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 10, 390, 20)];
    [_selectedDiskInfo setStringValue:@""];
    [_selectedDiskInfo setBezeled:NO];
    [_selectedDiskInfo setDrawsBackground:NO];
    [_selectedDiskInfo setEditable:NO];
    [_selectedDiskInfo setSelectable:NO];
    [_selectedDiskInfo setFont:[NSFont boldSystemFontOfSize:12]];
    [_selectedDiskInfo setTextColor:[NSColor blueColor]];
    [view addSubview:_selectedDiskInfo];
    
    return [view autorelease];
}

- (void)stepWillAppear
{
    NSLog(@"BADiskSelectionStep: Step will appear, starting disk refresh timer");
    
    // Stop any existing global timer first
    if (g_activeDiskTimer) {
        NSLog(@"BADiskSelectionStep: Stopping existing global timer owned by %@", g_timerOwner);
        [g_activeDiskTimer invalidate];
        g_activeDiskTimer = nil;
        g_timerOwner = nil;
    }
    
    // Make sure our instance timer is also stopped
    if (_refreshTimer) {
        NSLog(@"BADiskSelectionStep: Stopping existing instance timer");
        [_refreshTimer invalidate];
        _refreshTimer = nil;
    }
    
    [self refreshDiskList];
    
    // Start refresh timer to detect newly connected disks (5 seconds instead of 2)
    _refreshTimer = [NSTimer scheduledTimerWithTimeInterval:5.0
                                                     target:self
                                                   selector:@selector(refreshDiskList)
                                                   userInfo:nil
                                                    repeats:YES];
    
    // Track this timer globally
    g_activeDiskTimer = _refreshTimer;
    g_timerOwner = self;
    
    NSLog(@"BADiskSelectionStep: Created new timer: %@ (global tracking active)", _refreshTimer);
}

- (void)stepWillDisappear
{
    NSLog(@"BADiskSelectionStep: === STEP WILL DISAPPEAR ===");
    NSLog(@"BADiskSelectionStep: Step will disappear, stopping refresh timer");
    NSLog(@"BADiskSelectionStep: Current _refreshTimer: %@", _refreshTimer);
    NSLog(@"BADiskSelectionStep: Current g_activeDiskTimer: %@", g_activeDiskTimer);
    NSLog(@"BADiskSelectionStep: Current g_timerOwner: %@", g_timerOwner);
    
    if (_refreshTimer) {
        NSLog(@"BADiskSelectionStep: Invalidating instance timer");
        [_refreshTimer invalidate];
        _refreshTimer = nil;
    } else {
        NSLog(@"BADiskSelectionStep: No instance timer to invalidate");
    }
    
    // Clear global timer if we own it
    if (g_activeDiskTimer && g_timerOwner == self) {
        NSLog(@"BADiskSelectionStep: Clearing global timer tracking");
        [g_activeDiskTimer invalidate];  // Actually invalidate the global timer too
        g_activeDiskTimer = nil;
        g_timerOwner = nil;
    }
    
    NSLog(@"BADiskSelectionStep: === STEP WILL DISAPPEAR COMPLETE ===");
}

- (void)stepDidDisappear
{
    NSLog(@"BADiskSelectionStep: Step did disappear");
    // Additional cleanup if needed
    if (_refreshTimer) {
        NSLog(@"BADiskSelectionStep: Timer still exists in stepDidDisappear, cleaning up");
        [_refreshTimer invalidate];
        _refreshTimer = nil;
    }
    
    // Emergency cleanup of global timer
    if (g_activeDiskTimer) {
        NSLog(@"BADiskSelectionStep: EMERGENCY: Global timer still active in stepDidDisappear, force stopping");
        [g_activeDiskTimer invalidate];
        g_activeDiskTimer = nil;
        g_timerOwner = nil;
    }
}

- (void)refreshDiskList
{
    NSLog(@"BADiskSelectionStep: Refreshing disk list (instance timer: %@, global timer: %@, owner: %@)", 
          _refreshTimer, g_activeDiskTimer, g_timerOwner);
    
    // Safety check: if timer is nil, we shouldn't be running this
    if (!_refreshTimer) {
        NSLog(@"BADiskSelectionStep: WARNING - refreshDiskList called but instance timer is nil!");
        // Check if we're being called by a rogue global timer
        if (g_activeDiskTimer && g_timerOwner != self) {
            NSLog(@"BADiskSelectionStep: ERROR - Called by timer owned by different instance %@, stopping it!", g_timerOwner);
            [g_activeDiskTimer invalidate];
            g_activeDiskTimer = nil;
            g_timerOwner = nil;
        }
        return;
    }
    
    // Get removable disks
    NSArray *removableDisks = [GSDiskUtilities getRemovableDisks];
    
    // Only update if the disk list has actually changed to prevent unnecessary redraws
    BOOL disksChanged = NO;
    if ([_availableDisks count] != [removableDisks count]) {
        disksChanged = YES;
    } else {
        // Check if any disk devices have changed
        for (NSUInteger i = 0; i < [_availableDisks count]; i++) {
            GSDisk *existingDisk = [_availableDisks objectAtIndex:i];
            GSDisk *newDisk = [removableDisks objectAtIndex:i];
            if (![existingDisk.deviceName isEqualToString:newDisk.deviceName]) {
                disksChanged = YES;
                break;
            }
        }
    }
    
    if (disksChanged) {
        NSLog(@"BADiskSelectionStep: Disk list changed, updating UI");
        [_availableDisks removeAllObjects];
        [_availableDisks addObjectsFromArray:removableDisks];
        
        // Clear disk space cache since disks have changed
        [_diskSpaceCache removeAllObjects];
        
        [_diskTableView reloadData];
        
        if ([_availableDisks count] == 0) {
            [_statusLabel setStringValue:NSLocalizedString(@"No removable disks found. Please connect a USB or external disk.", @"No disks found message")];
        } else {
            [_statusLabel setStringValue:[NSString stringWithFormat:NSLocalizedString(@"Found %lu removable disk(s)", @"Disks found message"), (unsigned long)[_availableDisks count]]];
        }
    } else {
        NSLog(@"BADiskSelectionStep: No disk changes detected, skipping UI update");
    }
}

- (void)analyzeDisk:(NSString *)diskDevice
{
    NSLog(@"BADiskSelectionStep: Analyzing disk %@", diskDevice);
    
    [_selectedDiskInfo setStringValue:NSLocalizedString(@"Analyzing disk...", @"Analyzing disk message")];
    
    // Analyze the disk in a background thread using NSThread
    [NSThread detachNewThreadSelector:@selector(performDiskAnalysis:) 
                             toTarget:self 
                           withObject:diskDevice];
}

- (void)performDiskAnalysis:(NSString *)diskDevice
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    BADiskAnalysisResult result = [_controller analyzeDisk:diskDevice];
    
    // Update UI on main thread
    [self performSelectorOnMainThread:@selector(updateAnalysisResult:) 
                           withObject:@{
                               @"result": @(result),
                               @"diskDevice": diskDevice
                           } 
                        waitUntilDone:NO];
    
    [pool release];
}

- (void)updateAnalysisResult:(NSDictionary *)resultInfo
{
    BADiskAnalysisResult result = [[resultInfo objectForKey:@"result"] integerValue];
    NSString *diskDevice = [resultInfo objectForKey:@"diskDevice"];
    
    NSLog(@"BADiskSelectionStep: Updating analysis result for disk: '%@', result: %ld", diskDevice, (long)result);
    
    _controller.diskAnalysisResult = result;
    _controller.selectedDiskDevice = diskDevice;
    
    NSLog(@"BADiskSelectionStep: Set controller.selectedDiskDevice to: '%@'", _controller.selectedDiskDevice);
    
    NSString *statusMessage = @"";
    switch (result) {
        case BADiskAnalysisResultEmpty:
            statusMessage = NSLocalizedString(@"Empty disk - can create new backup", @"Empty disk analysis");
            break;
        case BADiskAnalysisResultHasBackup:
            statusMessage = NSLocalizedString(@"Existing backup found - can update or restore", @"Backup found analysis");
            break;
        case BADiskAnalysisResultCorrupted:
            statusMessage = NSLocalizedString(@"Corrupted ZFS pool detected", @"Corrupted disk analysis");
            break;
        case BADiskAnalysisResultIncompatible:
            statusMessage = NSLocalizedString(@"Incompatible disk format", @"Incompatible disk analysis");
            break;
    }
    
    [_selectedDiskInfo setStringValue:statusMessage];
    
    // Enable continue button if disk is usable
    self.canProceed = (result == BADiskAnalysisResultEmpty || result == BADiskAnalysisResultHasBackup);
    
    if (self.assistantWindow) {
        [self.assistantWindow updateNavigationButtons];
    }
}

#pragma mark - NSTableViewDataSource

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
    return [_availableDisks count];
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
    if ((NSUInteger)row >= [_availableDisks count]) {
        return nil;
    }
    
    GSDisk *disk = [_availableDisks objectAtIndex:row];
    NSString *identifier = [tableColumn identifier];
    
    if ([identifier isEqualToString:@"device"]) {
        return disk.deviceName;
    } else if ([identifier isEqualToString:@"description"]) {
        return disk.description;
    } else if ([identifier isEqualToString:@"size"]) {
        // Check cache first to avoid expensive ZFS operations
        NSString *cachedSize = [_diskSpaceCache objectForKey:disk.deviceName];
        if (cachedSize) {
            return cachedSize;
        }
        
        // Cache the raw disk size immediately as a fallback
        NSString *fallbackSize = [GSDiskUtilities formatSize:disk.size];
        [_diskSpaceCache setObject:fallbackSize forKey:disk.deviceName];
        
        // Calculate available space asynchronously to avoid blocking the UI
        [NSThread detachNewThreadSelector:@selector(calculateDiskSpaceAsync:) 
                                 toTarget:self 
                               withObject:disk.deviceName];
        
        return fallbackSize;
    }
    
    return nil;
}

#pragma mark - NSTableViewDelegate

- (void)tableViewSelectionDidChange:(NSNotification *)notification
{
    NSInteger selectedRow = [_diskTableView selectedRow];
    
    if (selectedRow >= 0 && (NSUInteger)selectedRow < [_availableDisks count]) {
        GSDisk *selectedDisk = [_availableDisks objectAtIndex:selectedRow];
        NSLog(@"BADiskSelectionStep: Selected disk %@ (device: %@, size: %lld)", 
              selectedDisk.description, selectedDisk.deviceName, selectedDisk.size);
        
        [self analyzeDisk:selectedDisk.deviceName];
    } else {
        [_selectedDiskInfo setStringValue:@""];
        self.canProceed = NO;
        
        if (self.assistantWindow) {
            [self.assistantWindow updateNavigationButtons];
        }
    }
}

- (NSString *)continueButtonTitle
{
    return NSLocalizedString(@"Continue", @"Continue button title");
}

- (void)stopTimerNotification:(NSNotification *)notification
{
    NSLog(@"BADiskSelectionStep: === RECEIVED TIMER STOP NOTIFICATION ===");
    [self forceStopTimer];
}

- (void)forceStopTimer
{
    NSLog(@"BADiskSelectionStep: Force stopping timer");
    NSLog(@"BADiskSelectionStep: Current _refreshTimer: %@", _refreshTimer);
    NSLog(@"BADiskSelectionStep: Current g_activeDiskTimer: %@", g_activeDiskTimer);
    NSLog(@"BADiskSelectionStep: Current g_timerOwner: %@", g_timerOwner);
    
    if (_refreshTimer) {
        NSLog(@"BADiskSelectionStep: Force invalidating instance timer");
        [_refreshTimer invalidate];
        _refreshTimer = nil;
    }
    
    // Clear global timer if we own it
    if (g_activeDiskTimer && g_timerOwner == self) {
        NSLog(@"BADiskSelectionStep: Force clearing global timer tracking");
        [g_activeDiskTimer invalidate];
        g_activeDiskTimer = nil;
        g_timerOwner = nil;
    }
    
    NSLog(@"BADiskSelectionStep: === FORCE STOP TIMER COMPLETE ===");
}

- (void)calculateDiskSpaceAsync:(NSString *)diskDevice
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    // Check if the disk is still in our current list (avoid calculating for old disks)
    BOOL diskStillExists = NO;
    for (GSDisk *disk in _availableDisks) {
        if ([disk.deviceName isEqualToString:diskDevice]) {
            diskStillExists = YES;
            break;
        }
    }
    
    if (!diskStillExists) {
        NSLog(@"BADiskSelectionStep: Disk %@ no longer in list, skipping space calculation", diskDevice);
        [pool release];
        return;
    }
    
    // Calculate available space using ZFS utilities
    long long availableSpace = [BAZFSUtility getAvailableSpace:diskDevice];
    NSString *formattedSize;
    
    if (availableSpace > 0) {
        formattedSize = [GSDiskUtilities formatSize:availableSpace];
    } else {
        // Find the disk to get its raw size
        GSDisk *targetDisk = nil;
        for (GSDisk *disk in _availableDisks) {
            if ([disk.deviceName isEqualToString:diskDevice]) {
                targetDisk = disk;
                break;
            }
        }
        
        if (targetDisk) {
            formattedSize = [GSDiskUtilities formatSize:targetDisk.size];
        } else {
            formattedSize = NSLocalizedString(@"Unknown", @"Unknown disk size");
        }
    }
    
    // Update cache and UI on main thread
    [self performSelectorOnMainThread:@selector(updateDiskSpaceCache:) 
                           withObject:@{@"diskDevice": diskDevice, @"size": formattedSize} 
                        waitUntilDone:NO];
    
    [pool release];
}

- (void)updateDiskSpaceCache:(NSDictionary *)info
{
    NSString *diskDevice = [info objectForKey:@"diskDevice"];
    NSString *size = [info objectForKey:@"size"];
    
    // Update cache
    [_diskSpaceCache setObject:size forKey:diskDevice];
    
    // Find the row for this disk and refresh only that cell
    BOOL found = NO;
    for (NSUInteger i = 0; i < [_availableDisks count]; i++) {
        GSDisk *disk = [_availableDisks objectAtIndex:i];
        if ([disk.deviceName isEqualToString:diskDevice]) {
            found = YES;
            NSInteger columnIndex = [_diskTableView columnWithIdentifier:@"size"];
            if (columnIndex != -1) {
                // Make sure the table view still exists and is valid before updating
                if (_diskTableView && [_diskTableView superview]) {
                    [_diskTableView reloadDataForRowIndexes:[NSIndexSet indexSetWithIndex:i] 
                                              columnIndexes:[NSIndexSet indexSetWithIndex:columnIndex]];
                }
            }
            break;
        }
    }
    if (!found) {
        NSLog(@"BADiskSelectionStep: Disk %@ not found in current list, skipping UI update", diskDevice);
    }
}
@end
