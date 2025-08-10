//
// CLMIntroStep.m
// Create Live Media Assistant - Introduction Step
//

#import "CLMIntroStep.h"

@implementation CLMIntroStep

- (id)init
{
    if (self = [super init]) {
        NSLog(@"CLMIntroStep: init");
        [self setupView];
    }
    return self;
}

- (void)dealloc
{
    NSLog(@"CLMIntroStep: dealloc");
    [_stepView release];
    [super dealloc];
}

- (void)setupView
{
    NSLog(@"CLMIntroStep: setupView");
    
    // Match installer card inner area (approx 354x204)
    _stepView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 354, 204)];
    
    // Inside-card welcome/info content (titles are handled by the framework outside the card)
    NSTextField *welcomeLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(16, 150, 322, 36)];
    [welcomeLabel setStringValue:@"This assistant will help you create bootable Live media from ISO images."];
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
    [features setStringValue:@"• Download images from GitHub releases\n• Use local ISO/IMG files\n• Write directly to USB or removable media\n• Verifies required disk space"];
    [features setFont:[NSFont systemFontOfSize:11]];
    [features setBezeled:NO];
    [features setDrawsBackground:NO];
    [features setEditable:NO];
    [features setSelectable:NO];
    [[features cell] setWraps:YES];
    [_stepView addSubview:features];
    [features release];
    
    // Subtle warning
    NSTextField *warningLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(16, 12, 322, 28)];
    [warningLabel setStringValue:@"All data on the selected destination disk will be erased."];
    [warningLabel setFont:[NSFont boldSystemFontOfSize:10]];
    [warningLabel setAlignment:NSCenterTextAlignment];
    [warningLabel setBezeled:NO];
    [warningLabel setDrawsBackground:NO];
    [warningLabel setEditable:NO];
    [warningLabel setSelectable:NO];
    [warningLabel setTextColor:[NSColor redColor]];
    [_stepView addSubview:warningLabel];
    [warningLabel release];
}

#pragma mark - GSAssistantStepProtocol

- (NSString *)stepTitle
{
    return @"Create Live Media";
}

- (NSString *)stepDescription  
{
    return @"Welcome to the Live Media Creator";
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
    NSLog(@"CLMIntroStep: stepWillAppear");
}

- (void)stepDidAppear
{
    NSLog(@"CLMIntroStep: stepDidAppear");
}

- (void)stepWillDisappear
{
    NSLog(@"CLMIntroStep: stepWillDisappear");
}

@end
