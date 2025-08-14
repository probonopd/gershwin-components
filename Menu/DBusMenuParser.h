#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

@interface DBusMenuParser : NSObject

// Parse the complete DBus menu result into an NSMenu
+ (NSMenu *)parseMenuFromDBusResult:(id)result serviceName:(NSString *)serviceName;

// Parse a layout item (recursive)
+ (NSMenu *)parseLayoutItem:(id)layoutItem isRoot:(BOOL)isRoot;

// Create a menu item from a layout item
+ (NSMenuItem *)createMenuItemFromLayoutItem:(id)layoutItem;

// Convert DBus properties array to NSDictionary
+ (NSDictionary *)convertPropertiesToDictionary:(id)propertiesObj;

@end
