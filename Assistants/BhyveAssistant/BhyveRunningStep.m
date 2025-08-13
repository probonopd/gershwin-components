//
// BhyveRunningStep.m
// Bhyve Assistant - VM Running Step
//

#import "BhyveRunningStep.h"
#import "BhyveController.h"

@implementation BhyveRunningStep

@synthesize controller = _controller;

- (id)init
{
    if (self = [super init]) {
        NSLog(@"BhyveRunningStep: init");
        [self setupView];
    }
    return self;
}

- (void)dealloc
{
    NSLog(@"BhyveRunningStep: dealloc");
    [_stepView release];
    [super dealloc];
}

- (void)setupView
{
    NSLog(@"BhyveRunningStep: setupView");
    
    // Match installer card inner area (approx 354x204)
    _stepView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 354, 204)];
    
    // VM Info Label
    _vmInfoLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(16, 150, 322, 36)];
    [_vmInfoLabel setStringValue:@""];
    [_vmInfoLabel setFont:[NSFont systemFontOfSize:12]];
    [_vmInfoLabel setAlignment:NSCenterTextAlignment];
    [_vmInfoLabel setBezeled:NO];
    [_vmInfoLabel setDrawsBackground:NO];
    [_vmInfoLabel setEditable:NO];
    [_vmInfoLabel setSelectable:NO];
    [[_vmInfoLabel cell] setWraps:YES];
    [_stepView addSubview:_vmInfoLabel];
    
    // Status Label
    _statusLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(16, 110, 322, 20)];
    [_statusLabel setStringValue:NSLocalizedString(@"Ready to start virtual machine", @"Initial status")];
    [_statusLabel setFont:[NSFont boldSystemFontOfSize:11]];
    [_statusLabel setAlignment:NSCenterTextAlignment];
    [_statusLabel setBezeled:NO];
    [_statusLabel setDrawsBackground:NO];
    [_statusLabel setEditable:NO];
    [_statusLabel setSelectable:NO];
    [_stepView addSubview:_statusLabel];
    
    // Control Buttons - 4 buttons now
    CGFloat buttonWidth = 70;
    CGFloat buttonSpacing = 8;
    CGFloat totalButtonWidth = (4 * buttonWidth) + (3 * buttonSpacing);
    CGFloat startX = (354 - totalButtonWidth) / 2;
    
    // Start Button
    _startButton = [[NSButton alloc] initWithFrame:NSMakeRect(startX, 70, buttonWidth, 24)];
    [_startButton setTitle:NSLocalizedString(@"Start VM", @"Start button")];
    [_startButton setBezelStyle:NSRoundedBezelStyle];
    [_startButton setTarget:self];
    [_startButton setAction:@selector(startVM:)];
    [_stepView addSubview:_startButton];
    
    // Stop Button
    _stopButton = [[NSButton alloc] initWithFrame:NSMakeRect(startX + buttonWidth + buttonSpacing, 70, buttonWidth, 24)];
    [_stopButton setTitle:NSLocalizedString(@"Stop VM", @"Stop button")];
    [_stopButton setBezelStyle:NSRoundedBezelStyle];
    [_stopButton setTarget:self];
    [_stopButton setAction:@selector(stopVM:)];
    [_stopButton setEnabled:NO];
    [_stepView addSubview:_stopButton];
    
    // VNC Button
    _vncButton = [[NSButton alloc] initWithFrame:NSMakeRect(startX + (2 * (buttonWidth + buttonSpacing)), 70, buttonWidth, 24)];
    [_vncButton setTitle:NSLocalizedString(@"VNC", @"VNC button")];
    [_vncButton setBezelStyle:NSRoundedBezelStyle];
    [_vncButton setTarget:self];
    [_vncButton setAction:@selector(openVNC:)];
    [_vncButton setEnabled:NO];
    [_stepView addSubview:_vncButton];
    
    // Show Log Button
    _logButton = [[NSButton alloc] initWithFrame:NSMakeRect(startX + (3 * (buttonWidth + buttonSpacing)), 70, buttonWidth, 24)];
    [_logButton setTitle:NSLocalizedString(@"Show Log", @"Show Log button")];
    [_logButton setBezelStyle:NSRoundedBezelStyle];
    [_logButton setTarget:self];
    [_logButton setAction:@selector(showLog:)];
    [_logButton setEnabled:YES];
    [_stepView addSubview:_logButton];
    
    // Instructions
    NSTextField *instructionsLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(16, 12, 322, 48)];
    [instructionsLabel setStringValue:NSLocalizedString(@"Click 'Start VM' to boot the virtual machine with your selected ISO. VNC will be available for graphical access if enabled. Use 'Stop VM' to cleanly shut down.", @"Instructions")];
    [instructionsLabel setFont:[NSFont systemFontOfSize:10]];
    [instructionsLabel setAlignment:NSCenterTextAlignment];
    [instructionsLabel setBezeled:NO];
    [instructionsLabel setDrawsBackground:NO];
    [instructionsLabel setEditable:NO];
    [instructionsLabel setSelectable:NO];
    [instructionsLabel setTextColor:[NSColor darkGrayColor]];
    [[instructionsLabel cell] setWraps:YES];
    [_stepView addSubview:instructionsLabel];
    [instructionsLabel release];
}

- (void)updateStatus:(NSString *)status
{
    NSLog(@"BhyveRunningStep: updateStatus: %@", status);
    
    // Ensure we're on the main thread for UI updates
    if (![NSThread isMainThread]) {
        [self performSelectorOnMainThread:@selector(updateStatus:) 
                               withObject:status 
                            waitUntilDone:NO];
        return;
    }
    
    [_statusLabel setStringValue:status];
    [_stepView setNeedsDisplay:YES];
}

#pragma mark - Control Actions

- (void)startVM:(id)sender
{
    NSLog(@"BhyveRunningStep: startVM");
    
    if (_controller) {
        // Check bhyve availability first
        if (![_controller checkBhyveAvailable]) {
            [self updateStatus:NSLocalizedString(@"Error: bhyve not available on this system", @"Bhyve not available")];
            return;
        }
        
        [_startButton setEnabled:NO];
        [self updateStatus:NSLocalizedString(@"Starting virtual machine...", @"Starting status")];
        
        // Start VM in background
        [_controller performSelectorInBackground:@selector(startVirtualMachine) withObject:nil];
        
        // Update button states
        [_stopButton setEnabled:YES];
        if (_controller.enableVNC) {
            [_vncButton setEnabled:YES];
        }
    }
}

- (void)stopVM:(id)sender
{
    NSLog(@"BhyveRunningStep: stopVM");
    
    if (_controller) {
        [_stopButton setEnabled:NO];
        [_vncButton setEnabled:NO];
        [self updateStatus:NSLocalizedString(@"Stopping virtual machine...", @"Stopping status")];
        
        // Stop VM in background
        [_controller performSelectorInBackground:@selector(stopVirtualMachine) withObject:nil];
        
        // Update button states
        [_startButton setEnabled:YES];
    }
}

- (void)openVNC:(id)sender
{
    NSLog(@"BhyveRunningStep: openVNC");
    
    if (_controller && _controller.enableVNC) {
        [_controller startVNCViewer];
        
        // Also show connection info to help with X11 troubleshooting
        [_controller performSelector:@selector(showVNCConnectionInfo) withObject:nil afterDelay:0.5];
    }
}

- (void)showLog:(id)sender
{
    NSLog(@"BhyveRunningStep: showLog");
    
    if (_controller) {
        [_controller showVMLog];
    }
}

#pragma mark - GSAssistantStepProtocol

- (NSString *)stepTitle
{
    return NSLocalizedString(@"Virtual Machine", @"Step title");
}

- (NSString *)stepDescription  
{
    return NSLocalizedString(@"Control the virtual machine", @"Step description");
}

- (NSView *)stepView
{
    return _stepView;
}

- (BOOL)canContinue
{
    // This is the final step, so we can always "continue" (which means finish)
    return YES;
}

- (void)stepWillAppear
{
    NSLog(@"BhyveRunningStep: stepWillAppear");
    
    // Update VM info display
    if (_controller) {
        NSString *vmInfo = [NSString stringWithFormat:@"VM: %@\nISO: %@\nRAM: %ld MB, CPUs: %ld, Disk: %ld GB", 
                           _controller.vmName ?: @"Unknown",
                           _controller.selectedISOName ?: @"Unknown",
                           (long)_controller.allocatedRAM,
                           (long)_controller.allocatedCPUs,
                           (long)_controller.diskSize];
        [_vmInfoLabel setStringValue:vmInfo];
        
        // Update button states based on current VM state
        [_startButton setEnabled:!_controller.vmRunning];
        [_stopButton setEnabled:_controller.vmRunning];
        [_vncButton setEnabled:_controller.vmRunning && _controller.enableVNC];
        
        if (_controller.vmRunning) {
            [self updateStatus:NSLocalizedString(@"Virtual machine is running", @"Running status")];
        } else {
            [self updateStatus:NSLocalizedString(@"Ready to start virtual machine", @"Ready status")];
        }
    }
}

- (void)stepDidAppear
{
    NSLog(@"BhyveRunningStep: stepDidAppear");
}

- (void)stepWillDisappear
{
    NSLog(@"BhyveRunningStep: stepWillDisappear");
}

@end
