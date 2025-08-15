#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

@class GNUDBusConnection;

@interface DBusMenuActionHandler : NSObject

// Set up action handling for a menu item
+ (void)setupActionForMenuItem:(NSMenuItem *)menuItem
                   serviceName:(NSString *)serviceName
                    objectPath:(NSString *)objectPath
                dbusConnection:(GNUDBusConnection *)dbusConnection;

// Menu item action handler
+ (void)menuItemAction:(id)sender;

// Settings for Ctrl/Alt swapping
+ (BOOL)shouldSwapCtrlAlt;
+ (void)setSwapCtrlAlt:(BOOL)swap;

// Cleanup method
+ (void)cleanup;

@end
