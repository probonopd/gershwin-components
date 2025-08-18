#import <AppKit/AppKit.h>

@class GNUDBusConnection;

// GTK Submenu Manager for handling lazy loading of GTK menu groups
@interface GTKSubmenuManager : NSObject

+ (void)setupSubmenu:(NSMenu *)submenu
         forMenuItem:(NSMenuItem *)menuItem
         serviceName:(NSString *)serviceName
            menuPath:(NSString *)menuPath
          actionPath:(NSString *)actionPath
      dbusConnection:(GNUDBusConnection *)dbusConnection
             groupId:(NSNumber *)groupId
            menuDict:(NSMutableDictionary *)menuDict;

+ (void)cleanup;

@end

// GTK Submenu Delegate for handling menu events
@interface GTKSubmenuDelegate : NSObject <NSMenuDelegate>
{
    NSString *_serviceName;
    NSString *_menuPath;
    NSString *_actionPath;
    GNUDBusConnection *_dbusConnection;
    NSNumber *_groupId;
    NSMutableDictionary *_menuDict;
}

- (id)initWithServiceName:(NSString *)serviceName
                 menuPath:(NSString *)menuPath
               actionPath:(NSString *)actionPath
           dbusConnection:(GNUDBusConnection *)dbusConnection
                  groupId:(NSNumber *)groupId
                 menuDict:(NSMutableDictionary *)menuDict;

@end
