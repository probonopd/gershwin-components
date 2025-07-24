#import <PreferencePanes/PreferencePanes.h>

@class BootConfigController;

@interface BootEnvironmentPane : NSPreferencePane
{
    BootConfigController *bootConfigController;
    NSTimer *refreshTimer;
}

@end
