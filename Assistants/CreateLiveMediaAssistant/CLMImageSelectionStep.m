/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */


//
// CLMImageSelectionStep.m
// Create Live Media Assistant - Image Selection Step
//

#import "CLMImageSelectionStep.h"
#import "CLMController.h"
#import "CLMConstants.h"
#import "CLMGitHubAPI.h"
#import "CLMStreamOperation.h"
#import <GSNetworkUtilities.h>
#import <GSDiskUtilities.h>
#import "GSAssistantFramework.h"

@implementation CLMImageSelectionStep

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
        NSDebugLLog(@"gwcomp", @"CLMImageSelectionStep: requesting navigation button update");
        GSAssistantWindow *assistantWindow = (GSAssistantWindow *)wc;
        // Always call the public method - it should handle layout-specific logic
        [assistantWindow updateNavigationButtons];
    } else {
        NSDebugLLog(@"gwcomp", @"CLMImageSelectionStep: could not find GSAssistantWindow to update navigation (wc=%@)", wc);
    }
}

- (id)init
{
    if (self = [super init]) {
        NSDebugLLog(@"gwcomp", @"CLMImageSelectionStep: init");
        _availableReleases = [[NSMutableArray alloc] init];
        _isLoading = NO;
        [self setupView];
    }
    return self;
}

- (void)setupView
{
    NSDebugLLog(@"gwcomp", @"CLMImageSelectionStep: setupView");
    
    // Fit step view to installer card inner area
    _stepView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 354, 228)];
    
    // Repository selection (flush top)
    NSTextField *repoLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(8, 210, 86, 16)];
    [repoLabel setStringValue:NSLocalizedString(@"Repository:", @"")];
    [repoLabel setBezeled:NO];
    [repoLabel setDrawsBackground:NO];
    [repoLabel setEditable:NO];
    [repoLabel setSelectable:NO];
    [_stepView addSubview:repoLabel];
    
    _repositoryPopUp = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(96, 208, 250, 20)];
    NSArray<NSString *> *repos = CLMAvailableRepositories();
    for (NSString *repoURL in repos) {
        NSString *repoTitle = repoURL;
        NSRange prefixRange = [repoTitle rangeOfString:@"https://api.github.com/repos/"];
        if (prefixRange.location != NSNotFound) {
            repoTitle = [repoTitle substringFromIndex:prefixRange.location + prefixRange.length];
            NSRange suffixRange = [repoTitle rangeOfString:@"/releases"];
            if (suffixRange.location != NSNotFound) {
                repoTitle = [repoTitle substringToIndex:suffixRange.location];
            }
        }
        [_repositoryPopUp addItemWithTitle:NSLocalizedString(repoTitle, @"")];
    }
    [_repositoryPopUp addItemWithTitle:NSLocalizedString(@"Other...", @"")];
    [_repositoryPopUp addItemWithTitle:NSLocalizedString(@"Local ISO file...", @"")];
    [_repositoryPopUp setTarget:self];
    [_repositoryPopUp setAction:@selector(repositoryChanged:)];
    [_stepView addSubview:_repositoryPopUp];
    
    // Prerelease checkbox
    _prereleaseCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(8, 188, 220, 18)];
    [_prereleaseCheckbox setButtonType:NSSwitchButton];
    [_prereleaseCheckbox setTitle:@"Show Pre-release builds"];
    [_prereleaseCheckbox setState:NSOffState];
    [_prereleaseCheckbox setTarget:self];
    [_prereleaseCheckbox setAction:@selector(prereleaseChanged:)];
    [_stepView addSubview:_prereleaseCheckbox];
    
    // Loading indicator and label
    _loadingIndicator = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(240, 188, 16, 16)];
    [_loadingIndicator setStyle:NSProgressIndicatorSpinningStyle];
    [_loadingIndicator setDisplayedWhenStopped:NO];
    [_stepView addSubview:_loadingIndicator];
    
    _loadingLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(260, 186, 90, 18)];
    [_loadingLabel setStringValue:NSLocalizedString(@"Loading...", @"")];
    [_loadingLabel setBezeled:NO];
    [_loadingLabel setDrawsBackground:NO];
    [_loadingLabel setEditable:NO];
    [_loadingLabel setSelectable:NO];
    [_loadingLabel setFont:[NSFont systemFontOfSize:11]];
    [_loadingLabel setHidden:YES];
    [_stepView addSubview:_loadingLabel];
    
    // Release table (flush below checkbox)
    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(8, 86, 338, 100)];
    [scrollView setHasVerticalScroller:YES];
    [scrollView setHasHorizontalScroller:NO];
    [scrollView setBorderType:NSBezelBorder];
    
    _releaseTableView = [[NSTableView alloc] init];
    [_releaseTableView setAllowsMultipleSelection:NO];
    [_releaseTableView setAllowsEmptySelection:YES];
    
    // Add columns
    NSTableColumn *nameColumn = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    [[nameColumn headerCell] setStringValue:NSLocalizedString(@"Release", @"")];
    [nameColumn setWidth:190];
    [_releaseTableView addTableColumn:nameColumn];
    
    NSTableColumn *versionColumn = [[NSTableColumn alloc] initWithIdentifier:@"version"];
    [[versionColumn headerCell] setStringValue:NSLocalizedString(@"Version", @"")];
    [versionColumn setWidth:70];
    [_releaseTableView addTableColumn:versionColumn];
    
    NSTableColumn *sizeColumn = [[NSTableColumn alloc] initWithIdentifier:@"sizeFormatted"];
    [[sizeColumn headerCell] setStringValue:NSLocalizedString(@"Size", @"")];
    [sizeColumn setWidth:70];
    [_releaseTableView addTableColumn:sizeColumn];
    
    [scrollView setDocumentView:_releaseTableView];
    [_stepView addSubview:scrollView];
    
    // Array controller for table data
    _releaseArrayController = [[NSArrayController alloc] init];
    [_releaseArrayController setContent:_availableReleases];
    
    [nameColumn bind:@"value" toObject:_releaseArrayController withKeyPath:@"arrangedObjects.name" options:nil];
    [versionColumn bind:@"value" toObject:_releaseArrayController withKeyPath:@"arrangedObjects.version" options:nil];
    [sizeColumn bind:@"value" toObject:_releaseArrayController withKeyPath:@"arrangedObjects.sizeFormatted" options:nil];
    
    [_releaseTableView bind:@"selectionIndexes" toObject:_releaseArrayController withKeyPath:@"selectionIndexes" options:nil];
    
    // Selection change notification
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(tableSelectionChanged:)
                                                 name:NSTableViewSelectionDidChangeNotification
                                               object:_releaseTableView];
    
    // Info labels below the table
    _dateLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(8, 70, 338, 14)];
    [_dateLabel setStringValue:NSLocalizedString(@"", @"")];
    [_dateLabel setBezeled:NO];
    [_dateLabel setDrawsBackground:NO];
    [_dateLabel setEditable:NO];
    [_dateLabel setSelectable:NO];
    [_dateLabel setFont:[NSFont systemFontOfSize:10]];
    [_stepView addSubview:_dateLabel];
    
    _urlLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(8, 26, 338, 42)];
    [_urlLabel setStringValue:NSLocalizedString(@"", @"")];
    [_urlLabel setBezeled:NO];
    [_urlLabel setDrawsBackground:NO];
    [_urlLabel setEditable:NO];
    [_urlLabel setSelectable:NO];
    [_urlLabel setFont:[NSFont systemFontOfSize:10]];
    [[_urlLabel cell] setLineBreakMode:NSLineBreakByWordWrapping];
    [[_urlLabel cell] setUsesSingleLineMode:NO];
    [_stepView addSubview:_urlLabel];
    
    _sizeLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(8, 10, 338, 14)];
    [_sizeLabel setStringValue:NSLocalizedString(@"", @"")];
    [_sizeLabel setBezeled:NO];
    [_sizeLabel setDrawsBackground:NO];
    [_sizeLabel setEditable:NO];
    [_sizeLabel setSelectable:NO];
    [_sizeLabel setFont:[NSFont systemFontOfSize:10]];
    [_stepView addSubview:_sizeLabel];
}

- (void)repositoryChanged:(id)sender
{
    NSDebugLLog(@"gwcomp", @"CLMImageSelectionStep: repositoryChanged");
    
    NSInteger selectedIndex = [_repositoryPopUp indexOfSelectedItem];
    
    NSInteger repoCount = (NSInteger)[CLMAvailableRepositories() count];
    if (selectedIndex == repoCount) { // Other...
        NSAlert *alert = [NSAlert alertWithMessageText:@"Custom Repository"
                                         defaultButton:@"OK"
                                       alternateButton:@"Cancel"
                                           otherButton:nil
                             informativeTextWithFormat:@"Enter the GitHub API URL for releases:"];
        
        NSTextField *input = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 400, 24)];
        [input setStringValue:NSLocalizedString(@"https://api.github.com/repos/owner/repo/releases", @"")];

        if ([alert respondsToSelector:@selector(setAccessoryView:)]) {
            // Newer AppKit/GNUstep may support accessory views on NSAlert
            [(id)alert setAccessoryView:input];
            NSInteger response = [alert runModal];
            if (response == NSAlertDefaultReturn) {
                NSString *customURL = [input stringValue];
                if ([customURL length] > 0) {
                    [self loadReleasesFromURL:customURL];
                }
            }
        } else {
            // Fallback for GNUstep without setAccessoryView: - create a small modal panel
            NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 420, 120)
                                                        styleMask:(NSTitledWindowMask | NSClosableWindowMask)
                                                          backing:NSBackingStoreBuffered
                                                            defer:NO];
            [panel setTitle:@"Custom Repository"];
            [panel center];

            NSView *contentView = [panel contentView];

            NSTextField *label = [[NSTextField alloc] initWithFrame:NSMakeRect(12, 72, 396, 24)];
            [label setStringValue:NSLocalizedString(@"Enter the GitHub API URL for releases:", @"")];
            [label setBezeled:NO];
            [label setDrawsBackground:NO];
            [label setEditable:NO];
            [label setSelectable:NO];
            [contentView addSubview:label];

            [input setFrame:NSMakeRect(12, 44, 396, 24)];
            [contentView addSubview:input];

            NSButton *okButton = [[NSButton alloc] initWithFrame:NSMakeRect(320, 10, 90, 24)];
            [okButton setTitle:@"OK"];
            [okButton setTarget:NSApp];
            [okButton setAction:@selector(stopModal)];
            [okButton setKeyEquivalent:@"\r"];
            [contentView addSubview:okButton];

            NSButton *cancelButton = [[NSButton alloc] initWithFrame:NSMakeRect(220, 10, 90, 24)];
            [cancelButton setTitle:@"Cancel"];
            [cancelButton setTarget:NSApp];
            [cancelButton setAction:@selector(abortModal)];
            [cancelButton setKeyEquivalent:@"\e"];
            [contentView addSubview:cancelButton];

            [panel setInitialFirstResponder:input];
            [panel makeFirstResponder:input];

            NSInteger response = [NSApp runModalForWindow:panel];
            if (response == NSRunStoppedResponse) {
                NSString *customURL = [input stringValue];
                if ([customURL length] > 0) {
                    [self loadReleasesFromURL:customURL];
                }
            }

            // Clean up
            [panel orderOut:nil];
        }
    }
    else if (selectedIndex == repoCount + 1) { // Local ISO file...
        NSOpenPanel *openPanel = [NSOpenPanel openPanel];
        [openPanel setCanChooseFiles:YES];
        [openPanel setCanChooseDirectories:NO];
        [openPanel setAllowsMultipleSelection:NO];
        [openPanel setAllowedFileTypes:@[@"iso", @"img",
                                         @"gz", @"gzip",
                                         @"xz",
                                         @"bz2", @"bzip2",
                                         @"zst", @"zstd",
                                         @"lz", @"lzma",
                                         @"Z",
                                         @"zip"]];
        
        NSInteger result = [openPanel runModal];
        if (result == NSFileHandlingPanelOKButton) {
            NSArray *filenames = [openPanel filenames];
            if ([filenames count] > 0) {
                [self loadLocalFile:[filenames objectAtIndex:0]];
            }
        }
    }
    else {
        NSArray *repoURLs = CLMAvailableRepositories();
        if (selectedIndex >= 0 && selectedIndex < (NSInteger)[repoURLs count]) {
            [self loadReleasesFromURL:[repoURLs objectAtIndex:selectedIndex]];
        }
    }
}

- (void)prereleaseChanged:(id)sender
{
    NSDebugLLog(@"gwcomp", @"CLMImageSelectionStep: prereleaseChanged");
    [self repositoryChanged:nil]; // Reload current repository with new prerelease setting
}

- (void)loadReleasesFromURL:(NSString *)repoURL
{
    NSDebugLLog(@"gwcomp", @"CLMImageSelectionStep: loadReleasesFromURL: %@", repoURL);
    
    if (_isLoading) {
        return;
    }
    
    // Check if this is a direct download URL (single image, not a GitHub API query)
    NSURL *parsedURL = [NSURL URLWithString:repoURL];
    if (parsedURL && [CLMStreamOperation isImageAssetName:[parsedURL lastPathComponent]]) {
        [self loadDirectDownloadURL:repoURL];
        return;
    }
    
    _isLoading = YES;
    [_loadingIndicator startAnimation:nil];
    [_loadingLabel setHidden:NO];
    [_availableReleases removeAllObjects];
    [_releaseArrayController rearrangeObjects];
    [_releaseTableView reloadData];
    [_releaseTableView deselectAll:nil];
    [self requestNavigationUpdate];
    
    // Check internet connection
    if (![_controller checkInternetConnection]) {
        [self showError:@"This requires an active internet connection."];
        return;
    }
    
    BOOL includePrereleases = ([_prereleaseCheckbox state] == NSOnState);
    NSArray *releases = [CLMGitHubAPI fetchReleasesFromRepository:repoURL includePrereleases:includePrereleases];
    NSArray *isoAssets = [CLMGitHubAPI extractISOAssetsFromReleases:releases 
                                             includePrereleases:includePrereleases];
    
    [self finishLoadingWithAssets:isoAssets];
}

- (void)loadDirectDownloadURL:(NSString *)urlString
{
    NSDebugLLog(@"gwcomp", @"CLMImageSelectionStep: loadDirectDownloadURL: %@", urlString);
    
    [_availableReleases removeAllObjects];
    
    NSMutableDictionary *asset = [NSMutableDictionary dictionary];
    [asset setObject:[urlString lastPathComponent] forKey:@"name"];
    [asset setObject:urlString forKey:@"url"];
    [asset setObject:[NSNumber numberWithLongLong:0] forKey:@"size"];
    [asset setObject:@"Direct URL" forKey:@"version"];
    [asset setObject:@"" forKey:@"htmlURL"];
    [asset setObject:[NSNumber numberWithBool:NO] forKey:@"prerelease"];
    [asset setObject:[NSDate date] forKey:@"updatedAt"];
    [asset setObject:[GSDiskUtilities formatSize:0] forKey:@"sizeFormatted"];
    
    [_availableReleases addObject:asset];
    [_releaseArrayController rearrangeObjects];
    [_releaseTableView reloadData];
    [_releaseArrayController setSelectionIndex:0];
    
    [self requestNavigationUpdate];

    // Fetch the real size via a HEAD request so the UI shows it and the
    // disk-space check can use it. Size stays 0 (unknown) until it arrives,
    // but the selection is already usable.
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        NSURL *url = [NSURL URLWithString:urlString];
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
        [req setHTTPMethod:@"HEAD"];
        [req setTimeoutInterval:15.0];

        NSHTTPURLResponse *response = nil;
        NSError *error = nil;
        [NSURLConnection sendSynchronousRequest:req
                              returningResponse:&response
                                          error:&error];
        long long size = 0;
        if (!error && response) {
            size = [response expectedContentLength];
        }
        NSLog(@"CLMImageSelectionStep: HEAD %@ -> size=%lld err=%@",
              urlString, size, error);

        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf2 = weakSelf;
            if (!strongSelf2 || size <= 0) return;
            [asset setObject:[NSNumber numberWithLongLong:size] forKey:@"size"];
            [asset setObject:[GSDiskUtilities formatSize:size] forKey:@"sizeFormatted"];
            [strongSelf2->_releaseArrayController rearrangeObjects];
            [strongSelf2->_releaseTableView reloadData];
            [strongSelf2 requestNavigationUpdate];
        });
    });
}

- (void)loadLocalFile:(NSString *)filePath
{
    NSDebugLLog(@"gwcomp", @"CLMImageSelectionStep: loadLocalFile: %@", filePath);
    
    [_availableReleases removeAllObjects];
    
    // Get file info
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSDictionary *attributes = [fileManager attributesOfItemAtPath:filePath error:nil];
    NSNumber *fileSize = [attributes objectForKey:NSFileSize];
    
    NSMutableDictionary *localFile = [NSMutableDictionary dictionary];
    [localFile setObject:[filePath lastPathComponent] forKey:@"name"];
    [localFile setObject:[NSString stringWithFormat:@"file://%@", filePath] forKey:@"url"];
    [localFile setObject:fileSize forKey:@"size"];
    [localFile setObject:@"Local File" forKey:@"version"];
    [localFile setObject:@"" forKey:@"htmlURL"];
    [localFile setObject:[NSNumber numberWithBool:NO] forKey:@"prerelease"];
    [localFile setObject:[NSDate date] forKey:@"updatedAt"];
    
    // Format size for display
    long long sizeInBytes = [fileSize longLongValue];
    [localFile setObject:[GSDiskUtilities formatSize:sizeInBytes] forKey:@"sizeFormatted"];
    
    [_availableReleases addObject:localFile];
    [_releaseArrayController rearrangeObjects];
    
    // Auto-select the file
    [_releaseArrayController setSelectionIndex:0];
    
    // Update navigation buttons to reflect new selection
    [self requestNavigationUpdate];
}

- (void)finishLoadingWithAssets:(NSArray *)assets
{
    NSDebugLLog(@"gwcomp", @"CLMImageSelectionStep: finishLoadingWithAssets: %lu", (unsigned long)[assets count]);
    
    _isLoading = NO;
    [_loadingIndicator stopAnimation:nil];
    [_loadingLabel setHidden:YES];
    
    // Add formatted size to each asset
    for (NSMutableDictionary *asset in assets) {
        NSNumber *size = [asset objectForKey:@"size"];
        [asset setObject:[GSDiskUtilities formatSize:[size longLongValue]] forKey:@"sizeFormatted"];
    }
    
    [_availableReleases addObjectsFromArray:assets];
    [_releaseArrayController rearrangeObjects];
    
    // Force table view to reload its data
    [_releaseTableView reloadData];
    
    // Clear any selection to ensure nothing is pre-selected
    [_releaseTableView deselectAll:nil];
    
    // Ensure navigation buttons reflect the current ability to continue (should be disabled with no selection)
    [self requestNavigationUpdate];
    
}

- (void)showError:(NSString *)message
{
    NSDebugLLog(@"gwcomp", @"CLMImageSelectionStep: showError: %@", message);
    
    _isLoading = NO;
    [_loadingIndicator stopAnimation:nil];
    [_loadingLabel setHidden:YES];
    
    // Update navigation buttons since loading state changed
    [self requestNavigationUpdate];
    
    NSAlert *alert = [NSAlert alertWithMessageText:@"Error"
                                     defaultButton:@"OK"
                                   alternateButton:nil
                                       otherButton:nil
                         informativeTextWithFormat:@"%@", message];
    [alert runModal];
}

- (void)tableSelectionChanged:(NSNotification *)notification
{
    NSDebugLLog(@"gwcomp", @"CLMImageSelectionStep: tableSelectionChanged");
    
    NSInteger selectedRow = [_releaseTableView selectedRow];
    
    if (selectedRow >= 0 && selectedRow < (NSInteger)[_availableReleases count]) {
        NSDictionary *selectedRelease = [_availableReleases objectAtIndex:selectedRow];
        
        // Update controller with selection
        _controller.selectedImageURL = [selectedRelease objectForKey:@"url"];
        _controller.selectedImageName = [selectedRelease objectForKey:@"name"];
        _controller.selectedImageSize = [[selectedRelease objectForKey:@"size"] longLongValue];
        
        // Update info labels
        NSDate *updatedAt = [selectedRelease objectForKey:@"updatedAt"];
        if (updatedAt) {
            NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
            [formatter setDateStyle:NSDateFormatterLongStyle];
            [formatter setTimeStyle:NSDateFormatterShortStyle];
            [_dateLabel setStringValue:[NSString stringWithFormat:@"Date: %@", [formatter stringFromDate:updatedAt]]];
        } else {
            [_dateLabel setStringValue:NSLocalizedString(@"", @"")];
        }
        
        NSString *downloadURL = [selectedRelease objectForKey:@"url"];
        if (downloadURL && [downloadURL length] > 0) {
            [_urlLabel setStringValue:downloadURL];
        } else {
            [_urlLabel setStringValue:NSLocalizedString(@"", @"")];
        }
        
        NSNumber *size = [selectedRelease objectForKey:@"size"];
        [_sizeLabel setStringValue:[NSString stringWithFormat:@"Size: %@ (%lld MB required)", 
                                   [GSDiskUtilities formatSize:[size longLongValue]],
                                   [size longLongValue] / (1024 * 1024)]];
    } else {
        // Clear selection
        _controller.selectedImageURL = @"";
        _controller.selectedImageName = @"";
        _controller.selectedImageSize = 0;
        
        [_dateLabel setStringValue:NSLocalizedString(@"", @"")];
        [_urlLabel setStringValue:NSLocalizedString(@"", @"")];
        [_sizeLabel setStringValue:NSLocalizedString(@"", @"")];
    }
    
    // Ask the assistant window to re-evaluate canContinue and update button state
    [self requestNavigationUpdate];
}

#pragma mark - GSAssistantStepProtocol

- (NSString *)stepTitle
{
    return NSLocalizedString(@"Select Live Image", @"");
}

- (NSString *)stepDescription  
{
    return NSLocalizedString(@"Choose a Live image to download and write to the medium", @"");
}

- (NSView *)stepView
{
    return _stepView;
}

- (BOOL)canContinue
{
    NSDebugLLog(@"gwcomp", @"CLMImageSelectionStep: canContinue called");
    NSIndexSet *selectedIndexes = [_releaseTableView selectedRowIndexes];
    NSDebugLLog(@"gwcomp", @"CLMImageSelectionStep: selectedRowIndexes count = %lu", (unsigned long)[selectedIndexes count]);
    if ([selectedIndexes count] == 1) {
        NSInteger selectedRow = [_releaseTableView selectedRow];
        NSDebugLLog(@"gwcomp", @"CLMImageSelectionStep: selectedRow = %ld", (long)selectedRow);
        if (selectedRow >= 0 && selectedRow < (NSInteger)[_availableReleases count]) {
            NSDictionary *selectedRelease = [_availableReleases objectAtIndex:selectedRow];
            NSNumber *size = [selectedRelease objectForKey:@"size"];
            NSString *url = [selectedRelease objectForKey:@"url"];
            NSString *name = [selectedRelease objectForKey:@"name"];
            NSDebugLLog(@"gwcomp", @"CLMImageSelectionStep: name=%@ url=%@ size=%@", name, url, size);
            // Size may be 0 (unknown) for direct download URLs; the image name
            // check is enough to allow continuing.
            if ([url length] > 0 &&
                [CLMStreamOperation isImageAssetName:name]) {
                NSDebugLLog(@"gwcomp", @"CLMImageSelectionStep: canContinue = YES");
                return YES;
            }
        }
    }
    NSDebugLLog(@"gwcomp", @"CLMImageSelectionStep: canContinue = NO");
    return NO;
}

- (void)stepWillAppear
{
    NSDebugLLog(@"gwcomp", @"CLMImageSelectionStep: stepWillAppear");
    
    // Ensure navigation buttons start with correct state (should be disabled if no selection)
    [self requestNavigationUpdate];
    
    // Load default repository when this step first appears
    if ([_availableReleases count] == 0 && !_isLoading) {
        NSArray *repos = CLMAvailableRepositories();
        if ([repos count] > 0) {
            [self loadReleasesFromURL:[repos objectAtIndex:0]];
        }
    }
}

- (void)stepDidAppear
{
    NSDebugLLog(@"gwcomp", @"CLMImageSelectionStep: stepDidAppear");
}

- (void)stepWillDisappear
{
    NSDebugLLog(@"gwcomp", @"CLMImageSelectionStep: stepWillDisappear");
}

@end
