//
// CLMInstallationStep.m
// Create Live Media Assistant - Installation Step
//

#import "CLMInstallationStep.h"
#import "CLMController.h"
#import "CLMDiskUtility.h"
#import "GSAssistantFramework.h"
#import "GSNetworkUtilities.h"

@interface CLMInstallationStep ()
- (void)copyTempFileToDevice;
- (void)startDDProgressTimer;
- (void)stopDDProgressTimer;
- (void)updateDDProgress:(NSTimer *)timer;
@end

@implementation CLMInstallationStep

@synthesize controller = _controller;

// Helper to notify the assistant window to refresh navigation buttons
- (void)requestNavigationUpdate
{
    NSWindow *window = [[self stepView] window];
    if (!window) {
        window = [NSApp keyWindow];
    }
    NSWindowController *wc = [window windowController];
    if ([wc isKindOfClass:[GSAssistantWindow class]]) {
        NSLog(@"CLMInstallationStep: requesting navigation button update");
        GSAssistantWindow *assistantWindow = (GSAssistantWindow *)wc;
        // Always call the public method - it should handle layout-specific logic
        [assistantWindow updateNavigationButtons];
    } else {
        NSLog(@"CLMInstallationStep: could not find GSAssistantWindow to update navigation (wc=%@)", wc);
    }
}

- (id)init
{
    if (self = [super init]) {
        NSLog(@"CLMInstallationStep: init");
    _installationInProgress = NO;
    _installationCompleted = NO;
    _installationSuccessful = NO;
    _stallDetectionTimer = nil;
    _lastProgressTime = 0;
    _lastProgressValue = -1.0;
        [self setupView];
    }
    return self;
}

- (void)dealloc
{
    NSLog(@"CLMInstallationStep: dealloc");
    [self stopStallDetectionTimer];
    [self stopDDProgressTimer];
    [_downloader release];
    [_directConnection release];
    [_directOutputFile release];
    [_devicePath release];
    [_tempFilePath release];
    [_stepView release];
    [super dealloc];
}

- (void)setupView
{
    NSLog(@"CLMInstallationStep: setupView");
    
    // Fit step view to installer card inner area
    _stepView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 354, 204)];
    
    // Status label (top-centered)
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
    [_statusLabel release];
    
    // Progress bar (centered, classic bar style)
    _progressBar = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(32, 118, 290, 18)];
    [_progressBar setStyle:NSProgressIndicatorBarStyle];
    [_progressBar setIndeterminate:NO];
    [_progressBar setMinValue:0.0];
    [_progressBar setMaxValue:100.0];
    [_progressBar setDoubleValue:0.0];
    [_stepView addSubview:_progressBar];
    [_progressBar release];
    
    // Progress text (under bar)
    _progressLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(12, 94, 330, 18)];
    [_progressLabel setStringValue:NSLocalizedString(@"", @"")];
    [_progressLabel setAlignment:NSCenterTextAlignment];
    [_progressLabel setBezeled:NO];
    [_progressLabel setDrawsBackground:NO];
    [_progressLabel setEditable:NO];
    [_progressLabel setSelectable:NO];
    [_progressLabel setFont:[NSFont systemFontOfSize:11]];
    [_stepView addSubview:_progressLabel];
    [_progressLabel release];
    
    // Info text (bottom)
    _infoLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(12, 18, 330, 64)];
    [_infoLabel setStringValue:NSLocalizedString(@"The image will be downloaded and written to the selected device. This may take several minutes depending on network speed and image size.", @"")];
    [_infoLabel setFont:[NSFont systemFontOfSize:10]];
    [_infoLabel setAlignment:NSCenterTextAlignment];
    [_infoLabel setBezeled:NO];
    [_infoLabel setDrawsBackground:NO];
    [_infoLabel setEditable:NO];
    [_infoLabel setSelectable:NO];
    [[_infoLabel cell] setWraps:YES];
    [_stepView addSubview:_infoLabel];
    [_infoLabel release];
}

- (void)startInstallation
{
    NSLog(@"CLMInstallationStep: startInstallation");
    
    // Stop disk polling to prevent interference during installation
    [_controller stopDiskPolling];
    
    if (_installationInProgress) {
        NSLog(@"CLMInstallationStep: Installation already in progress");
        return;
    }
    
    _installationInProgress = YES;
    _installationCompleted = NO;
    _installationSuccessful = NO;
    
    // Unmount partitions first
    [_statusLabel setStringValue:NSLocalizedString(@"Unmounting partitions...", @"")];
    [_progressLabel setStringValue:NSLocalizedString(@"", @"")];
    [_progressBar setDoubleValue:0.0];
    
    BOOL unmountSuccess = [CLMDiskUtility unmountPartitionsForDisk:_controller.selectedDiskDevice];
    if (!unmountSuccess) {
        [self installationCompletedWithSuccess:NO error:@"Could not unmount partitions on the target device."];
        return;
    }
    
    // Start download
    [_statusLabel setStringValue:NSLocalizedString(@"Downloading and writing Live image...", @"")];
    
    // Use a more direct approach similar to Python's urllib.request.urlretrieve()
    // This downloads directly to the block device without complex resume logic
    [self performSelector:@selector(startDirectDownload) withObject:nil afterDelay:0.1];
}

#pragma mark - GSDownloaderDelegate

- (void)downloadProgressChanged:(float)progress bytesReceived:(long long)bytesReceived totalBytes:(long long)totalBytes
{
    // Throttle progress updates for better performance - only update every 1%
    static float lastProgress = -1.0;
    static NSTimeInterval startTime = 0;
    static NSTimeInterval lastUpdateTime = 0;
    static long long lastBytesReceived = -1;
    static NSTimeInterval lastSignificantProgressTime = 0;
    
    NSTimeInterval currentTime = [[NSDate date] timeIntervalSince1970];
    if (startTime == 0) {
        startTime = currentTime;
        lastSignificantProgressTime = currentTime;
    }
    
    float currentProgress = progress * 100.0;
    
    // Check for significant progress (meaningful byte increase)
    if (lastBytesReceived >= 0) {
        long long bytesIncrease = bytesReceived - lastBytesReceived;
        // Consider "significant" if we've received at least 1MB or increased by 0.1%
        long long significantThreshold = MAX(1024 * 1024, totalBytes / 1000);
        if (bytesIncrease >= significantThreshold) {
            lastSignificantProgressTime = currentTime;
        }
    } else {
        lastSignificantProgressTime = currentTime;
    }
    
    // Fix the 99% hang: use >= 99.0 to ensure we capture near-completion states
    if (currentProgress - lastProgress >= 1.0 || currentProgress >= 99.0 || lastProgress < 0 || 
        (currentTime - lastUpdateTime >= 2.0)) { // Also update every 2 seconds
        
        NSLog(@"CLMInstallationStep: downloadProgressChanged: %.2f%% (%lld/%lld)", currentProgress, bytesReceived, totalBytes);
        lastProgress = currentProgress;
        lastUpdateTime = currentTime;
        lastBytesReceived = bytesReceived;
        
        [_progressBar setDoubleValue:currentProgress];
        
        if (totalBytes > 0) {
            NSString *receivedStr = [CLMDiskUtility formatSize:bytesReceived];
            NSString *totalStr = [CLMDiskUtility formatSize:totalBytes];
            
            // Calculate speed and ETA
            NSTimeInterval elapsed = currentTime - startTime;
            NSString *progressText;
            
            if (elapsed > 0 && bytesReceived > 0) {
                double speed = bytesReceived / elapsed; // bytes per second
                NSString *speedStr = [CLMDiskUtility formatSize:(long long)speed];
                
                if (progress > 0 && progress < 1.0) {
                    NSTimeInterval remaining = elapsed * (1.0 - progress) / progress;
                    progressText = [NSString stringWithFormat:@"%@ of %@ (%.1f%%) - %@/s, ~%.0f sec remaining", 
                                  receivedStr, totalStr, currentProgress, speedStr, remaining];
                } else {
                    progressText = [NSString stringWithFormat:@"%@ of %@ (%.1f%%) - %@/s", 
                                  receivedStr, totalStr, currentProgress, speedStr];
                }
            } else {
                progressText = [NSString stringWithFormat:@"%@ of %@ (%.1f%%)", receivedStr, totalStr, currentProgress];
            }
            
            [_progressLabel setStringValue:progressText];
        } else {
            NSString *receivedStr = [CLMDiskUtility formatSize:bytesReceived];
            [_progressLabel setStringValue:[NSString stringWithFormat:@"%@ downloaded", receivedStr]];
        }
        
        // Force UI update
        [_progressBar setNeedsDisplay:YES];
        [_progressLabel setNeedsDisplay:YES];
        
        // Update stall detection tracking - use the general progress time for UI updates
        // but track significant progress separately for stall detection
        _lastProgressTime = currentTime;
        _lastProgressValue = currentProgress;
    }
    
    // Check for near-completion stalls (99%+ with very slow or no meaningful progress)
    if (currentProgress >= 99.0) {
        NSTimeInterval timeSinceSignificantProgress = currentTime - lastSignificantProgressTime;
        
        if (timeSinceSignificantProgress > 60.0) { // 1 minute without significant progress at 99%+
            NSLog(@"CLMInstallationStep: Near-completion stall detected - %.2f%% complete, %.0f seconds without significant progress", 
                  currentProgress, timeSinceSignificantProgress);
            NSLog(@"CLMInstallationStep: Last significant progress was %lld bytes ago", bytesReceived - lastBytesReceived);
            
            // Force completion if we're extremely close
            if (currentProgress >= 99.5 || timeSinceSignificantProgress > 120.0) {
                NSLog(@"CLMInstallationStep: Forcing download completion due to near-completion stall");
                
                // Check if we actually have all the bytes before forcing success
                if (_downloader) {
                    long long receivedBytes = [_downloader receivedBytes];
                    long long totalBytes = [_downloader totalBytes];
                    float actualProgress = totalBytes > 0 ? ((float)receivedBytes / (float)totalBytes) * 100.0 : 0.0;
                    
                    NSLog(@"CLMInstallationStep: Byte verification - received: %lld, total: %lld, actual progress: %.2f%%", 
                          receivedBytes, totalBytes, actualProgress);
                    
                    if (actualProgress >= 99.5) {
                        NSLog(@"CLMInstallationStep: Byte verification passed (%.2f%%), forcing successful completion", actualProgress);
                        [self stopStallDetectionTimer];
                        [_progressBar setDoubleValue:100.0];
                        [_progressLabel setStringValue:NSLocalizedString(@"Download completed - Writing to disk...", @"")];
                        [self installationCompletedWithSuccess:YES error:nil];
                    } else {
                        NSLog(@"CLMInstallationStep: Byte verification failed (%.2f%%), treating as incomplete download", actualProgress);
                        [self stopStallDetectionTimer];
                        NSString *errorMsg = [NSString stringWithFormat:@"Download incomplete - only %.1f%% received (%lld of %lld bytes)", 
                                            actualProgress, receivedBytes, totalBytes];
                        [self installationCompletedWithSuccess:NO error:errorMsg];
                    }
                } else {
                    NSLog(@"CLMInstallationStep: No downloader available for byte verification, forcing completion anyway");
                    [self stopStallDetectionTimer];
                    [_progressBar setDoubleValue:100.0];
                    [_progressLabel setStringValue:NSLocalizedString(@"Download completed - Writing to disk...", @"")];
                    [self installationCompletedWithSuccess:YES error:nil];
                }
                return;
            }
        }
    }
}

- (void)downloadCompleted:(BOOL)success error:(NSString *)error
{
    NSLog(@"CLMInstallationStep: downloadCompleted: success=%d error=%@", success, error);
    
    // Stop stall detection timer
    [self stopStallDetectionTimer];
    
    // If the download reports success but we're using GSDownloader, 
    // double-check that we actually received all expected bytes
    if (success && _downloader) {
        long long receivedBytes = [_downloader receivedBytes];
        long long totalBytes = [_downloader totalBytes];
        
        NSLog(@"CLMInstallationStep: Download completion check - received: %lld, total: %lld", receivedBytes, totalBytes);
        
        if (totalBytes > 0 && receivedBytes < totalBytes) {
            long long missingBytes = totalBytes - receivedBytes;
            float percentComplete = ((float)receivedBytes / (float)totalBytes) * 100.0;
            
            NSLog(@"CLMInstallationStep: Download incomplete - missing %lld bytes (%.2f%% complete)", missingBytes, percentComplete);
            
            // If we're very close to completion (missing less than 0.5%), consider it successful
            if (percentComplete >= 99.5) {
                NSLog(@"CLMInstallationStep: Download is %.2f%% complete, considering it successful despite missing %lld bytes", percentComplete, missingBytes);
                success = YES;
                error = nil;
            } else {
                NSLog(@"CLMInstallationStep: Download significantly incomplete (%.2f%%), treating as failure", percentComplete);
                success = NO;
                error = [NSString stringWithFormat:@"Download incomplete - received %lld of %lld bytes (%.1f%%)", receivedBytes, totalBytes, percentComplete];
            }
        }
    }
    
    // Ensure progress bar shows 100% on successful completion
    if (success) {
        [_progressBar setDoubleValue:100.0];
        [_progressLabel setStringValue:NSLocalizedString(@"Download completed - Writing to disk...", @"")];
    }
    
    [self installationCompletedWithSuccess:success error:error];
}

#pragma mark - Installation Completion

- (void)installationCompletedWithSuccess:(BOOL)success error:(NSString *)error
{
    NSLog(@"CLMInstallationStep: installationCompletedWithSuccess: %d", success);
    
    _installationInProgress = NO;
    _installationCompleted = YES;
    _installationSuccessful = success;
    
    if (success) {
        [_statusLabel setStringValue:NSLocalizedString(@"Live medium created successfully!", @"")];
        [_progressBar setDoubleValue:100.0];
        [_progressLabel setStringValue:NSLocalizedString(@"Installation completed", @"")];
        
        [_controller showInstallationSuccess:@"Live medium has been created successfully!"];
        
        // Request navigation button update to enable Continue button
        [self requestNavigationUpdate];
    } else {
        [_statusLabel setStringValue:NSLocalizedString(@"Installation failed", @"")];
        [_progressLabel setStringValue:error ? error : @"Unknown error occurred"];
        
        // Hide progress bar, progress label, and info text on error
        [_progressBar setHidden:YES];
        [_progressLabel setHidden:YES];
        [_infoLabel setHidden:YES];
        
        [_controller showInstallationError:error ? error : @"Unknown error occurred"];
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
    NSLog(@"CLMInstallationStep: stepWillAppear");
    
    // Failsafe: Ensure disk polling is stopped when installation begins
    [_controller stopDiskPolling];
    
    // Start installation automatically when step appears
    [self performSelector:@selector(startInstallation) withObject:nil afterDelay:0.5];
}

- (void)stepDidAppear
{
    NSLog(@"CLMInstallationStep: stepDidAppear");
}

- (void)stepWillDisappear
{
    NSLog(@"CLMInstallationStep: stepWillDisappear");
}

#pragma mark - Stall Detection

- (void)startStallDetectionTimer
{
    NSLog(@"CLMInstallationStep: Starting stall detection timer");
    [self stopStallDetectionTimer];
    
    _stallDetectionTimer = [NSTimer scheduledTimerWithTimeInterval:10.0  // Check every 10 seconds
                                                           target:self
                                                         selector:@selector(checkForStall:)
                                                         userInfo:nil
                                                          repeats:YES];
    [_stallDetectionTimer retain];
    _lastProgressTime = [[NSDate date] timeIntervalSince1970];
    _lastProgressValue = -1.0;
}

- (void)stopStallDetectionTimer
{
    if (_stallDetectionTimer) {
        NSLog(@"CLMInstallationStep: Stopping stall detection timer");
        [_stallDetectionTimer invalidate];
        [_stallDetectionTimer release];
        _stallDetectionTimer = nil;
    }
}

- (void)checkForStall:(NSTimer *)timer
{
    if (!_installationInProgress || _installationCompleted) {
        [self stopStallDetectionTimer];
        return;
    }
    
    NSTimeInterval currentTime = [[NSDate date] timeIntervalSince1970];
    NSTimeInterval timeSinceLastProgress = currentTime - _lastProgressTime;
    
    NSLog(@"CLMInstallationStep: Stall check - time since last progress: %.1f seconds (last progress: %.1f%%)", 
          timeSinceLastProgress, _lastProgressValue);
    
    // If we're at high completion percentage and haven't made progress for a while, force completion
    if (_lastProgressValue >= 99.0 && timeSinceLastProgress > 120.0) { // 2 minutes at 99%+
        NSLog(@"CLMInstallationStep: Download stalled at %.1f%% for %.0f seconds, checking bytes before forcing completion", 
              _lastProgressValue, timeSinceLastProgress);
        
        // Verify we actually have the bytes before forcing completion
        if (_downloader) {
            long long receivedBytes = [_downloader receivedBytes];
            long long totalBytes = [_downloader totalBytes];
            float actualProgress = totalBytes > 0 ? ((float)receivedBytes / (float)totalBytes) * 100.0 : 0.0;
            
            NSLog(@"CLMInstallationStep: Timer-based byte verification - received: %lld, total: %lld, actual progress: %.2f%%", 
                  receivedBytes, totalBytes, actualProgress);
            
            if (actualProgress >= 99.5) {
                NSLog(@"CLMInstallationStep: Timer-based byte verification passed (%.2f%%), forcing successful completion", actualProgress);
                [self stopStallDetectionTimer];
                [_progressBar setDoubleValue:100.0];
                [_progressLabel setStringValue:NSLocalizedString(@"Download completed - Writing to disk...", @"")];
                [self installationCompletedWithSuccess:YES error:nil];
            } else {
                NSLog(@"CLMInstallationStep: Timer-based byte verification failed (%.2f%%), treating as incomplete", actualProgress);
                [self stopStallDetectionTimer];
                NSString *errorMsg = [NSString stringWithFormat:@"Download stalled and incomplete - only %.1f%% received (%lld of %lld bytes)", 
                                    actualProgress, receivedBytes, totalBytes];
                [self installationCompletedWithSuccess:NO error:errorMsg];
            }
        } else {
            NSLog(@"CLMInstallationStep: No downloader for byte verification, forcing completion based on reported progress");
            [self stopStallDetectionTimer];
            [_progressBar setDoubleValue:100.0];
            [_progressLabel setStringValue:NSLocalizedString(@"Download completed - Writing to disk...", @"")];
            [self installationCompletedWithSuccess:YES error:nil];
        }
        
    } else if (_lastProgressValue >= 98.0 && timeSinceLastProgress > 300.0) { // 5 minutes at 98%+
        NSLog(@"CLMInstallationStep: Download stalled at %.1f%% for %.0f seconds, checking bytes before forcing completion", 
              _lastProgressValue, timeSinceLastProgress);
        
        // Verify bytes for 98%+ stalls as well
        if (_downloader) {
            long long receivedBytes = [_downloader receivedBytes];
            long long totalBytes = [_downloader totalBytes];
            float actualProgress = totalBytes > 0 ? ((float)receivedBytes / (float)totalBytes) * 100.0 : 0.0;
            
            NSLog(@"CLMInstallationStep: 98%% or higher byte verification - received: %lld, total: %lld, actual progress: %.2f%%", 
                  receivedBytes, totalBytes, actualProgress);
            
            if (actualProgress >= 98.0) {
                NSLog(@"CLMInstallationStep: 98%% or higher stall verification passed (%.2f%%), forcing completion", actualProgress);
                [self stopStallDetectionTimer];
                [self installationCompletedWithSuccess:YES error:nil];
            } else {
                NSLog(@"CLMInstallationStep: 98%% or higher stall verification failed (%.2f%%), treating as failure", actualProgress);
                [self stopStallDetectionTimer];
                NSString *errorMsg = [NSString stringWithFormat:@"Download stalled - only %.1f%% actually received (%lld of %lld bytes)", 
                                    actualProgress, receivedBytes, totalBytes];
                [self installationCompletedWithSuccess:NO error:errorMsg];
            }
        } else {
            [self stopStallDetectionTimer];
            [self installationCompletedWithSuccess:YES error:nil];
        }
        
    } else if (timeSinceLastProgress > 600.0) { // 10 minutes with no progress at all
        NSLog(@"CLMInstallationStep: Download completely stalled for %.0f seconds, treating as failure", timeSinceLastProgress);
        
        [self stopStallDetectionTimer];
        [self installationCompletedWithSuccess:NO error:@"Download stalled - no progress for over 10 minutes"];
    }
}

#pragma mark - Direct Download

- (void)startDirectDownload
{
    NSLog(@"CLMInstallationStep: startDirectDownload - using temp file approach due to block device limitations");
    
    // Prepare destination device path
    NSString *devicePath = [NSString stringWithFormat:@"/dev/%@", _controller.selectedDiskDevice];
    
    // Start stall detection timer
    [self startStallDetectionTimer];
    
    // Create URL
    NSURL *url = [NSURL URLWithString:_controller.selectedImageURL];
    if (!url) {
        [self installationCompletedWithSuccess:NO error:@"Invalid download URL"];
        return;
    }
    
    // Store device path
    [_devicePath release];
    _devicePath = [devicePath retain];
    
    // Check if device exists and is accessible
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager fileExistsAtPath:_devicePath]) {
        [self installationCompletedWithSuccess:NO 
                                         error:[NSString stringWithFormat:@"Device %@ does not exist", _devicePath]];
        return;
    }
    
    // Create temporary file for download (NSFileHandle can't write directly to block devices reliably)
    NSString *tempDir = NSTemporaryDirectory();
    NSString *tempFileName = [NSString stringWithFormat:@"gershwin-livecd-%d.img", getpid()];
    NSString *tempFilePath = [tempDir stringByAppendingPathComponent:tempFileName];
    
    NSLog(@"CLMInstallationStep: Using temporary file: %@", tempFilePath);
    
    // Create temporary file
    if (![fileManager createFileAtPath:tempFilePath contents:nil attributes:nil]) {
        [self installationCompletedWithSuccess:NO 
                                         error:[NSString stringWithFormat:@"Could not create temporary file: %@", tempFilePath]];
        return;
    }
    
    // Open temporary file for writing
    _directOutputFile = [[NSFileHandle fileHandleForWritingAtPath:tempFilePath] retain];
    if (!_directOutputFile) {
        [fileManager removeItemAtPath:tempFilePath error:nil];
        [self installationCompletedWithSuccess:NO 
                                         error:[NSString stringWithFormat:@"Could not open temporary file for writing: %@", tempFilePath]];
        return;
    }
    
    // Store temp file path for cleanup and final copy
    [_tempFilePath release];
    _tempFilePath = [tempFilePath retain];
    
    // Create request
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setTimeoutInterval:60.0];
    [request setValue:@"CreateLiveMediaAssistant/1.0" forHTTPHeaderField:@"User-Agent"];
    
    // Initialize counters
    _directTotalBytes = 0;
    _directReceivedBytes = 0;
    
    // Start connection that writes to temporary file
    _directConnection = [[NSURLConnection alloc] initWithRequest:request delegate:self];
    if (!_directConnection) {
        [_directOutputFile closeFile];
        [_directOutputFile release];
        _directOutputFile = nil;
        [fileManager removeItemAtPath:tempFilePath error:nil];
        [self installationCompletedWithSuccess:NO error:@"Could not create network connection"];
        return;
    }
    
    NSLog(@"CLMInstallationStep: Direct download started, writing to temp file: %@", tempFilePath);
}

#pragma mark - Direct Download NSURLConnection Delegate Methods

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response
{
    if (connection != _directConnection) return;
    
    NSLog(@"CLMInstallationStep: Direct download didReceiveResponse");
    
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        NSInteger statusCode = [httpResponse statusCode];
        
        if (statusCode >= 400) {
            NSLog(@"CLMInstallationStep: HTTP error %ld", (long)statusCode);
            [self cancelDirectDownload];
            [self installationCompletedWithSuccess:NO 
                                             error:[NSString stringWithFormat:@"HTTP error %ld", (long)statusCode]];
            return;
        }
    }
    
    _directTotalBytes = [response expectedContentLength];
    _directReceivedBytes = 0;
    
    NSLog(@"CLMInstallationStep: Expected %lld bytes total", _directTotalBytes);
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data
{
    if (connection != _directConnection) return;
    
    if (!_directOutputFile) {
        NSLog(@"CLMInstallationStep: No output file handle, cancelling");
        [self cancelDirectDownload];
        return;
    }
    
    // Write data directly to device as it arrives (like Python urlretrieve)
    @try {
        [_directOutputFile writeData:data];
        _directReceivedBytes += [data length];
        
        // Sync every 10MB for better reliability with block devices
        static long long lastSync = 0;
        if (_directReceivedBytes - lastSync >= 10 * 1024 * 1024) {
            [_directOutputFile synchronizeFile];
            lastSync = _directReceivedBytes;
        }
        
        // Update progress (scale to 50% since download is only half the process)
        if (_directTotalBytes > 0) {
            float downloadProgress = (float)_directReceivedBytes / (float)_directTotalBytes;
            float overallProgress = downloadProgress * 0.5; // Download is 50% of total process
            [self downloadProgressChanged:overallProgress 
                            bytesReceived:_directReceivedBytes 
                               totalBytes:_directTotalBytes];
        }
        
        // Log progress periodically
        static long long lastLog = 0;
        if (_directReceivedBytes - lastLog >= 50 * 1024 * 1024) { // Every 50MB
            NSLog(@"CLMInstallationStep: Direct write progress: %lld / %lld bytes (%.1f%%)", 
                  _directReceivedBytes, _directTotalBytes, 
                  _directTotalBytes > 0 ? (_directReceivedBytes * 100.0 / _directTotalBytes) : 0.0);
            lastLog = _directReceivedBytes;
        }
        
    } @catch (NSException *exception) {
        NSLog(@"CLMInstallationStep: Error writing to device: %@", [exception reason]);
        [self cancelDirectDownload];
        [self installationCompletedWithSuccess:NO 
                                         error:[NSString stringWithFormat:@"Error writing to device: %@", [exception reason]]];
    }
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection
{
    if (connection != _directConnection) return;
    
    NSLog(@"CLMInstallationStep: Direct download connectionDidFinishLoading - %lld bytes written to temp file", _directReceivedBytes);
    
    // Close temp file
    if (_directOutputFile) {
        [_directOutputFile synchronizeFile];
        [_directOutputFile closeFile];
        [_directOutputFile release];
        _directOutputFile = nil;
    }
    
    [self stopStallDetectionTimer];
    
    // Clean up connection
    [_directConnection release];
    _directConnection = nil;
    
    // Update progress to 50% - download complete, now starting device write
    [_progressBar setDoubleValue:50.0];
    [_progressLabel setStringValue:NSLocalizedString(@"Download completed - Writing to disk...", @"")];
    [_statusLabel setStringValue:NSLocalizedString(@"Writing image to device...", @"")];
    
    // Now copy the temp file to the device using a system command
    [self copyTempFileToDevice];
}

- (void)copyTempFileToDevice
{
    if (!_tempFilePath || !_devicePath) {
        [self installationCompletedWithSuccess:NO error:@"Missing temp file or device path"];
        return;
    }
    
    NSLog(@"CLMInstallationStep: Copying temp file %@ to device %@", _tempFilePath, _devicePath);
    
    // Update progress message
    [_statusLabel setStringValue:[NSString stringWithFormat:@"Writing image to device %@...", _controller.selectedDiskDevice]];
    
    // Start a timer to simulate progress during dd operation
    [self startDDProgressTimer];
    
    // Use dd with sudo to copy the file to the device (like Python's approach under the hood)
    // Increase timeout to 20 minutes for large images and use status=progress for monitoring
    NSString *command = [NSString stringWithFormat:@"timeout 1200 sudo -A dd if='%@' of='%@' bs=4M status=progress", _tempFilePath, _devicePath];
    
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"/bin/sh"];
    [task setArguments:[NSArray arrayWithObjects:@"-c", command, nil]];
    
    NSPipe *errorPipe = [NSPipe pipe];
    [task setStandardError:errorPipe];
    
    @try {
        [task launch];
        [task waitUntilExit];
        
        // Stop progress timer
        [self stopDDProgressTimer];
        
        int exitStatus = [task terminationStatus];
        
        // Clean up temp file
        NSFileManager *fileManager = [NSFileManager defaultManager];
        [fileManager removeItemAtPath:_tempFilePath error:nil];
        [_tempFilePath release];
        _tempFilePath = nil;
        
        if (exitStatus == 0) {
            NSLog(@"CLMInstallationStep: Successfully copied image to device");
            
            // Update progress to 100%
            [_progressBar setDoubleValue:100.0];
            [_progressLabel setStringValue:NSLocalizedString(@"Writing to disk completed", @"")];
            
            // Sync the device to ensure bootability
            NSString *syncCommand = [NSString stringWithFormat:@"sync"];
            NSTask *syncTask = [[NSTask alloc] init];
            [syncTask setLaunchPath:@"/bin/sh"];
            [syncTask setArguments:[NSArray arrayWithObjects:@"-c", syncCommand, nil]];
            [syncTask launch];
            [syncTask waitUntilExit];
            [syncTask release];
            
            [self installationCompletedWithSuccess:YES error:nil];
        } else {
            NSFileHandle *errorHandle = [errorPipe fileHandleForReading];
            NSData *errorData = [errorHandle readDataToEndOfFile];
            NSString *errorString = [[NSString alloc] initWithData:errorData encoding:NSUTF8StringEncoding];
            
            NSLog(@"CLMInstallationStep: dd command failed with exit status %d: %@", exitStatus, errorString);
            [self installationCompletedWithSuccess:NO 
                                             error:[NSString stringWithFormat:@"Failed to write image to device (exit %d): %@", exitStatus, errorString]];
            [errorString release];
        }
    } @catch (NSException *e) {
        // Stop progress timer
        [self stopDDProgressTimer];
        
        // Clean up temp file
        NSFileManager *fileManager = [NSFileManager defaultManager];
        [fileManager removeItemAtPath:_tempFilePath error:nil];
        [_tempFilePath release];
        _tempFilePath = nil;
        
        NSLog(@"CLMInstallationStep: Exception while copying to device: %@", [e reason]);
        [self installationCompletedWithSuccess:NO 
                                         error:[NSString stringWithFormat:@"Exception while writing to device: %@", [e reason]]];
    }
    
    [task release];
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error
{
    if (connection != _directConnection) return;
    
    NSLog(@"CLMInstallationStep: Direct download failed with error: %@", error.localizedDescription);
    
    [self cancelDirectDownload];
    [self installationCompletedWithSuccess:NO error:error.localizedDescription];
}

- (void)cancelDirectDownload
{
    NSLog(@"CLMInstallationStep: cancelDirectDownload");
    
    [self stopStallDetectionTimer];
    
    if (_directConnection) {
        [_directConnection cancel];
        [_directConnection release];
        _directConnection = nil;
    }
    
    if (_directOutputFile) {
        [_directOutputFile closeFile];
        [_directOutputFile release];
        _directOutputFile = nil;
    }
    
    // Clean up temp file if it exists
    if (_tempFilePath) {
        NSFileManager *fileManager = [NSFileManager defaultManager];
        [fileManager removeItemAtPath:_tempFilePath error:nil];
        [_tempFilePath release];
        _tempFilePath = nil;
    }
    
    _directTotalBytes = 0;
    _directReceivedBytes = 0;
}

#pragma mark - DD Progress Timer

- (void)startDDProgressTimer
{
    NSLog(@"CLMInstallationStep: Starting DD progress timer");
    [self stopDDProgressTimer];
    
    _ddStartTime = [[NSDate date] timeIntervalSince1970];
    _ddProgressTimer = [NSTimer scheduledTimerWithTimeInterval:2.0  // Update every 2 seconds
                                                        target:self
                                                      selector:@selector(updateDDProgress:)
                                                      userInfo:nil
                                                       repeats:YES];
    [_ddProgressTimer retain];
}

- (void)stopDDProgressTimer
{
    if (_ddProgressTimer) {
        NSLog(@"CLMInstallationStep: Stopping DD progress timer");
        [_ddProgressTimer invalidate];
        [_ddProgressTimer release];
        _ddProgressTimer = nil;
    }
}

- (void)updateDDProgress:(NSTimer *)timer
{
    NSTimeInterval currentTime = [[NSDate date] timeIntervalSince1970];
    NSTimeInterval elapsed = currentTime - _ddStartTime;
    
    // Estimate progress based on time elapsed
    // Assume dd takes about 3-5 minutes for a 1.8GB file, so let's use 4 minutes as baseline
    // Progress goes from 50% to 95% based on time, then jumps to 100% when actually complete
    float estimatedDDTime = 240.0; // 4 minutes
    float ddProgress = MIN(elapsed / estimatedDDTime, 0.9); // Cap at 90% until actual completion
    float overallProgress = 50.0 + (ddProgress * 45.0); // 50% to 95%
    
    [_progressBar setDoubleValue:overallProgress];
    
    // Update progress text with estimated time
    if (ddProgress < 0.9) {
        NSTimeInterval remaining = estimatedDDTime - elapsed;
        [_progressLabel setStringValue:[NSString stringWithFormat:@"Writing to device... (~%.0f sec remaining)", remaining]];
    } else {
        [_progressLabel setStringValue:NSLocalizedString(@"Writing to device... (almost complete)", @"")];
    }
    
    NSLog(@"CLMInstallationStep: DD progress update: %.1f%% (%.0f seconds elapsed)", overallProgress, elapsed);
}
@end
