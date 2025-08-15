#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

@class GNUDBusConnection;

@interface DBusMenuParser : NSObject

// Parse the complete DBus menu result into an NSMenu
+ (NSMenu *)parseMenuFromDBusResult:(id)result serviceName:(NSString *)serviceName;

// Parse the complete DBus menu result into an NSMenu with action support
+ (NSMenu *)parseMenuFromDBusResult:(id)result 
                        serviceName:(NSString *)serviceName 
                         objectPath:(NSString *)objectPath 
                     dbusConnection:(GNUDBusConnection *)dbusConnection;

// Parse a layout item (recursive)
+ (NSMenu *)parseLayoutItem:(id)layoutItem 
                     isRoot:(BOOL)isRoot 
                serviceName:(NSString *)serviceName 
                 objectPath:(NSString *)objectPath 
             dbusConnection:(GNUDBusConnection *)dbusConnection;

// Create a menu item from a layout item
+ (NSMenuItem *)createMenuItemFromLayoutItem:(id)layoutItem 
                                 serviceName:(NSString *)serviceName 
                                  objectPath:(NSString *)objectPath 
                              dbusConnection:(GNUDBusConnection *)dbusConnection;

// Convert DBus properties array to NSDictionary
+ (NSDictionary *)convertPropertiesToDictionary:(id)propertiesObj;

// Cleanup method
+ (void)cleanup;

@end
