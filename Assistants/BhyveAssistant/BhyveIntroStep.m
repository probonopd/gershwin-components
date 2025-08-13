//
// BhyveIntroStep.m
// Bhyve Assistant - Introduction Step
//

#import "BhyveIntroStep.h"

@implementation BhyveIntroStep

- (id)init
{
    if (self = [super init]) {
        NSLog(@"BhyveIntroStep: init");
        [self setupView];
    }
    return self;
}

- (void)dealloc
{
    NSLog(@"BhyveIntroStep: dealloc");
    [_stepView release];
    [super dealloc];
}

- (void)setupView
{
    NSLog(@"BhyveIntroStep: setupView");
    
    // Match installer card inner area (approx 354x204)
    _stepView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 354, 204)];
    
    // Welcome message
    NSTextField *welcomeLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(16, 150, 322, 36)];
    [welcomeLabel setStringValue:NSLocalizedString(@"This assistant will help you run Live ISO images using bhyve, FreeBSD's native hypervisor.", @"Intro welcome message")];
    [welcomeLabel setFont:[NSFont systemFontOfSize:12]];
    [welcomeLabel setAlignment:NSCenterTextAlignment];
    [welcomeLabel setBezeled:NO];
    [welcomeLabel setDrawsBackground:NO];
    [welcomeLabel setEditable:NO];
    [welcomeLabel setSelectable:NO];
    [[welcomeLabel cell] setWraps:YES];
    [_stepView addSubview:welcomeLabel];
    [welcomeLabel release];
    
    // Feature bullets
    NSTextField *features = [[NSTextField alloc] initWithFrame:NSMakeRect(24, 56, 306, 88)];
    [features setStringValue:NSLocalizedString(@"• Native FreeBSD virtualization with bhyve\n• VNC display for graphical access\n• Configurable memory and CPU allocation\n• Bridge or NAT networking options\n• Compatible with most x86_64 Live ISOs", @"Feature list")];
    [features setFont:[NSFont systemFontOfSize:11]];
    [features setBezeled:NO];
    [features setDrawsBackground:NO];
    [features setEditable:NO];
    [features setSelectable:NO];
    [[features cell] setWraps:YES];
    [_stepView addSubview:features];
    [features release];
    
    // Requirements note
    NSTextField *requirementsLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(16, 12, 322, 28)];
    [requirementsLabel setStringValue:NSLocalizedString(@"Requires root privileges and VT-x/AMD-V hardware virtualization support.", @"Requirements message")];
    [requirementsLabel setFont:[NSFont systemFontOfSize:10]];
    [requirementsLabel setAlignment:NSCenterTextAlignment];
    [requirementsLabel setBezeled:NO];
    [requirementsLabel setDrawsBackground:NO];
    [requirementsLabel setEditable:NO];
    [requirementsLabel setSelectable:NO];
    [requirementsLabel setTextColor:[NSColor colorWithCalibratedRed:0.0 green:0.4 blue:0.8 alpha:1.0]];
    [_stepView addSubview:requirementsLabel];
    [requirementsLabel release];
}

#pragma mark - GSAssistantStepProtocol

- (NSString *)stepTitle
{
    return NSLocalizedString(@"Bhyve Virtual Machine", @"Step title");
}

- (NSString *)stepDescription  
{
    return NSLocalizedString(@"Welcome to the Bhyve VM Assistant", @"Step description");
}

- (NSView *)stepView
{
    return _stepView;
}

- (BOOL)canContinue
{
    return YES;
}

- (void)stepWillAppear
{
    NSLog(@"BhyveIntroStep: stepWillAppear");
}

- (void)stepDidAppear
{
    NSLog(@"BhyveIntroStep: stepDidAppear");
}

- (void)stepWillDisappear
{
    NSLog(@"BhyveIntroStep: stepWillDisappear");
}

@end
