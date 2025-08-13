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
    
    // Control Buttons - 1 button centered
    CGFloat buttonWidth = 70;
    CGFloat startX = (354 - buttonWidth) / 2;
    
    // Show Log Button
    _logButton = [[NSButton alloc] initWithFrame:NSMakeRect(startX, 70, buttonWidth, 24)];
    [_logButton setTitle:NSLocalizedString(@"Show Log", @"Show Log button")];
    [_logButton setBezelStyle:NSRoundedBezelStyle];
    [_logButton setTarget:self];
    [_logButton setAction:@selector(showLog:)];
    [_logButton setEnabled:YES];
    [_stepView addSubview:_logButton];
    
    // Instructions
    NSTextField *instructionsLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(16, 12, 322, 48)];
    [instructionsLabel setStringValue:NSLocalizedString(@"The virtual machine starts automatically when you reach this step. VNC display opens automatically. Close the VNC window to stop the virtual machine.", @"Instructions")];
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
        
        // If VM is not already running, start it automatically
        if (!_controller.vmRunning) {
            NSLog(@"BhyveRunningStep: Auto-starting VM");
            [self updateStatus:NSLocalizedString(@"Auto-starting virtual machine...", @"Auto-starting status")];
            
            // Check bhyve availability first
            if (![_controller checkBhyveAvailable]) {
                [self updateStatus:NSLocalizedString(@"Error: bhyve not available on this system", @"Bhyve not available")];
                return;
            }
            
            // Start VM in background after a short delay to let UI update
            [_controller performSelector:@selector(startVirtualMachine) withObject:nil afterDelay:0.5];
        } else {
            // VM is already running
            [self updateStatus:NSLocalizedString(@"Virtual machine is running", @"Running status")];
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
