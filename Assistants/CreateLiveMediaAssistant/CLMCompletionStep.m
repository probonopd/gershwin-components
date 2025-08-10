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
    
    _stepView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 354, 204)];
    
    // Success icon (top center)
    NSImageView *iconView = [[NSImageView alloc] initWithFrame:NSMakeRect(127, 132, 100, 60)];
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
    [_stepView addSubview:iconView];
    [iconView release];
    
    // Success text
    NSTextField *successLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(12, 100, 330, 24)];
    [successLabel setStringValue:@"Live Medium Created Successfully!"];
    [successLabel setFont:[NSFont boldSystemFontOfSize:13]];
    [successLabel setAlignment:NSCenterTextAlignment];
    [successLabel setBezeled:NO];
    [successLabel setDrawsBackground:NO];
    [successLabel setEditable:NO];
    [successLabel setSelectable:NO];
    [_stepView addSubview:successLabel];
    [successLabel release];
    
    // Instructions text
    NSTextField *instructLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(12, 54, 330, 40)];
    [instructLabel setStringValue:@"You can now boot from this Live medium by inserting it and rebooting your computer."];
    [instructLabel setFont:[NSFont systemFontOfSize:11]];
    [instructLabel setAlignment:NSCenterTextAlignment];
    [instructLabel setBezeled:NO];
    [instructLabel setDrawsBackground:NO];
    [instructLabel setEditable:NO];
    [instructLabel setSelectable:NO];
    [[instructLabel cell] setWraps:YES];
    [_stepView addSubview:instructLabel];
    [instructLabel release];
    
    // Safety reminder
    NSTextField *safetyLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(12, 16, 330, 18)];
    [safetyLabel setStringValue:@"Remember to safely eject the device before removing it."];
    [safetyLabel setFont:[NSFont systemFontOfSize:10]];
    [safetyLabel setAlignment:NSCenterTextAlignment];
    [safetyLabel setBezeled:NO];
    [safetyLabel setDrawsBackground:NO];
    [safetyLabel setEditable:NO];
    [safetyLabel setSelectable:NO];
    [safetyLabel setTextColor:[NSColor blueColor]];
    [_stepView addSubview:safetyLabel];
    [safetyLabel release];
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
