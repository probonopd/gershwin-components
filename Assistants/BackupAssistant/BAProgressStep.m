//
// BAProgressStep.m
// Backup Assistant - Progress Step Implementation
//

#import "BAProgressStep.h"
#import "BAController.h"

@implementation BAProgressStep

@synthesize controller = _controller;

- (id)initWithController:(BAController *)controller
{
    NSView *progressView = [self createProgressView];
    
    self = [super initWithTitle:NSLocalizedString(@"Operation in Progress", @"Progress step title")
                    description:NSLocalizedString(@"Please wait while the operation completes", @"Progress step description")
                           view:progressView];
    
    if (self) {
        _controller = controller;
        self.stepType = GSAssistantStepTypeProgress;
        self.canProceed = NO;
        self.canReturn = NO;
        _operationInProgress = NO;
    }
    
    return self;
}

- (NSView *)createProgressView
{
    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 390, 240)];
    
    // Operation description
    _operationLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 190, 390, 40)];
    [_operationLabel setBezeled:NO];
    [_operationLabel setDrawsBackground:NO];
    [_operationLabel setEditable:NO];
    [_operationLabel setSelectable:NO];
    [_operationLabel setFont:[NSFont systemFontOfSize:14]];
    [_operationLabel setAlignment:NSTextAlignmentCenter];
    [[_operationLabel cell] setWraps:YES];
    [view addSubview:_operationLabel];
    
    // Progress bar
    _progressBar = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(50, 130, 290, 20)];
    [_progressBar setStyle:NSProgressIndicatorBarStyle];
    [_progressBar setIndeterminate:NO];
    [_progressBar setMinValue:0.0];
    [_progressBar setMaxValue:100.0];
    [_progressBar setDoubleValue:0.0];
    [view addSubview:_progressBar];
    
    // Progress percentage label
    _progressLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 100, 390, 20)];
    [_progressLabel setStringValue:@"0%"];
    [_progressLabel setBezeled:NO];
    [_progressLabel setDrawsBackground:NO];
    [_progressLabel setEditable:NO];
    [_progressLabel setSelectable:NO];
    [_progressLabel setFont:[NSFont systemFontOfSize:12]];
    [_progressLabel setAlignment:NSTextAlignmentCenter];
    [view addSubview:_progressLabel];
    
    // Current task label
    _currentTaskLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 60, 390, 30)];
    [_currentTaskLabel setStringValue:NSLocalizedString(@"Preparing...", @"Initial task message")];
    [_currentTaskLabel setBezeled:NO];
    [_currentTaskLabel setDrawsBackground:NO];
    [_currentTaskLabel setEditable:NO];
    [_currentTaskLabel setSelectable:NO];
    [_currentTaskLabel setFont:[NSFont systemFontOfSize:12]];
    [_currentTaskLabel setTextColor:[NSColor secondaryLabelColor]];
    [_currentTaskLabel setAlignment:NSTextAlignmentCenter];
    [[_currentTaskLabel cell] setWraps:YES];
    [view addSubview:_currentTaskLabel];
    
    // Warning/instruction label
    NSTextField *warningLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 20, 390, 30)];
    [warningLabel setStringValue:NSLocalizedString(@"Do not disconnect the disk or close this application during the operation.", @"Progress warning")];
    [warningLabel setBezeled:NO];
    [warningLabel setDrawsBackground:NO];
    [warningLabel setEditable:NO];
    [warningLabel setSelectable:NO];
    [warningLabel setFont:[NSFont systemFontOfSize:11]];
    [warningLabel setTextColor:[NSColor systemOrangeColor]];
    [warningLabel setAlignment:NSTextAlignmentCenter];
    [[warningLabel cell] setWraps:YES];
    [view addSubview:warningLabel];
    [warningLabel release];
    
    return [view autorelease];
}

- (void)stepWillAppear
{
    NSLog(@"BAProgressStep: Step will appear");
    
    // Update operation description based on selected operation
    NSString *operationDesc = @"";
    switch (_controller.selectedOperation) {
        case BAOperationTypeNewBackup:
            operationDesc = NSLocalizedString(@"Creating new backup...", @"New backup progress description");
            break;
        case BAOperationTypeUpdateBackup:
            operationDesc = NSLocalizedString(@"Updating existing backup...", @"Update backup progress description");
            break;
        case BAOperationTypeRestoreBackup:
            operationDesc = NSLocalizedString(@"Restoring files from backup...", @"Restore progress description");
            break;
        case BAOperationTypeDestroyAndRecreate:
            operationDesc = NSLocalizedString(@"Destroying existing backup and creating new one...", @"Destroy and recreate progress description");
            break;
        case BAOperationTypeMountBackup:
            operationDesc = NSLocalizedString(@"Mounting existing backup for access...", @"Mount backup progress description");
            break;
        default:
            operationDesc = NSLocalizedString(@"Processing...", @"Generic progress description");
            break;
    }
    
    [_operationLabel setStringValue:operationDesc];
    
    // Start the operation after a brief delay to allow UI to update
    [self performSelector:@selector(startOperation) withObject:nil afterDelay:0.5];
}

- (void)startOperation
{
    if (_operationInProgress) {
        NSLog(@"BAProgressStep: Operation already in progress, ignoring duplicate start request");
        return;
    }
    
    _operationInProgress = YES;
    NSLog(@"BAProgressStep: Starting operation: %ld", (long)_controller.selectedOperation);
    
    // Perform operation in background thread
    [NSThread detachNewThreadSelector:@selector(performOperation) 
                             toTarget:self 
                           withObject:nil];
}

- (void)performOperation
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    BOOL success = NO;
    NSString *errorMessage = nil;
    
    // Create progress callback block
    void(^progressBlock)(CGFloat, NSString *) = ^(CGFloat progress, NSString *currentTask) {
        NSDictionary *progressInfo = @{
            @"progress": @(progress),
            @"task": currentTask ? currentTask : @""
        };
        [self performSelectorOnMainThread:@selector(updateProgressFromBackground:) 
                               withObject:progressInfo 
                            waitUntilDone:NO];
    };
    
    @try {
        switch (_controller.selectedOperation) {
            case BAOperationTypeNewBackup:
                // First create the ZFS pool
                if ([_controller createZFSPool:_controller.selectedDiskDevice]) {
                    success = [_controller performBackupWithProgress:progressBlock];
                } else {
                    errorMessage = NSLocalizedString(@"Failed to create ZFS pool on the selected disk.", @"ZFS pool creation error");
                }
                break;
                
            case BAOperationTypeUpdateBackup:
                // Import existing pool first
                if ([_controller importZFSPool:_controller.selectedDiskDevice]) {
                    success = [_controller performIncrementalBackupWithProgress:progressBlock];
                } else {
                    errorMessage = NSLocalizedString(@"Failed to import existing ZFS pool from the disk.", @"ZFS pool import error");
                }
                break;
                
            case BAOperationTypeRestoreBackup:
                // Import existing pool first
                if ([_controller importZFSPool:_controller.selectedDiskDevice]) {
                    success = [_controller performRestoreWithProgress:progressBlock];
                } else {
                    errorMessage = NSLocalizedString(@"Failed to import existing ZFS pool from the disk.", @"ZFS pool import error");
                }
                break;
                
            case BAOperationTypeDestroyAndRecreate:
                // First destroy existing pool, then create new one
                if ([_controller destroyExistingZFSPool:_controller.selectedDiskDevice]) {
                    if ([_controller createZFSPool:_controller.selectedDiskDevice]) {
                        success = [_controller performBackupWithProgress:progressBlock];
                    } else {
                        errorMessage = NSLocalizedString(@"Failed to create new ZFS pool after destroying the old one.", @"ZFS pool recreation error");
                    }
                } else {
                    errorMessage = NSLocalizedString(@"Failed to destroy existing ZFS pool on the disk.", @"ZFS pool destruction error");
                }
                break;
                
            case BAOperationTypeMountBackup:
                // Import existing pool first
                if ([_controller importZFSPool:_controller.selectedDiskDevice]) {
                    success = [_controller performMountBackupWithProgress:progressBlock];
                } else {
                    errorMessage = NSLocalizedString(@"Failed to import existing ZFS pool from the disk.", @"ZFS pool import error");
                }
                break;
                
            default:
                errorMessage = NSLocalizedString(@"Unknown operation type.", @"Unknown operation error");
                break;
        }
    } @catch (NSException *exception) {
        NSLog(@"ERROR: Operation failed with exception: %@", [exception reason]);
        errorMessage = [NSString stringWithFormat:NSLocalizedString(@"Operation failed: %@", @"Operation exception error"), [exception reason]];
    }
    
    NSDictionary *resultInfo = @{
        @"success": @(success),
        @"errorMessage": errorMessage ? errorMessage : @""
    };
    
    [self performSelectorOnMainThread:@selector(handleOperationResult:) 
                           withObject:resultInfo 
                        waitUntilDone:NO];
    
    [pool release];
}

- (void)updateProgressFromBackground:(NSDictionary *)progressInfo
{
    CGFloat progress = [[progressInfo objectForKey:@"progress"] floatValue];
    NSString *task = [progressInfo objectForKey:@"task"];
    
    [self updateProgress:progress withTask:task];
}

- (void)handleOperationResult:(NSDictionary *)resultInfo
{
    BOOL success = [[resultInfo objectForKey:@"success"] boolValue];
    NSString *errorMessage = [resultInfo objectForKey:@"errorMessage"];
    
    _operationInProgress = NO;
    
    if (success) {
        NSLog(@"BAProgressStep: Operation completed successfully");
        [self updateProgress:1.0 withTask:NSLocalizedString(@"Operation completed successfully", @"Success task message")];
        
        NSString *successMessage = @"";
        switch (_controller.selectedOperation) {
            case BAOperationTypeNewBackup:
                successMessage = NSLocalizedString(@"User home directories have been successfully backed up to the ZFS disk.", @"New backup success message");
                break;
            case BAOperationTypeUpdateBackup:
                successMessage = NSLocalizedString(@"The backup has been successfully updated with the latest changes.", @"Update backup success message");
                break;
            case BAOperationTypeRestoreBackup:
                successMessage = NSLocalizedString(@"Your selected files have been successfully restored from the backup.", @"Restore success message");
                break;
            case BAOperationTypeDestroyAndRecreate:
                successMessage = NSLocalizedString(@"The old backup has been destroyed and a new backup of home directories has been successfully created.", @"Destroy and recreate success message");
                break;
            case BAOperationTypeMountBackup:
                successMessage = NSLocalizedString(@"The backup has been successfully mounted and is now accessible.", @"Mount backup success message");
                break;
            default:
                successMessage = NSLocalizedString(@"The operation completed successfully.", @"Generic success message");
                break;
        }
        
        [_controller showOperationSuccess:successMessage];
        
        // Don't auto-advance - let the user see the success page
        NSLog(@"BAProgressStep: Operation completed successfully, staying on success page");
    } else {
        NSLog(@"BAProgressStep: Operation failed: %@", errorMessage);
        
        if (!errorMessage || [errorMessage length] == 0) {
            errorMessage = NSLocalizedString(@"The operation failed for an unknown reason.", @"Generic error message");
        }
        
        [_controller showOperationError:errorMessage];
    }
}

- (void)updateProgress:(CGFloat)progress withTask:(NSString *)currentTask
{
    CGFloat percentage = progress * 100.0;
    
    [_progressBar setDoubleValue:percentage];
    [_progressLabel setStringValue:[NSString stringWithFormat:@"%.0f%%", percentage]];
    
    if (currentTask && [currentTask length] > 0) {
        [_currentTaskLabel setStringValue:currentTask];
    }
    
    // Update the step's progress property for the framework
    self.progress = progress;
    
    NSLog(@"BAProgressStep: Progress update: %.1f%% - %@", percentage, currentTask);
}

- (BOOL)showsProgress
{
    return YES;
}

- (CGFloat)progressValue
{
    return self.progress;
}

- (NSString *)continueButtonTitle
{
    return NSLocalizedString(@"Finish", @"Finish button title");
}

@end
