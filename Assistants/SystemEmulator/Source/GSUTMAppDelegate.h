#import <AppKit/AppKit.h>

@class GSUTMMainWindowController;
@class GSUTMAssistant;

@interface GSUTMAppDelegate : NSObject <NSApplicationDelegate>
{
    GSUTMMainWindowController *_mainController;
    GSUTMAssistant *_assistant;
    NSMenu *_mainMenu;
    NSString *_pendingOpenPath;
}

@property (retain) NSString *pendingOpenPath;

- (IBAction)showAboutPanel:(id)sender;
- (IBAction)newVM:(id)sender;
- (IBAction)openVM:(id)sender;
- (IBAction)saveVM:(id)sender;

- (IBAction)startVM:(id)sender;
- (IBAction)stopVM:(id)sender;
- (IBAction)openConsole:(id)sender;
- (IBAction)quitApp:(id)sender;

@end
