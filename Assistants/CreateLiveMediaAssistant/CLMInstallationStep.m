/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "CLMInstallationStep.h"
#import "CLMController.h"
#import "CLMDiskUtility.h"
#import "GSAssistantFramework.h"

@implementation CLMInstallationStep

@synthesize controller = _controller;

- (void)requestNavigationUpdate
{
    NSWindow *window = [[self stepView] window];
    if (!window) {
        window = [NSApp keyWindow];
    }
    NSWindowController *wc = [window windowController];
    if ([wc isKindOfClass:[GSAssistantWindow class]]) {
        NSDebugLLog(@"gwcomp", @"CLMInstallationStep: requesting navigation button update");
        GSAssistantWindow *assistantWindow = (GSAssistantWindow *)wc;
        [assistantWindow updateNavigationButtons];
    } else {
        NSDebugLLog(@"gwcomp", @"CLMInstallationStep: could not find GSAssistantWindow to update navigation (wc=%@)", wc);
    }
}

- (id)init
{
    if (self = [super init]) {
        NSDebugLLog(@"gwcomp", @"CLMInstallationStep: init");
        _installationInProgress = NO;
        _installationCompleted = NO;
        _installationSuccessful = NO;
        _opQueue = [[NSOperationQueue alloc] init];
        [_opQueue setName:@"com.gershwin.streamoperation"];
        [self setupView];
    }
    return self;
}

- (void)dealloc
{
    NSDebugLLog(@"gwcomp", @"CLMInstallationStep: dealloc");
    if (_streamOp) {
        [_streamOp cancel];
    }
    [_opQueue cancelAllOperations];
}

- (void)setupView
{
    NSDebugLLog(@"gwcomp", @"CLMInstallationStep: setupView");

    _stepView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 354, 204)];

    _statusLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(12, 160, 330, 34)];
    [_statusLabel setStringValue:NSLocalizedString(@"Preparing to download and write Live medium...", @"")];
    [_statusLabel setFont:[NSFont boldSystemFontOfSize:13]];
    [_statusLabel setAlignment:NSCenterTextAlignment];
    [_statusLabel setBezeled:NO];
    [_statusLabel setDrawsBackground:NO];
    [_statusLabel setEditable:NO];
    [_statusLabel setSelectable:NO];
    [[_statusLabel cell] setWraps:YES];
    [_stepView addSubview:_statusLabel];

    _progressBar = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(32, 118, 290, 18)];
    [_progressBar setStyle:NSProgressIndicatorBarStyle];
    [_progressBar setIndeterminate:NO];
    [_progressBar setMinValue:0.0];
    [_progressBar setMaxValue:100.0];
    [_progressBar setDoubleValue:0.0];
    [_stepView addSubview:_progressBar];

    _etaLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(32, 92, 290, 18)];
    [_etaLabel setStringValue:@""];
    [_etaLabel setAlignment:NSCenterTextAlignment];
    [_etaLabel setBezeled:NO];
    [_etaLabel setDrawsBackground:NO];
    [_etaLabel setEditable:NO];
    [_etaLabel setSelectable:NO];
    [_etaLabel setFont:[NSFont systemFontOfSize:11]];
    [_etaLabel setTextColor:[NSColor grayColor]];
    [_stepView addSubview:_etaLabel];

    _progressLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(32, 66, 290, 18)];
    [_progressLabel setStringValue:@""];
    [_progressLabel setAlignment:NSCenterTextAlignment];
    [_progressLabel setBezeled:NO];
    [_progressLabel setDrawsBackground:NO];
    [_progressLabel setEditable:NO];
    [_progressLabel setSelectable:NO];
    [_progressLabel setFont:[NSFont systemFontOfSize:10]];
    [_progressLabel setTextColor:[NSColor grayColor]];
    [_stepView addSubview:_progressLabel];

}

- (void)startInstallation
{
    NSDebugLLog(@"gwcomp", @"CLMInstallationStep: startInstallation");

    [_controller stopDiskPolling];

    if (_installationInProgress) {
        NSDebugLLog(@"gwcomp", @"CLMInstallationStep: Installation already in progress");
        return;
    }

    _installationInProgress = YES;
    _installationCompleted = NO;
    _installationSuccessful = NO;

    [_statusLabel setStringValue:NSLocalizedString(@"Unmounting partitions...", @"")];
    [_progressLabel setStringValue:@""];
    [_progressBar setDoubleValue:0.0];

    BOOL unmountSuccess = [CLMDiskUtility unmountPartitionsForDisk:_controller.selectedDiskDevice];
    if (!unmountSuccess) {
        [self installationCompletedWithSuccess:NO error:NSLocalizedString(@"Could not unmount partitions on the target device.", @"")];
        return;
    }

    NSString *devicePath = [NSString stringWithFormat:@"/dev/%@", _controller.selectedDiskDevice];

    // Check device exists
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:devicePath]) {
        [self installationCompletedWithSuccess:NO
                                         error:[NSString stringWithFormat:
                                                   NSLocalizedString(@"Device %@ does not exist", @""),
                                                   devicePath]];
        return;
    }

    NSURL *url = [NSURL URLWithString:_controller.selectedImageURL];
    if (!url) {
        [self installationCompletedWithSuccess:NO error:NSLocalizedString(@"Invalid download URL", @"")];
        return;
    }

    CLMStreamContentType contentType = [CLMStreamOperation contentTypeForURL:url];
    NSString *fname = [_controller.selectedImageName lastPathComponent];
    if ([[url scheme] isEqualToString:@"file"]) {
        [_statusLabel setStringValue:[NSString stringWithFormat:
            NSLocalizedString(@"Writing %@...", @""), fname]];
    } else if (contentType == CLMStreamContentTypeCompressed) {
        [_statusLabel setStringValue:[NSString stringWithFormat:
            NSLocalizedString(@"Downloading, decompressing and writing %@...", @""), fname]];
    } else {
        [_statusLabel setStringValue:[NSString stringWithFormat:
            NSLocalizedString(@"Downloading and writing %@...", @""), fname]];
    }

    _streamOp = [[CLMStreamOperation alloc] initWithURL:url devicePath:devicePath];
    [_streamOp setDelegate:self];
    [_opQueue addOperation:_streamOp];
}

#pragma mark - CLMStreamOperationDelegate

- (void)streamOperation:(CLMStreamOperation *)op
       progressUpdated:(float)progress
          bytesReceived:(int64_t)bytes
            totalBytes:(int64_t)total
{
    if (_downloadStartTime == 0) {
        _downloadStartTime = [NSDate timeIntervalSinceReferenceDate];
        _lastUIUpdateTime = _downloadStartTime;
    }

    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if ((now - _lastUIUpdateTime) < 0.5 && progress < 1.0f) {
        return;
    }
    _lastUIUpdateTime = now;

    float percent = progress * 100.0;
    [_progressBar setDoubleValue:percent];
    [_progressBar setNeedsDisplay:YES];

    // Data downloaded label
    NSString *dataStr = @"";
    if (total > 0 && bytes > 0) {
        NSString *receivedStr = [CLMDiskUtility formatSize:bytes];
        NSString *totalStr = [CLMDiskUtility formatSize:total];
        dataStr = [NSString stringWithFormat:NSLocalizedString(@"%@ of %@", @""),
                          receivedStr, totalStr];
    } else if (bytes > 0) {
        NSString *receivedStr = [CLMDiskUtility formatSize:bytes];
        dataStr = [NSString stringWithFormat:NSLocalizedString(@"%@ received", @""),
                           receivedStr];
    }
    [_progressLabel setStringValue:dataStr];

    // ETA label using InstallationAssistant-style wording
    if (total > 0 && bytes > 0) {
        NSTimeInterval elapsed = now - _downloadStartTime;
        double pct = (double)bytes / (double)total * 100.0;

        if (pct < 2.0 || elapsed < 10.0) {
            [_etaLabel setStringValue:NSLocalizedString(@"Estimating time remaining...", @"")];
        } else {
            double rate = pct / elapsed;
            if (rate < 0.001) {
                [_etaLabel setStringValue:NSLocalizedString(@"Estimating time remaining...", @"")];
            } else {
                double remaining = (100.0 - pct) / rate;
                int secs = (int)remaining;

                NSString *etaStr;
                if (secs > 7200) {
                    int hours = secs / 3600;
                    int mins = (secs % 3600) / 60;
                    etaStr = [NSString stringWithFormat:
                        NSLocalizedString(@"About %d hours and %d minutes remaining", @""),
                        hours, mins];
                } else if (secs > 120) {
                    int mins = (secs + 30) / 60;
                    etaStr = [NSString stringWithFormat:
                        NSLocalizedString(@"About %d minutes remaining", @""), mins];
                } else if (secs > 60) {
                    etaStr = NSLocalizedString(@"About a minute remaining", @"");
                } else {
                    etaStr = NSLocalizedString(@"Less than a minute remaining", @"");
                }
                [_etaLabel setStringValue:etaStr];
            }
        }
    } else {
        [_etaLabel setStringValue:@""];
    }
}

- (void)streamOperation:(CLMStreamOperation *)op
          statusUpdated:(NSString *)status
{
    [_statusLabel setStringValue:status];
}

- (void)streamOperation:(CLMStreamOperation *)op
     didCompleteWithError:(NSError *)error
{
    _streamOp = nil;
    [self installationCompletedWithSuccess:(error == nil)
                                     error:[error localizedDescription]];
}

#pragma mark - Installation Completion

- (void)installationCompletedWithSuccess:(BOOL)success error:(NSString *)error
{
    NSDebugLLog(@"gwcomp", @"CLMInstallationStep: installationCompletedWithSuccess: %d", success);

    _installationInProgress = NO;
    _installationCompleted = YES;
    _installationSuccessful = success;

    if (success) {
        [_statusLabel setStringValue:NSLocalizedString(@"Live medium created successfully!", @"")];
        [_progressBar setDoubleValue:100.0];
        [_progressLabel setStringValue:NSLocalizedString(@"Installation completed", @"")];
        [_controller showInstallationSuccess:NSLocalizedString(@"Live medium has been created successfully!", @"")];
        [self requestNavigationUpdate];
    } else {
        [_statusLabel setStringValue:NSLocalizedString(@"Installation failed", @"")];
        [_progressLabel setStringValue:error ? error : NSLocalizedString(@"Unknown error occurred", @"")];
        [_progressBar setHidden:YES];
        [_progressLabel setHidden:YES];
        [_infoLabel setHidden:YES];
        [_controller showInstallationError:error ? error : NSLocalizedString(@"Unknown error occurred", @"")];
    }
}

#pragma mark - GSAssistantStepProtocol

- (NSString *)stepTitle
{
    return NSLocalizedString(@"Write Live Medium", @"");
}

- (NSString *)stepDescription
{
    return NSLocalizedString(@"Downloading and writing the Live image to the selected device. This may take some time depending on the image size and network speed.", @"");
}

- (NSView *)stepView
{
    return _stepView;
}

- (BOOL)canContinue
{
    return _installationCompleted && _installationSuccessful;
}

- (void)stepWillAppear
{
    NSDebugLLog(@"gwcomp", @"CLMInstallationStep: stepWillAppear");
    [_controller stopDiskPolling];
}

- (void)stepDidAppear
{
    NSDebugLLog(@"gwcomp", @"CLMInstallationStep: stepDidAppear");
    [self performSelector:@selector(startInstallation) withObject:nil afterDelay:0.5];
}

- (void)stepWillDisappear
{
    NSDebugLLog(@"gwcomp", @"CLMInstallationStep: stepWillDisappear");
}

@end
