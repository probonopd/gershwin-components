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
    
    _stepView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300)];
    
    // Main container with proper layout
    NSView *containerView = [[NSView alloc] initWithFrame:NSMakeRect(20, 20, 360, 260)];
    [_stepView addSubview:containerView];
    
    // App icon
    NSImageView *iconView = [[NSImageView alloc] initWithFrame:NSMakeRect(130, 180, 100, 80)];
    NSString *iconPath = [[NSBundle mainBundle] pathForResource:@"Create_Live_Media" ofType:@"png"];
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
    
    // Welcome text
    NSTextField *welcomeLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 120, 320, 50)];
    [welcomeLabel setStringValue:@"Welcome to Create Live Media"];
    [welcomeLabel setFont:[NSFont boldSystemFontOfSize:16]];
    [welcomeLabel setAlignment:NSCenterTextAlignment];
    [welcomeLabel setBezeled:NO];
    [welcomeLabel setDrawsBackground:NO];
    [welcomeLabel setEditable:NO];
    [welcomeLabel setSelectable:NO];
    [containerView addSubview:welcomeLabel];
    [welcomeLabel release];
    
    // Description text
    NSTextField *descLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 50, 320, 60)];
    [descLabel setStringValue:@"This assistant will help you create bootable live media from ISO images. You can download images from GitHub repositories or use local ISO files."];
    [descLabel setFont:[NSFont systemFontOfSize:12]];
    [descLabel setAlignment:NSCenterTextAlignment];
    [descLabel setBezeled:NO];
    [descLabel setDrawsBackground:NO];
    [descLabel setEditable:NO];
    [descLabel setSelectable:NO];
    [[descLabel cell] setWraps:YES];
    [containerView addSubview:descLabel];
    [descLabel release];
    
    // Warning text
    NSTextField *warningLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 10, 320, 30)];
    [warningLabel setStringValue:@"⚠️ All data on the selected disk will be erased!"];
    [warningLabel setFont:[NSFont boldSystemFontOfSize:11]];
    [warningLabel setAlignment:NSCenterTextAlignment];
    [warningLabel setBezeled:NO];
    [warningLabel setDrawsBackground:NO];
    [warningLabel setEditable:NO];
    [warningLabel setSelectable:NO];
    [warningLabel setTextColor:[NSColor redColor]];
    [containerView addSubview:warningLabel];
    [warningLabel release];
    
    [containerView release];
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
