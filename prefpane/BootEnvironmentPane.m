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
    [self stopRefreshTimer];
    [bootConfigController release];
    [super dealloc];
}

- (void)startRefreshTimer
{
    if (!refreshTimer) {
        refreshTimer = [NSTimer scheduledTimerWithTimeInterval:1.5 
                                                        target:bootConfigController 
                                                      selector:@selector(refreshConfigurations:) 
                                                      userInfo:nil 
                                                       repeats:YES];
        [refreshTimer retain];
    }
}

- (void)stopRefreshTimer
{
    if (refreshTimer) {
        [refreshTimer invalidate];
        [refreshTimer release];
        refreshTimer = nil;
    }
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
    // Refresh data when the pane is selected and start polling
    [bootConfigController refreshConfigurations:nil];
    [self startRefreshTimer];
}

- (void)didUnselect
{
    [super didUnselect];
    // Stop polling when the pane is not visible
    [self stopRefreshTimer];
}

- (BOOL)autoSaveTextFields
{
    return YES;
}

@end
