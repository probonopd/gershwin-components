//
// BAOperationSelectionStep.m
// Backup Assistant - Operation Selection Step Implementation
//

#import "BAOperationSelectionStep.h"
#import "BAController.h"

@implementation BAOperationSelectionStep

@synthesize controller = _controller;

- (id)initWithController:(BAController *)controller
{
    NSView *operationView = [self createOperationSelectionView];
    
    self = [super initWithTitle:NSLocalizedString(@"Select Operation", @"Operation selection step title")
                    description:NSLocalizedString(@"Choose the backup operation to perform", @"Operation selection step description")
                           view:operationView];
    
    if (self) {
        _controller = controller;
        self.stepType = GSAssistantStepTypeConfiguration;
        self.canProceed = NO;
        self.canReturn = YES;
    }
    
    return self;
}

- (NSView *)createOperationSelectionView
{
    _containerView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 390, 240)];
    
    // Disk info label
    _diskInfoLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 200, 390, 40)];
    [_diskInfoLabel setBezeled:NO];
    [_diskInfoLabel setDrawsBackground:NO];
    [_diskInfoLabel setEditable:NO];
    [_diskInfoLabel setSelectable:NO];
    [_diskInfoLabel setFont:[NSFont systemFontOfSize:13]];
    [_diskInfoLabel setAlignment:NSTextAlignmentLeft];
    [[_diskInfoLabel cell] setWraps:YES];
    [_containerView addSubview:_diskInfoLabel];
    
    // Operation selection matrix (will be created later in updateOperationOptions)
    _operationMatrix = nil;
    
    // Warning label - moved to bottom with smaller height
    _warningLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 5, 390, 40)];
    [_warningLabel setBezeled:NO];
    [_warningLabel setDrawsBackground:NO];
    [_warningLabel setEditable:NO];
    [_warningLabel setSelectable:NO];
    [_warningLabel setFont:[NSFont systemFontOfSize:11]];
    [_warningLabel setTextColor:[NSColor systemRedColor]];
    [_warningLabel setAlignment:NSTextAlignmentLeft];
    [[_warningLabel cell] setWraps:YES];
    [_containerView addSubview:_warningLabel];
    
    return [_containerView autorelease];
}

- (void)stepWillAppear
{
    NSLog(@"BAOperationSelectionStep: Step will appear");
    
    // Stop any disk refresh timers from the previous step
    [_controller stopDiskRefreshTimers];
    
    [self updateOperationOptions];
}

- (void)updateOperationOptions
{
    NSLog(@"BAOperationSelectionStep: Updating operation options");
    
    // Update disk info
    NSString *diskInfo = [NSString stringWithFormat:NSLocalizedString(@"Selected disk: %@", @"Selected disk info"), _controller.selectedDiskDevice];
    [_diskInfoLabel setStringValue:diskInfo];
    NSLog(@"BAOperationSelectionStep: Set disk info: %@", diskInfo);
    
    // Clear existing matrix if it exists
    if (_operationMatrix) {
        [_operationMatrix removeFromSuperview];
        [_operationMatrix release];
        _operationMatrix = nil;
    }
    
    // Create new matrix based on disk analysis
    BADiskAnalysisResult result = _controller.diskAnalysisResult;
    NSLog(@"BAOperationSelectionStep: Disk analysis result: %d", (int)result);
    NSMutableArray *operations = [NSMutableArray array];
    
    if (result == BADiskAnalysisResultEmpty) {
        [operations addObject:@{
            @"title": NSLocalizedString(@"Create New Backup", @"New backup operation"),
            @"description": NSLocalizedString(@"Initialize the disk and create a full backup of your home directory", @"New backup description"),
            @"type": @(BAOperationTypeNewBackup)
        }];
        
        [_warningLabel setStringValue:NSLocalizedString(@"WARNING: Creating a new backup will completely erase all data on the selected disk!", @"New backup warning")];
    } else if (result == BADiskAnalysisResultHasBackup) {
        [operations addObject:@{
            @"title": NSLocalizedString(@"Update Existing Backup", @"Update backup operation"),
            @"description": NSLocalizedString(@"Add a new snapshot with recent changes to the existing backup", @"Update backup description"),
            @"type": @(BAOperationTypeUpdateBackup)
        }];
        
        [operations addObject:@{
            @"title": NSLocalizedString(@"Restore from Backup", @"Restore operation"),
            @"description": NSLocalizedString(@"Restore files from the backup to your home directory", @"Restore description"),
            @"type": @(BAOperationTypeRestoreBackup)
        }];
        
        [operations addObject:@{
            @"title": NSLocalizedString(@"Mount Existing Backup", @"Mount backup operation"),
            @"description": NSLocalizedString(@"Mount the backup for browsing and manual file access", @"Mount backup description"),
            @"type": @(BAOperationTypeMountBackup)
        }];
        
        [operations addObject:@{
            @"title": NSLocalizedString(@"Destroy and Create New Backup", @"Destroy and recreate operation"),
            @"description": NSLocalizedString(@"Destroy the existing backup and create a completely fresh full backup", @"Destroy and recreate description"),
            @"type": @(BAOperationTypeDestroyAndRecreate)
        }];
        
        [_warningLabel setStringValue:NSLocalizedString(@"Note: Restoring will overwrite files. Destroying will permanently erase the existing backup!", @"Multiple operations warning")];
    }
    
    NSLog(@"BAOperationSelectionStep: Created %lu operations", (unsigned long)[operations count]);
    
    // Calculate matrix dimensions properly
    NSUInteger operationCount = [operations count];
    CGFloat cellHeight = 30;  // Reduced from 40 to fit better
    CGFloat matrixHeight = operationCount * cellHeight; // Simple calculation
    CGFloat matrixY = 60;  // Moved up to give more space
    
    NSLog(@"BAOperationSelectionStep: Matrix frame: x=20, y=%f, width=350, height=%f", matrixY, matrixHeight);
    
    // Create operation matrix
    _operationMatrix = [[NSMatrix alloc] initWithFrame:NSMakeRect(20, matrixY, 350, matrixHeight)];
    [_operationMatrix setCellClass:[NSButtonCell class]];
    [_operationMatrix setMode:NSRadioModeMatrix];
    [_operationMatrix setAllowsEmptySelection:NO];
    [_operationMatrix setTarget:self];
    [_operationMatrix setAction:@selector(operationChanged:)];
    [_operationMatrix setIntercellSpacing:NSMakeSize(5, 5)];
    
    // Add radio buttons for each operation BEFORE setting cell size
    [_operationMatrix renewRows:[operations count] columns:1];
    
    // Now set the cell size after the matrix knows how many cells it has
    [_operationMatrix setCellSize:NSMakeSize(340, cellHeight)];
    
    for (NSUInteger i = 0; i < [operations count]; i++) {
        NSDictionary *operation = [operations objectAtIndex:i];
        NSButtonCell *cell = [_operationMatrix cellAtRow:i column:0];
        [cell setButtonType:NSRadioButton];
        [cell setTitle:[operation objectForKey:@"title"]];
        [cell setTag:[[operation objectForKey:@"type"] integerValue]];
        [cell setFont:[NSFont systemFontOfSize:13]];
        [cell setAlignment:NSTextAlignmentLeft];
        NSLog(@"BAOperationSelectionStep: Added operation %lu: %@", (unsigned long)i, [operation objectForKey:@"title"]);
    }
    
    [_containerView addSubview:_operationMatrix];
    NSLog(@"BAOperationSelectionStep: Added matrix to container view with %lu operations", (unsigned long)[operations count]);
    NSLog(@"BAOperationSelectionStep: Container frame: %@", NSStringFromRect([_containerView frame]));
    NSLog(@"BAOperationSelectionStep: Matrix frame: %@", NSStringFromRect([_operationMatrix frame]));
    NSLog(@"BAOperationSelectionStep: Matrix cell count: %ld rows, %ld cols", (long)[_operationMatrix numberOfRows], (long)[_operationMatrix numberOfColumns]);
    
    // Force the matrix to layout and display properly
    [_operationMatrix setNeedsDisplay:YES];
    [_containerView setNeedsDisplay:YES];
    
    // Reset selection
    _controller.selectedOperation = BAOperationTypeNone;
    self.canProceed = NO;
    
    if (self.assistantWindow) {
        [self.assistantWindow updateNavigationButtons];
    }
}

- (void)operationChanged:(id)sender
{
    NSInteger selectedTag = [[_operationMatrix selectedCell] tag];
    _controller.selectedOperation = (BAOperationType)selectedTag;
    
    NSLog(@"BAOperationSelectionStep: Selected operation: %ld", (long)selectedTag);
    
    // Enable continue button
    self.canProceed = (_controller.selectedOperation != BAOperationTypeNone);
    
    if (self.assistantWindow) {
        [self.assistantWindow updateNavigationButtons];
    }
}

- (void)stepWillDisappear
{
    NSLog(@"BAOperationSelectionStep: stepWillDisappear called");
    
    // If mount operation is selected, skip configuration and go directly to progress
    if (_controller.selectedOperation == BAOperationTypeMountBackup) {
        NSLog(@"BAOperationSelectionStep: Mount operation selected, attempting to skip configuration step");
        
        if (self.assistantWindow) {
            // Get current step index
            NSInteger currentIndex = [self.assistantWindow.steps indexOfObject:self];
            NSLog(@"BAOperationSelectionStep: Current step index: %ld", (long)currentIndex);
            
            if (currentIndex != NSNotFound && currentIndex + 2 < (NSInteger)[self.assistantWindow.steps count]) {
                NSLog(@"BAOperationSelectionStep: Scheduling jump to progress step at index %ld", (long)(currentIndex + 2));
                
                // Use performSelector to ensure the current step transition completes first
                [self performSelector:@selector(performStepSkip:) 
                           withObject:@(currentIndex + 2) 
                           afterDelay:0.1];
            } else {
                NSLog(@"BAOperationSelectionStep: ERROR - Invalid step indices for skipping (current: %ld, total: %lu)", 
                      (long)currentIndex, (unsigned long)[self.assistantWindow.steps count]);
            }
        } else {
            NSLog(@"BAOperationSelectionStep: ERROR - No assistant window reference");
        }
    }
}

- (void)performStepSkip:(NSNumber *)targetIndexNumber
{
    NSInteger targetIndex = [targetIndexNumber integerValue];
    NSLog(@"BAOperationSelectionStep: Executing jump to progress step at index %ld", (long)targetIndex);
    
    if (self.assistantWindow) {
        [self.assistantWindow goToStepAtIndex:targetIndex];
    }
}

- (NSString *)continueButtonTitle
{
    if (_controller.selectedOperation == BAOperationTypeMountBackup) {
        return NSLocalizedString(@"Mount Backup", @"Mount backup button title");
    }
    return NSLocalizedString(@"Continue", @"Continue button title");
}

- (BOOL)validateStep
{
    NSLog(@"BAOperationSelectionStep: validateStep called, operation: %ld", (long)_controller.selectedOperation);
    
    // If mount operation is selected, skip configuration and go directly to progress
    if (_controller.selectedOperation == BAOperationTypeMountBackup) {
        NSLog(@"BAOperationSelectionStep: Mount operation selected, skipping configuration step");
        
        // Tell the assistant window to skip the next step (configuration)
        if (self.assistantWindow) {
            // Get current step index and skip configuration step
            NSInteger currentIndex = [self.assistantWindow.steps indexOfObject:self];
            NSLog(@"BAOperationSelectionStep: Current step index: %ld", (long)currentIndex);
            
            if (currentIndex != NSNotFound && currentIndex + 2 < (NSInteger)[self.assistantWindow.steps count]) {
                NSLog(@"BAOperationSelectionStep: Jumping to progress step at index %ld", (long)(currentIndex + 2));
                // Skip configuration step (index + 1) and go to progress step (index + 2)
                [self.assistantWindow goToStepAtIndex:(currentIndex + 2)];
                return NO; // Don't use normal navigation
            } else {
                NSLog(@"BAOperationSelectionStep: ERROR - Invalid step indices for skipping");
            }
        } else {
            NSLog(@"BAOperationSelectionStep: ERROR - No assistant window reference");
        }
    }
    
    return YES; // Use normal navigation for other operations
}

@end
