#import <PreferencePanes/PreferencePanes.h>

@class DisplayController;

@interface DisplayPane : NSPreferencePane
{
    DisplayController *displayController;
    NSTimer *refreshTimer;
}

@end
