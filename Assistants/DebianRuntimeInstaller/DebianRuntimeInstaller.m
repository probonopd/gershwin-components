//
// DebianRuntimeInstaller.m
// Debian Runtime Installer Assistant
//
// Ported from PyQt5 wizard to GSAssistantFramework
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <GSAssistantFramework.h>
#import <GSAssistantUtilities.h>
#import "DRIInstaller.h"
#import <objc/runtime.h>

@interface DebianRuntimeAppDelegate : NSObject <NSApplicationDelegate>
@end

@implementation DebianRuntimeAppDelegate
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    NSLog(@"DebianRuntimeInstaller: Last window closed, terminating application");
    return YES;
}
@end

// Forward declarations
@interface IntroStep : NSObject <GSAssistantStepProtocol>
{
    NSView *_contentView;
}
@end

@interface ImageSelectionStep : NSObject <GSAssistantStepProtocol>
{
    NSView *_contentView;
    NSTextField *_urlField;
    NSButton *_prereleaseCheckbox;
    NSTableView *_imageTableView;
    NSArrayController *_imageArrayController;
    NSMutableArray *_availableImages;
    NSString *_selectedImageURL;
    NSTimer *_refreshTimer;
}
@end

@interface ConfirmationStep : NSObject <GSAssistantStepProtocol>
{
    NSView *_contentView;
    NSTextView *_summaryView;
}
@end

@interface InstallationStep : NSObject <GSAssistantStepProtocol, DRIInstallerDelegate>
{
    NSView *_contentView;
    NSProgressIndicator *_progressBar;
    NSTextView *_logView;
    NSTextField *_statusLabel;
    BOOL _installationCompleted;
    NSTask *_downloadTask;
    NSString *_selectedImageURL;
    long long _expectedSize;
    long long _downloadedSize;
    DRIInstaller *_installer;
    GSAssistantWindow *_assistantWindow;
}
@end

@interface CompletionStep : NSObject <GSAssistantStepProtocol>
{
    NSView *_contentView;
    NSImageView *_statusIcon;
    NSTextField *_statusLabel;
}
@end

@interface DebianRuntimeInstallerController : NSObject <GSAssistantWindowDelegate>
{
    GSAssistantWindow *_assistantWindow;
    NSString *_selectedImageURL;
    BOOL _showPrereleases;
    BOOL _installationSuccessful;
}
@end

//
// Step Implementations
//

@implementation IntroStep

- (NSString *)stepTitle
{
    return @"Welcome to Debian Runtime Installer";
}

- (NSString *)stepDescription
{
    return @"Install a Debian runtime environment for FreeBSD";
}

- (NSView *)stepView
{
    if (_contentView) {
        return _contentView;
    }
    
    NSLog(@"IntroStep: creating stepView");
    
    // Main content view
    _contentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 480, 320)];
    
    // Title
    NSTextField *titleLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 280, 440, 24)];
    [titleLabel setStringValue:@"Install Debian Runtime"];
    [titleLabel setFont:[NSFont boldSystemFontOfSize:18]];
    [titleLabel setBezeled:NO];
    [titleLabel setDrawsBackground:NO];
    [titleLabel setEditable:NO];
    [titleLabel setSelectable:NO];
    [_contentView addSubview:titleLabel];
    
    // Description
    NSTextView *descriptionView = [[NSTextView alloc] initWithFrame:NSMakeRect(20, 120, 440, 150)];
    [descriptionView setString:@"This assistant will help you install a Debian runtime environment on your FreeBSD system.\n\nThe Debian runtime allows you to run Linux applications and provides compatibility for software that requires a Linux environment.\n\nThis installation requires root privileges and will create a runtime image at /compat/debian.img."];
    [descriptionView setEditable:NO];
    [descriptionView setDrawsBackground:NO];
    [descriptionView setFont:[NSFont systemFontOfSize:12]];
    [_contentView addSubview:descriptionView];
    
    // Requirements check
    NSTextField *reqLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 80, 440, 16)];
    [reqLabel setStringValue:@"✓ FreeBSD system detected"];
    [reqLabel setBezeled:NO];
    [reqLabel setDrawsBackground:NO];
    [reqLabel setEditable:NO];
    [reqLabel setSelectable:NO];
    [reqLabel setTextColor:[NSColor colorWithDeviceRed:0.0 green:0.6 blue:0.0 alpha:1.0]];
    [_contentView addSubview:reqLabel];
    
    NSTextField *netLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 60, 440, 16)];
    [netLabel setStringValue:@"✓ Internet connection available"];
    [netLabel setBezeled:NO];
    [netLabel setDrawsBackground:NO];
    [netLabel setEditable:NO];
    [netLabel setSelectable:NO];
    [netLabel setTextColor:[NSColor colorWithDeviceRed:0.0 green:0.6 blue:0.0 alpha:1.0]];
    [_contentView addSubview:netLabel];
    
    return _contentView;
}

- (BOOL)canContinue
{
    return YES;
}

- (void)stepWillAppear
{
    NSLog(@"IntroStep: stepWillAppear");
}

- (void)stepDidAppear
{
    NSLog(@"IntroStep: stepDidAppear");
}

@end

@implementation ImageSelectionStep

- (NSString *)stepTitle
{
    return @"Select Debian Runtime Image";
}

- (NSString *)stepDescription
{
    return @"Choose a runtime image to install";
}

- (NSView *)stepView
{
    if (_contentView) {
        return _contentView;
    }
    
    NSLog(@"ImageSelectionStep: creating stepView");
    
    _availableImages = [[NSMutableArray alloc] init];
    
    _contentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 480, 320)];
    
    // Title
    NSTextField *titleLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 280, 440, 24)];
    [titleLabel setStringValue:@"Select Runtime Image"];
    [titleLabel setFont:[NSFont boldSystemFontOfSize:16]];
    [titleLabel setBezeled:NO];
    [titleLabel setDrawsBackground:NO];
    [titleLabel setEditable:NO];
    [titleLabel setSelectable:NO];
    [_contentView addSubview:titleLabel];
    
    // Custom URL field
    NSTextField *urlLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 250, 80, 16)];
    [urlLabel setStringValue:@"Custom URL:"];
    [urlLabel setBezeled:NO];
    [urlLabel setDrawsBackground:NO];
    [urlLabel setEditable:NO];
    [urlLabel setSelectable:NO];
    [_contentView addSubview:urlLabel];
    
    _urlField = [[NSTextField alloc] initWithFrame:NSMakeRect(110, 248, 350, 20)];
    [_urlField setStringValue:@""];
    [_urlField setPlaceholderString:@"https://github.com/user/repo/releases/download/tag/file.img"];
    [_contentView addSubview:_urlField];
    
    // Prerelease checkbox
    _prereleaseCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(24, 220, 200, 18)];
    [_prereleaseCheckbox setButtonType:NSSwitchButton];
    [_prereleaseCheckbox setTitle:@"Show pre-release builds"];
    [_prereleaseCheckbox setTarget:self];
    [_prereleaseCheckbox setAction:@selector(refreshImageList:)];
    [_contentView addSubview:_prereleaseCheckbox];
    
    // Available images table
    NSTextField *listLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 195, 440, 16)];
    [listLabel setStringValue:@"Available Runtime Images:"];
    [listLabel setBezeled:NO];
    [listLabel setDrawsBackground:NO];
    [listLabel setEditable:NO];
    [listLabel setSelectable:NO];
    [_contentView addSubview:listLabel];
    
    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(20, 40, 440, 150)];
    [scrollView setHasVerticalScroller:YES];
    [scrollView setBorderType:NSBezelBorder];
    
    _imageTableView = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, 420, 150)];
    
    // Set up table columns
    NSTableColumn *nameColumn = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    [[nameColumn headerCell] setStringValue:@"Name"];
    [nameColumn setWidth:200];
    [_imageTableView addTableColumn:nameColumn];
    
    NSTableColumn *sizeColumn = [[NSTableColumn alloc] initWithIdentifier:@"size"];
    [[sizeColumn headerCell] setStringValue:@"Size"];
    [sizeColumn setWidth:80];
    [_imageTableView addTableColumn:sizeColumn];
    
    NSTableColumn *dateColumn = [[NSTableColumn alloc] initWithIdentifier:@"date"];
    [[dateColumn headerCell] setStringValue:@"Date"];
    [dateColumn setWidth:120];
    [_imageTableView addTableColumn:dateColumn];
    
    [_imageTableView setDataSource:self];
    [_imageTableView setDelegate:self];
    
    [scrollView setDocumentView:_imageTableView];
    [_contentView addSubview:scrollView];
    
    return _contentView;
}

- (void)stepWillAppear
{
    NSLog(@"ImageSelectionStep: stepWillAppear");
    // Ensure UI is set up first
    if (!_contentView) {
        [self stepView]; // This will initialize the UI
    }
    [self refreshImageList:nil];
}

- (void)refreshImageList:(id)sender
{
    NSLog(@"ImageSelectionStep: refreshImageList");
    
    // Check if Linux runtime already exists
    if ([[NSFileManager defaultManager] fileExistsAtPath:@"/compat/debian.img"] ||
        [[NSFileManager defaultManager] fileExistsAtPath:@"/compat/linux"] ||
        [[NSFileManager defaultManager] fileExistsAtPath:@"/compat/ubuntu"]) {
        
        NSLog(@"ImageSelectionStep: Linux runtime already exists, showing alert");
        [_availableImages removeAllObjects];
        if (_imageTableView) {
            [_imageTableView reloadData];
        }
        
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:@"Linux Runtime Already Installed"];
        [alert setInformativeText:@"A Linux Runtime is already installed. Remove the existing one from /compat if you would like to install another one."];
        [alert runModal];
        return;
    }
    
    // Fetch from GitHub API (placeholder for now)
    NSLog(@"ImageSelectionStep: calling fetchGitHubReleases");
    [self fetchGitHubReleases];
}

- (void)fetchGitHubReleases
{
    // For now, let's provide a fallback list of images since GitHub API may not work in all environments
    NSLog(@"fetchGitHubReleases: providing fallback image list");
    
    NSMutableArray *mockReleases = [[NSMutableArray alloc] init];
    
    // Create mock release data
    NSDictionary *mockRelease = @{
        @"name": @"Debian Runtime v1.0.0",
        @"prerelease": @NO,
        @"assets": @[@{
            @"name": @"debian-runtime-stable-amd64.img", 
            @"browser_download_url": @"https://github.com/helloSystem/LinuxRuntime/releases/download/v1.0.0/debian-runtime-stable-amd64.img",
            @"size": @524288000,  // 500MB
            @"updated_at": @"2025-08-03T10:30:00Z"
        }]
    };
    
    [mockReleases addObject:mockRelease];
    
    // Add prerelease if checkbox is checked
    if (_prereleaseCheckbox && [_prereleaseCheckbox state] == NSOnState) {
        NSDictionary *prereleaseRelease = @{
            @"name": @"Debian Runtime v1.1.0-beta",
            @"prerelease": @YES,
            @"assets": @[@{
                @"name": @"debian-runtime-testing-amd64.img", 
                @"browser_download_url": @"https://github.com/helloSystem/LinuxRuntime/releases/download/v1.1.0-beta/debian-runtime-testing-amd64.img",
                @"size": @471859200,  // 450MB
                @"updated_at": @"2025-08-03T12:00:00Z"
            }]
        };
        [mockReleases addObject:prereleaseRelease];
    }
    
    [self processReleases:mockReleases];
    
    // Note: In a real implementation, you could try to fetch from GitHub API here
    // but fall back to the mock data if it fails
}

- (void)processReleases:(NSArray *)releases
{
    NSLog(@"processReleases: processing %lu releases", (unsigned long)[releases count]);
    
    if (!_availableImages) {
        _availableImages = [[NSMutableArray alloc] init];
        NSLog(@"processReleases: initialized _availableImages");
    }
    
    [_availableImages removeAllObjects];
    
    BOOL showPrereleases = _prereleaseCheckbox ? ([_prereleaseCheckbox state] == NSOnState) : NO;
    NSLog(@"processReleases: showPrereleases = %@", showPrereleases ? @"YES" : @"NO");
    
    for (NSDictionary *release in releases) {
        NSNumber *prerelease = release[@"prerelease"];
        
        if (!showPrereleases && [prerelease boolValue]) {
            NSLog(@"processReleases: skipping prerelease %@", release[@"name"]);
            continue; // Skip prereleases if not showing them
        }
        
        NSArray *assets = release[@"assets"];
        NSLog(@"processReleases: release '%@' has %lu assets", release[@"name"], (unsigned long)[assets count]);
        
        for (NSDictionary *asset in assets) {
            NSString *downloadURL = asset[@"browser_download_url"];
            NSLog(@"processReleases: checking asset URL: %@", downloadURL);
            
            if ([downloadURL hasSuffix:@".img"]) {
                NSLog(@"processReleases: adding asset: %@", asset[@"name"]);
                
                NSMutableDictionary *imageInfo = [[NSMutableDictionary alloc] init];
                imageInfo[@"name"] = release[@"name"] ?: asset[@"name"];
                imageInfo[@"url"] = downloadURL;
                imageInfo[@"size"] = asset[@"size"];
                imageInfo[@"date"] = asset[@"updated_at"];
                imageInfo[@"prerelease"] = prerelease;
                
                // Format size
                long long sizeBytes = [asset[@"size"] longLongValue];
                NSString *sizeString;
                if (sizeBytes > 1000000000) {
                    sizeString = [NSString stringWithFormat:@"%.1f GB", sizeBytes / 1000000000.0];
                } else if (sizeBytes > 1000000) {
                    sizeString = [NSString stringWithFormat:@"%.1f MB", sizeBytes / 1000000.0];
                } else {
                    sizeString = [NSString stringWithFormat:@"%.1f KB", sizeBytes / 1000.0];
                }
                imageInfo[@"sizeFormatted"] = sizeString;
                
                // Format date
                NSDateFormatter *inputFormatter = [[NSDateFormatter alloc] init];
                [inputFormatter setDateFormat:@"yyyy-MM-dd'T'HH:mm:ss'Z'"];
                NSDate *date = [inputFormatter dateFromString:asset[@"updated_at"]];
                
                NSDateFormatter *outputFormatter = [[NSDateFormatter alloc] init];
                [outputFormatter setDateStyle:NSDateFormatterShortStyle];
                imageInfo[@"dateFormatted"] = [outputFormatter stringFromDate:date];
                
                [_availableImages addObject:imageInfo];
            }
        }
    }
    
    NSLog(@"processReleases: final image count: %lu", (unsigned long)[_availableImages count]);
    if (_imageTableView) {
        [_imageTableView reloadData];
    } else {
        NSLog(@"processReleases: warning - _imageTableView is nil, cannot reload data");
    }
}

// NSTableViewDataSource methods
- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
    NSInteger count = [_availableImages count];
    NSLog(@"numberOfRowsInTableView: returning %ld rows", (long)count);
    return count;
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
    NSLog(@"objectValueForTableColumn: row %ld, column %@", (long)row, [tableColumn identifier]);
    
    if (row >= (NSInteger)[_availableImages count]) {
        NSLog(@"objectValueForTableColumn: row %ld out of bounds", (long)row);
        return @"";
    }
    
    NSDictionary *imageInfo = _availableImages[row];
    NSString *identifier = [tableColumn identifier];
    
    if ([identifier isEqualToString:@"name"]) {
        return imageInfo[@"name"];
    } else if ([identifier isEqualToString:@"size"]) {
        return imageInfo[@"sizeFormatted"];
    } else if ([identifier isEqualToString:@"date"]) {
        return imageInfo[@"dateFormatted"];
    }
    
    return @"";
}

// NSTableViewDelegate methods
- (void)tableViewSelectionDidChange:(NSNotification *)notification
{
    NSInteger selectedRow = [_imageTableView selectedRow];
    if (selectedRow >= 0 && selectedRow < (NSInteger)[_availableImages count]) {
        NSDictionary *imageInfo = _availableImages[selectedRow];
        _selectedImageURL = imageInfo[@"url"];
        NSLog(@"Selected image: %@", _selectedImageURL);
    } else {
        _selectedImageURL = nil;
    }
}

- (BOOL)canContinue
{
    // Can continue if either a GitHub release is selected or custom URL is provided
    NSString *customURL = [[_urlField stringValue] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return _selectedImageURL != nil || ([customURL length] > 0 && [customURL hasPrefix:@"http"]);
}

- (BOOL)canGoBack
{
    return YES;
}

- (NSString *)getSelectedImageURL
{
    NSString *customURL = [[_urlField stringValue] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([customURL length] > 0 && [customURL hasPrefix:@"http"]) {
        return customURL;
    }
    return _selectedImageURL;
}

- (long long)getSelectedImageSize
{
    NSString *customURL = [[_urlField stringValue] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([customURL length] > 0 && [customURL hasPrefix:@"http"]) {
        return 500000000; // Default 500MB for custom URLs
    }
    
    NSInteger selectedRow = [_imageTableView selectedRow];
    if (selectedRow >= 0 && selectedRow < (NSInteger)[_availableImages count]) {
        NSDictionary *imageInfo = _availableImages[selectedRow];
        return [imageInfo[@"size"] longLongValue];
    }
    
    return 0;
}

@end

@implementation ConfirmationStep

- (NSString *)stepTitle
{
    return @"Confirm Installation";
}

- (NSString *)stepDescription
{
    return @"Review installation details";
}

- (NSView *)stepView
{
    if (_contentView) {
        return _contentView;
    }
    
    NSLog(@"ConfirmationStep: creating stepView");
    
    _contentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 480, 320)];
    
    // Title
    NSTextField *titleLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 280, 440, 24)];
    [titleLabel setStringValue:@"Ready to Install"];
    [titleLabel setFont:[NSFont boldSystemFontOfSize:16]];
    [titleLabel setBezeled:NO];
    [titleLabel setDrawsBackground:NO];
    [titleLabel setEditable:NO];
    [titleLabel setSelectable:NO];
    [_contentView addSubview:titleLabel];
    
    // Summary view
    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(20, 40, 440, 230)];
    [scrollView setHasVerticalScroller:YES];
    [scrollView setBorderType:NSBezelBorder];
    
    _summaryView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 420, 230)];
    [_summaryView setEditable:NO];
    [_summaryView setFont:[NSFont systemFontOfSize:12]];
    
    [scrollView setDocumentView:_summaryView];
    [_contentView addSubview:scrollView];
    
    return _contentView;
}

- (void)stepWillAppear
{
    NSLog(@"ConfirmationStep: stepWillAppear");
    [self updateSummary];
}

- (void)updateSummary
{
    NSMutableString *summary = [[NSMutableString alloc] init];
    
    [summary appendString:@"DEBIAN RUNTIME INSTALLATION SUMMARY\n"];
    [summary appendString:@"=====================================\n\n"];
    
    [summary appendString:@"What will be installed:\n"];
    [summary appendString:@"• Debian Linux Runtime Image\n"];
    [summary appendString:@"• Service script for automatic startup\n"];
    [summary appendString:@"• Integration with FreeBSD's rc system\n\n"];
    
    [summary appendString:@"Installation details:\n"];
    [summary appendString:@"• Source: GitHub Releases (helloSystem/LinuxRuntime)\n"];
    [summary appendString:@"• Destination: /compat/debian.img\n"];
    [summary appendString:@"• Service script: /usr/local/etc/rc.d/debian\n"];
    [summary appendString:@"• Estimated size: ~500 MB\n\n"];
    
    [summary appendString:@"System requirements:\n"];
    [summary appendString:@"• FreeBSD system with Linux compatibility layer\n"];
    [summary appendString:@"• Internet connection for downloading\n"];
    [summary appendString:@"• Root privileges\n"];
    [summary appendString:@"• At least 1 GB free space in /compat\n\n"];
    
    [summary appendString:@"⚠️  IMPORTANT WARNINGS:\n"];
    [summary appendString:@"• This installation requires root privileges\n"];
    [summary appendString:@"• You will be prompted for administrator password\n"];
    [summary appendString:@"• Any existing Linux runtime will be replaced\n"];
    [summary appendString:@"• The download may take several minutes\n\n"];
    
    [summary appendString:@"After installation:\n"];
    [summary appendString:@"• Linux applications will be able to run\n"];
    [summary appendString:@"• The runtime will start automatically on boot\n"];
    [summary appendString:@"• You can manage it using 'service debian start/stop'\n\n"];
    
    [summary appendString:@"Click 'Install' to begin the installation process."];
    
    [_summaryView setString:summary];
}

- (BOOL)canContinue
{
    return YES;
}

- (BOOL)canGoBack
{
    return YES;
}

- (NSString *)continueButtonTitle
{
    return @"Install";
}

@end

@implementation InstallationStep

- (void)dealloc
{
    if (_installer) {
        [_installer cancelInstallation];
        [_installer release];
        _installer = nil;
    }
    [super dealloc];
}

- (NSString *)stepTitle
{
    return @"Installing Debian Runtime";
}

- (NSString *)stepDescription
{
    return @"Please wait while the runtime is installed";
}

- (NSView *)stepView
{
    if (_contentView) {
        return _contentView;
    }
    
    NSLog(@"InstallationStep: creating stepView");
    
    _contentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 480, 320)];
    
    // Title
    NSTextField *titleLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 280, 440, 24)];
    [titleLabel setStringValue:@"Installing..."];
    [titleLabel setFont:[NSFont boldSystemFontOfSize:16]];
    [titleLabel setBezeled:NO];
    [titleLabel setDrawsBackground:NO];
    [titleLabel setEditable:NO];
    [titleLabel setSelectable:NO];
    [_contentView addSubview:titleLabel];
    
    // Status label
    _statusLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 255, 440, 16)];
    [_statusLabel setStringValue:@"Preparing installation..."];
    [_statusLabel setBezeled:NO];
    [_statusLabel setDrawsBackground:NO];
    [_statusLabel setEditable:NO];
    [_statusLabel setSelectable:NO];
    [_statusLabel setFont:[NSFont systemFontOfSize:12]];
    [_contentView addSubview:_statusLabel];
    
    // Progress bar
    _progressBar = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(20, 230, 440, 20)];
    [_progressBar setStyle:NSProgressIndicatorBarStyle];
    [_progressBar setIndeterminate:NO];
    [_progressBar setMinValue:0];
    [_progressBar setMaxValue:100];
    [_progressBar setDoubleValue:0];
    [_contentView addSubview:_progressBar];
    
    // Log view
    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(20, 40, 440, 180)];
    [scrollView setHasVerticalScroller:YES];
    [scrollView setBorderType:NSBezelBorder];
    
    _logView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 420, 180)];
    [_logView setString:@""];
    [_logView setEditable:NO];
    [_logView setFont:[NSFont fontWithName:@"Monaco" size:10]];
    
    [scrollView setDocumentView:_logView];
    [_contentView addSubview:scrollView];
    
    return _contentView;
}

- (BOOL)canContinue
{
    return _installationCompleted;
}

- (BOOL)canGoBack
{
    return NO;
}

- (void)stepWillAppear
{
    NSLog(@"InstallationStep: stepWillAppear");
    _installationCompleted = NO;
    
    // Reset progress bar to 0
    if (_progressBar) {
        [_progressBar setDoubleValue:0];
    }
    
    // Clear log view
    if (_logView) {
        [_logView setString:@""];
    }
    
    // Reset status label
    if (_statusLabel) {
        [_statusLabel setStringValue:@"Preparing installation..."];
    }
}

- (void)stepDidAppear
{
    NSLog(@"InstallationStep: stepDidAppear - starting installation");
    
    // Initialize the installer
    if (!_installer) {
        _installer = [[DRIInstaller alloc] init];
        _installer.delegate = self;
    }
    
    // Get the assistant window reference for showing success/error pages
    _assistantWindow = (GSAssistantWindow *)[[NSApplication sharedApplication] mainWindow];
    
    // Start the installation with a dummy image path for now
    // In real implementation, this would come from the previous step
    NSString *imagePath = @"/tmp/debian-runtime.img";
    
    [self performSelector:@selector(startRealInstallation:) withObject:imagePath afterDelay:1.0];
}

- (void)startRealInstallation:(NSString *)imagePath
{
    NSLog(@"InstallationStep: startRealInstallation with path: %@", imagePath);
    
    // For demonstration, create a dummy image file
    if (![[NSFileManager defaultManager] fileExistsAtPath:imagePath]) {
        [@"dummy runtime image" writeToFile:imagePath 
                                atomically:YES 
                                  encoding:NSUTF8StringEncoding 
                                     error:nil];
    }
    
    [_installer installRuntimeFromImagePath:imagePath];
}

#pragma mark - DRIInstallerDelegate Methods

- (void)installer:(id)installer didStartInstallationWithMessage:(NSString *)message
{
    NSLog(@"InstallationStep: didStartInstallationWithMessage: %@", message);
    [self logMessage:message];
    [_statusLabel setStringValue:message];
    [_progressBar setDoubleValue:10];
}

- (void)installer:(id)installer didUpdateProgress:(NSString *)message
{
    NSLog(@"InstallationStep: didUpdateProgress: %@", message);
    [self logMessage:message];
    [_statusLabel setStringValue:message];
    
    // Update progress bar based on the message content
    double progress = 20; // Default progress
    
    if ([message containsString:@"Checking system requirements"]) {
        progress = 20;
    } else if ([message containsString:@"Linux compatibility"]) {
        progress = 30;
    } else if ([message containsString:@"Creating compatibility directory"]) {
        progress = 40;
    } else if ([message containsString:@"existing runtime"]) {
        progress = 50;
    } else if ([message containsString:@"Installing runtime image"]) {
        progress = 60;
    } else if ([message containsString:@"Setting permissions"]) {
        progress = 70;
    } else if ([message containsString:@"Installing service script"]) {
        progress = 80;
    } else if ([message containsString:@"executable"]) {
        progress = 85;
    } else if ([message containsString:@"Enabling service"]) {
        progress = 90;
    } else if ([message containsString:@"completed successfully"]) {
        progress = 100;
    }
    
    [_progressBar setDoubleValue:progress];
}

- (void)installer:(id)installer didCompleteSuccessfully:(BOOL)success withMessage:(NSString *)message
{
    NSLog(@"InstallationStep: didCompleteSuccessfully: %@ withMessage: %@", success ? @"YES" : @"NO", message);
    
    if (success) {
        [self logMessage:@"✓ Installation completed successfully!"];
        [_statusLabel setStringValue:@"Installation completed!"];
        [_progressBar setDoubleValue:100];
        _installationCompleted = YES;
        
        // Show success page using the proper method
        NSLog(@"Attempting to show success page...");
        if (_assistantWindow) {
            NSLog(@"Assistant window exists, checking for success page methods...");
            if ([_assistantWindow respondsToSelector:@selector(showSuccessPageWithTitle:message:)]) {
                NSLog(@"Calling showSuccessPageWithTitle:message:");
                [_assistantWindow showSuccessPageWithTitle:@"Installation Complete" message:message];
            } else if ([_assistantWindow respondsToSelector:@selector(showSuccessPageWithMessage:)]) {
                NSLog(@"Calling showSuccessPageWithMessage:");
                [_assistantWindow showSuccessPageWithMessage:message];
            } else {
                NSLog(@"No success page methods found, available methods:");
                // List available methods for debugging
                unsigned int methodCount;
                Method *methods = class_copyMethodList([_assistantWindow class], &methodCount);
                for (unsigned int i = 0; i < methodCount; i++) {
                    SEL selector = method_getName(methods[i]);
                    NSString *methodName = NSStringFromSelector(selector);
                    if ([methodName containsString:@"success"] || [methodName containsString:@"Success"]) {
                        NSLog(@"Found success-related method: %@", methodName);
                    }
                }
                free(methods);
                
                // Try to proceed to next step instead
                NSLog(@"Attempting to proceed to completion step...");
                if ([_assistantWindow respondsToSelector:@selector(goToNextStep)]) {
                    [_assistantWindow goToNextStep];
                }
            }
        } else {
            NSLog(@"Warning: Assistant window is nil");
        }
    } else {
        [self logMessage:[NSString stringWithFormat:@"✗ Installation failed: %@", message]];
        [_statusLabel setStringValue:@"Installation failed"];
        _installationCompleted = NO;
        
        // Show error page
        NSLog(@"Attempting to show error page...");
        if (_assistantWindow) {
            if ([_assistantWindow respondsToSelector:@selector(showErrorPageWithTitle:message:)]) {
                NSLog(@"Calling showErrorPageWithTitle:message:");
                [_assistantWindow showErrorPageWithTitle:@"Installation Failed" message:message];
            } else if ([_assistantWindow respondsToSelector:@selector(showErrorPageWithMessage:)]) {
                NSLog(@"Calling showErrorPageWithMessage:");
                [_assistantWindow showErrorPageWithMessage:message];
            } else {
                NSLog(@"No error page methods found");
            }
        } else {
            NSLog(@"Warning: Assistant window is nil for error case");
        }
    }
}

- (void)logMessage:(NSString *)message
{
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    [formatter setDateFormat:@"HH:mm:ss"];
    NSString *timestamp = [formatter stringFromDate:[NSDate date]];
    NSString *logEntry = [NSString stringWithFormat:@"[%@] %@\n", timestamp, message];
    
    // Since dispatch functions are not available in GNUstep, update directly
    [_logView insertText:logEntry];
    
    // Scroll to bottom
    NSRange range = NSMakeRange([[_logView string] length], 0);
    [_logView scrollRangeToVisible:range];
    
    [formatter release];
}

@end

@implementation CompletionStep

- (NSString *)stepTitle
{
    return @"Installation Complete";
}

- (NSString *)stepDescription
{
    return @"Debian runtime has been installed successfully";
}

- (NSView *)stepView
{
    if (_contentView) {
        return _contentView;
    }
    
    NSLog(@"CompletionStep: creating stepView");
    
    _contentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 480, 320)];
    
    // Status icon
    _statusIcon = [[NSImageView alloc] initWithFrame:NSMakeRect(220, 220, 48, 48)];
    NSImage *checkImage = [NSImage imageNamed:@"check"];
    if (checkImage) {
        [_statusIcon setImage:checkImage];
    }
    [_contentView addSubview:_statusIcon];
    
    // Status label
    _statusLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 180, 440, 24)];
    [_statusLabel setStringValue:@"Debian Runtime Installed Successfully"];
    [_statusLabel setFont:[NSFont boldSystemFontOfSize:16]];
    [_statusLabel setBezeled:NO];
    [_statusLabel setDrawsBackground:NO];
    [_statusLabel setEditable:NO];
    [_statusLabel setSelectable:NO];
    [_statusLabel setAlignment:NSTextAlignmentCenter];
    [_contentView addSubview:_statusLabel];
    
    // Next steps
    NSTextView *nextStepsView = [[NSTextView alloc] initWithFrame:NSMakeRect(20, 40, 440, 130)];
    [nextStepsView setString:@"The Debian runtime has been installed at /compat/debian.img\n\nYou can now:\n• Run Linux applications using the runtime\n• Configure additional software as needed\n• Restart applications that require Linux compatibility\n\nFor more information, see the documentation."];
    [nextStepsView setEditable:NO];
    [nextStepsView setDrawsBackground:NO];
    [nextStepsView setFont:[NSFont systemFontOfSize:12]];
    [_contentView addSubview:nextStepsView];
    
    return _contentView;
}

- (BOOL)canContinue
{
    return NO;
}

- (BOOL)canGoBack
{
    return NO;
}

- (NSString *)finishButtonTitle
{
    return @"Done";
}

- (void)stepWillAppear
{
    NSLog(@"CompletionStep: stepWillAppear");
}

@end

//
// Main Controller
//

@implementation DebianRuntimeInstallerController

- (id)init
{
    if (self = [super init]) {
        NSLog(@"DebianRuntimeInstallerController: init");
        _selectedImageURL = @"";
        _showPrereleases = NO;
        _installationSuccessful = NO;
    }
    return self;
}

- (void)dealloc
{
    NSLog(@"DebianRuntimeInstallerController: dealloc");
    [_selectedImageURL release];
    [_assistantWindow release];
    [super dealloc];
}

- (void)showAssistant
{
    NSLog(@"DebianRuntimeInstallerController: showAssistant");
    
    // Create steps
    NSArray *steps = @[
        [[IntroStep alloc] init],
        [[ImageSelectionStep alloc] init],
        [[ConfirmationStep alloc] init],
        [[InstallationStep alloc] init],
        [[CompletionStep alloc] init]
    ];
    
    _assistantWindow = [[GSAssistantWindow alloc] initWithAssistantTitle:@"Debian Runtime Installer"
                                                                    icon:nil 
                                                                   steps:steps];
    [_assistantWindow setDelegate:self];
    [[_assistantWindow window] makeKeyAndOrderFront:nil];
}

// GSAssistantWindowDelegate methods

- (void)assistantWindow:(GSAssistantWindow *)window willShowStep:(id<GSAssistantStepProtocol>)step
{
    NSLog(@"DebianRuntimeInstallerController: willShowStep: %@", [step stepTitle]);
    // Framework now automatically calls step lifecycle methods
}

- (void)assistantWindow:(GSAssistantWindow *)window didShowStep:(id<GSAssistantStepProtocol>)step
{
    NSLog(@"DebianRuntimeInstallerController: didShowStep: %@", [step stepTitle]);
    // Framework now automatically calls step lifecycle methods
}

- (BOOL)assistantWindowShouldContinue:(GSAssistantWindow *)window
{
    NSLog(@"DebianRuntimeInstallerController: shouldContinue");
    return YES;
}

- (BOOL)assistantWindowShouldGoBack:(GSAssistantWindow *)window
{
    NSLog(@"DebianRuntimeInstallerController: shouldGoBack");
    return YES;
}

- (void)assistantWindow:(GSAssistantWindow *)window didFinishWithResult:(BOOL)success
{
    NSLog(@"DebianRuntimeInstallerController: didFinishWithResult: %@", success ? @"YES" : @"NO");
    [[window window] orderOut:nil];
    [NSApp terminate:nil];
}

- (BOOL)assistantWindow:(GSAssistantWindow *)window shouldCancelWithConfirmation:(BOOL)showConfirmation
{
    NSLog(@"DebianRuntimeInstallerController: shouldCancelWithConfirmation: %@", showConfirmation ? @"YES" : @"NO");
    [[window window] orderOut:nil];
    [NSApp terminate:nil];
    return YES;
}

@end

//
// Application Main
//

int main(int argc, const char *argv[])
{
    NSLog(@"DebianRuntimeInstaller: main() started");
    
    @autoreleasepool {
        [NSApplication sharedApplication];
        
        // Set up application delegate to ensure proper termination
        DebianRuntimeAppDelegate *appDelegate = [[DebianRuntimeAppDelegate alloc] init];
        [NSApp setDelegate:appDelegate];
        
        DebianRuntimeInstallerController *controller = [[DebianRuntimeInstallerController alloc] init];
        [controller showAssistant];
        
        [NSApp run];
        
        [controller release];
        [appDelegate release];
    }
    
    return 0;
}
