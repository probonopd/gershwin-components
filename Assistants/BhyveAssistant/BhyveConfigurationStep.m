//
// BhyveConfigurationStep.m
// Bhyve Assistant - VM Configuration Step
//

#import "BhyveConfigurationStep.h"
#import "BhyveController.h"

@implementation BhyveConfigurationStep

@synthesize controller = _controller;

- (id)init
{
    if (self = [super init]) {
        NSLog(@"BhyveConfigurationStep: init");
        [self setupView];
    }
    return self;
}

- (void)dealloc
{
    NSLog(@"BhyveConfigurationStep: dealloc");
    [_stepView release];
    [super dealloc];
}

- (void)setupView
{
    NSLog(@"BhyveConfigurationStep: setupView");
    
    // Match installer card inner area (approx 354x230 for more fields)
    _stepView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 354, 230)];
    
    CGFloat yPos = 205;
    
    // VM Name
    NSTextField *vmNameLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(16, yPos, 80, 16)];
    [vmNameLabel setStringValue:NSLocalizedString(@"VM Name:", @"VM Name label")];
    [vmNameLabel setFont:[NSFont boldSystemFontOfSize:11]];
    [vmNameLabel setBezeled:NO];
    [vmNameLabel setDrawsBackground:NO];
    [vmNameLabel setEditable:NO];
    [vmNameLabel setSelectable:NO];
    [_stepView addSubview:vmNameLabel];
    [vmNameLabel release];
    
    _vmNameField = [[NSTextField alloc] initWithFrame:NSMakeRect(100, yPos, 238, 20)];
    [_vmNameField setStringValue:@"FreeBSD-Live"];
    [_vmNameField setTarget:self];
    [_vmNameField setAction:@selector(vmNameChanged:)];
    [_stepView addSubview:_vmNameField];
    
    yPos -= 25;
    
    // RAM Configuration
    NSTextField *ramTitleLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(16, yPos, 80, 16)];
    [ramTitleLabel setStringValue:NSLocalizedString(@"RAM (MB):", @"RAM label")];
    [ramTitleLabel setFont:[NSFont boldSystemFontOfSize:11]];
    [ramTitleLabel setBezeled:NO];
    [ramTitleLabel setDrawsBackground:NO];
    [ramTitleLabel setEditable:NO];
    [ramTitleLabel setSelectable:NO];
    [_stepView addSubview:ramTitleLabel];
    [ramTitleLabel release];
    
    _ramSlider = [[NSSlider alloc] initWithFrame:NSMakeRect(100, yPos, 180, 20)];
    [_ramSlider setMinValue:512];
    [_ramSlider setMaxValue:8192];
    [_ramSlider setIntegerValue:2048];
    [_ramSlider setTarget:self];
    [_ramSlider setAction:@selector(ramChanged:)];
    [_stepView addSubview:_ramSlider];
    
    _ramLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(290, yPos, 48, 16)];
    [_ramLabel setStringValue:@"2048"];
    [_ramLabel setFont:[NSFont systemFontOfSize:11]];
    [_ramLabel setBezeled:NO];
    [_ramLabel setDrawsBackground:NO];
    [_ramLabel setEditable:NO];
    [_ramLabel setSelectable:NO];
    [_stepView addSubview:_ramLabel];
    
    yPos -= 25;
    
    // CPU Configuration
    NSTextField *cpuTitleLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(16, yPos, 80, 16)];
    [cpuTitleLabel setStringValue:NSLocalizedString(@"CPUs:", @"CPU label")];
    [cpuTitleLabel setFont:[NSFont boldSystemFontOfSize:11]];
    [cpuTitleLabel setBezeled:NO];
    [cpuTitleLabel setDrawsBackground:NO];
    [cpuTitleLabel setEditable:NO];
    [cpuTitleLabel setSelectable:NO];
    [_stepView addSubview:cpuTitleLabel];
    [cpuTitleLabel release];
    
    _cpuSlider = [[NSSlider alloc] initWithFrame:NSMakeRect(100, yPos, 180, 20)];
    [_cpuSlider setMinValue:1];
    [_cpuSlider setMaxValue:8];
    [_cpuSlider setIntegerValue:2];
    [_cpuSlider setTarget:self];
    [_cpuSlider setAction:@selector(cpuChanged:)];
    [_stepView addSubview:_cpuSlider];
    
    _cpuLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(290, yPos, 48, 16)];
    [_cpuLabel setStringValue:@"2"];
    [_cpuLabel setFont:[NSFont systemFontOfSize:11]];
    [_cpuLabel setBezeled:NO];
    [_cpuLabel setDrawsBackground:NO];
    [_cpuLabel setEditable:NO];
    [_cpuLabel setSelectable:NO];
    [_stepView addSubview:_cpuLabel];
    
    yPos -= 25;
    
    // Disk Size Configuration
    NSTextField *diskTitleLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(16, yPos, 80, 16)];
    [diskTitleLabel setStringValue:NSLocalizedString(@"Disk (GB):", @"Disk label")];
    [diskTitleLabel setFont:[NSFont boldSystemFontOfSize:11]];
    [diskTitleLabel setBezeled:NO];
    [diskTitleLabel setDrawsBackground:NO];
    [diskTitleLabel setEditable:NO];
    [diskTitleLabel setSelectable:NO];
    [_stepView addSubview:diskTitleLabel];
    [diskTitleLabel release];
    
    _diskSlider = [[NSSlider alloc] initWithFrame:NSMakeRect(100, yPos, 180, 20)];
    [_diskSlider setMinValue:1];
    [_diskSlider setMaxValue:100];
    [_diskSlider setIntegerValue:20];
    [_diskSlider setTarget:self];
    [_diskSlider setAction:@selector(diskChanged:)];
    [_stepView addSubview:_diskSlider];
    
    _diskLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(290, yPos, 48, 16)];
    [_diskLabel setStringValue:@"20"];
    [_diskLabel setFont:[NSFont systemFontOfSize:11]];
    [_diskLabel setBezeled:NO];
    [_diskLabel setDrawsBackground:NO];
    [_diskLabel setEditable:NO];
    [_diskLabel setSelectable:NO];
    [_stepView addSubview:_diskLabel];
    
    yPos -= 25;
    
    // VNC Configuration
    _vncCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(16, yPos, 120, 18)];
    [_vncCheckbox setTitle:NSLocalizedString(@"Enable VNC", @"VNC checkbox")];
    [_vncCheckbox setButtonType:NSSwitchButton];
    [_vncCheckbox setState:NSOnState];
    [_vncCheckbox setTarget:self];
    [_vncCheckbox setAction:@selector(vncToggled:)];
    [_stepView addSubview:_vncCheckbox];
    
    NSTextField *vncPortLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(140, yPos, 40, 16)];
    [vncPortLabel setStringValue:NSLocalizedString(@"Port:", @"VNC Port label")];
    [vncPortLabel setFont:[NSFont systemFontOfSize:11]];
    [vncPortLabel setBezeled:NO];
    [vncPortLabel setDrawsBackground:NO];
    [vncPortLabel setEditable:NO];
    [vncPortLabel setSelectable:NO];
    [_stepView addSubview:vncPortLabel];
    [vncPortLabel release];
    
    _vncPortField = [[NSTextField alloc] initWithFrame:NSMakeRect(185, yPos, 60, 20)];
    [_vncPortField setStringValue:@"5900"];
    [_vncPortField setTarget:self];
    [_vncPortField setAction:@selector(vncPortChanged:)];
    [_stepView addSubview:_vncPortField];
    
    yPos -= 25;
    
    // Network Configuration
    NSTextField *networkLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(16, yPos, 80, 16)];
    [networkLabel setStringValue:NSLocalizedString(@"Network:", @"Network label")];
    [networkLabel setFont:[NSFont boldSystemFontOfSize:11]];
    [networkLabel setBezeled:NO];
    [networkLabel setDrawsBackground:NO];
    [networkLabel setEditable:NO];
    [networkLabel setSelectable:NO];
    [_stepView addSubview:networkLabel];
    [networkLabel release];
    
    _networkPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(100, yPos, 120, 22)];
    [_networkPopup addItemWithTitle:NSLocalizedString(@"Bridge", @"Bridge network")];
    [_networkPopup addItemWithTitle:NSLocalizedString(@"NAT", @"NAT network")];
    [_networkPopup addItemWithTitle:NSLocalizedString(@"None", @"No network")];
    [_networkPopup selectItemAtIndex:0];
    [_networkPopup setTarget:self];
    [_networkPopup setAction:@selector(networkChanged:)];
    [_stepView addSubview:_networkPopup];
    
    yPos -= 25;
    
    // Boot Mode Configuration
    NSTextField *bootModeLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(16, yPos, 80, 16)];
    [bootModeLabel setStringValue:NSLocalizedString(@"Boot Mode:", @"Boot Mode label")];
    [bootModeLabel setFont:[NSFont boldSystemFontOfSize:11]];
    [bootModeLabel setBezeled:NO];
    [bootModeLabel setDrawsBackground:NO];
    [bootModeLabel setEditable:NO];
    [bootModeLabel setSelectable:NO];
    [_stepView addSubview:bootModeLabel];
    [bootModeLabel release];
    
    _bootModePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(100, yPos, 120, 22)];
    [_bootModePopup addItemWithTitle:NSLocalizedString(@"BIOS (Legacy)", @"BIOS boot mode")];
    [_bootModePopup addItemWithTitle:NSLocalizedString(@"UEFI", @"UEFI boot mode")];
    [_bootModePopup selectItemAtIndex:1]; // Default to UEFI
    [_bootModePopup setTarget:self];
    [_bootModePopup setAction:@selector(bootModeChanged:)];
    [_stepView addSubview:_bootModePopup];
}

#pragma mark - Control Actions

- (void)vmNameChanged:(id)sender
{
    NSString *vmName = [_vmNameField stringValue];
    NSLog(@"BhyveConfigurationStep: VM name changed to: %@", vmName);
    if (_controller) {
        [_controller setVmName:vmName];
    }
}

- (void)ramChanged:(id)sender
{
    NSInteger ramValue = [_ramSlider integerValue];
    [_ramLabel setStringValue:[NSString stringWithFormat:@"%ld", (long)ramValue]];
    NSLog(@"BhyveConfigurationStep: RAM changed to: %ld MB", (long)ramValue);
    if (_controller) {
        [_controller setAllocatedRAM:ramValue];
    }
}

- (void)cpuChanged:(id)sender
{
    NSInteger cpuValue = [_cpuSlider integerValue];
    [_cpuLabel setStringValue:[NSString stringWithFormat:@"%ld", (long)cpuValue]];
    NSLog(@"BhyveConfigurationStep: CPU changed to: %ld", (long)cpuValue);
    if (_controller) {
        [_controller setAllocatedCPUs:cpuValue];
    }
}

- (void)diskChanged:(id)sender
{
    NSInteger diskValue = [_diskSlider integerValue];
    [_diskLabel setStringValue:[NSString stringWithFormat:@"%ld", (long)diskValue]];
    NSLog(@"BhyveConfigurationStep: Disk size changed to: %ld GB", (long)diskValue);
    if (_controller) {
        [_controller setDiskSize:diskValue];
    }
}

- (void)vncToggled:(id)sender
{
    BOOL vncEnabled = ([_vncCheckbox state] == NSOnState);
    [_vncPortField setEnabled:vncEnabled];
    NSLog(@"BhyveConfigurationStep: VNC toggled: %@", vncEnabled ? @"YES" : @"NO");
    if (_controller) {
        [_controller setEnableVNC:vncEnabled];
    }
}

- (void)vncPortChanged:(id)sender
{
    NSInteger vncPort = [[_vncPortField stringValue] integerValue];
    if (vncPort < 5900 || vncPort > 5999) {
        vncPort = 5900;
        [_vncPortField setStringValue:@"5900"];
    }
    NSLog(@"BhyveConfigurationStep: VNC port changed to: %ld", (long)vncPort);
    if (_controller) {
        [_controller setVncPort:vncPort];
    }
}

- (void)networkChanged:(id)sender
{
    NSString *networkMode;
    NSInteger selectedIndex = [_networkPopup indexOfSelectedItem];
    switch (selectedIndex) {
        case 0:
            networkMode = @"bridge";
            break;
        case 1:
            networkMode = @"nat";
            break;
        case 2:
            networkMode = @"none";
            break;
        default:
            networkMode = @"bridge";
            break;
    }
    NSLog(@"BhyveConfigurationStep: Network mode changed to: %@", networkMode);
    if (_controller) {
        [_controller setNetworkMode:networkMode];
    }
}

- (void)bootModeChanged:(id)sender
{
    NSString *bootMode;
    NSInteger selectedIndex = [_bootModePopup indexOfSelectedItem];
    switch (selectedIndex) {
        case 0:
            bootMode = @"bios";
            break;
        case 1:
            bootMode = @"uefi";
            break;
        default:
            bootMode = @"bios";
            break;
    }
    NSLog(@"BhyveConfigurationStep: Boot mode changed to: %@", bootMode);
    if (_controller) {
        [_controller setBootMode:bootMode];
    }
}

#pragma mark - GSAssistantStepProtocol

- (NSString *)stepTitle
{
    return NSLocalizedString(@"VM Configuration", @"Step title");
}

- (NSString *)stepDescription  
{
    return NSLocalizedString(@"Configure virtual machine settings", @"Step description");
}

- (NSView *)stepView
{
    return _stepView;
}

- (BOOL)canContinue
{
    // Can continue if VM name is set
    NSString *vmName = [_vmNameField stringValue];
    BOOL hasName = vmName && [vmName length] > 0;
    NSLog(@"BhyveConfigurationStep: canContinue = %@", hasName ? @"YES" : @"NO");
    return hasName;
}

- (void)stepWillAppear
{
    NSLog(@"BhyveConfigurationStep: stepWillAppear");
    
    // Update UI with controller values
    if (_controller) {
        [_vmNameField setStringValue:_controller.vmName ?: @"FreeBSD-Live"];
        [_ramSlider setIntegerValue:_controller.allocatedRAM];
        [_ramLabel setStringValue:[NSString stringWithFormat:@"%ld", (long)_controller.allocatedRAM]];
        [_cpuSlider setIntegerValue:_controller.allocatedCPUs];
        [_cpuLabel setStringValue:[NSString stringWithFormat:@"%ld", (long)_controller.allocatedCPUs]];
        [_diskSlider setIntegerValue:_controller.diskSize];
        [_diskLabel setStringValue:[NSString stringWithFormat:@"%ld", (long)_controller.diskSize]];
        [_vncCheckbox setState:_controller.enableVNC ? NSOnState : NSOffState];
        [_vncPortField setStringValue:[NSString stringWithFormat:@"%ld", (long)_controller.vncPort]];
        [_vncPortField setEnabled:_controller.enableVNC];
        
        // Select network mode
        if ([_controller.networkMode isEqualToString:@"bridge"]) {
            [_networkPopup selectItemAtIndex:0];
        } else if ([_controller.networkMode isEqualToString:@"nat"]) {
            [_networkPopup selectItemAtIndex:1];
        } else {
            [_networkPopup selectItemAtIndex:2];
        }
        
        // Select boot mode
        if ([_controller.bootMode isEqualToString:@"uefi"]) {
            [_bootModePopup selectItemAtIndex:1];
        } else {
            [_bootModePopup selectItemAtIndex:0];
        }
    }
}

- (void)stepDidAppear
{
    NSLog(@"BhyveConfigurationStep: stepDidAppear");
}

- (void)stepWillDisappear
{
    NSLog(@"BhyveConfigurationStep: stepWillDisappear");
}

@end
