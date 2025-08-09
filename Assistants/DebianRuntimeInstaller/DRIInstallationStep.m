//
// DRIInstallationStep.m
// Debian Runtime Installer - Installation Step
//

#import "DRIInstallationStep.h"

@implementation DRIInstallationStep

- (instancetype)init
{
    if (self = [super init]) {
        NSLog(@"DRIInstallationStep: init");
        _downloader = [[DRIDownloader alloc] init];
        _downloader.delegate = self;
        _installer = [[DRIInstaller alloc] init];
        _installer.delegate = self;
        
        // Initialize progress tracking
        _installationCompleted = NO;
        _currentProgress = 0.0;
        _currentTask = @"";
    }
    return self;
}

- (void)dealloc
{
    NSLog(@"DRIInstallationStep: dealloc");
    [_downloader cancelDownload];
    [_installer cancelInstallation];
    [super dealloc];
}

- (void)cancel
{
    NSLog(@"DRIInstallationStep: cancel");
    [_downloader cancelDownload];
    [_installer cancelInstallation];
}

- (NSString *)stepTitle
{
    return @"Installing Debian Runtime";
}

- (NSString *)stepDescription
{
    return @"Please wait while the runtime is downloaded and installed";
}

- (NSView *)stepView
{
    if (!_stepView) {
        _stepView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 480, 320)];
        
        // Title label
        NSTextField *titleLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 280, 440, 24)];
        [titleLabel setStringValue:@"Installing Debian Runtime"];
        [titleLabel setFont:[NSFont boldSystemFontOfSize:16]];
        [titleLabel setBezeled:NO];
        [titleLabel setDrawsBackground:NO];
        [titleLabel setEditable:NO];
        [titleLabel setSelectable:NO];
        [_stepView addSubview:titleLabel];
        
        // Status label
        _statusLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 250, 440, 20)];
        [_statusLabel setStringValue:@"Preparing..."];
        [_statusLabel setFont:[NSFont systemFontOfSize:12]];
        [_statusLabel setBezeled:NO];
        [_statusLabel setDrawsBackground:NO];
        [_statusLabel setEditable:NO];
        [_statusLabel setSelectable:NO];
        [_stepView addSubview:_statusLabel];
        
        // Progress bar
        _progressBar = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(60, 220, 360, 20)];
        [_progressBar setStyle:NSProgressIndicatorBarStyle];
        [_progressBar setIndeterminate:NO];
        [_progressBar setMinValue:0.0];
        [_progressBar setMaxValue:100.0];
        [_progressBar setDoubleValue:0.0];
        [_stepView addSubview:_progressBar];
        
        // Log view
        NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(20, 40, 440, 160)];
        [scrollView setHasVerticalScroller:YES];
        [scrollView setBorderType:NSBezelBorder];
        
        _logView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 420, 160)];
        [_logView setString:@"Ready to start installation...\n"];
        [_logView setEditable:NO];
        [_logView setFont:[NSFont fontWithName:@"Monaco" size:10]];
        
        [scrollView setDocumentView:_logView];
        [_stepView addSubview:scrollView];
    }
    return _stepView;
}

- (BOOL)canContinue
{
    return NO; // Never allow continue during installation
}

- (BOOL)canGoBack
{
    return NO;
}

- (BOOL)showsProgress
{
    return YES;
}

- (NSString *)continueButtonTitle
{
    return _installationCompleted ? @"Done" : @"Continue";
}

- (NSString *)finishButtonTitle
{
    return @"Done";
}

- (BOOL)isLastStep
{
    return _installationCompleted;
}

- (GSAssistantStepType)stepType
{
    return GSAssistantStepTypeProgress;
}

- (CGFloat)progressValue
{
    return _currentProgress;
}

- (void)updateProgress:(CGFloat)progress withTask:(NSString *)task
{
    NSLog(@"[DRIInstallationStep] *** updateProgress called: %.1f%% task: %@", progress * 100.0, task);
    // NSLog(@"[DRIInstallationStep] *** _progressBar=%p _statusLabel=%p", _progressBar, _statusLabel);
    
    _currentProgress = progress;
    if (task) {
        _currentTask = [task copy];
    }
    
    // Update the internal progress bar
    if (_progressBar) {
        // NSLog(@"[DRIInstallationStep] *** Setting progress bar to %.1f%%", progress * 100.0);
        [_progressBar setDoubleValue:progress * 100.0];
        [_progressBar setNeedsDisplay:YES]; // Force redraw
    } else {
        NSLog(@"[DRIInstallationStep] *** ERROR: _progressBar is nil!");
    }
    
    // Update status label
    if (_statusLabel && task) {
        // NSLog(@"[DRIInstallationStep] *** Setting status label to: %@", task);
        [_statusLabel setStringValue:task];
        [_statusLabel setNeedsDisplay:YES]; // Force redraw
    } else if (!_statusLabel) {
        NSLog(@"[DRIInstallationStep] *** ERROR: _statusLabel is nil!");
    }
}

- (void)stepWillAppear
{
    NSLog(@"DRIInstallationStep: stepWillAppear");
    _installationCompleted = NO;
}

- (void)stepDidAppear
{
    NSLog(@"DRIInstallationStep: stepDidAppear - starting installation");
    [self performSelector:@selector(startInstallation) withObject:nil afterDelay:1.0];
}

- (void)setSelectedImageURL:(NSString *)url
{
    _selectedImageURL = url;
    NSLog(@"DRIInstallationStep: set selected image URL: %@", url);
}

- (void)setController:(DRIController *)controller
{
    _controller = controller;
    NSLog(@"DRIInstallationStep: set controller reference");
}

- (void)startInstallation
{
    NSLog(@"DRIInstallationStep: startInstallation");
    
    if (!_selectedImageURL || [_selectedImageURL length] == 0) {
        [self logMessage:@"✗ Error: No image URL provided"];
        [self installationFailed:@"No runtime image selected"];
        return;
    }
    
    [self logMessage:@"Starting Debian Runtime installation..."];
    [_statusLabel setStringValue:@"Starting download..."];
    
    // Create download path
    _downloadPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"debian-runtime.img"];
    
    [self logMessage:[NSString stringWithFormat:@"Downloading from: %@", _selectedImageURL]];
    [self logMessage:[NSString stringWithFormat:@"Temporary file: %@", _downloadPath]];
    
    // Start download
    [_downloader downloadFileFromURL:_selectedImageURL toPath:_downloadPath];
}

#pragma mark - DRIDownloaderDelegate

- (void)downloader:(id)downloader didStartDownloadWithExpectedSize:(long long)expectedSize
{
    NSLog(@"DRIInstallationStep: download started, expected size: %lld", expectedSize);
    [self logMessage:[NSString stringWithFormat:@"Download started, expected size: %@", [self formatFileSize:expectedSize]]];
    [self updateProgress:0.0 withTask:@"Downloading runtime image..."];
}

- (void)downloader:(id)downloader didUpdateProgress:(double)progress bytesDownloaded:(long long)bytesDownloaded
{
    // Download is 0-80% of total progress
    double overallProgress = progress * 0.8;
    
    NSString *statusText = [NSString stringWithFormat:@"Downloading... %.1f%% (%@)", 
                           progress * 100.0, [self formatFileSize:bytesDownloaded]];
    
    [self updateProgress:overallProgress withTask:statusText];
    
    if ((long long)(progress * 100) % 10 == 0) { // Log every 10%
        [self logMessage:[NSString stringWithFormat:@"Downloaded %.0f%%", progress * 100.0]];
    }
}

- (void)downloader:(id)downloader didCompleteWithFilePath:(NSString *)filePath
{
    NSLog(@"DRIInstallationStep: download completed: %@", filePath);
    [self logMessage:@"✓ Download completed successfully"];
    [_statusLabel setStringValue:@"Download completed, starting installation..."];
    [_progressBar setDoubleValue:80.0];
    
    // Start system installation
    [self startSystemInstallation];
}

- (void)downloader:(id)downloader didFailWithError:(NSError *)error
{
    NSLog(@"DRIInstallationStep: download failed: %@", error.localizedDescription);
    [self logMessage:[NSString stringWithFormat:@"✗ Download failed: %@", error.localizedDescription]];
    [self installationFailed:[NSString stringWithFormat:@"Download failed: %@", error.localizedDescription]];
}

- (void)startSystemInstallation
{
    NSLog(@"DRIInstallationStep: startSystemInstallation");
    [self logMessage:@"Starting system installation..."];
    [_installer installRuntimeFromImagePath:_downloadPath];
}

#pragma mark - DRIInstallerDelegate

- (void)installer:(id)installer didStartInstallationWithMessage:(NSString *)message
{
    NSLog(@"DRIInstallationStep: installer started: %@", message);
    [self logMessage:message];
    [_statusLabel setStringValue:message];
    [_progressBar setDoubleValue:85.0];
}

- (void)installer:(id)installer didUpdateProgress:(NSString *)message
{
    NSLog(@"DRIInstallationStep: installer progress: %@", message);
    [self logMessage:message];
    [_statusLabel setStringValue:message];
    
    // Update progress (installation is 80-100% of total progress)
    double currentProgress = [_progressBar doubleValue];
    if (currentProgress < 95.0) {
        [_progressBar setDoubleValue:currentProgress + 2.0];
    }
}

- (void)installer:(id)installer didCompleteSuccessfully:(BOOL)success withMessage:(NSString *)message
{
    NSLog(@"DRIInstallationStep: installer completed: %@ - %@", success ? @"SUCCESS" : @"FAILED", message);
    
    if (success) {
        [self logMessage:[NSString stringWithFormat:@"✓ %@", message]];
        [_statusLabel setStringValue:@"Installation completed successfully!"];
        [_progressBar setDoubleValue:100.0];
        
        // Clean up downloaded file
        if (_downloadPath && [[NSFileManager defaultManager] fileExistsAtPath:_downloadPath]) {
            [[NSFileManager defaultManager] removeItemAtPath:_downloadPath error:nil];
            [self logMessage:@"Temporary file cleaned up"];
        }
        
        [self logMessage:@"\n=== INSTALLATION COMPLETED SUCCESSFULLY ==="];
        [self logMessage:@"The Debian runtime is now installed and ready to use."];
        
        // Show success page via controller
        if (_controller) {
            [_controller showInstallationSuccess:@"Debian runtime has been installed successfully. You can now run Linux applications."];
        }
    } else {
        [self logMessage:[NSString stringWithFormat:@"✗ %@", message]];
        [self installationFailed:message];
    }
}

- (void)installationFailed:(NSString *)error
{
    NSLog(@"DRIInstallationStep: installation failed: %@", error);
    [self logMessage:[NSString stringWithFormat:@"\n=== INSTALLATION FAILED ===\nError: %@", error]];
    [_statusLabel setStringValue:@"Installation failed"];
    
    // Clean up downloaded file on failure
    if (_downloadPath && [[NSFileManager defaultManager] fileExistsAtPath:_downloadPath]) {
        [[NSFileManager defaultManager] removeItemAtPath:_downloadPath error:nil];
        [self logMessage:@"Temporary file cleaned up"];
    }
    
    // Show error page via controller
    if (_controller) {
        NSLog(@"DRIInstallationStep: calling controller showInstallationError");
        [_controller showInstallationError:error];
    } else {
        NSLog(@"DRIInstallationStep: ERROR - no controller reference to show error page");
    }
}

- (void)cancelInstallation
{
    NSLog(@"DRIInstallationStep: cancelInstallation called");
    
    // Cancel ongoing download
    if (_downloader && _downloader.isDownloading) {
        NSLog(@"DRIInstallationStep: canceling download");
        [_downloader cancelDownload];
        [self logMessage:@"Download canceled by user"];
    }
    
    // Cancel ongoing installation 
    if (_installer) {
        NSLog(@"DRIInstallationStep: canceling installation");
        [_installer cancelInstallation];
        [self logMessage:@"Installation canceled by user"];
    }
    
    // Clean up any temporary files
    if (_downloadPath && [[NSFileManager defaultManager] fileExistsAtPath:_downloadPath]) {
        NSError *error;
        if ([[NSFileManager defaultManager] removeItemAtPath:_downloadPath error:&error]) {
            NSLog(@"DRIInstallationStep: cleaned up temporary file: %@", _downloadPath);
            [self logMessage:@"Temporary files cleaned up"];
        } else {
            NSLog(@"DRIInstallationStep: failed to cleanup temporary file %@: %@", _downloadPath, error.localizedDescription);
        }
    }
    
    NSLog(@"DRIInstallationStep: cancellation complete");
}

- (void)notifyCompletion
{
    NSLog(@"DRIInstallationStep: notifyCompletion - user can proceed to next step");
    // The GSAssistantFramework will automatically detect canContinue change
}

- (void)logMessage:(NSString *)message
{
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    [formatter setDateFormat:@"HH:mm:ss"];
    NSString *timestamp = [formatter stringFromDate:[NSDate date]];
    NSString *logEntry = [NSString stringWithFormat:@"[%@] %@\n", timestamp, message];
    
    // Direct call since we're always on main thread in GNUstep
    [_logView insertText:logEntry];
    
    // Scroll to bottom
    NSRange range = NSMakeRange([[_logView string] length], 0);
    [_logView scrollRangeToVisible:range];
    
    [formatter release];
}

- (NSString *)formatFileSize:(long long)bytes
{
    if (bytes > 1000000000) {
        return [NSString stringWithFormat:@"%.1f GB", bytes / 1000000000.0];
    } else if (bytes > 1000000) {
        return [NSString stringWithFormat:@"%.1f MB", bytes / 1000000.0];
    } else {
        return [NSString stringWithFormat:@"%.1f KB", bytes / 1000.0];
    }
}

@end
