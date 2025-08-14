#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

@class DBusMenuImporter;

@interface AppMenuWidget : NSView
{
    DBusMenuImporter *_dbusMenuImporter;
    NSMutableArray *_menuButtons;
    NSString *_currentApplicationName;
    unsigned long _currentWindowId;
    NSMenu *_currentMenu;
    NSTimer *_updateTimer;
}

@property (nonatomic, assign) DBusMenuImporter *dbusMenuImporter;

- (void)updateForActiveWindow;
- (void)clearMenu;
- (void)displayMenuForWindow:(unsigned long)windowId;
- (void)createMenuButtonsFromMenu:(NSMenu *)menu;
- (NSButton *)createMenuButtonWithTitle:(NSString *)title action:(SEL)action;
- (void)menuButtonClicked:(id)sender;

@end
