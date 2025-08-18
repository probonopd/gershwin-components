#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

@class GNUDBusConnection;

/**
 * GTKMenuParser
 * 
 * Parses GTK-style menu structures using org.gtk.Menus interface.
 * Handles GMenuModel serialization format, which is different from canonical dbusmenu.
 */
@interface GTKMenuParser : NSObject

// Parse GTK GMenuModel data into NSMenu
+ (NSMenu *)parseGTKMenuFromDBusResult:(id)result 
                           serviceName:(NSString *)serviceName 
                            actionPath:(NSString *)actionPath 
                        dbusConnection:(GNUDBusConnection *)dbusConnection;

// Parse a GMenuModel item structure
+ (NSMenu *)parseGMenuModelItem:(id)modelItem 
                         isRoot:(BOOL)isRoot 
                    serviceName:(NSString *)serviceName 
                     actionPath:(NSString *)actionPath 
                 dbusConnection:(GNUDBusConnection *)dbusConnection;

// Create menu item from GMenuModel item
+ (NSMenuItem *)createMenuItemFromGModelItem:(id)modelItem 
                                 serviceName:(NSString *)serviceName 
                                  actionPath:(NSString *)actionPath 
                              dbusConnection:(GNUDBusConnection *)dbusConnection;

// Parse action group information
+ (NSDictionary *)parseActionGroupFromResult:(id)result;

// Internal helper method for exploring GTK menu structure
+ (NSMenu *)exploreGTKMenu:(NSArray *)menuId
                withLabels:(NSArray *)labelList
                  menuDict:(NSDictionary *)menuDict
               serviceName:(NSString *)serviceName
                actionPath:(NSString *)actionPath
            dbusConnection:(GNUDBusConnection *)dbusConnection;

// Helper method to parse additional menu data into existing dictionary
+ (void)parseMenuData:(NSArray *)menuData intoDict:(NSMutableDictionary *)menuDict;

// Keyboard shortcut parsing helpers
+ (NSString *)parseKeyboardShortcut:(NSString *)accel;
+ (NSUInteger)parseKeyboardModifiers:(NSString *)accel;

@end
