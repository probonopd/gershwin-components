#import "DisplayPane.h"
#import "DisplayController.h"

@implementation DisplayPane

- (id)initWithBundle:(NSBundle *)bundle
{
    self = [super initWithBundle:bundle];
    if (self) {
        displayController = [[DisplayController alloc] init];
    }
    return self;
}

- (void)dealloc
{
    [self stopRefreshTimer];
    [displayController release];
    [super dealloc];
}

- (void)startRefreshTimer
{
    if (!refreshTimer) {
        refreshTimer = [NSTimer scheduledTimerWithTimeInterval:2.0 
                                                        target:displayController 
                                                      selector:@selector(refreshDisplays:) 
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
        _mainView = [[displayController createMainView] retain];
    }
    return _mainView;
}

- (NSString *)mainNibName
{
    return nil; // We create the view programmatically
}

- (void)mainViewDidLoad
{
    // Initialize the display controller data
    [displayController refreshDisplays:nil];
}

- (void)didSelect
{
    [super didSelect];
    // Refresh data when the pane is selected but don't start polling
    [displayController refreshDisplays:nil];
}

- (void)didUnselect
{
    [super didUnselect];
    // No polling to stop anymore
}

- (BOOL)autoSaveTextFields
{
    return YES;
}

@end
