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
    if (_downloader) { [_downloader release]; _downloader = nil; }
    if (_installer) { [_installer release]; _installer = nil; }
    if (_stepView) { [_stepView release]; _stepView = nil; }
    if (_progressBar) { [_progressBar release]; _progressBar = nil; }
    if (_statusLabel) { [_statusLabel release]; _statusLabel = nil; }
    if (_logView) { [_logView release]; _logView = nil; }
    if (_downloadPath) { [_downloadPath release]; _downloadPath = nil; }
    if (_currentTask) { [_currentTask release]; _currentTask = nil; }
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
    return NSLocalizedString(@"Installing Debian Runtime", @"");
}

- (NSString *)stepDescription
{
    return NSLocalizedString(@"Please wait while the runtime is downloaded and installed", @"");
}

- (NSView *)stepView
{
    if (!_stepView) {
        // View sized to the installer card content (354x204). We'll keep 12pt margins.
        _stepView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 354, 204)];
        
        // Status label (top)
        _statusLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(12, 170, 330, 16)];
        [_statusLabel setStringValue:NSLocalizedString(@"Preparing...", @"")]; 
        [_statusLabel setFont:[NSFont systemFontOfSize:12]];
        [_statusLabel setBezeled:NO];
        [_statusLabel setDrawsBackground:NO];
        [_statusLabel setEditable:NO];
        [_statusLabel setSelectable:NO];
        [_stepView addSubview:_statusLabel];
        
        // Progress bar
        _progressBar = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(12, 146, 330, 16)];
        [_progressBar setStyle:NSProgressIndicatorBarStyle];
        [_progressBar setIndeterminate:NO];
        [_progressBar setMinValue:0.0];
        [_progressBar setMaxValue:100.0];
        [_progressBar setDoubleValue:0.0];
        [_stepView addSubview:_progressBar];
        
        // Log view (monospaced, inside bordered scroll view)
        NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(12, 12, 330, 124)];
        [scrollView setHasVerticalScroller:YES];
        [scrollView setBorderType:NSBezelBorder];
        
        _logView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 310, 124)];
        [_logView setString:@"Ready to start installation...\n"]; 
        [_logView setEditable:NO];
        [_logView setFont:[NSFont fontWithName:@"Monaco" size:10]];
        
        [scrollView setDocumentView:_logView];
        [_stepView addSubview:scrollView];
        [scrollView release];
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
    return NSLocalizedString(@"Done", @"");
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
    
    _currentProgress = progress;
    if (task) {
        if (_currentTask) { [_currentTask release]; }
        _currentTask = [task copy];
    }
    
    // Update the internal progress bar
    if (_progressBar) {
        [_progressBar setDoubleValue:progress * 100.0];
        [_progressBar setNeedsDisplay:YES]; // Force redraw
    } else {
        NSLog(@"[DRIInstallationStep] *** ERROR: _progressBar is nil!");
    }
    
    // Update status label
    if (_statusLabel && task) {
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
    if (_selectedImageURL != url) {
        if (_selectedImageURL) { [_selectedImageURL release]; }
        _selectedImageURL = [url copy];
    }
    NSLog(@"DRIInstallationStep: set selected image URL: %@", url);
}

- (void)setController:(DRIController *)controller
{
    _controller = controller; // weak ref, owned by app
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
    if (_statusLabel) { [_statusLabel setStringValue:NSLocalizedString(@"Starting download...", @"")]; }
    
    // Create download path
    NSString *tmp = NSTemporaryDirectory();
    if (_downloadPath) { [_downloadPath release]; }
    _downloadPath = [[tmp stringByAppendingPathComponent:@"debian-runtime.img"] copy];
    
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
    if (_statusLabel) { [_statusLabel setStringValue:NSLocalizedString(@"Download completed, starting installation...", @"")]; }
    if (_progressBar) { [_progressBar setDoubleValue:80.0]; }
    
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
    if (_statusLabel) { [_statusLabel setStringValue:message]; }
    if (_progressBar) { [_progressBar setDoubleValue:85.0]; }
}

- (void)installer:(id)installer didUpdateProgress:(NSString *)message
{
    NSLog(@"DRIInstallationStep: installer progress: %@", message);
    [self logMessage:message]; 
    if (_statusLabel) { [_statusLabel setStringValue:message]; }
    
    // Update progress (installation is 80-100% of total progress)
    if (_progressBar) {
        double currentProgress = [_progressBar doubleValue];
        if (currentProgress < 95.0) {
            [_progressBar setDoubleValue:currentProgress + 2.0];
        }
    }
}

- (void)installer:(id)installer didCompleteSuccessfully:(BOOL)success withMessage:(NSString *)message
{
    NSLog(@"DRIInstallationStep: installer completed: %@ - %@", success ? @"SUCCESS" : @"FAILED", message);
    
    if (success) {
        [self logMessage:[NSString stringWithFormat:@"✓ %@", message]]; 
        if (_statusLabel) { [_statusLabel setStringValue:NSLocalizedString(@"Installation completed successfully!", @"")]; }
        if (_progressBar) { [_progressBar setDoubleValue:100.0]; }
        
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
    if (_statusLabel) { [_statusLabel setStringValue:NSLocalizedString(@"Installation failed", @"")]; }
    
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
    
    if (_logView) {
        [_logView insertText:logEntry];
        // Scroll to bottom
        NSRange range = NSMakeRange([[_logView string] length], 0);
        [_logView scrollRangeToVisible:range];
    }
    
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
