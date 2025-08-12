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
        NSLog(@"[NSNetworkConfigStep] init");
        self.stepTitle = @"Network Configuration";
        self.stepDescription = @"Configure your network interface settings";
        [self setupView];
    }
    return self;
}

- (void)dealloc
{
    NSLog(@"[NSNetworkConfigStep] dealloc");
    [_dnsField release];
    [_gatewayField release];
    [_subnetMaskField release];
    [_ipAddressField release];
    [_manualRadio release];
    [_dhcpRadio release];
    [_interfacePopup release];
    [_stepView release];
    [stepTitle release];
    [stepDescription release];
    [super dealloc];
}

- (void)setupView
{
    NSLog(@"[NSNetworkConfigStep] setupView");
    // Match installer card inner area (approx 354x204)
    _stepView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 354, 204)];
    CGFloat left = 24.0; // Standard left margin  
    CGFloat rightInset = 24.0; // Standard right margin
    CGFloat fieldX = 154.0; // Adjusted for new left margin
    CGFloat fieldW = 354.0 - fieldX - rightInset; // Recalculated width

    // Interface selection with standard spacing
    NSTextField *interfaceLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(left, 172, 120, 16)];
    [interfaceLabel setStringValue:NSLocalizedString(@"Network Interface:", @"")];
    [interfaceLabel setBezeled:NO];
    [interfaceLabel setDrawsBackground:NO];
    [interfaceLabel setEditable:NO];
    [interfaceLabel setSelectable:NO];
    [_stepView addSubview:interfaceLabel];
    [interfaceLabel release];

    _interfacePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(fieldX, 168, fieldW, 24)];
    [_interfacePopup addItemWithTitle:NSLocalizedString(@"em0 (Ethernet)", @"")];
    [_interfacePopup addItemWithTitle:NSLocalizedString(@"wlan0 (Wireless)", @"")];
    [_interfacePopup addItemWithTitle:NSLocalizedString(@"re0 (Ethernet)", @"")];
    [_stepView addSubview:_interfacePopup];

    // Configuration method radio buttons (compact)
    _dhcpRadio = [[NSButton alloc] initWithFrame:NSMakeRect(left, 140, 322, 18)];
    [_dhcpRadio setButtonType:NSRadioButton];
    [_dhcpRadio setTitle:@"Obtain IP address automatically (DHCP)"];
    [_dhcpRadio setState:NSOnState]; // Default selection
    [_dhcpRadio setTarget:self];
    [_dhcpRadio setAction:@selector(configMethodChanged:)];
    [_stepView addSubview:_dhcpRadio];

    _manualRadio = [[NSButton alloc] initWithFrame:NSMakeRect(left, 118, 322, 18)];
    [_manualRadio setButtonType:NSRadioButton];
    [_manualRadio setTitle:@"Use manual configuration"];
    [_manualRadio setState:NSOffState];
    [_manualRadio setTarget:self];
    [_manualRadio setAction:@selector(configMethodChanged:)];
    [_stepView addSubview:_manualRadio];

    // Manual configuration fields (initially disabled)
    // Row Y origins for fields
    CGFloat row1Y = 104.0;
    CGFloat row2Y = 76.0;
    CGFloat row3Y = 48.0;
    CGFloat row4Y = 20.0;

    NSTextField *ipLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(left + 24, row1Y + 4, 100, 16)];
    [ipLabel setStringValue:NSLocalizedString(@"IP Address:", @"")];
    [ipLabel setBezeled:NO];
    [ipLabel setDrawsBackground:NO];
    [ipLabel setEditable:NO];
    [ipLabel setSelectable:NO];
    [_stepView addSubview:ipLabel];
    [ipLabel release];

    _ipAddressField = [[NSTextField alloc] initWithFrame:NSMakeRect(fieldX, row1Y, fieldW, 22)];
    [_ipAddressField setEnabled:NO];
    [_stepView addSubview:_ipAddressField];

    NSTextField *maskLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(left + 24, row2Y + 4, 100, 16)];
    [maskLabel setStringValue:NSLocalizedString(@"Subnet Mask:", @"")];
    [maskLabel setBezeled:NO];
    [maskLabel setDrawsBackground:NO];
    [maskLabel setEditable:NO];
    [maskLabel setSelectable:NO];
    [_stepView addSubview:maskLabel];
    [maskLabel release];

    _subnetMaskField = [[NSTextField alloc] initWithFrame:NSMakeRect(fieldX, row2Y, fieldW, 22)];
    [_subnetMaskField setEnabled:NO];
    [_stepView addSubview:_subnetMaskField];

    NSTextField *gatewayLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(left + 16, row3Y + 4, 100, 16)];
    [gatewayLabel setStringValue:NSLocalizedString(@"Gateway:", @"")];
    [gatewayLabel setBezeled:NO];
    [gatewayLabel setDrawsBackground:NO];
    [gatewayLabel setEditable:NO];
    [gatewayLabel setSelectable:NO];
    [_stepView addSubview:gatewayLabel];
    [gatewayLabel release];

    _gatewayField = [[NSTextField alloc] initWithFrame:NSMakeRect(fieldX, row3Y, fieldW, 22)];
    [_gatewayField setEnabled:NO];
    [_stepView addSubview:_gatewayField];

    NSTextField *dnsLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(left + 16, row4Y + 4, 100, 16)];
    [dnsLabel setStringValue:NSLocalizedString(@"DNS Server:", @"")];
    [dnsLabel setBezeled:NO];
    [dnsLabel setDrawsBackground:NO];
    [dnsLabel setEditable:NO];
    [dnsLabel setSelectable:NO];
    [_stepView addSubview:dnsLabel];
    [dnsLabel release];

    _dnsField = [[NSTextField alloc] initWithFrame:NSMakeRect(fieldX, row4Y, fieldW, 22)];
    [_dnsField setEnabled:NO];
    [_stepView addSubview:_dnsField];
}

- (void)configMethodChanged:(id)sender
{
    NSLog(@"[NSNetworkConfigStep] configMethodChanged: sender=%@", sender);
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

    BOOL ok = ([ipAddress length] > 0 && [subnetMask length] > 0);
    NSLog(@"[NSNetworkConfigStep] canContinue (manual=%d) -> %@", ([_manualRadio state] == NSOnState), ok ? @"YES" : @"NO");
    return ok;
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
        NSLog(@"[NSAuthConfigStep] init");
        self.stepTitle = @"Authentication";
        self.stepDescription = @"Set up network authentication";
        [self setupView];
    }
    return self;
}

- (void)dealloc
{
    NSLog(@"[NSAuthConfigStep] dealloc");
    [_wpaPasswordField release];
    [_enableWPACheckbox release];
    [_domainField release];
    [_passwordField release];
    [_usernameField release];
    [_stepView release];
    [stepTitle release];
    [stepDescription release];
    [super dealloc];
}

- (void)setupView
{
    NSLog(@"[NSAuthConfigStep] setupView");
    _stepView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 354, 204)];

    NSTextField *infoLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(16, 176, 322, 16)];
    [infoLabel setStringValue:NSLocalizedString(@"Enter authentication credentials (optional):", @"")];
    [infoLabel setBezeled:NO];
    [infoLabel setDrawsBackground:NO];
    [infoLabel setEditable:NO];
    [infoLabel setSelectable:NO];
    [_stepView addSubview:infoLabel];
    [infoLabel release];

    // Username field
    NSTextField *usernameLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(16, 148, 100, 16)];
    [usernameLabel setStringValue:NSLocalizedString(@"Username:", @"")];
    [usernameLabel setBezeled:NO];
    [usernameLabel setDrawsBackground:NO];
    [usernameLabel setEditable:NO];
    [usernameLabel setSelectable:NO];
    [_stepView addSubview:usernameLabel];
    [usernameLabel release];

    _usernameField = [[NSTextField alloc] initWithFrame:NSMakeRect(130, 144, 208, 22)];
    [_stepView addSubview:_usernameField];

    // Password field
    NSTextField *passwordLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(16, 120, 100, 16)];
    [passwordLabel setStringValue:NSLocalizedString(@"Password:", @"")];
    [passwordLabel setBezeled:NO];
    [passwordLabel setDrawsBackground:NO];
    [passwordLabel setEditable:NO];
    [passwordLabel setSelectable:NO];
    [_stepView addSubview:passwordLabel];
    [passwordLabel release];

    _passwordField = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(130, 116, 208, 22)];
    [_stepView addSubview:_passwordField];

    // Domain field
    NSTextField *domainLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(16, 92, 100, 16)];
    [domainLabel setStringValue:NSLocalizedString(@"Domain:", @"")];
    [domainLabel setBezeled:NO];
    [domainLabel setDrawsBackground:NO];
    [domainLabel setEditable:NO];
    [domainLabel setSelectable:NO];
    [_stepView addSubview:domainLabel];
    [domainLabel release];

    _domainField = [[NSTextField alloc] initWithFrame:NSMakeRect(130, 88, 208, 22)];
    [_stepView addSubview:_domainField];

    // WPA checkbox
    _enableWPACheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(16, 60, 300, 18)];
    [_enableWPACheckbox setButtonType:NSSwitchButton];
    [_enableWPACheckbox setTitle:@"Enable WPA/WPA2 Security"];
    [_enableWPACheckbox setState:NSOffState];
    [_enableWPACheckbox setTarget:self];
    [_enableWPACheckbox setAction:@selector(wpaCheckboxChanged:)];
    [_stepView addSubview:_enableWPACheckbox];

    // WPA Password field
    NSTextField *wpaPasswordLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(16, 32, 100, 16)];
    [wpaPasswordLabel setStringValue:NSLocalizedString(@"WPA Password:", @"")];
    [wpaPasswordLabel setBezeled:NO];
    [wpaPasswordLabel setDrawsBackground:NO];
    [wpaPasswordLabel setEditable:NO];
    [wpaPasswordLabel setSelectable:NO];
    [_stepView addSubview:wpaPasswordLabel];
    [wpaPasswordLabel release];

    _wpaPasswordField = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(130, 28, 208, 22)];
    [_wpaPasswordField setEnabled:NO]; // Initially disabled
    [_stepView addSubview:_wpaPasswordField];
}

- (void)wpaCheckboxChanged:(id)sender
{
    BOOL enableWPA = ([_enableWPACheckbox state] == NSOnState);
    NSLog(@"[NSAuthConfigStep] wpaCheckboxChanged -> %@", enableWPA ? @"ENABLED" : @"DISABLED");
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
        BOOL ok = ([wpaPassword length] > 0);
        NSLog(@"[NSAuthConfigStep] canContinue (WPA) -> %@", ok ? @"YES" : @"NO");
        return ok;
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
