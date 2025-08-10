//
// SystemSetupSteps.m
// System Setup Assistant - Custom Step Classes
//

#import "SystemSetupSteps.h"

@implementation SSUserInfoStep

@synthesize stepTitle, stepDescription;

- (instancetype)init
{
    if (self = [super init]) {
        NSLog(@"[SSUserInfoStep] init");
        self.stepTitle = @"User Information";
        self.stepDescription = @"Please provide your user information";
        [self setupView];
    }
    return self;
}

- (void)dealloc
{
    NSLog(@"[SSUserInfoStep] dealloc");
    [_confirmPasswordField release];
    [_passwordField release];
    [_usernameField release];
    [_fullNameField release];
    [_stepView release];
    [stepTitle release];
    [stepDescription release];
    [super dealloc];
}

- (void)setupView
{
    _stepView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 354, 204)];

    CGFloat left = 16.0;
    CGFloat fieldX = 130.0;
    CGFloat fieldW = 354.0 - fieldX - 16.0;

    // Full Name field
    NSTextField *fullNameLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(left, 160, 100, 16)];
    [fullNameLabel setStringValue:@"Full Name:"];
    [fullNameLabel setBezeled:NO];
    [fullNameLabel setDrawsBackground:NO];
    [fullNameLabel setEditable:NO];
    [fullNameLabel setSelectable:NO];
    [_stepView addSubview:fullNameLabel];
    [fullNameLabel release];

    _fullNameField = [[NSTextField alloc] initWithFrame:NSMakeRect(fieldX, 156, fieldW, 22)];
    [_fullNameField setTarget:self];
    [_fullNameField setAction:@selector(fieldChanged:)];
    [_stepView addSubview:_fullNameField];

    // Username field
    NSTextField *usernameLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(left, 128, 100, 16)];
    [usernameLabel setStringValue:@"Username:"];
    [usernameLabel setBezeled:NO];
    [usernameLabel setDrawsBackground:NO];
    [usernameLabel setEditable:NO];
    [usernameLabel setSelectable:NO];
    [_stepView addSubview:usernameLabel];
    [usernameLabel release];

    _usernameField = [[NSTextField alloc] initWithFrame:NSMakeRect(fieldX, 124, fieldW, 22)];
    [_usernameField setTarget:self];
    [_usernameField setAction:@selector(fieldChanged:)];
    [_stepView addSubview:_usernameField];

    // Password field
    NSTextField *passwordLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(left, 96, 100, 16)];
    [passwordLabel setStringValue:@"Password:"];
    [passwordLabel setBezeled:NO];
    [passwordLabel setDrawsBackground:NO];
    [passwordLabel setEditable:NO];
    [passwordLabel setSelectable:NO];
    [_stepView addSubview:passwordLabel];
    [passwordLabel release];

    _passwordField = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(fieldX, 92, fieldW, 22)];
    [_passwordField setTarget:self];
    [_passwordField setAction:@selector(fieldChanged:)];
    [_stepView addSubview:_passwordField];

    // Confirm Password field
    NSTextField *confirmLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(left, 64, 100, 16)];
    [confirmLabel setStringValue:@"Confirm:"];
    [confirmLabel setBezeled:NO];
    [confirmLabel setDrawsBackground:NO];
    [confirmLabel setEditable:NO];
    [confirmLabel setSelectable:NO];
    [_stepView addSubview:confirmLabel];
    [confirmLabel release];

    _confirmPasswordField = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(fieldX, 60, fieldW, 22)];
    [_confirmPasswordField setTarget:self];
    [_confirmPasswordField setAction:@selector(fieldChanged:)];
    [_stepView addSubview:_confirmPasswordField];
}

- (void)fieldChanged:(id)sender
{
    NSLog(@"[SSUserInfoStep] fieldChanged:%@", sender);
    // Request navigation button update when fields change
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
    NSString *fullName = [[_fullNameField stringValue] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *username = [[_usernameField stringValue] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *password = [_passwordField stringValue];
    NSString *confirmPassword = [_confirmPasswordField stringValue];

    // All fields must be filled and passwords must match
    BOOL ok = ([fullName length] > 0 &&
               [username length] > 0 &&
               [password length] > 0 &&
               [confirmPassword length] > 0 &&
               [password isEqualToString:confirmPassword]);
    NSLog(@"[SSUserInfoStep] canContinue -> %@", ok ? @"YES" : @"NO");
    return ok;
}

- (NSString *)username
{
    return [_usernameField stringValue];
}

- (NSString *)fullName
{
    return [_fullNameField stringValue];
}

- (NSString *)password
{
    return [_passwordField stringValue];
}

@end

@implementation SSPreferencesStep

@synthesize stepTitle, stepDescription;

- (instancetype)init
{
    if (self = [super init]) {
        NSLog(@"[SSPreferencesStep] init");
        self.stepTitle = @"System Preferences";
        self.stepDescription = @"Configure your system preferences";
        [self setupView];
    }
    return self;
}

- (void)dealloc
{
    NSLog(@"[SSPreferencesStep] dealloc");
    [_timezonePopup release];
    [_enableLocationCheckbox release];
    [_enableUpdateCheckbox release];
    [_enableFirewallCheckbox release];
    [_stepView release];
    [stepTitle release];
    [stepDescription release];
    [super dealloc];
}

- (void)setupView
{
    _stepView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 354, 204)];

    // Enable Firewall checkbox
    _enableFirewallCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(16, 164, 322, 18)];
    [_enableFirewallCheckbox setButtonType:NSSwitchButton];
    [_enableFirewallCheckbox setTitle:@"Enable Firewall"];
    [_enableFirewallCheckbox setState:NSOnState]; // Default to enabled
    [_stepView addSubview:_enableFirewallCheckbox];

    // Enable Automatic Updates checkbox
    _enableUpdateCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(16, 140, 322, 18)];
    [_enableUpdateCheckbox setButtonType:NSSwitchButton];
    [_enableUpdateCheckbox setTitle:@"Enable Automatic Updates"];
    [_enableUpdateCheckbox setState:NSOnState]; // Default to enabled
    [_stepView addSubview:_enableUpdateCheckbox];

    // Enable Location Services checkbox
    _enableLocationCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(16, 116, 322, 18)];
    [_enableLocationCheckbox setButtonType:NSSwitchButton];
    [_enableLocationCheckbox setTitle:@"Enable Location Services"];
    [_enableLocationCheckbox setState:NSOffState]; // Default to disabled
    [_stepView addSubview:_enableLocationCheckbox];

    // Timezone selection
    NSTextField *timezoneLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(16, 84, 100, 16)];
    [timezoneLabel setStringValue:@"Timezone:"];
    [timezoneLabel setBezeled:NO];
    [timezoneLabel setDrawsBackground:NO];
    [timezoneLabel setEditable:NO];
    [timezoneLabel setSelectable:NO];
    [_stepView addSubview:timezoneLabel];
    [timezoneLabel release];

    _timezonePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(130, 80, 208, 24)];
    [_timezonePopup addItemsWithTitles:@[@"America/New_York", @"America/Chicago",
                                        @"America/Denver", @"America/Los_Angeles",
                                        @"Europe/London", @"Europe/Paris",
                                        @"Asia/Tokyo", @"Australia/Sydney"]];
    [_stepView addSubview:_timezonePopup];
}

- (NSView *)stepView
{
    return _stepView;
}

- (BOOL)canContinue
{
    // Always can continue from preferences step - all selections are optional with defaults
    return YES;
}

- (BOOL)enableFirewall
{
    return ([_enableFirewallCheckbox state] == NSOnState);
}

- (BOOL)enableAutomaticUpdates
{
    return ([_enableUpdateCheckbox state] == NSOnState);
}

- (BOOL)enableLocationServices
{
    return ([_enableLocationCheckbox state] == NSOnState);
}

- (NSString *)selectedTimezone
{
    return [_timezonePopup titleOfSelectedItem];
}

@end
