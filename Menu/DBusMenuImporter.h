#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import "DBusConnection.h"
#import "MenuProtocolManager.h"

@class AppMenuWidget;

@interface DBusMenuImporter : NSObject <MenuProtocolHandler>
{
    GNUDBusConnection *_dbusConnection;
    NSMutableDictionary *_registeredWindows; // windowId -> service name
    NSMutableDictionary *_windowMenuPaths;   // windowId -> object path
    NSMutableDictionary *_menuCache;         // windowId -> NSMenu
    NSTimer *_cleanupTimer;
    AppMenuWidget *_appMenuWidget;  // Reference to AppMenuWidget for immediate menu display
}

@property (nonatomic, assign) AppMenuWidget *appMenuWidget;

- (BOOL)connectToDBus;
- (void)showDBusErrorAndExit;
- (BOOL)hasMenuForWindow:(unsigned long)windowId;
- (NSMenu *)getMenuForWindow:(unsigned long)windowId;
- (void)activateMenuItem:(NSMenuItem *)menuItem forWindow:(unsigned long)windowId;
- (void)registerWindow:(unsigned long)windowId 
           serviceName:(NSString *)serviceName 
            objectPath:(NSString *)objectPath;
- (void)unregisterWindow:(unsigned long)windowId;
- (void)scanForExistingMenuServices;
- (NSString *)getMenuServiceForWindow:(unsigned long)windowId;
- (NSString *)getMenuObjectPathForWindow:(unsigned long)windowId;
- (NSMenu *)createTestMenu;

// DBus method handlers
- (void)handleDBusMethodCall:(NSDictionary *)callInfo;
- (void)handleRegisterWindow:(NSArray *)arguments;
- (void)handleUnregisterWindow:(NSArray *)arguments;
- (NSString *)handleGetMenuForWindow:(NSArray *)arguments;

@end
