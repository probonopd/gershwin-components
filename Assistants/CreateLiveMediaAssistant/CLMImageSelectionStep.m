//
// CLMImageSelectionStep.m
// Create Live Media Assistant - Image Selection Step
//

#import "CLMImageSelectionStep.h"
#import "CLMController.h"
#import "CLMGitHubAPI.h"
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
        NSLog(@"CLMImageSelectionStep: requesting navigation button update");
        GSAssistantWindow *assistantWindow = (GSAssistantWindow *)wc;
        // Always call the public method - it should handle layout-specific logic
        [assistantWindow updateNavigationButtons];
    } else {
        NSLog(@"CLMImageSelectionStep: could not find GSAssistantWindow to update navigation (wc=%@)", wc);
    }
}

- (id)init
{
    if (self = [super init]) {
        NSLog(@"CLMImageSelectionStep: init");
        _availableReleases = [[NSMutableArray alloc] init];
        _isLoading = NO;
        [self setupView];
    }
    return self;
}

- (void)dealloc
{
    NSLog(@"CLMImageSelectionStep: dealloc");
    [_stepView release];
    [_availableReleases release];
    [_releaseArrayController release];
    [super dealloc];
}

- (void)setupView
{
    NSLog(@"CLMImageSelectionStep: setupView");
    
    // Fit step view to installer card inner area
    _stepView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 354, 204)];
    
    // Repository selection
    NSTextField *repoLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(8, 176, 86, 18)];
    [repoLabel setStringValue:@"Repository:"];
    [repoLabel setBezeled:NO];
    [repoLabel setDrawsBackground:NO];
    [repoLabel setEditable:NO];
    [repoLabel setSelectable:NO];
    [_stepView addSubview:repoLabel];
    [repoLabel release];
    
    _repositoryPopUp = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(96, 174, 250, 22)];
    [_repositoryPopUp addItemWithTitle:@"probonopd/ghostbsd-build"];
    [_repositoryPopUp addItemWithTitle:@"ventoy/Ventoy"];
    [_repositoryPopUp addItemWithTitle:@"Other..."];
    [_repositoryPopUp addItemWithTitle:@"Local ISO file..."];
    [_repositoryPopUp setTarget:self];
    [_repositoryPopUp setAction:@selector(repositoryChanged:)];
    [_stepView addSubview:_repositoryPopUp];
    [_repositoryPopUp release];
    
    // Prerelease checkbox
    _prereleaseCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(8, 152, 220, 18)];
    [_prereleaseCheckbox setButtonType:NSSwitchButton];
    [_prereleaseCheckbox setTitle:@"Show Pre-release builds"];
    [_prereleaseCheckbox setState:NSOffState];
    [_prereleaseCheckbox setTarget:self];
    [_prereleaseCheckbox setAction:@selector(prereleaseChanged:)];
    [_stepView addSubview:_prereleaseCheckbox];
    [_prereleaseCheckbox release];
    
    // Loading indicator and label
    _loadingIndicator = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(240, 152, 16, 16)];
    [_loadingIndicator setStyle:NSProgressIndicatorSpinningStyle];
    [_loadingIndicator setDisplayedWhenStopped:NO];
    [_stepView addSubview:_loadingIndicator];
    [_loadingIndicator release];
    
    _loadingLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(260, 150, 90, 18)];
    [_loadingLabel setStringValue:@"Loading..."];
    [_loadingLabel setBezeled:NO];
    [_loadingLabel setDrawsBackground:NO];
    [_loadingLabel setEditable:NO];
    [_loadingLabel setSelectable:NO];
    [_loadingLabel setHidden:YES];
    [_stepView addSubview:_loadingLabel];
    [_loadingLabel release];
    
    // Release table (compact)
    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(8, 36, 338, 112)];
    [scrollView setHasVerticalScroller:YES];
    [scrollView setHasHorizontalScroller:NO];
    [scrollView setBorderType:NSBezelBorder];
    
    _releaseTableView = [[NSTableView alloc] init];
    [_releaseTableView setAllowsMultipleSelection:NO];
    [_releaseTableView setAllowsEmptySelection:YES];
    
    // Add columns
    NSTableColumn *nameColumn = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    [[nameColumn headerCell] setStringValue:@"Release"];
    [nameColumn setWidth:190];
    [_releaseTableView addTableColumn:nameColumn];
    [nameColumn release];
    
    NSTableColumn *versionColumn = [[NSTableColumn alloc] initWithIdentifier:@"version"];
    [[versionColumn headerCell] setStringValue:@"Version"];
    [versionColumn setWidth:70];
    [_releaseTableView addTableColumn:versionColumn];
    [versionColumn release];
    
    NSTableColumn *sizeColumn = [[NSTableColumn alloc] initWithIdentifier:@"sizeFormatted"];
    [[sizeColumn headerCell] setStringValue:@"Size"];
    [sizeColumn setWidth:70];
    [_releaseTableView addTableColumn:sizeColumn];
    [sizeColumn release];
    
    [scrollView setDocumentView:_releaseTableView];
    [_stepView addSubview:scrollView];
    [scrollView release];
    
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
    
    // Info labels (compact, below the table)
    _dateLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(8, 20, 338, 14)];
    [_dateLabel setStringValue:@""];
    [_dateLabel setBezeled:NO];
    [_dateLabel setDrawsBackground:NO];
    [_dateLabel setEditable:NO];
    [_dateLabel setSelectable:NO];
    [_dateLabel setFont:[NSFont systemFontOfSize:10]];
    [_stepView addSubview:_dateLabel];
    [_dateLabel release];
    
    _urlLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(8, 6, 338, 14)];
    [_urlLabel setStringValue:@""];
    [_urlLabel setBezeled:NO];
    [_urlLabel setDrawsBackground:NO];
    [_urlLabel setEditable:NO];
    [_urlLabel setSelectable:NO];
    [_urlLabel setFont:[NSFont systemFontOfSize:10]];
    [_stepView addSubview:_urlLabel];
    [_urlLabel release];
    
    _sizeLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(8, -8, 338, 14)];
    [_sizeLabel setStringValue:@""];
    [_sizeLabel setBezeled:NO];
    [_sizeLabel setDrawsBackground:NO];
    [_sizeLabel setEditable:NO];
    [_sizeLabel setSelectable:NO];
    [_sizeLabel setFont:[NSFont systemFontOfSize:10]];
    [_stepView addSubview:_sizeLabel];
    [_sizeLabel release];
}

- (void)repositoryChanged:(id)sender
{
    NSLog(@"CLMImageSelectionStep: repositoryChanged");
    
    NSInteger selectedIndex = [_repositoryPopUp indexOfSelectedItem];
    
    if (selectedIndex == 2) { // Other...
        NSAlert *alert = [NSAlert alertWithMessageText:@"Custom Repository"
                                         defaultButton:@"OK"
                                       alternateButton:@"Cancel"
                                           otherButton:nil
                             informativeTextWithFormat:@"Enter the GitHub API URL for releases:"];
        
        NSTextField *input = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 300, 24)];
        [input setStringValue:@"https://api.github.com/repos/owner/repo/releases"];
        
        // Create a simple input dialog instead of using setAccessoryView
        NSInteger response = [alert runModal];
        [input release];
        
        if (response == NSAlertDefaultReturn) {
            // For now, use a hardcoded URL or implement a proper input dialog
            NSString *customURL = @"https://api.github.com/repos/probonopd/ghostbsd-build/releases";
            [self loadReleasesFromURL:customURL];
        }
    }
    else if (selectedIndex == 3) { // Local ISO file...
        NSOpenPanel *openPanel = [NSOpenPanel openPanel];
        [openPanel setCanChooseFiles:YES];
        [openPanel setCanChooseDirectories:NO];
        [openPanel setAllowsMultipleSelection:NO];
        [openPanel setAllowedFileTypes:@[@"iso", @"img"]];
        
        NSInteger result = [openPanel runModal];
        if (result == NSFileHandlingPanelOKButton) {
            NSArray *filenames = [openPanel filenames];
            if ([filenames count] > 0) {
                [self loadLocalFile:[filenames objectAtIndex:0]];
            }
        }
    }
    else {
        // Standard repositories
        NSArray *repoURLs = @[
            @"https://api.github.com/repos/probonopd/ghostbsd-build/releases",
            @"https://api.github.com/repos/ventoy/Ventoy/releases"
        ];
        
        if (selectedIndex < (NSInteger)[repoURLs count]) {
            [self loadReleasesFromURL:[repoURLs objectAtIndex:selectedIndex]];
        }
    }
}

- (void)prereleaseChanged:(id)sender
{
    NSLog(@"CLMImageSelectionStep: prereleaseChanged");
    [self repositoryChanged:nil]; // Reload current repository with new prerelease setting
}

- (void)loadReleasesFromURL:(NSString *)repoURL
{
    NSLog(@"CLMImageSelectionStep: loadReleasesFromURL: %@", repoURL);
    
    if (_isLoading) {
        return;
    }
    
    _isLoading = YES;
    [_loadingIndicator startAnimation:nil];
    [_loadingLabel setHidden:NO];
    [_availableReleases removeAllObjects];
    [_releaseArrayController rearrangeObjects];
    // Force table view to reload its data
    [_releaseTableView reloadData];
    // Clear any existing selection and update buttons while loading
    [_releaseTableView deselectAll:nil];
    [self requestNavigationUpdate];
    
    // Check internet connection
    if (![_controller checkInternetConnection]) {
        [self showError:@"This requires an active internet connection."];
        return;
    }
    
    // Perform in background - for now do synchronously
    // TODO: Implement proper background threading for GNUstep
    BOOL includePrereleases = ([_prereleaseCheckbox state] == NSOnState);
    NSArray *releases = [CLMGitHubAPI fetchReleasesFromRepository:repoURL includePrereleases:includePrereleases];
    NSArray *isoAssets = [CLMGitHubAPI extractISOAssetsFromReleases:releases 
                                             includePrereleases:includePrereleases];
    
    [self finishLoadingWithAssets:isoAssets];
}

- (void)loadLocalFile:(NSString *)filePath
{
    NSLog(@"CLMImageSelectionStep: loadLocalFile: %@", filePath);
    
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
    NSLog(@"CLMImageSelectionStep: finishLoadingWithAssets: %lu", (unsigned long)[assets count]);
    
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
    NSLog(@"CLMImageSelectionStep: showError: %@", message);
    
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
    NSLog(@"CLMImageSelectionStep: tableSelectionChanged");
    
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
            [formatter release];
        } else {
            [_dateLabel setStringValue:@""];
        }
        
        NSString *htmlURL = [selectedRelease objectForKey:@"htmlURL"];
        if (htmlURL && [htmlURL length] > 0) {
            [_urlLabel setStringValue:[NSString stringWithFormat:@"URL: %@", htmlURL]];
        } else {
            [_urlLabel setStringValue:@""];
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
        
        [_dateLabel setStringValue:@""];
        [_urlLabel setStringValue:@""];
        [_sizeLabel setStringValue:@""];
    }
    
    // Ask the assistant window to re-evaluate canContinue and update button state
    [self requestNavigationUpdate];
}

#pragma mark - GSAssistantStepProtocol

- (NSString *)stepTitle
{
    return @"Select Live Image";
}

- (NSString *)stepDescription  
{
    return @"Choose a Live image to download and write to the medium";
}

- (NSView *)stepView
{
    return _stepView;
}

- (BOOL)canContinue
{
    NSLog(@"CLMImageSelectionStep: canContinue called");
    NSIndexSet *selectedIndexes = [_releaseTableView selectedRowIndexes];
    NSLog(@"CLMImageSelectionStep: selectedRowIndexes count = %lu", (unsigned long)[selectedIndexes count]);
    if ([selectedIndexes count] == 1) {
        NSInteger selectedRow = [_releaseTableView selectedRow];
        NSLog(@"CLMImageSelectionStep: selectedRow = %ld", (long)selectedRow);
        if (selectedRow >= 0 && selectedRow < (NSInteger)[_availableReleases count]) {
            NSDictionary *selectedRelease = [_availableReleases objectAtIndex:selectedRow];
            NSNumber *size = [selectedRelease objectForKey:@"size"];
            NSString *url = [selectedRelease objectForKey:@"url"];
            NSString *name = [selectedRelease objectForKey:@"name"];
            NSLog(@"CLMImageSelectionStep: name=%@ url=%@ size=%@", name, url, size);
            if ([url length] > 0 && [size longLongValue] > 0 &&
                ([name hasSuffix:@".iso"] || [name hasSuffix:@".img"])) {
                NSLog(@"CLMImageSelectionStep: canContinue = YES");
                return YES;
            }
        }
    }
    NSLog(@"CLMImageSelectionStep: canContinue = NO");
    return NO;
}

- (void)stepWillAppear
{
    NSLog(@"CLMImageSelectionStep: stepWillAppear");
    
    // Ensure navigation buttons start with correct state (should be disabled if no selection)
    [self requestNavigationUpdate];
    
    // Load default repository when this step first appears
    if ([_availableReleases count] == 0 && !_isLoading) {
        [self loadReleasesFromURL:@"https://api.github.com/repos/probonopd/ghostbsd-build/releases"];
    }
}

- (void)stepDidAppear
{
    NSLog(@"CLMImageSelectionStep: stepDidAppear");
}

- (void)stepWillDisappear
{
    NSLog(@"CLMImageSelectionStep: stepWillDisappear");
}

@end
