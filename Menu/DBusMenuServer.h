#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

@class GNUDBusConnection;

/**
 * DBusMenuServer
 * 
 * Implements the org.freedesktop.DBus.Menu D-Bus interface
 * Exports NSMenu structures over D-Bus for StatusNotifierItem context menus
 */
@interface DBusMenuServer : NSObject
{
    NSString *_objectPath;
    NSMenu *_menu;
    GNUDBusConnection *_connection;
    NSMutableDictionary *_menuItems; // id -> NSMenuItem mapping
    NSInteger _nextItemId;
    BOOL _isRegistered;
}

@property (nonatomic, readonly) NSString *objectPath;
@property (nonatomic, retain) NSMenu *menu;

// Initialization
- (instancetype)initWithMenu:(NSMenu *)menu objectPath:(NSString *)objectPath;

// Registration
- (BOOL)registerWithDBus;
- (void)unregister;

// D-Bus method implementations
- (NSArray *)getLayout:(NSInteger)parentId recursionDepth:(NSInteger)depth propertyNames:(NSArray *)propertyNames;
- (NSDictionary *)getGroupProperties:(NSArray *)itemIds propertyNames:(NSArray *)propertyNames;
- (id)getProperty:(NSInteger)itemId propertyName:(NSString *)propertyName;
- (void)event:(NSInteger)itemId eventId:(NSString *)eventId data:(id)data timestamp:(NSUInteger)timestamp;
- (NSArray *)eventGroup:(NSArray *)events;
- (BOOL)aboutToShow:(NSInteger)itemId;
- (NSArray *)aboutToShowGroup:(NSArray *)itemIds;

// Menu updates
- (void)menuDidChange:(NSNotification *)notification;
- (void)emitLayoutUpdated:(NSInteger)revision parentId:(NSInteger)parentId;
- (void)emitItemsPropertiesUpdated:(NSArray *)updatedProps removedProps:(NSArray *)removedProps;

@end

/**
 * DBusMenuProperty
 * 
 * Represents properties of menu items in the DBusMenu protocol
 */
@interface DBusMenuProperty : NSObject

+ (NSDictionary *)propertiesForMenuItem:(NSMenuItem *)item;
+ (NSString *)typeForMenuItem:(NSMenuItem *)item;
+ (NSString *)labelForMenuItem:(NSMenuItem *)item;
+ (BOOL)enabledForMenuItem:(NSMenuItem *)item;
+ (BOOL)visibleForMenuItem:(NSMenuItem *)item;
+ (NSArray *)childrenDisplayForMenuItem:(NSMenuItem *)item;
+ (NSData *)iconDataForMenuItem:(NSMenuItem *)item;
+ (NSString *)shortcutForMenuItem:(NSMenuItem *)item;

@end
