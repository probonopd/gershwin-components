//
// DRIImageSelectionStep.m
// Debian Runtime Installer - Image Selection Step
//

#import "DRIImageSelectionStep.h"

@implementation DRIImageSelectionStep

- (instancetype)init
{
    if (self = [super init]) {
        NSLog(@"DRIImageSelectionStep: init");
        self.stepTitle = @"Select Debian Runtime Image";
        self.stepDescription = @"Choose a runtime image to install";
    }
    return self;
}

- (void)dealloc
{
    NSLog(@"DRIImageSelectionStep: dealloc");
    // Release retained subviews
    if (_urlField) { [_urlField release]; _urlField = nil; }
    if (_prereleaseCheckbox) { [_prereleaseCheckbox release]; _prereleaseCheckbox = nil; }
    if (_refreshButton) { [_refreshButton release]; _refreshButton = nil; }
    [super dealloc];
}

- (void)stepWillAppear
{
    NSLog(@"DRIImageSelectionStep: stepWillAppear");
    [super stepWillAppear];
    
    // Check network connectivity
    if (![GSNetworkUtilities checkInternetConnectivity]) {
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:@"No Internet Connection"]; 
        [alert setInformativeText:@"An internet connection is required to download runtime images. Please check your network settings and try again."];
        [alert addButtonWithTitle:@"OK"]; 
        [alert setAlertStyle:NSWarningAlertStyle];
        [alert runModal];
        [alert release];
        return;
    }
    
    // Check if Linux runtime already exists
    if ([[NSFileManager defaultManager] fileExistsAtPath:@"/compat/debian.img"] ||
        [[NSFileManager defaultManager] fileExistsAtPath:@"/compat/linux"] ||
        [[NSFileManager defaultManager] fileExistsAtPath:@"/compat/ubuntu"]) {
        
        NSLog(@"DRIImageSelectionStep: Linux runtime already exists, showing alert");
        
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:@"Linux Runtime Already Installed"]; 
        [alert setInformativeText:@"A Linux Runtime is already installed. Remove the existing one from /compat if you would like to install another one."];
        [alert runModal];
        [alert release];
        return;
    }
    
    // Start loading items (the base class will trigger loadItems)
    [self loadItems];
}

- (void)stepDidAppear
{
    NSLog(@"DRIImageSelectionStep: stepDidAppear");
}

#pragma mark - Action Methods

- (void)urlFieldChanged:(id)sender
{
    NSLog(@"DRIImageSelectionStep: URL field changed");
    // Clear table selection when custom URL is entered
    if ([_urlField stringValue].length > 0) {
        _selectedImageURL = nil;
        [self selectItemAtIndex:-1]; // Use base class method to clear selection
    }
}

- (void)refreshButtonClicked:(id)sender
{
    NSLog(@"DRIImageSelectionStep: refresh button clicked");
    [self refreshItems]; // Use base class method
}

- (void)prereleaseCheckboxChanged:(id)sender
{
    NSLog(@"DRIImageSelectionStep: prerelease checkbox changed");
    [self refreshItems]; // Use base class method
}

- (void)loadItems
{
    NSLog(@"DRIImageSelectionStep: loadItems (called by base class)");
    
    // Clear existing items
    [self.items removeAllObjects];
    
    // Check network connectivity first
    if (![GSNetworkUtilities checkInternetConnectivity]) {
        NSLog(@"DRIImageSelectionStep: No internet connectivity, using fallback data");
        // Could add fallback data here if needed
        return;
    }
    
    BOOL includePrereleases = (_prereleaseCheckbox && [_prereleaseCheckbox state] == NSOnState);
    
    // Use framework GitHub API
    NSArray *releases = [DRIGitHubAPI fetchReleasesFromRepository:@"helloSystem" name:@"LinuxRuntime" includePrereleases:includePrereleases];
    NSArray *imageAssets = [DRIGitHubAPI extractImageAssetsFromReleases:releases 
                                               includePrereleases:includePrereleases];
    
    // Add assets to items array
    for (NSDictionary *asset in imageAssets) {
        NSMutableDictionary *item = [asset mutableCopy];
        
        // Add formatted date
        NSDate *date = [asset objectForKey:@"updatedAt"]; 
        if (date) {
            NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
            [formatter setDateStyle:NSDateFormatterShortStyle];
            [formatter setTimeStyle:NSDateFormatterNoStyle];
            [item setObject:[formatter stringFromDate:date] forKey:@"dateFormatted"]; 
            [formatter release];
        } else {
            [item setObject:@"Unknown" forKey:@"dateFormatted"]; 
        }
        
        [self.items addObject:item];
        [item release];
    }
    
    NSLog(@"DRIImageSelectionStep: loaded %lu items", (unsigned long)self.items.count);
    
    // Refresh the table view
    [self.arrayController rearrangeObjects];
}

- (void)selectionDidChange
{
    NSLog(@"DRIImageSelectionStep: selectionDidChange");
    
    if (self.selectedItem) {
        NSDictionary *imageInfo = (NSDictionary *)self.selectedItem;
        _selectedImageURL = imageInfo[@"url"]; 
        NSLog(@"DRIImageSelectionStep: selected image: %@", _selectedImageURL);
        
        // Clear custom URL when selecting from table
        [_urlField setStringValue:@""];
    } else {
        _selectedImageURL = nil;
    }
}

#pragma mark - Public Methods

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
    
    if (self.selectedItem) {
        NSDictionary *imageInfo = (NSDictionary *)self.selectedItem;
        return [imageInfo[@"size"] longLongValue];
    }
    
    return 0;
}

- (NSString *)getSelectedImageName
{
    NSString *customURL = [[_urlField stringValue] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([customURL length] > 0 && [customURL hasPrefix:@"http"]) {
        return [[customURL lastPathComponent] stringByDeletingPathExtension];
    }
    
    if (self.selectedItem) {
        NSDictionary *imageInfo = (NSDictionary *)self.selectedItem;
        return imageInfo[@"name"]; 
    }
    
    return @"Unknown";
}

- (void)setupTableColumns
{
    NSLog(@"DRIImageSelectionStep: setupTableColumns");
    [self addTableColumn:@"name" title:@"Name" width:200 keyPath:@"name"]; 
    [self addTableColumn:@"sizeFormatted" title:@"Size" width:80 keyPath:@"sizeFormatted"]; 
    [self addTableColumn:@"dateFormatted" title:@"Date" width:120 keyPath:@"dateFormatted"]; 
}

- (void)setupAdditionalViews:(NSView *)containerView
{
    NSLog(@"DRIImageSelectionStep: setupAdditionalViews");
    
    // Ensure the table fits inside the installer card (354x204). Use 12pt margins.
    NSScrollView *scrollView = [self.tableView enclosingScrollView];
    if (scrollView) {
        // Table area below the controls
        NSRect tableFrame = NSMakeRect(12, 12, 330, 126);
        [scrollView setFrame:tableFrame];
    }
    
    // Custom URL section (top row)
    NSTextField *urlLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(12, 172, 70, 16)];
    [urlLabel setStringValue:@"Custom URL:"]; 
    [urlLabel setBezeled:NO];
    [urlLabel setDrawsBackground:NO];
    [urlLabel setEditable:NO];
    [urlLabel setSelectable:NO];
    [containerView addSubview:urlLabel];
    [urlLabel release];
    
    _urlField = [[NSTextField alloc] initWithFrame:NSMakeRect(88, 170, 184, 20)];
    [_urlField setStringValue:@""]; 
    [_urlField setPlaceholderString:@"https://github.com/user/repo/releases/download/tag/file.img"]; 
    [_urlField setTarget:self];
    [_urlField setAction:@selector(urlFieldChanged:)];
    [containerView addSubview:_urlField];
    
    // Refresh button (top-right)
    _refreshButton = [[NSButton alloc] initWithFrame:NSMakeRect(278, 168, 64, 24)];
    [_refreshButton setTitle:@"Refresh"]; 
    [_refreshButton setTarget:self];
    [_refreshButton setAction:@selector(refreshButtonClicked:)];
    [containerView addSubview:_refreshButton];
    
    // Prerelease checkbox (second row)
    _prereleaseCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(12, 146, 200, 18)];
    [_prereleaseCheckbox setButtonType:NSSwitchButton];
    [_prereleaseCheckbox setTitle:@"Show pre-release builds"]; 
    [_prereleaseCheckbox setTarget:self];
    [_prereleaseCheckbox setAction:@selector(prereleaseCheckboxChanged:)];
    [containerView addSubview:_prereleaseCheckbox];
    
    // Omit extra section title to conserve vertical space; the table below lists available images.
}

#pragma mark - GSAssistantStepProtocol overrides

- (BOOL)canContinue
{
    // Can continue if either a GitHub release is selected or custom URL is provided
    NSString *customURL = [[_urlField stringValue] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    BOOL hasSelectedImage = (self.selectedItem != nil);
    BOOL hasCustomURL = ([customURL length] > 0 && [customURL hasPrefix:@"http"]);
    BOOL canContinue = hasSelectedImage || hasCustomURL;
    
    NSLog(@"DRIImageSelectionStep: canContinue called - selectedItem=%@ customURL='%@' result=%@", 
          self.selectedItem ? @"YES" : @"NO", customURL, canContinue ? @"YES" : @"NO");
    
    return canContinue;
}

@end
