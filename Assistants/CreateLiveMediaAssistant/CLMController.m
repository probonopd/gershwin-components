/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */


//
// CLMController.m
// Create Live Media Assistant - Main Controller
//

#import "CLMController.h"
#import "CLMConstants.h"
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
        NSDebugLLog(@"gwcomp", @"CLMController: init");
        _selectedImageURL = @"";
        _selectedImageName = @"";
        _selectedImageSize = 0;
        _selectedDiskDevice = @"";
        _userAgreedToErase = NO;
        _installationSuccessful = NO;
        _showPrereleases = NO;
        
        // Initialize available repositories (single source of truth)
        _availableRepositories = CLMAvailableRepositories();
        
        _availableReleases = [[NSArray alloc] init];
    }
    return self;
}

- (void)showAssistant
{
    NSDebugLLog(@"gwcomp", @"CLMController: showAssistant");
    
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
    [builder withTitle:NSLocalizedString(@"Create Live Media", @"Application title")];
    NSImage *icon = [NSApp applicationIconImage];
    if (!icon) {
        icon = [NSImage imageNamed:@"Create_Live_Media"];
    }
    [builder withIcon:icon];
    
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
    NSDebugLLog(@"gwcomp", @"CLMController: checkInternetConnection");
    return [GSNetworkUtilities checkInternetConnectivity];
}

- (long long)requiredDiskSpaceInMiB
{
    return (_selectedImageSize / (1024 * 1024));
}

#pragma mark - Disk Polling Control

- (void)stopDiskPolling
{
    NSDebugLLog(@"gwcomp", @"CLMController: stopDiskPolling - failsafe to stop any running disk polling");
    if (_diskSelectionStep) {
        NSDebugLLog(@"gwcomp", @"CLMController: Calling stopRefreshTimer on diskSelectionStep");
        [_diskSelectionStep stopRefreshTimer];
    } else {
        NSDebugLLog(@"gwcomp", @"CLMController: diskSelectionStep is nil, cannot stop timer");
    }
}

#pragma mark - Success and Error Handling

- (void)showInstallationSuccess:(NSString *)message
{
    NSDebugLLog(@"gwcomp", @"CLMController: showInstallationSuccess: %@", message);
    _installationSuccessful = YES;

    [_assistantWindow showSuccessPageWithTitle:NSLocalizedString(@"Installation Complete", @"")
                                      message:message];
}

- (void)showInstallationError:(NSString *)message
{
    NSDebugLLog(@"gwcomp", @"CLMController: showInstallationError: %@", message);
    _installationSuccessful = NO;
    
    // Ensure we're on the main thread for UI updates
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showInstallationError:message];
        });
        return;
    }
    
    // Try to navigate to error page with red X graphic
    if ([_assistantWindow respondsToSelector:@selector(showErrorPageWithTitle:message:)]) {
        NSDebugLLog(@"gwcomp", @"CLMController: calling showErrorPageWithTitle:message:");
        [_assistantWindow showErrorPageWithTitle:NSLocalizedString(@"Installation Failed", @"Error title") message:message];
    } else if ([_assistantWindow respondsToSelector:@selector(showErrorPageWithMessage:)]) {
        NSDebugLLog(@"gwcomp", @"CLMController: calling showErrorPageWithMessage:");
        [_assistantWindow showErrorPageWithMessage:message];
    } else {
        NSDebugLLog(@"gwcomp", @"CLMController: assistant window doesn't respond to error page methods, showing alert");
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
    NSDebugLLog(@"gwcomp", @"CLMController: assistantWindowWillFinish");
}

- (void)assistantWindowDidFinish:(GSAssistantWindow *)window
{
    NSDebugLLog(@"gwcomp", @"CLMController: assistantWindowDidFinish");
    [[window window] close];
    [NSApp terminate:nil];
}

- (void)assistantWindowDidCancel:(GSAssistantWindow *)window
{
    NSDebugLLog(@"gwcomp", @"CLMController: assistantWindowDidCancel");
    [[window window] close];
    [NSApp terminate:nil];
}

@end
