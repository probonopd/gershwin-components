//
// CLMInstallationStep.m
// Create Live Media Assistant - Installation Step
//

#import "CLMInstallationStep.h"
#import "CLMController.h"
#import "CLMDiskUtility.h"
#import "GSAssistantFramework.h"

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
        [self setupView];
    }
    return self;
}

- (void)dealloc
{
    NSLog(@"CLMInstallationStep: dealloc");
    [_downloader release];
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
    [_statusLabel setStringValue:@"Preparing to download and write Live medium..."];
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
    [_progressLabel setStringValue:@""];
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
    [_infoLabel setStringValue:@"The image will be downloaded and written to the selected device. This may take several minutes depending on network speed and image size."];
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
    
    // Prepare destination device path
    NSString *devicePath = [NSString stringWithFormat:@"/dev/%@", _controller.selectedDiskDevice];
    
    // Unmount partitions first
    [_statusLabel setStringValue:@"Unmounting partitions..."];
    [_progressLabel setStringValue:@""];
    [_progressBar setDoubleValue:0.0];
    
    BOOL unmountSuccess = [CLMDiskUtility unmountPartitionsForDisk:_controller.selectedDiskDevice];
    if (!unmountSuccess) {
        [self installationCompletedWithSuccess:NO error:@"Could not unmount partitions on the target device."];
        return;
    }
    
    // Start download
    [_statusLabel setStringValue:@"Downloading and writing Live image..."];
    
    _downloader = [[CLMDownloader alloc] init];
    [_downloader setDelegate:self];
    [_downloader downloadFromURL:_controller.selectedImageURL toPath:devicePath];
}

#pragma mark - CLMDownloaderDelegate

- (void)downloadProgressChanged:(float)progress bytesReceived:(long long)bytesReceived totalBytes:(long long)totalBytes
{
    // Throttle progress updates for better performance - only update every 1%
    static float lastProgress = -1.0;
    static NSTimeInterval startTime = 0;
    static NSTimeInterval lastUpdateTime = 0;
    
    NSTimeInterval currentTime = [[NSDate date] timeIntervalSince1970];
    if (startTime == 0) {
        startTime = currentTime;
    }
    
    float currentProgress = progress * 100.0;
    
    // Fix the 99% hang: use >= 99.0 to ensure we capture near-completion states
    if (currentProgress - lastProgress >= 1.0 || currentProgress >= 99.0 || lastProgress < 0 || 
        (currentTime - lastUpdateTime >= 2.0)) { // Also update every 2 seconds
        
        NSLog(@"CLMInstallationStep: downloadProgressChanged: %.2f%% (%lld/%lld)", currentProgress, bytesReceived, totalBytes);
        lastProgress = currentProgress;
        lastUpdateTime = currentTime;
        
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
    }
}

- (void)downloadCompleted:(BOOL)success error:(NSString *)error
{
    NSLog(@"CLMInstallationStep: downloadCompleted: success=%d error=%@", success, error);
    
    // Ensure progress bar shows 100% on successful completion
    if (success) {
        [_progressBar setDoubleValue:100.0];
        [_progressLabel setStringValue:@"Download completed - Writing to disk..."];
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
        [_statusLabel setStringValue:@"Live medium created successfully!"];
        [_progressBar setDoubleValue:100.0];
        [_progressLabel setStringValue:@"Installation completed"];
        
        // Update icon to success
        NSImageView *iconView = [[_stepView subviews] objectAtIndex:0];
        NSString *successIconPath = [[NSBundle mainBundle] pathForResource:@"usbsuccess" ofType:@"svg"];
        if (!successIconPath) {
            successIconPath = [[NSBundle mainBundle] pathForResource:@"check" ofType:@"png"];
        }
        if (successIconPath) {
            NSImage *successIcon = [[NSImage alloc] initWithContentsOfFile:successIconPath];
            if (successIcon) {
                [iconView setImage:successIcon];
                [successIcon release];
            }
        }
        
        [_controller showInstallationSuccess:@"Live medium has been created successfully!"];
        
        // Request navigation button update to enable Continue button
        [self requestNavigationUpdate];
    } else {
        [_statusLabel setStringValue:@"Installation failed"];
        [_progressLabel setStringValue:error ? error : @"Unknown error occurred"];
        
        // Hide progress bar, progress label, and info text on error
        [_progressBar setHidden:YES];
        [_progressLabel setHidden:YES];
        [_infoLabel setHidden:YES];
        
        // Update icon to error
        NSImageView *iconView = [[_stepView subviews] objectAtIndex:0];
        NSString *errorIconPath = [[NSBundle mainBundle] pathForResource:@"cross" ofType:@"png"];
        if (errorIconPath) {
            NSImage *errorIcon = [[NSImage alloc] initWithContentsOfFile:errorIconPath];
            if (errorIcon) {
                [iconView setImage:errorIcon];
                [errorIcon release];
            }
        }
        
        [_controller showInstallationError:error ? error : @"Unknown error occurred"];
    }
}

#pragma mark - GSAssistantStepProtocol

- (NSString *)stepTitle
{
    return @"Creating Live Medium";
}

- (NSString *)stepDescription  
{
    return @"Downloading and writing the Live image to the selected device";
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

@end
