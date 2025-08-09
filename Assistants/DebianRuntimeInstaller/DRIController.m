//
// DRIController.m
// Debian Runtime Installer - Main Controller
//

#import "DRIController.h"
#import <GSAssistantUtilities.h>
#import "DRIIntroStep.h"
#import "DRIImageSelectionStep.h"
#import "DRIInstallationStep.h"
#import "DRICompletionStep.h"

@interface DRIController()
@property (nonatomic, strong) DRIIntroStep *introStep;
@property (nonatomic, strong) DRIImageSelectionStep *imageSelectionStep;
@property (nonatomic, strong) DRIInstallationStep *installationStep;
@property (nonatomic, strong) DRICompletionStep *completionStep;
@end

@implementation DRIController

- (id)init
{
    if (self = [super init]) {
        NSLog(@"DRIController: init");
        _selectedImageURL = @"";
        _selectedImageName = @"";
        _selectedImageSize = 0;
        _installationSuccessful = NO;
    }
    return self;
}

- (void)dealloc
{
    NSLog(@"DRIController: dealloc");
    [_assistantWindow release];
    [super dealloc];
}

- (void)showAssistant
{
    NSLog(@"DRIController: showAssistant");
    
    // Create step views
    _introStep = [[DRIIntroStep alloc] init];
    _imageSelectionStep = [[DRIImageSelectionStep alloc] init];
    // Removed _confirmationStep - no longer needed
    _installationStep = [[DRIInstallationStep alloc] init];
    [_installationStep setController:self];  // Set controller reference
    _completionStep = [[DRICompletionStep alloc] init];
    
    // Build the assistant using the builder
    GSAssistantBuilder *builder = [GSAssistantBuilder builder];
    [builder withLayoutStyle:GSAssistantLayoutStyleInstaller];
    [builder withTitle:@"Debian Runtime Installer"];
    [builder withIcon:[NSImage imageNamed:@"NSApplicationIcon"]];
    
    // Add introduction
    [builder addIntroductionWithMessage:@"This assistant will help you install a Debian runtime environment on your FreeBSD system."
             features:@[@"Downloads runtime images from GitHub releases",
                       @"Supports custom image URLs", 
                       @"Configures Linux compatibility layer",
                       @"Sets up automatic service startup"]];
    
    // Add configuration steps directly (not wrapped)
    [builder addStep:_imageSelectionStep];
    
    // Removed confirmation step - go directly to installation
    
    // Add our custom installation step with progress
    [builder addStep:_installationStep];
    
    // Add completion
    [builder addCompletionWithMessage:@"Debian runtime has been installed successfully!"
           success:YES];
    
    // Build and show
    _assistantWindow = [builder build];
    [_assistantWindow setDelegate:self];
    [[_assistantWindow window] makeKeyAndOrderFront:nil];
}

#pragma mark - GSAssistantWindowDelegate

- (void)assistantWindowWillFinish:(GSAssistantWindow *)window
{
    NSLog(@"DRIController: assistantWindowWillFinish");
}

- (void)assistantWindowDidFinish:(GSAssistantWindow *)window
{
    NSLog(@"DRIController: assistantWindowDidFinish");
    [[window window] close];
    [NSApp terminate:nil];
}

- (void)assistantWindowDidCancel:(GSAssistantWindow *)window
{
    NSLog(@"DRIController: assistantWindowDidCancel");
    
    // Cancel any ongoing installations
    if (_installationStep) {
        [_installationStep cancel];
    }
    
    // Show cancellation message
    [self showInstallationError:@"Installation was cancelled by the user. Any temporary files have been cleaned up."];
}

// Step navigation delegate methods
- (void)assistantWindow:(GSAssistantWindow *)window willShowStep:(id<GSAssistantStepProtocol>)step
{
    NSLog(@"DRIController: willShowStep: %@", [step stepTitle]);
    
    // If going to installation step, pass the selected image URL
    if ([step isKindOfClass:[DRIInstallationStep class]]) {
        NSString *selectedURL = [_imageSelectionStep getSelectedImageURL];
        NSLog(@"DRIController: transferring selected URL to installation step: %@", selectedURL);
        [(DRIInstallationStep *)step setSelectedImageURL:selectedURL];
    }
}

- (void)assistantWindow:(GSAssistantWindow *)window didShowStep:(id<GSAssistantStepProtocol>)step
{
    NSLog(@"DRIController: didShowStep: %@", [step stepTitle]);
    
    // Trigger loading when the image selection step appears
    if ([[step stepTitle] isEqualToString:@"Select Runtime Image"]) {
        NSLog(@"DRIController: Image selection step appeared, triggering load");
        [_imageSelectionStep stepWillAppear];
        NSLog(@"DRIController: stepWillAppear called");
    } else {
        NSLog(@"DRIController: Step is not image selection step (title: %@)", [step stepTitle]);
    }
}

- (BOOL)assistantWindow:(GSAssistantWindow *)window shouldCancelWithConfirmation:(BOOL)showConfirmation
{
    if (showConfirmation) {
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:@"Cancel Installation?"];
        [alert setInformativeText:@"Are you sure you want to cancel the installation? Any downloads in progress will be stopped and temporary files will be cleaned up."];
        [alert addButtonWithTitle:@"Cancel Installation"];
        [alert addButtonWithTitle:@"Continue Installation"];
        [alert setAlertStyle:NSWarningAlertStyle];
        
        NSModalResponse response = [alert runModal];
        [alert release];
        
        if (response == NSAlertFirstButtonReturn) {
            // User confirmed cancellation - clean up
            NSLog(@"DRIController: User confirmed cancellation, cleaning up...");
            if (_installationStep) {
                [_installationStep cancel];
            }
            
            // Show cancellation error page instead of just returning YES
            [self showInstallationError:@"Installation was cancelled by the user. Any temporary files have been cleaned up."];
            return NO; // Don't close the assistant, let the error page handle it
        }
        return NO;
    }
    return YES;
}

#pragma mark - Success and Error Handling

- (void)showInstallationSuccess:(NSString *)message
{
    NSLog(@"DRIController: showInstallationSuccess: %@", message);
    
    // Ensure we're on the main thread for UI updates
    if (![NSThread isMainThread]) {
        [self performSelectorOnMainThread:@selector(showInstallationSuccess:) 
                               withObject:message 
                            waitUntilDone:NO];
        return;
    }
    
    [_assistantWindow showSuccessPageWithTitle:@"Installation Complete" message:message];
}

- (void)showInstallationError:(NSString *)message
{
    NSLog(@"DRIController: showInstallationError: %@", message);
    
    // Ensure we're on the main thread for UI updates
    if (![NSThread isMainThread]) {
        [self performSelectorOnMainThread:@selector(showInstallationError:) 
                               withObject:message 
                            waitUntilDone:NO];
        return;
    }
    
    // Try multiple approaches to show the error
    if ([_assistantWindow respondsToSelector:@selector(showErrorPageWithTitle:message:)]) {
        NSLog(@"DRIController: calling showErrorPageWithTitle:message:");
        [_assistantWindow showErrorPageWithTitle:@"Installation Failed" message:message];
    } else if ([_assistantWindow respondsToSelector:@selector(showErrorPageWithMessage:)]) {
        NSLog(@"DRIController: calling showErrorPageWithMessage:");
        [_assistantWindow showErrorPageWithMessage:message];
    } else {
        NSLog(@"DRIController: assistant window doesn't respond to error page methods, showing alert");
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:@"Installation Failed"];
        [alert setInformativeText:message];
        [alert addButtonWithTitle:@"OK"];
        [alert setAlertStyle:NSCriticalAlertStyle];
        [alert runModal];
        [alert release];
    }
}

@end
