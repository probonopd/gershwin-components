//
// CLMCompletionStep.m
// Create Live Media Assistant - Completion Step
//

#import "CLMCompletionStep.h"

@implementation CLMCompletionStep

- (id)init
{
    if (self = [super init]) {
        NSLog(@"CLMCompletionStep: init");
        [self setupView];
    }
    return self;
}

- (void)dealloc
{
    NSLog(@"CLMCompletionStep: dealloc");
    [_stepView release];
    [super dealloc];
}

- (void)setupView
{
    NSLog(@"CLMCompletionStep: setupView");
    
    _stepView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300)];
    
    // Main container with proper layout
    NSView *containerView = [[NSView alloc] initWithFrame:NSMakeRect(20, 20, 360, 260)];
    [_stepView addSubview:containerView];
    
    // Success icon
    NSImageView *iconView = [[NSImageView alloc] initWithFrame:NSMakeRect(130, 180, 100, 80)];
    NSString *iconPath = [[NSBundle mainBundle] pathForResource:@"check" ofType:@"png"];
    if (!iconPath) {
        iconPath = [[NSBundle mainBundle] pathForResource:@"usbsuccess" ofType:@"svg"];
    }
    if (iconPath) {
        NSImage *icon = [[NSImage alloc] initWithContentsOfFile:iconPath];
        if (icon) {
            [iconView setImage:icon];
            [icon release];
        }
    }
    [iconView setImageScaling:NSImageScaleProportionallyUpOrDown];
    [containerView addSubview:iconView];
    [iconView release];
    
    // Success text
    NSTextField *successLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 120, 320, 50)];
    [successLabel setStringValue:@"Live Medium Created Successfully!"];
    [successLabel setFont:[NSFont boldSystemFontOfSize:16]];
    [successLabel setAlignment:NSCenterTextAlignment];
    [successLabel setBezeled:NO];
    [successLabel setDrawsBackground:NO];
    [successLabel setEditable:NO];
    [successLabel setSelectable:NO];
    [successLabel setTextColor:[NSColor colorWithDeviceRed:0.0 green:0.6 blue:0.0 alpha:1.0]];
    [containerView addSubview:successLabel];
    [successLabel release];
    
    // Instructions text
    NSTextField *instructLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 50, 320, 60)];
    [instructLabel setStringValue:@"The Live image has been successfully written to your device. You can now start your computer from this Live medium by inserting it and rebooting."];
    [instructLabel setFont:[NSFont systemFontOfSize:12]];
    [instructLabel setAlignment:NSCenterTextAlignment];
    [instructLabel setBezeled:NO];
    [instructLabel setDrawsBackground:NO];
    [instructLabel setEditable:NO];
    [instructLabel setSelectable:NO];
    [[instructLabel cell] setWraps:YES];
    [containerView addSubview:instructLabel];
    [instructLabel release];
    
    // Safety reminder
    NSTextField *safetyLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 10, 320, 30)];
    [safetyLabel setStringValue:@"💡 Remember to safely eject the device before removing it!"];
    [safetyLabel setFont:[NSFont systemFontOfSize:11]];
    [safetyLabel setAlignment:NSCenterTextAlignment];
    [safetyLabel setBezeled:NO];
    [safetyLabel setDrawsBackground:NO];
    [safetyLabel setEditable:NO];
    [safetyLabel setSelectable:NO];
    [safetyLabel setTextColor:[NSColor blueColor]];
    [containerView addSubview:safetyLabel];
    [safetyLabel release];
    
    [containerView release];
}

#pragma mark - GSAssistantStepProtocol

- (NSString *)stepTitle
{
    return @"Live Medium Complete";
}

- (NSString *)stepDescription  
{
    return @"Your Live medium is ready to use";
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
    NSLog(@"CLMCompletionStep: stepWillAppear");
    
    // Play success sound if available
    NSString *soundPath = [[NSBundle mainBundle] pathForResource:@"success" ofType:@"mp3"];
    if (soundPath) {
        NSTask *playTask = [[NSTask alloc] init];
        [playTask setLaunchPath:@"/usr/bin/timeout"];
        [playTask setArguments:@[@"5", @"mpg321", soundPath]];
        
        @try {
            [playTask launch];
            // Don't wait for completion
        }
        @catch (NSException *exception) {
            NSLog(@"CLMCompletionStep: Could not play success sound: %@", [exception reason]);
        }
        
        [playTask release];
    }
}

- (void)stepDidAppear
{
    NSLog(@"CLMCompletionStep: stepDidAppear");
}

- (void)stepWillDisappear
{
    NSLog(@"CLMCompletionStep: stepWillDisappear");
}

@end
