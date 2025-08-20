#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import "GNUstepGUI/GSTheme.h"
#import <X11/Xlib.h>
#import <X11/Xatom.h>

@class MenuBarView;
@class AppMenuWidget;
@class MenuProtocolManager;
@class RoundedCornersView;

@interface MenuController : NSObject <NSApplicationDelegate>
{
@public
    NSWindow *_menuBar;
    NSRect _screenFrame;
    NSSize _screenSize;
    MenuBarView *_menuBarView;
    AppMenuWidget *_appMenuWidget;
    MenuProtocolManager *_protocolManager;
    RoundedCornersView *_roundedCornersView;
    NSMenuView *_timeMenuView;
    NSMenu *_timeMenu;
    NSMenuItem *_timeMenuItem;
    NSMenuItem *_dateMenuItem;
    NSTimer *_timeUpdateTimer;
    NSDateFormatter *_timeFormatter;
    NSDateFormatter *_dateFormatter;
    Display *_display;
    Window _rootWindow;
    Atom _netActiveWindowAtom;
    Atom _netClientListAtom;
    NSThread *_x11Thread;
    BOOL _shouldStopMonitoring;
    int _dbusFileDescriptor;
}

- (id)init;
- (NSColor *)backgroundColor;
- (NSColor *)transparentColor;
- (void)createMenuBar;
- (void)applicationDidFinishLaunching:(NSNotification *)notification;
- (void)applicationWillTerminate:(NSNotification *)notification;
- (void)setupMenuBar;
- (void)updateActiveWindow;
- (void)createProtocolManager;
- (void)initializeProtocols;
- (void)setupWindowMonitoring;
- (void)announceGlobalMenuSupport;
- (void)scanForNewMenus;
- (AppMenuWidget *)appMenuWidget;
- (void)x11ActiveWindowMonitor;

- (void)createTimeMenu;
- (void)updateTimeMenu;

@end
