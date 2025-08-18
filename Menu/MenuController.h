#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import "GNUstepGUI/GSTheme.h"
#import <X11/Xlib.h>
#import <X11/Xatom.h>

@class MenuBarView;
@class AppMenuWidget;
@class MenuProtocolManager;
@class RoundedCornersView;

#define RIGHTPADDING 20
#define LEFTPADDING 20
#define PADDING 10

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
    Display *_display;
    Window _rootWindow;
    Atom _netActiveWindowAtom;
    Atom _netClientListAtom;
    NSThread *_x11Thread;
    BOOL _shouldStopMonitoring;
}

- (id)init;
- (NSColor *)backgroundColor;
- (NSColor *)transparentColor;
- (void)createTopBar;
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

@end
