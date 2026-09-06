#import <AppKit/AppKit.h>
#import "GSUTMVirtualMachine.h"
#import "GSUTMConsoleController.h"

@interface GSUTMMainWindowController : NSWindowController

@property (nonatomic, strong, readonly) GSUTMVirtualMachine *virtualMachine;
@property (nonatomic, strong, readonly) GSUTMConsoleController *consoleController;

- (void)saveConfig;
- (void)loadConfigFromURL:(NSURL *)url;
- (void)resetConfig;

- (void)startVM;
- (void)stopVM;
- (void)openConsole:(id)sender;
- (void)cleanupVM;

@end
