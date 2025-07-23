#import "BootEnvironmentPane.h"
#import "BootConfigController.h"

@implementation BootEnvironmentPane

- (id)initWithBundle:(NSBundle *)bundle
{
    self = [super initWithBundle:bundle];
    if (self) {
        bootConfigController = [[BootConfigController alloc] init];
    }
    return self;
}

- (void)dealloc
{
    [bootConfigController release];
    [super dealloc];
}

- (NSView *)loadMainView
{
    if (!_mainView) {
        _mainView = [[bootConfigController createMainView] retain];
    }
    return _mainView;
}

- (NSString *)mainNibName
{
    return nil; // We create the view programmatically
}

- (void)mainViewDidLoad
{
    // Initialize the boot config controller data
    [bootConfigController refreshConfigurations:nil];
}

- (void)didSelect
{
    [super didSelect];
    // Refresh data when the pane is selected
    [bootConfigController refreshConfigurations:nil];
}

- (BOOL)autoSaveTextFields
{
    return YES;
}

@end
