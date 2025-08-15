#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

@class DBusMenuImporter;

@interface AppMenuWidget : NSView <NSMenuDelegate>
{
    DBusMenuImporter *_dbusMenuImporter;
    NSMenuView *_menuView;
    NSString *_currentApplicationName;
    unsigned long _currentWindowId;
    NSMenu *_currentMenu;
    NSTimer *_updateTimer;
}

@property (nonatomic, assign) DBusMenuImporter *dbusMenuImporter;

- (void)updateForActiveWindow;
- (void)clearMenu;
- (void)displayMenuForWindow:(unsigned long)windowId;
- (void)setupMenuViewWithMenu:(NSMenu *)menu;
- (void)checkAndDisplayMenuForNewlyRegisteredWindow:(unsigned long)windowId;

// Debug methods
- (void)debugLogCurrentMenuState;
- (void)menuItemClicked:(NSMenuItem *)sender;

@end
