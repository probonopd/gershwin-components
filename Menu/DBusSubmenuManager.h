#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

@class GNUDBusConnection;

// MARK: - DBusSubmenuDelegate Interface

@interface DBusSubmenuDelegate : NSObject <NSMenuDelegate>
{
    NSString *_serviceName;
    NSString *_objectPath;
    GNUDBusConnection *_dbusConnection;
    NSNumber *_itemId;
}

- (id)initWithServiceName:(NSString *)serviceName 
               objectPath:(NSString *)objectPath 
           dbusConnection:(GNUDBusConnection *)dbusConnection 
                   itemId:(NSNumber *)itemId;
- (void)refreshSubmenu:(NSMenu *)submenu;

@end

// MARK: - DBusSubmenuManager Interface

@interface DBusSubmenuManager : NSObject

// Setup a submenu with lazy loading delegate
+ (void)setupSubmenu:(NSMenu *)submenu
         forMenuItem:(NSMenuItem *)menuItem
         serviceName:(NSString *)serviceName
          objectPath:(NSString *)objectPath
      dbusConnection:(GNUDBusConnection *)dbusConnection
              itemId:(NSNumber *)itemId;

// Cleanup method
+ (void)cleanup;

@end
