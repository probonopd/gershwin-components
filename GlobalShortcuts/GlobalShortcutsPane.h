#import <PreferencePanes/PreferencePanes.h>

@class GlobalShortcutsController;

@interface GlobalShortcutsPane : NSPreferencePane
{
    GlobalShortcutsController *shortcutsController;
    NSTimer *refreshTimer;
}

@end
