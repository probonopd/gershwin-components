//
// NetworkSetupSteps.m
// Network Setup Assistant - Custom Step Classes
//

#import "NetworkSetupSteps.h"

@implementation NSNetworkConfigStep

@synthesize stepTitle, stepDescription;

- (instancetype)init
{
    if (self = [super init]) {
        self.stepTitle = @"Network Configuration";
        self.stepDescription = @"Configure your network interface settings";
        [self setupView];
    }
    return self;
}

- (void)dealloc
{
    [_stepView release];
    [stepTitle release];
    [stepDescription release];
    [super dealloc];
}

- (void)setupView
{
    _stepView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 280)];
    
    // Interface selection
    NSTextField *interfaceLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 250, 120, 20)];
    [interfaceLabel setStringValue:@"Network Interface:"];
    [interfaceLabel setBezeled:NO];
    [interfaceLabel setDrawsBackground:NO];
    [interfaceLabel setEditable:NO];
    [interfaceLabel setSelectable:NO];
    [_stepView addSubview:interfaceLabel];
    [interfaceLabel release];
    
    _interfacePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(150, 248, 200, 24)];
    [_interfacePopup addItemWithTitle:@"em0 (Ethernet)"];
    [_interfacePopup addItemWithTitle:@"wlan0 (Wireless)"];
    [_interfacePopup addItemWithTitle:@"re0 (Ethernet)"];
    [_stepView addSubview:_interfacePopup];
    
    // Configuration method radio buttons
    _dhcpRadio = [[NSButton alloc] initWithFrame:NSMakeRect(20, 210, 200, 20)];
    [_dhcpRadio setButtonType:NSRadioButton];
    [_dhcpRadio setTitle:@"Obtain IP address automatically (DHCP)"];
    [_dhcpRadio setState:NSOnState]; // Default selection
    [_dhcpRadio setTarget:self];
    [_dhcpRadio setAction:@selector(configMethodChanged:)];
    [_stepView addSubview:_dhcpRadio];
    
    _manualRadio = [[NSButton alloc] initWithFrame:NSMakeRect(20, 185, 200, 20)];
    [_manualRadio setButtonType:NSRadioButton];
    [_manualRadio setTitle:@"Use manual configuration"];
    [_manualRadio setState:NSOffState];
    [_manualRadio setTarget:self];
    [_manualRadio setAction:@selector(configMethodChanged:)];
    [_stepView addSubview:_manualRadio];
    
    // Manual configuration fields (initially disabled)
    NSTextField *ipLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(40, 150, 100, 20)];
    [ipLabel setStringValue:@"IP Address:"];
    [ipLabel setBezeled:NO];
    [ipLabel setDrawsBackground:NO];
    [ipLabel setEditable:NO];
    [ipLabel setSelectable:NO];
    [_stepView addSubview:ipLabel];
    [ipLabel release];
    
    _ipAddressField = [[NSTextField alloc] initWithFrame:NSMakeRect(150, 150, 150, 24)];
    [_ipAddressField setEnabled:NO];
    [_stepView addSubview:_ipAddressField];
    
    NSTextField *maskLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(40, 120, 100, 20)];
    [maskLabel setStringValue:@"Subnet Mask:"];
    [maskLabel setBezeled:NO];
    [maskLabel setDrawsBackground:NO];
    [maskLabel setEditable:NO];
    [maskLabel setSelectable:NO];
    [_stepView addSubview:maskLabel];
    [maskLabel release];
    
    _subnetMaskField = [[NSTextField alloc] initWithFrame:NSMakeRect(150, 120, 150, 24)];
    [_subnetMaskField setEnabled:NO];
    [_stepView addSubview:_subnetMaskField];
    
    NSTextField *gatewayLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(40, 90, 100, 20)];
    [gatewayLabel setStringValue:@"Gateway:"];
    [gatewayLabel setBezeled:NO];
    [gatewayLabel setDrawsBackground:NO];
    [gatewayLabel setEditable:NO];
    [gatewayLabel setSelectable:NO];
    [_stepView addSubview:gatewayLabel];
    [gatewayLabel release];
    
    _gatewayField = [[NSTextField alloc] initWithFrame:NSMakeRect(150, 90, 150, 24)];
    [_gatewayField setEnabled:NO];
    [_stepView addSubview:_gatewayField];
    
    NSTextField *dnsLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(40, 60, 100, 20)];
    [dnsLabel setStringValue:@"DNS Server:"];
    [dnsLabel setBezeled:NO];
    [dnsLabel setDrawsBackground:NO];
    [dnsLabel setEditable:NO];
    [dnsLabel setSelectable:NO];
    [_stepView addSubview:dnsLabel];
    [dnsLabel release];
    
    _dnsField = [[NSTextField alloc] initWithFrame:NSMakeRect(150, 60, 150, 24)];
    [_dnsField setEnabled:NO];
    [_stepView addSubview:_dnsField];
}

- (void)configMethodChanged:(id)sender
{
    BOOL manualConfig = ([_manualRadio state] == NSOnState);
    
    if (sender == _dhcpRadio && [_dhcpRadio state] == NSOnState) {
        [_manualRadio setState:NSOffState];
        manualConfig = NO;
    } else if (sender == _manualRadio && [_manualRadio state] == NSOnState) {
        [_dhcpRadio setState:NSOffState];
        manualConfig = YES;
    }
    
    [_ipAddressField setEnabled:manualConfig];
    [_subnetMaskField setEnabled:manualConfig];
    [_gatewayField setEnabled:manualConfig];
    [_dnsField setEnabled:manualConfig];
    
    [self requestNavigationUpdate];
}

- (void)requestNavigationUpdate
{
    NSWindow *window = [[self stepView] window];
    if (!window) {
        window = [NSApp keyWindow];
    }
    NSWindowController *wc = [window windowController];
    if ([wc isKindOfClass:[GSAssistantWindow class]]) {
        GSAssistantWindow *assistantWindow = (GSAssistantWindow *)wc;
        [assistantWindow updateNavigationButtons];
    }
}

- (NSView *)stepView
{
    return _stepView;
}

- (BOOL)canContinue
{
    if ([_dhcpRadio state] == NSOnState) {
        return YES; // DHCP mode is always valid
    }
    
    // Manual mode requires at least IP address and subnet mask
    NSString *ipAddress = [[_ipAddressField stringValue] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *subnetMask = [[_subnetMaskField stringValue] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    
    return ([ipAddress length] > 0 && [subnetMask length] > 0);
}

- (NSString *)selectedInterface
{
    return [_interfacePopup titleOfSelectedItem];
}

- (BOOL)usesDHCP
{
    return ([_dhcpRadio state] == NSOnState);
}

- (NSString *)ipAddress
{
    return [_ipAddressField stringValue];
}

- (NSString *)subnetMask
{
    return [_subnetMaskField stringValue];
}

- (NSString *)gateway
{
    return [_gatewayField stringValue];
}

- (NSString *)dnsServer
{
    return [_dnsField stringValue];
}

@end

@implementation NSAuthConfigStep

@synthesize stepTitle, stepDescription;

- (instancetype)init
{
    if (self = [super init]) {
        self.stepTitle = @"Authentication";
        self.stepDescription = @"Set up network authentication";
        [self setupView];
    }
    return self;
}

- (void)dealloc
{
    [_stepView release];
    [stepTitle release];
    [stepDescription release];
    [super dealloc];
}

- (void)setupView
{
    _stepView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 220)];
    
    NSTextField *infoLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 190, 360, 20)];
    [infoLabel setStringValue:@"Enter authentication credentials (optional):"];
    [infoLabel setBezeled:NO];
    [infoLabel setDrawsBackground:NO];
    [infoLabel setEditable:NO];
    [infoLabel setSelectable:NO];
    [_stepView addSubview:infoLabel];
    [infoLabel release];
    
    // Username field
    NSTextField *usernameLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 160, 100, 20)];
    [usernameLabel setStringValue:@"Username:"];
    [usernameLabel setBezeled:NO];
    [usernameLabel setDrawsBackground:NO];
    [usernameLabel setEditable:NO];
    [usernameLabel setSelectable:NO];
    [_stepView addSubview:usernameLabel];
    [usernameLabel release];
    
    _usernameField = [[NSTextField alloc] initWithFrame:NSMakeRect(130, 160, 200, 24)];
    [_stepView addSubview:_usernameField];
    
    // Password field
    NSTextField *passwordLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 130, 100, 20)];
    [passwordLabel setStringValue:@"Password:"];
    [passwordLabel setBezeled:NO];
    [passwordLabel setDrawsBackground:NO];
    [passwordLabel setEditable:NO];
    [passwordLabel setSelectable:NO];
    [_stepView addSubview:passwordLabel];
    [passwordLabel release];
    
    _passwordField = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(130, 130, 200, 24)];
    [_stepView addSubview:_passwordField];
    
    // Domain field
    NSTextField *domainLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 100, 100, 20)];
    [domainLabel setStringValue:@"Domain:"];
    [domainLabel setBezeled:NO];
    [domainLabel setDrawsBackground:NO];
    [domainLabel setEditable:NO];
    [domainLabel setSelectable:NO];
    [_stepView addSubview:domainLabel];
    [domainLabel release];
    
    _domainField = [[NSTextField alloc] initWithFrame:NSMakeRect(130, 100, 200, 24)];
    [_stepView addSubview:_domainField];
    
    // WPA checkbox
    _enableWPACheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(20, 70, 200, 20)];
    [_enableWPACheckbox setButtonType:NSSwitchButton];
    [_enableWPACheckbox setTitle:@"Enable WPA/WPA2 Security"];
    [_enableWPACheckbox setState:NSOffState];
    [_enableWPACheckbox setTarget:self];
    [_enableWPACheckbox setAction:@selector(wpaCheckboxChanged:)];
    [_stepView addSubview:_enableWPACheckbox];
    
    // WPA Password field
    NSTextField *wpaPasswordLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 40, 100, 20)];
    [wpaPasswordLabel setStringValue:@"WPA Password:"];
    [wpaPasswordLabel setBezeled:NO];
    [wpaPasswordLabel setDrawsBackground:NO];
    [wpaPasswordLabel setEditable:NO];
    [wpaPasswordLabel setSelectable:NO];
    [_stepView addSubview:wpaPasswordLabel];
    [wpaPasswordLabel release];
    
    _wpaPasswordField = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(130, 40, 200, 24)];
    [_wpaPasswordField setEnabled:NO]; // Initially disabled
    [_stepView addSubview:_wpaPasswordField];
}

- (void)wpaCheckboxChanged:(id)sender
{
    BOOL enableWPA = ([_enableWPACheckbox state] == NSOnState);
    [_wpaPasswordField setEnabled:enableWPA];
    [self requestNavigationUpdate];
}

- (void)requestNavigationUpdate
{
    NSWindow *window = [[self stepView] window];
    if (!window) {
        window = [NSApp keyWindow];
    }
    NSWindowController *wc = [window windowController];
    if ([wc isKindOfClass:[GSAssistantWindow class]]) {
        GSAssistantWindow *assistantWindow = (GSAssistantWindow *)wc;
        [assistantWindow updateNavigationButtons];
    }
}

- (NSView *)stepView
{
    return _stepView;
}

- (BOOL)canContinue
{
    // Authentication is optional, but if WPA is enabled, password is required
    if ([_enableWPACheckbox state] == NSOnState) {
        NSString *wpaPassword = [[_wpaPasswordField stringValue] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        return ([wpaPassword length] > 0);
    }
    
    // Always can continue if WPA is not enabled
    return YES;
}

- (NSString *)username
{
    return [_usernameField stringValue];
}

- (NSString *)password
{
    return [_passwordField stringValue];
}

- (NSString *)domain
{
    return [_domainField stringValue];
}

- (BOOL)enableWPA
{
    return ([_enableWPACheckbox state] == NSOnState);
}

- (NSString *)wpaPassword
{
    return [_wpaPasswordField stringValue];
}

@end
