//
// BAIntroStep.m
// Backup Assistant - Introduction Step Implementation
//

#import "BAIntroStep.h"

@implementation BAIntroStep

- (id)init
{
    NSView *introView = [self createIntroView];
    
    self = [super initWithTitle:NSLocalizedString(@"Welcome to Backup Assistant", @"Intro step title")
                    description:NSLocalizedString(@"Back up and restore user home directories using ZFS", @"Intro step description")
                           view:introView];
    
    if (self) {
        self.stepType = GSAssistantStepTypeIntroduction;
        self.canProceed = YES;
        self.canReturn = NO;
    }
    
    return self;
}

- (NSView *)createIntroView
{
    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 390, 240)];
    
    // Main welcome message
    NSTextField *welcomeLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 180, 390, 40)];
    [welcomeLabel setStringValue:NSLocalizedString(@"The Backup Assistant helps you create secure backups of user home directories using the ZFS filesystem.", @"Welcome message")];
    [welcomeLabel setBezeled:NO];
    [welcomeLabel setDrawsBackground:NO];
    [welcomeLabel setEditable:NO];
    [welcomeLabel setSelectable:NO];
    [welcomeLabel setFont:[NSFont systemFontOfSize:13]];
    [welcomeLabel setAlignment:NSTextAlignmentLeft];
    [[welcomeLabel cell] setWraps:YES];
    [view addSubview:welcomeLabel];
    [welcomeLabel release];
    
    // Features list
    NSTextField *featuresLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 150, 390, 20)];
    [featuresLabel setStringValue:NSLocalizedString(@"Features:", @"Features label")];
    [featuresLabel setBezeled:NO];
    [featuresLabel setDrawsBackground:NO];
    [featuresLabel setEditable:NO];
    [featuresLabel setSelectable:NO];
    [featuresLabel setFont:[NSFont boldSystemFontOfSize:13]];
    [view addSubview:featuresLabel];
    [featuresLabel release];
    
    // Feature bullets
    NSArray *features = @[
        NSLocalizedString(@"• Create full backups of user home directories to removable ZFS disks", @"Feature 1"),
        NSLocalizedString(@"• Perform incremental backups with snapshots", @"Feature 2"),
        NSLocalizedString(@"• Restore entire home directories or specific files", @"Feature 3"),
        NSLocalizedString(@"• Automatic disk analysis and setup", @"Feature 4"),
        NSLocalizedString(@"• Safe handling of existing backup disks", @"Feature 5")
    ];
    
    CGFloat yPos = 120;
    for (NSString *feature in features) {
        NSTextField *featureLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, yPos, 350, 20)];
        [featureLabel setStringValue:feature];
        [featureLabel setBezeled:NO];
        [featureLabel setDrawsBackground:NO];
        [featureLabel setEditable:NO];
        [featureLabel setSelectable:NO];
        [featureLabel setFont:[NSFont systemFontOfSize:12]];
        [view addSubview:featureLabel];
        [featureLabel release];
        yPos -= 20;
    }
    
    // Requirements section
    NSTextField *reqLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 15, 390, 20)];
    [reqLabel setStringValue:NSLocalizedString(@"Requirements: ZFS filesystem support and root privileges", @"Requirements label")];
    [reqLabel setBezeled:NO];
    [reqLabel setDrawsBackground:NO];
    [reqLabel setEditable:NO];
    [reqLabel setSelectable:NO];
    [reqLabel setFont:[NSFont systemFontOfSize:11]];
    [reqLabel setTextColor:[NSColor secondaryLabelColor]];
    [view addSubview:reqLabel];
    [reqLabel release];
    
    return [view autorelease];
}

- (NSString *)continueButtonTitle
{
    return NSLocalizedString(@"Continue", @"Continue button title");
}

@end
