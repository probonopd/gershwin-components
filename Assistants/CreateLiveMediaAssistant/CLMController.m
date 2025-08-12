//
// CLMController.m
// Create Live Media Assistant - Main Controller
//

#import "CLMController.h"
#import "CLMIntroStep.h"
#import "CLMImageSelectionStep.h"
#import "CLMDiskSelectionStep.h"
#import "CLMInstallationStep.h"
#import "CLMCompletionStep.h"

@interface CLMController()
@property (nonatomic, strong) CLMIntroStep *introStep;
@property (nonatomic, strong) CLMImageSelectionStep *imageSelectionStep;
@property (nonatomic, strong) CLMDiskSelectionStep *diskSelectionStep;
@property (nonatomic, strong) CLMInstallationStep *installationStep;
@property (nonatomic, strong) CLMCompletionStep *completionStep;
@end

@implementation CLMController

@synthesize selectedImageURL = _selectedImageURL;
@synthesize selectedImageName = _selectedImageName;
@synthesize selectedImageSize = _selectedImageSize;
@synthesize selectedDiskDevice = _selectedDiskDevice;
@synthesize userAgreedToErase = _userAgreedToErase;
@synthesize installationSuccessful = _installationSuccessful;
@synthesize availableRepositories = _availableRepositories;
@synthesize availableReleases = _availableReleases;
@synthesize showPrereleases = _showPrereleases;

- (id)init
{
    if (self = [super init]) {
        NSLog(@"CLMController: init");
        _selectedImageURL = @"";
        _selectedImageName = @"";
        _selectedImageSize = 0;
        _selectedDiskDevice = @"";
        _userAgreedToErase = NO;
        _installationSuccessful = NO;
        _showPrereleases = NO;
        
        // Initialize available repositories
        _availableRepositories = [[NSArray alloc] initWithObjects:
            @"https://api.github.com/repos/probonopd/ghostbsd-builder/releases",
            @"https://api.github.com/repos/ventoy/Ventoy/releases",
            nil];
        
        _availableReleases = [[NSArray alloc] init];
    }
    return self;
}

- (void)dealloc
{
    NSLog(@"CLMController: dealloc");
    [_assistantWindow release];
    [_selectedImageURL release];
    [_selectedImageName release];
    [_selectedDiskDevice release];
    [_availableRepositories release];
    [_availableReleases release];
    [super dealloc];
}

- (void)showAssistant
{
    NSLog(@"CLMController: showAssistant");
    
    // Create step views
    _introStep = [[CLMIntroStep alloc] init];
    _imageSelectionStep = [[CLMImageSelectionStep alloc] init];
    [_imageSelectionStep setController:self];
    _diskSelectionStep = [[CLMDiskSelectionStep alloc] init];
    [_diskSelectionStep setController:self];
    _installationStep = [[CLMInstallationStep alloc] init];
    [_installationStep setController:self];
    _completionStep = [[CLMCompletionStep alloc] init];
    
    // Build the assistant using the builder
    GSAssistantBuilder *builder = [GSAssistantBuilder builder];
    [builder withLayoutStyle:GSAssistantLayoutStyleInstaller];
    [builder withTitle:NSLocalizedString(@"Create Live Media", @"Application title")];
    [builder withIcon:[NSImage imageNamed:@"Create_Live_Media"]];
    
    // Add configuration steps directly (not wrapped)
    [builder addStep:_imageSelectionStep];
    [builder addStep:_diskSelectionStep];
    
    // Add our custom installation step with progress
    [builder addStep:_installationStep];
    
    // Add completion
    [builder addCompletionWithMessage:@"Live medium has been created successfully!"
           success:YES];
    
    // Build and show
    _assistantWindow = [builder build];
    [_assistantWindow setDelegate:self];
    [[_assistantWindow window] makeKeyAndOrderFront:nil];
}

#pragma mark - Helper Methods

- (BOOL)checkInternetConnection
{
    NSLog(@"CLMController: checkInternetConnection");
    return [GSNetworkUtilities checkInternetConnectivity];
}

- (long long)requiredDiskSpaceInMiB
{
    return (_selectedImageSize / (1024 * 1024));
}

#pragma mark - Disk Polling Control

- (void)stopDiskPolling
{
    NSLog(@"CLMController: stopDiskPolling - failsafe to stop any running disk polling");
    if (_diskSelectionStep) {
        NSLog(@"CLMController: Calling stopRefreshTimer on diskSelectionStep");
        [_diskSelectionStep stopRefreshTimer];
    } else {
        NSLog(@"CLMController: diskSelectionStep is nil, cannot stop timer");
    }
}

#pragma mark - Success and Error Handling

- (void)showInstallationSuccess:(NSString *)message
{
    NSLog(@"CLMController: showInstallationSuccess: %@", message);
    _installationSuccessful = YES;
    // The success will be handled by the completion step
}

- (void)showInstallationError:(NSString *)message
{
    NSLog(@"CLMController: showInstallationError: %@", message);
    _installationSuccessful = NO;
    
    // Ensure we're on the main thread for UI updates
    if (![NSThread isMainThread]) {
        [self performSelectorOnMainThread:@selector(showInstallationError:) 
                               withObject:message 
                            waitUntilDone:NO];
        return;
    }
    
    // Try to navigate to error page with red X graphic
    if ([_assistantWindow respondsToSelector:@selector(showErrorPageWithTitle:message:)]) {
        NSLog(@"CLMController: calling showErrorPageWithTitle:message:");
        [_assistantWindow showErrorPageWithTitle:NSLocalizedString(@"Installation Failed", @"Error title") message:message];
    } else if ([_assistantWindow respondsToSelector:@selector(showErrorPageWithMessage:)]) {
        NSLog(@"CLMController: calling showErrorPageWithMessage:");
        [_assistantWindow showErrorPageWithMessage:message];
    } else {
        NSLog(@"CLMController: assistant window doesn't respond to error page methods, showing alert");
        // Fallback to alert if error page methods are not available
        NSAlert *alert = [NSAlert alertWithMessageText:@"Installation Error"
                                      defaultButton:@"OK"
                                      alternateButton:nil
                                      otherButton:nil
                                      informativeTextWithFormat:@"%@", message];
        [alert runModal];
    }
}

#pragma mark - GSAssistantWindowDelegate

- (void)assistantWindowWillFinish:(GSAssistantWindow *)window
{
    NSLog(@"CLMController: assistantWindowWillFinish");
}

- (void)assistantWindowDidFinish:(GSAssistantWindow *)window
{
    NSLog(@"CLMController: assistantWindowDidFinish");
    [[window window] close];
    [NSApp terminate:nil];
}

- (void)assistantWindowDidCancel:(GSAssistantWindow *)window
{
    NSLog(@"CLMController: assistantWindowDidCancel");
    [[window window] close];
    [NSApp terminate:nil];
}

@end
