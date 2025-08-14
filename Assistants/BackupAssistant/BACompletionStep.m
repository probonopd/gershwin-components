//
// BACompletionStep.m
// Backup Assistant - Completion Step Implementation
//

#import "BACompletionStep.h"
#import "BAController.h"

@implementation BACompletionStep

@synthesize controller = _controller;

- (id)initWithController:(BAController *)controller
{
    NSView *completionView = [self createCompletionView];
    
    self = [super initWithTitle:NSLocalizedString(@"Operation Complete", @"Completion step title")
                    description:NSLocalizedString(@"The backup operation has finished", @"Completion step description")
                           view:completionView];
    
    if (self) {
        _controller = controller;
        self.stepType = GSAssistantStepTypeCompletion;
        self.canProceed = YES;
        self.canReturn = NO;
        self.wasSuccessful = YES;
    }
    
    return self;
}

- (NSView *)createCompletionView
{
    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 390, 240)];
    
    // Success/failure icon
    NSImageView *iconView = [[NSImageView alloc] initWithFrame:NSMakeRect(170, 180, 50, 50)];
    NSImage *icon = [NSImage imageNamed:NSImageNameInfo]; // We'll update this dynamically
    [iconView setImage:icon];
    [view addSubview:iconView];
    [iconView release];
    
    // Result message
    NSTextField *resultLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 140, 390, 30)];
    [resultLabel setBezeled:NO];
    [resultLabel setDrawsBackground:NO];
    [resultLabel setEditable:NO];
    [resultLabel setSelectable:NO];
    [resultLabel setFont:[NSFont boldSystemFontOfSize:14]];
    [resultLabel setAlignment:NSTextAlignmentCenter];
    [[resultLabel cell] setWraps:YES];
    [view addSubview:resultLabel];
    [resultLabel release];
    
    // Detailed information
    NSTextField *detailLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 90, 390, 40)];
    [detailLabel setBezeled:NO];
    [detailLabel setDrawsBackground:NO];
    [detailLabel setEditable:NO];
    [detailLabel setSelectable:NO];
    [detailLabel setFont:[NSFont systemFontOfSize:12]];
    [detailLabel setAlignment:NSTextAlignmentCenter];
    [[detailLabel cell] setWraps:YES];
    [view addSubview:detailLabel];
    [detailLabel release];
    
    // Next steps information
    NSTextField *nextStepsLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 40, 390, 40)];
    [nextStepsLabel setBezeled:NO];
    [nextStepsLabel setDrawsBackground:NO];
    [nextStepsLabel setEditable:NO];
    [nextStepsLabel setSelectable:NO];
    [nextStepsLabel setFont:[NSFont systemFontOfSize:11]];
    [nextStepsLabel setTextColor:[NSColor secondaryLabelColor]];
    [nextStepsLabel setAlignment:NSTextAlignmentCenter];
    [[nextStepsLabel cell] setWraps:YES];
    [view addSubview:nextStepsLabel];
    [nextStepsLabel release];
    
    // Disk safety reminder
    NSTextField *safetyLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 10, 390, 20)];
    [safetyLabel setStringValue:NSLocalizedString(@"You can now safely disconnect the backup disk.", @"Safety reminder")];
    [safetyLabel setBezeled:NO];
    [safetyLabel setDrawsBackground:NO];
    [safetyLabel setEditable:NO];
    [safetyLabel setSelectable:NO];
    [safetyLabel setFont:[NSFont systemFontOfSize:11]];
    [safetyLabel setTextColor:[NSColor systemGreenColor]];
    [safetyLabel setAlignment:NSTextAlignmentCenter];
    [view addSubview:safetyLabel];
    [safetyLabel release];
    
    return [view autorelease];
}

- (void)stepWillAppear
{
    NSLog(@"BACompletionStep: Step will appear");
    
    // Update the completion view based on operation result
    [self updateCompletionContent];
}

- (void)updateCompletionContent
{
    NSLog(@"BACompletionStep: Updating completion content");
    
    NSView *view = self.view;
    NSImageView *iconView = [[view subviews] objectAtIndex:0];
    NSTextField *resultLabel = [[view subviews] objectAtIndex:1];
    NSTextField *detailLabel = [[view subviews] objectAtIndex:2];
    NSTextField *nextStepsLabel = [[view subviews] objectAtIndex:3];
    NSTextField *safetyLabel = [[view subviews] objectAtIndex:4];
    
    if (_controller.operationSuccessful) {
        // Success case
        [iconView setImage:[NSImage imageNamed:@"NSMenuCheckmark"]];
        [resultLabel setStringValue:NSLocalizedString(@"Operation Completed Successfully!", @"Success result title")];
        [resultLabel setTextColor:[NSColor systemGreenColor]];
        
        NSString *detailMessage = @"";
        NSString *nextStepsMessage = @"";
        
        switch (_controller.selectedOperation) {
            case BAOperationTypeNewBackup:
                detailMessage = NSLocalizedString(@"Your home directory has been successfully backed up to the ZFS disk with snapshot protection.", @"New backup success detail");
                nextStepsMessage = NSLocalizedString(@"Store the backup disk in a safe place. You can use this assistant again to update the backup or restore files.", @"New backup next steps");
                break;
                
            case BAOperationTypeUpdateBackup:
                detailMessage = NSLocalizedString(@"The backup has been updated with your latest changes and a new snapshot has been created.", @"Update backup success detail");
                nextStepsMessage = NSLocalizedString(@"Your backup now contains the most recent version of your files with historical snapshots available.", @"Update backup next steps");
                break;
                
            case BAOperationTypeRestoreBackup:
                detailMessage = NSLocalizedString(@"The selected files have been successfully restored to your home directory from the backup.", @"Restore success detail");
                nextStepsMessage = NSLocalizedString(@"Check your restored files to ensure they are as expected. Original files may have been overwritten.", @"Restore next steps");
                break;
                
            default:
                detailMessage = NSLocalizedString(@"The backup operation completed without errors.", @"Generic success detail");
                nextStepsMessage = NSLocalizedString(@"You can close this assistant.", @"Generic next steps");
                break;
        }
        
        [detailLabel setStringValue:detailMessage];
        [nextStepsLabel setStringValue:nextStepsMessage];
        [safetyLabel setHidden:NO];
        
    } else {
        // Failure case
        [iconView setImage:[NSImage imageNamed:@"NSCaution"]];
        [resultLabel setStringValue:NSLocalizedString(@"Operation Failed", @"Failure result title")];
        [resultLabel setTextColor:[NSColor systemRedColor]];
        
        [detailLabel setStringValue:NSLocalizedString(@"The backup operation could not be completed. Please check the error messages and try again.", @"Failure detail message")];
        [nextStepsLabel setStringValue:NSLocalizedString(@"Ensure the disk is properly connected and has sufficient space, then restart the assistant.", @"Failure next steps")];
        [safetyLabel setHidden:YES];
    }
    
    self.wasSuccessful = _controller.operationSuccessful;
}

- (NSString *)continueButtonTitle
{
    return NSLocalizedString(@"Finish", @"Finish button title");
}

@end
