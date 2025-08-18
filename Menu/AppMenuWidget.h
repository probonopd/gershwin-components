#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <X11/Xlib.h>
#import <X11/keysym.h>

@class MenuProtocolManager;

@interface AppMenuWidget : NSView <NSMenuDelegate>
{
    MenuProtocolManager *_protocolManager;
    NSMenuView *_menuView;
    NSString *_currentApplicationName;
    unsigned long _currentWindowId;
    NSMenu *_currentMenu;
    NSTimer *_updateTimer;
}

@property (nonatomic, assign) MenuProtocolManager *protocolManager;

- (void)updateForActiveWindow;
- (void)clearMenu;
- (void)displayMenuForWindow:(unsigned long)windowId;
- (void)setupMenuViewWithMenu:(NSMenu *)menu;
- (void)loadMenu:(NSMenu *)menu forWindow:(unsigned long)windowId;
- (void)checkAndDisplayMenuForNewlyRegisteredWindow:(unsigned long)windowId;
- (BOOL)isPlaceholderMenu:(NSMenu *)menu;
- (NSMenu *)createFileMenuWithClose:(unsigned long)windowId;
- (void)closeWindow:(NSMenuItem *)sender;
- (void)closeActiveWindow:(NSMenuItem *)sender;
- (void)sendAltF4ToWindow:(unsigned long)windowId;

// Debug methods
- (void)debugLogCurrentMenuState;
- (void)menuItemClicked:(NSMenuItem *)sender;

@end
