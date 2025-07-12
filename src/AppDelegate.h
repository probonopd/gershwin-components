#import <AppKit/AppKit.h>

@class BootConfigController;

@interface AppDelegate : NSObject <NSApplicationDelegate>
{
    NSWindow *mainWindow;
    BootConfigController *bootConfigController;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification;
- (void)createMainWindow;

@end
