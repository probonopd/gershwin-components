#import <PreferencePanes/PreferencePanes.h>

@class StartupDiskController;

@interface StartupDiskPane : NSPreferencePane
{
    StartupDiskController *startupDiskController;
    NSTimer *refreshTimer;
}

@end
