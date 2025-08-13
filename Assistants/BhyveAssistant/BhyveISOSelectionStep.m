//
// BhyveISOSelectionStep.m
// Bhyve Assistant - ISO Selection Step
//

#import "BhyveISOSelectionStep.h"
#import "BhyveController.h"

@implementation BhyveISOSelectionStep

@synthesize controller = _controller;

- (id)init
{
    if (self = [super init]) {
        NSLog(@"BhyveISOSelectionStep: init");
        [self setupView];
    }
    return self;
}

- (void)dealloc
{
    NSLog(@"BhyveISOSelectionStep: dealloc");
    [_stepView release];
    [super dealloc];
}

- (void)setupView
{
    NSLog(@"BhyveISOSelectionStep: setupView");
    
    // Match installer card inner area (approx 354x204)
    _stepView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 354, 204)];
    
    // Instructions
    NSTextField *instructionLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(16, 160, 322, 36)];
    [instructionLabel setStringValue:NSLocalizedString(@"Select an ISO image file to boot in the virtual machine. This can be any x86_64 bootable ISO.", @"ISO selection instructions")];
    [instructionLabel setFont:[NSFont systemFontOfSize:12]];
    [instructionLabel setBezeled:NO];
    [instructionLabel setDrawsBackground:NO];
    [instructionLabel setEditable:NO];
    [instructionLabel setSelectable:NO];
    [[instructionLabel cell] setWraps:YES];
    [_stepView addSubview:instructionLabel];
    [instructionLabel release];
    
    // Browse button
    _browseButton = [[NSButton alloc] initWithFrame:NSMakeRect(127, 110, 100, 32)];
    [_browseButton setTitle:NSLocalizedString(@"Browse...", @"Browse button")];
    [_browseButton setBezelStyle:NSRoundedBezelStyle];
    [_browseButton setTarget:self];
    [_browseButton setAction:@selector(browseForISO:)];
    [_stepView addSubview:_browseButton];
    
    // Selected file label
    _selectedFileLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(16, 70, 322, 20)];
    [_selectedFileLabel setStringValue:NSLocalizedString(@"No ISO file selected", @"No file selected message")];
    [_selectedFileLabel setFont:[NSFont systemFontOfSize:11]];
    [_selectedFileLabel setAlignment:NSCenterTextAlignment];
    [_selectedFileLabel setBezeled:NO];
    [_selectedFileLabel setDrawsBackground:NO];
    [_selectedFileLabel setEditable:NO];
    [_selectedFileLabel setSelectable:NO];
    [_selectedFileLabel setTextColor:[NSColor grayColor]];
    [_stepView addSubview:_selectedFileLabel];
    
    // File size label
    _fileSizeLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(16, 50, 322, 16)];
    [_fileSizeLabel setStringValue:@""];
    [_fileSizeLabel setFont:[NSFont systemFontOfSize:10]];
    [_fileSizeLabel setAlignment:NSCenterTextAlignment];
    [_fileSizeLabel setBezeled:NO];
    [_fileSizeLabel setDrawsBackground:NO];
    [_fileSizeLabel setEditable:NO];
    [_fileSizeLabel setSelectable:NO];
    [_fileSizeLabel setTextColor:[NSColor darkGrayColor]];
    [_stepView addSubview:_fileSizeLabel];
    
    // Supported formats info
    NSTextField *formatsLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(16, 12, 322, 28)];
    [formatsLabel setStringValue:NSLocalizedString(@"Supported: ISO, IMG. Most Linux distributions, BSD systems, and installation media work.", @"Supported formats")];
    [formatsLabel setFont:[NSFont systemFontOfSize:9]];
    [formatsLabel setAlignment:NSCenterTextAlignment];
    [formatsLabel setBezeled:NO];
    [formatsLabel setDrawsBackground:NO];
    [formatsLabel setEditable:NO];
    [formatsLabel setSelectable:NO];
    [formatsLabel setTextColor:[NSColor darkGrayColor]];
    [[formatsLabel cell] setWraps:YES];
    [_stepView addSubview:formatsLabel];
    [formatsLabel release];
}

- (void)browseForISO:(id)sender
{
    NSLog(@"BhyveISOSelectionStep: browseForISO");
    
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    [panel setCanChooseFiles:YES];
    [panel setCanChooseDirectories:NO];
    [panel setAllowsMultipleSelection:NO];
    [panel setAllowedFileTypes:@[@"iso", @"img", @"ISO", @"IMG"]];
    [panel setTitle:NSLocalizedString(@"Select ISO Image", @"Open panel title")];
    [panel setPrompt:NSLocalizedString(@"Select", @"Open panel button")];
    
    NSInteger result = [panel runModal];
    if (result == NSOKButton) {
        NSArray *urls = [panel URLs];
        if (urls && [urls count] > 0) {
            NSURL *selectedURL = [urls objectAtIndex:0];
            NSString *selectedPath = [selectedURL path];
        
        NSLog(@"BhyveISOSelectionStep: Selected ISO: %@", selectedPath);
        
        // Update controller
        if (_controller) {
            [_controller setSelectedISOPath:selectedPath];
            NSString *fileName = [selectedPath lastPathComponent];
            NSString *nameWithoutExt = [fileName stringByDeletingPathExtension];
            [_controller setSelectedISOName:nameWithoutExt];
            
            // Get file size
            NSError *error = nil;
            NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:selectedPath error:&error];
            if (attributes && !error) {
                NSNumber *fileSize = [attributes objectForKey:NSFileSize];
                [_controller setSelectedISOSize:[fileSize longLongValue]];
                
                // Update UI
                if (_selectedFileLabel) {
                    [_selectedFileLabel setStringValue:[selectedPath lastPathComponent]];
                    [_selectedFileLabel setTextColor:[NSColor blackColor]];
                }
                
                // Format file size
                long long sizeInMB = [fileSize longLongValue] / (1024 * 1024);
                if (_fileSizeLabel) {
                    [_fileSizeLabel setStringValue:[NSString stringWithFormat:@"Size: %lld MB", sizeInMB]];
                }
                
                NSLog(@"BhyveISOSelectionStep: ISO size: %lld bytes (%lld MB)", [fileSize longLongValue], sizeInMB);
            } else {
                NSLog(@"BhyveISOSelectionStep: Error getting file attributes: %@", [error localizedDescription]);
                [_controller setSelectedISOSize:0];
            }
        }
        
        // Request navigation button update
        [self requestNavigationUpdate];
        }
    }
}

- (void)requestNavigationUpdate
{
    NSWindow *window = [[self stepView] window];
    if (!window) {
        window = [NSApp keyWindow];
    }
    NSWindowController *wc = [window windowController];
    if ([wc isKindOfClass:[GSAssistantWindow class]]) {
        NSLog(@"BhyveISOSelectionStep: requesting navigation button update");
        GSAssistantWindow *assistantWindow = (GSAssistantWindow *)wc;
        [assistantWindow updateNavigationButtons];
    } else {
        NSLog(@"BhyveISOSelectionStep: could not find GSAssistantWindow to update navigation (wc=%@)", wc);
    }
}

#pragma mark - GSAssistantStepProtocol

- (NSString *)stepTitle
{
    return NSLocalizedString(@"Select ISO Image", @"Step title");
}

- (NSString *)stepDescription  
{
    return NSLocalizedString(@"Choose the ISO file to boot", @"Step description");
}

- (NSView *)stepView
{
    return _stepView;
}

- (BOOL)canContinue
{
    // Can continue only if an ISO is selected
    BOOL hasISO = _controller && _controller.selectedISOPath && [_controller.selectedISOPath length] > 0;
    NSLog(@"BhyveISOSelectionStep: canContinue = %@", hasISO ? @"YES" : @"NO");
    return hasISO;
}

- (void)stepWillAppear
{
    NSLog(@"BhyveISOSelectionStep: stepWillAppear");
    
    // Update UI if ISO already selected
    if (_controller && _controller.selectedISOPath && [_controller.selectedISOPath length] > 0) {
        [_selectedFileLabel setStringValue:[_controller.selectedISOPath lastPathComponent]];
        [_selectedFileLabel setTextColor:[NSColor blackColor]];
        
        if (_controller.selectedISOSize > 0) {
            long long sizeInMB = _controller.selectedISOSize / (1024 * 1024);
            [_fileSizeLabel setStringValue:[NSString stringWithFormat:@"Size: %lld MB", sizeInMB]];
        }
    }
}

- (void)stepDidAppear
{
    NSLog(@"BhyveISOSelectionStep: stepDidAppear");
}

- (void)stepWillDisappear
{
    NSLog(@"BhyveISOSelectionStep: stepWillDisappear");
}

@end
