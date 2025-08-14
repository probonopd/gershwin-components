//
// BAConfigurationStep.m
// Backup Assistant - Configuration Step Implementation
//

#import "BAConfigurationStep.h"
#import "BAController.h"

@implementation BAConfigurationStep

@synthesize controller = _controller;

- (id)initWithController:(BAController *)controller
{
    NSView *configView = [self createConfigurationView];
    
    self = [super initWithTitle:NSLocalizedString(@"Configure Operation", @"Configuration step title")
                    description:NSLocalizedString(@"Review and configure the backup operation", @"Configuration step description")
                           view:configView];
    
    if (self) {
        _controller = controller;
        _availableSnapshots = [[NSMutableArray alloc] init];
        _selectableItems = [[NSMutableArray alloc] init];
        self.stepType = GSAssistantStepTypeConfiguration;
        self.canProceed = NO;
        self.canReturn = YES;
    }
    
    return self;
}

- (void)dealloc
{
    [_availableSnapshots release];
    [_selectableItems release];
    [super dealloc];
}

- (NSView *)createConfigurationView
{
    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 390, 240)];
    
    // Operation description
    _operationLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 200, 390, 40)];
    [_operationLabel setBezeled:NO];
    [_operationLabel setDrawsBackground:NO];
    [_operationLabel setEditable:NO];
    [_operationLabel setSelectable:NO];
    [_operationLabel setFont:[NSFont systemFontOfSize:13]];
    [_operationLabel setAlignment:NSTextAlignmentLeft];
    [[_operationLabel cell] setWraps:YES];
    [view addSubview:_operationLabel];
    
    // Space information
    _spaceInfoLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 160, 390, 30)];
    [_spaceInfoLabel setBezeled:NO];
    [_spaceInfoLabel setDrawsBackground:NO];
    [_spaceInfoLabel setEditable:NO];
    [_spaceInfoLabel setSelectable:NO];
    [_spaceInfoLabel setFont:[NSFont systemFontOfSize:12]];
    [_spaceInfoLabel setTextColor:[NSColor secondaryLabelColor]];
    [_spaceInfoLabel setAlignment:NSTextAlignmentLeft];
    [[_spaceInfoLabel cell] setWraps:YES];
    [view addSubview:_spaceInfoLabel];
    
    // Snapshot selection (for restore operations)
    _snapshotScrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 90, 390, 60)];
    [_snapshotScrollView setHasVerticalScroller:YES];
    [_snapshotScrollView setHasHorizontalScroller:NO];
    [_snapshotScrollView setBorderType:NSBezelBorder];
    [_snapshotScrollView setHidden:YES];
    [view addSubview:_snapshotScrollView];
    
    _snapshotTableView = [[NSTableView alloc] initWithFrame:[[_snapshotScrollView contentView] frame]];
    [_snapshotTableView setDelegate:(id<NSTableViewDelegate>)self];
    [_snapshotTableView setDataSource:(id<NSTableViewDataSource>)self];
    [_snapshotTableView setAllowsEmptySelection:YES];
    [_snapshotTableView setAllowsMultipleSelection:NO];
    
    NSTableColumn *snapshotColumn = [[NSTableColumn alloc] initWithIdentifier:@"snapshot"];
    [[snapshotColumn headerCell] setStringValue:NSLocalizedString(@"Available Snapshots", @"Snapshot column header")];
    [snapshotColumn setWidth:280];
    [_snapshotTableView addTableColumn:snapshotColumn];
    [snapshotColumn release];
    
    NSTableColumn *dateColumn = [[NSTableColumn alloc] initWithIdentifier:@"date"];
    [[dateColumn headerCell] setStringValue:NSLocalizedString(@"Date", @"Date column header")];
    [dateColumn setWidth:100];
    [_snapshotTableView addTableColumn:dateColumn];
    [dateColumn release];
    
    [_snapshotScrollView setDocumentView:_snapshotTableView];
    
    // Items selection (for restore operations)
    _itemsScrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 50, 390, 60)];
    [_itemsScrollView setHasVerticalScroller:YES];
    [_itemsScrollView setHasHorizontalScroller:NO];
    [_itemsScrollView setBorderType:NSBezelBorder];
    [_itemsScrollView setHidden:YES];
    [view addSubview:_itemsScrollView];
    
    _itemsTableView = [[NSTableView alloc] initWithFrame:[[_itemsScrollView contentView] frame]];
    [_itemsTableView setDelegate:(id<NSTableViewDelegate>)self];
    [_itemsTableView setDataSource:(id<NSTableViewDataSource>)self];
    [_itemsTableView setAllowsEmptySelection:YES];
    [_itemsTableView setAllowsMultipleSelection:YES];
    
    NSTableColumn *enabledColumn = [[NSTableColumn alloc] initWithIdentifier:@"enabled"];
    [[enabledColumn headerCell] setStringValue:@""];
    [enabledColumn setWidth:20];
    [_itemsTableView addTableColumn:enabledColumn];
    [enabledColumn release];
    
    NSTableColumn *itemColumn = [[NSTableColumn alloc] initWithIdentifier:@"item"];
    [[itemColumn headerCell] setStringValue:NSLocalizedString(@"Items to Restore", @"Items column header")];
    [itemColumn setWidth:360];
    [_itemsTableView addTableColumn:itemColumn];
    [itemColumn release];
    
    [_itemsScrollView setDocumentView:_itemsTableView];
    
    // Confirmation checkbox
    _confirmCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(0, 20, 390, 20)];
    [_confirmCheckbox setButtonType:NSSwitchButton];
    [_confirmCheckbox setTarget:self];
    [_confirmCheckbox setAction:@selector(confirmationChanged:)];
    [_confirmCheckbox setFont:[NSFont systemFontOfSize:12]];
    [view addSubview:_confirmCheckbox];
    
    return [view autorelease];
}

- (void)stepWillAppear
{
    NSLog(@"BAConfigurationStep: Step will appear");
    [self updateConfigurationView];
    [self calculateSpaceRequirements];
}

- (void)stepWillDisappear
{
    NSLog(@"BAConfigurationStep: Step will disappear");
    // Reset the calculation flag in case we're navigating away
    _spaceCalculationInProgress = NO;
}

- (void)updateConfigurationView
{
    NSLog(@"BAConfigurationStep: Updating configuration view");
    
    BAOperationType operation = _controller.selectedOperation;
    
    switch (operation) {
        case BAOperationTypeNewBackup:
            [_operationLabel setStringValue:NSLocalizedString(@"Create a new backup of your home directory. This will completely erase the selected disk and create a fresh ZFS backup.", @"New backup configuration description")];
            [_confirmCheckbox setTitle:NSLocalizedString(@"I understand that all data on the selected disk will be erased", @"New backup confirmation")];
            [_snapshotScrollView setHidden:YES];
            [_itemsScrollView setHidden:YES];
            break;
            
        case BAOperationTypeUpdateBackup:
            [_operationLabel setStringValue:NSLocalizedString(@"Update the existing backup with recent changes from your home directory. A new snapshot will be created.", @"Update backup configuration description")];
            [_confirmCheckbox setTitle:NSLocalizedString(@"I want to update the backup with current data", @"Update backup confirmation")];
            [_snapshotScrollView setHidden:YES];
            [_itemsScrollView setHidden:YES];
            break;
            
        case BAOperationTypeRestoreBackup:
            [_operationLabel setStringValue:NSLocalizedString(@"Restore files from the backup to your home directory. Select a snapshot and choose which items to restore.", @"Restore configuration description")];
            [_confirmCheckbox setTitle:NSLocalizedString(@"I understand that existing files may be overwritten", @"Restore confirmation")];
            [_snapshotScrollView setHidden:NO];
            [_itemsScrollView setHidden:NO];
            
            // Load available snapshots
            [self loadAvailableSnapshots];
            [self loadSelectableItems];
            break;
            
        case BAOperationTypeDestroyAndRecreate:
            [_operationLabel setStringValue:NSLocalizedString(@"Destroy the existing backup and create a completely new backup of your home directory. This will permanently erase all existing backup data and snapshots on the disk.", @"Destroy and recreate configuration description")];
            [_confirmCheckbox setTitle:NSLocalizedString(@"I understand that all existing backup data will be permanently destroyed", @"Destroy and recreate confirmation")];
            [_snapshotScrollView setHidden:YES];
            [_itemsScrollView setHidden:YES];
            break;
            
        default:
            break;
    }
    
    [_confirmCheckbox setState:NSOffState];
    self.canProceed = NO;
    
    if (self.assistantWindow) {
        [self.assistantWindow updateNavigationButtons];
    }
}

- (void)calculateSpaceRequirements
{
    if (_spaceCalculationInProgress) {
        NSLog(@"BAConfigurationStep: Space calculation already in progress, skipping");
        return;
    }
    
    NSLog(@"BAConfigurationStep: Calculating space requirements");
    _spaceCalculationInProgress = YES;
    
    [NSThread detachNewThreadSelector:@selector(performSpaceCalculation) 
                             toTarget:self 
                           withObject:nil];
}

- (void)performSpaceCalculation
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    NSLog(@"BAConfigurationStep: === Starting space calculation ===");
    NSLog(@"BAConfigurationStep: Selected disk device: '%@'", _controller.selectedDiskDevice);
    NSLog(@"BAConfigurationStep: Selected operation: %ld", (long)_controller.selectedOperation);
    
    long long requiredSpace = 0;
    long long availableSpace = [_controller getDiskAvailableSpace:_controller.selectedDiskDevice];
    
    NSLog(@"BAConfigurationStep: Space calculation - Disk: %@, Available space: %lld bytes", _controller.selectedDiskDevice, availableSpace);
    
    if (_controller.selectedOperation == BAOperationTypeNewBackup || _controller.selectedOperation == BAOperationTypeDestroyAndRecreate) {
        requiredSpace = [_controller calculateBackupSize];
        NSLog(@"BAConfigurationStep: New/Destroy and recreate backup - Required space: %lld bytes", requiredSpace);
    } else if (_controller.selectedOperation == BAOperationTypeUpdateBackup) {
        // For incremental backup, estimate 10% of home directory size as new changes
        requiredSpace = [_controller calculateBackupSize] / 10;
        NSLog(@"BAConfigurationStep: Incremental backup - Required space: %lld bytes", requiredSpace);
    }
    
    NSLog(@"BAConfigurationStep: === Space calculation complete ===");
    
    NSDictionary *spaceInfo = @{
        @"requiredSpace": @(requiredSpace),
        @"availableSpace": @(availableSpace)
    };
    
    [self performSelectorOnMainThread:@selector(updateSpaceInfo:) 
                           withObject:spaceInfo 
                        waitUntilDone:NO];
    
    [pool release];
}

- (void)updateSpaceInfo:(NSDictionary *)spaceInfo
{
    long long requiredSpace = [[spaceInfo objectForKey:@"requiredSpace"] longLongValue];
    long long availableSpace = [[spaceInfo objectForKey:@"availableSpace"] longLongValue];
    
    NSLog(@"BAConfigurationStep: updateSpaceInfo - Required: %lld bytes, Available: %lld bytes", requiredSpace, availableSpace);
    
    // IMPORTANT: Set the controller values here
    _controller.requiredSpace = requiredSpace;
    _controller.availableSpace = availableSpace;
    
    NSLog(@"BAConfigurationStep: After setting controller - requiredSpace: %lld, availableSpace: %lld", 
          _controller.requiredSpace, _controller.availableSpace);
    
    // Clear the in-progress flag
    _spaceCalculationInProgress = NO;
    
    NSString *spaceInfoStr = @"";
    if (requiredSpace > 0) {
        NSString *requiredStr = [_controller formatDiskSize:requiredSpace];
        NSString *availableStr = [_controller formatDiskSize:availableSpace];
        
        NSLog(@"BAConfigurationStep: Formatted - Required: %@, Available: %@", requiredStr, availableStr);
        
        if (requiredSpace <= availableSpace) {
            spaceInfoStr = [NSString stringWithFormat:NSLocalizedString(@"Required: %@, Available: %@ ✓", @"Space requirements met"), requiredStr, availableStr];
            [_spaceInfoLabel setTextColor:[NSColor blueColor]]; // Use blueColor instead of systemGreenColor
            NSLog(@"BAConfigurationStep: Space check PASSED");
        } else {
            spaceInfoStr = [NSString stringWithFormat:NSLocalizedString(@"Required: %@, Available: %@ ⚠️ Insufficient space!", @"Space requirements not met"), requiredStr, availableStr];
            [_spaceInfoLabel setTextColor:[NSColor redColor]]; // Use redColor instead of systemRedColor
            NSLog(@"BAConfigurationStep: Space check FAILED - need %lld more bytes", requiredSpace - availableSpace);
        }
    } else {
        spaceInfoStr = NSLocalizedString(@"Calculating space requirements...", @"Space calculation in progress");
        [_spaceInfoLabel setTextColor:[NSColor secondaryLabelColor]];
        NSLog(@"BAConfigurationStep: Still calculating space requirements");
    }
    
    [_spaceInfoLabel setStringValue:spaceInfoStr];
    
    // After updating space info, re-check the confirmation state
    NSLog(@"BAConfigurationStep: Space calculation complete, re-checking confirmation state");
    [self confirmationChanged:nil];
}

- (void)loadAvailableSnapshots
{
    NSLog(@"BAConfigurationStep: Loading available snapshots");
    
    [NSThread detachNewThreadSelector:@selector(performSnapshotLoad) 
                             toTarget:self 
                           withObject:nil];
}

- (void)performSnapshotLoad
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    NSArray *snapshots = [_controller getZFSSnapshots];
    
    [self performSelectorOnMainThread:@selector(updateSnapshots:) 
                           withObject:snapshots 
                        waitUntilDone:NO];
    
    [pool release];
}

- (void)updateSnapshots:(NSArray *)snapshots
{
    [_availableSnapshots removeAllObjects];
    [_availableSnapshots addObjectsFromArray:snapshots];
    [_snapshotTableView reloadData];
}

- (void)loadSelectableItems
{
    NSLog(@"BAConfigurationStep: Loading selectable items");
    
    // For now, provide common directories that users might want to restore
    [_selectableItems removeAllObjects];
    
    NSArray *commonItems = @[
        @"Documents",
        @"Desktop",
        @"Downloads",
        @"Pictures",
        @"Music",
        @"Movies",
        @"Library/Preferences",
        @".ssh",
        @".bashrc",
        @".zshrc"
    ];
    
    for (NSString *item in commonItems) {
        [_selectableItems addObject:@{
            @"name": item,
            @"enabled": @YES
        }];
    }
    
    [_itemsTableView reloadData];
}

- (void)confirmationChanged:(id)sender
{
    BOOL confirmed = ([_confirmCheckbox state] == NSOnState);
    
    NSLog(@"BAConfigurationStep: confirmationChanged - confirmed: %@, spaceCalculationInProgress: %@", 
          confirmed ? @"YES" : @"NO", _spaceCalculationInProgress ? @"YES" : @"NO");
    NSLog(@"BAConfigurationStep: confirmationChanged - controller.requiredSpace: %lld", _controller.requiredSpace);
    NSLog(@"BAConfigurationStep: confirmationChanged - controller.availableSpace: %lld", _controller.availableSpace);
    
    // Don't make decisions if space calculation is still in progress
    if (_spaceCalculationInProgress) {
        NSLog(@"BAConfigurationStep: Space calculation still in progress, deferring confirmation check");
        return;
    }
    
    // Additional validation for restore operations
    if (_controller.selectedOperation == BAOperationTypeRestoreBackup) {
        BOOL hasSelectedSnapshot = (_controller.selectedSnapshot != nil);
        self.canProceed = confirmed && hasSelectedSnapshot;
        NSLog(@"BAConfigurationStep: Restore operation - hasSelectedSnapshot: %@", hasSelectedSnapshot ? @"YES" : @"NO");
    } else {
        self.canProceed = confirmed;
    }
    
    // Check space requirements
    if (_controller.requiredSpace > _controller.availableSpace && _controller.requiredSpace > 0) {
        NSLog(@"BAConfigurationStep: BLOCKING due to insufficient space: required %lld > available %lld", 
              _controller.requiredSpace, _controller.availableSpace);
        self.canProceed = NO;
    } else {
        NSLog(@"BAConfigurationStep: Space check OK: required %lld <= available %lld", 
              _controller.requiredSpace, _controller.availableSpace);
    }
    
    NSLog(@"BAConfigurationStep: Final canProceed: %@", self.canProceed ? @"YES" : @"NO");
    
    if (self.assistantWindow) {
        [self.assistantWindow updateNavigationButtons];
    }
}

#pragma mark - NSTableViewDataSource

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
    if (tableView == _snapshotTableView) {
        return [_availableSnapshots count];
    } else if (tableView == _itemsTableView) {
        return [_selectableItems count];
    }
    return 0;
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
    NSString *identifier = [tableColumn identifier];
    
    if (tableView == _snapshotTableView) {
        if ((NSUInteger)row >= [_availableSnapshots count]) {
            return nil;
        }
        
        NSDictionary *snapshot = [_availableSnapshots objectAtIndex:row];
        
        if ([identifier isEqualToString:@"snapshot"]) {
            return [snapshot objectForKey:@"name"];
        } else if ([identifier isEqualToString:@"date"]) {
            return [snapshot objectForKey:@"creation"];
        }
    } else if (tableView == _itemsTableView) {
        if ((NSUInteger)row >= [_selectableItems count]) {
            return nil;
        }
        
        NSDictionary *item = [_selectableItems objectAtIndex:row];
        
        if ([identifier isEqualToString:@"enabled"]) {
            return [item objectForKey:@"enabled"];
        } else if ([identifier isEqualToString:@"item"]) {
            return [item objectForKey:@"name"];
        }
    }
    
    return nil;
}

- (void)tableView:(NSTableView *)tableView setObjectValue:(id)object forTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
    if (tableView == _itemsTableView && [[tableColumn identifier] isEqualToString:@"enabled"]) {
        if ((NSUInteger)row < [_selectableItems count]) {
            NSMutableDictionary *item = [NSMutableDictionary dictionaryWithDictionary:[_selectableItems objectAtIndex:row]];
            [item setObject:object forKey:@"enabled"];
            [_selectableItems replaceObjectAtIndex:row withObject:item];
            
            // Update controller's restore items list
            [_controller.restoreItems removeAllObjects];
            for (NSDictionary *selectableItem in _selectableItems) {
                if ([[selectableItem objectForKey:@"enabled"] boolValue]) {
                    [_controller.restoreItems addObject:[selectableItem objectForKey:@"name"]];
                }
            }
        }
    }
}

#pragma mark - NSTableViewDelegate

- (void)tableViewSelectionDidChange:(NSNotification *)notification
{
    NSTableView *tableView = [notification object];
    
    if (tableView == _snapshotTableView) {
        NSInteger selectedRow = [_snapshotTableView selectedRow];
        
        if (selectedRow >= 0 && (NSUInteger)selectedRow < [_availableSnapshots count]) {
            NSDictionary *selectedSnapshot = [_availableSnapshots objectAtIndex:selectedRow];
            _controller.selectedSnapshot = [selectedSnapshot objectForKey:@"name"];
            NSLog(@"BAConfigurationStep: Selected snapshot: %@", _controller.selectedSnapshot);
        } else {
            _controller.selectedSnapshot = nil;
        }
        
        [self confirmationChanged:nil]; // Update canProceed state
    }
}

- (NSCell *)tableView:(NSTableView *)tableView dataCellForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
    if (tableView == _itemsTableView && [[tableColumn identifier] isEqualToString:@"enabled"]) {
        NSButtonCell *checkboxCell = [[NSButtonCell alloc] init];
        [checkboxCell setButtonType:NSSwitchButton];
        [checkboxCell setTitle:@""];
        return [checkboxCell autorelease];
    }
    
    return nil;
}

- (NSString *)continueButtonTitle
{
    switch (_controller.selectedOperation) {
        case BAOperationTypeNewBackup:
            return NSLocalizedString(@"Create Backup", @"Create backup button title");
        case BAOperationTypeUpdateBackup:
            return NSLocalizedString(@"Update Backup", @"Update backup button title");
        case BAOperationTypeRestoreBackup:
            return NSLocalizedString(@"Restore Files", @"Restore files button title");
        case BAOperationTypeDestroyAndRecreate:
            return NSLocalizedString(@"Destroy & Create", @"Destroy and create backup button title");
        default:
            return NSLocalizedString(@"Continue", @"Continue button title");
    }
}

@end
