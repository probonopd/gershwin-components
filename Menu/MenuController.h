#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

@class MenuBarView;
@class AppMenuWidget;
@class DBusMenuImporter;

@interface MenuController : NSObject <NSApplicationDelegate>
{
    NSWindow *_menuWindow;
    MenuBarView *_menuBarView;
    AppMenuWidget *_appMenuWidget;
    DBusMenuImporter *_dbusMenuImporter;
    NSTimer *_updateTimer;
    NSTimer *_menuScanTimer;
}

- (id)init;
- (void)applicationDidFinishLaunching:(NSNotification *)notification;
- (void)applicationWillTerminate:(NSNotification *)notification;
- (void)setupMenuBar;
- (void)updateActiveWindow:(NSTimer *)timer;
- (void)windowDidBecomeKey:(NSNotification *)notification;
- (void)createDBusImporter;
- (void)initializeDBusConnection;
- (void)setupWindowMonitoring;
- (void)announceGlobalMenuSupport;

@end
