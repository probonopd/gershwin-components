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

@property (nonatomic, strong) NSWindow *menuBar;
@property (nonatomic, assign) NSRect screenFrame;
@property (nonatomic, assign) NSSize screenSize;
@property (nonatomic, strong) MenuBarView *menuBarView;
@property (nonatomic, strong) AppMenuWidget *appMenuWidget;
@property (nonatomic, strong) MenuProtocolManager *protocolManager;
@property (nonatomic, strong) RoundedCornersView *roundedCornersView;
@property (nonatomic, strong) NSMenuView *timeMenuView;
@property (nonatomic, strong) NSMenu *timeMenu;
@property (nonatomic, strong) NSMenuItem *timeMenuItem;
@property (nonatomic, strong) NSMenuItem *dateMenuItem;
@property (nonatomic, strong) NSTimer *timeUpdateTimer;
@property (nonatomic, strong) NSDateFormatter *timeFormatter;
@property (nonatomic, strong) NSDateFormatter *dateFormatter;
@property (nonatomic, assign) Display *display;
@property (nonatomic, assign) Window rootWindow;
@property (nonatomic, assign) Atom netActiveWindowAtom;
@property (nonatomic, assign) Atom netClientListAtom;
@property (nonatomic, strong) NSThread *x11Thread;
@property (atomic, assign) BOOL shouldStopMonitoring; // atomic for thread-safe access from X11 monitor thread
@property (nonatomic, assign) int dbusFileDescriptor;
@property (nonatomic, assign) Display *strutDisplay;
@property (nonatomic, assign) Window strutWindow;

- (id)init;
- (NSColor *)backgroundColor;
- (NSColor *)transparentColor;
- (void)createPersistentStrutWindow;
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
