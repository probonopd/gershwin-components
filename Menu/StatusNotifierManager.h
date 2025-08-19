#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import "MenuProtocolManager.h"

@class StatusNotifierItem;
@class StatusNotifierHost;
@class StatusNotifierWatcher;

/**
 * StatusNotifierManager
 * 
 * Manages StatusNotifierItem protocol for Menu.app
 * Integrates into the existing MenuProtocolManager system
 * Handles both hosting tray icons and potentially creating our own
 */
@interface StatusNotifierManager : NSObject <MenuProtocolHandler>
{
    StatusNotifierHost *_host;
    StatusNotifierWatcher *_watcher;
    NSMutableDictionary *_trackedItems; // service name -> StatusNotifierItem proxy
    NSView *_trayView;
    AppMenuWidget *_appMenuWidget;
    BOOL _isConnected;
}

@property (nonatomic, retain) NSView *trayView;
@property (nonatomic, assign) AppMenuWidget *appMenuWidget;

// Initialization
- (instancetype)initWithTrayView:(NSView *)trayView;

// MenuProtocolHandler implementation
- (BOOL)connectToDBus;
- (BOOL)hasMenuForWindow:(unsigned long)windowId;
- (NSMenu *)getMenuForWindow:(unsigned long)windowId;
- (void)activateMenuItem:(NSMenuItem *)menuItem forWindow:(unsigned long)windowId;
- (void)registerWindow:(unsigned long)windowId serviceName:(NSString *)serviceName objectPath:(NSString *)objectPath;
- (void)unregisterWindow:(unsigned long)windowId;
- (void)scanForExistingMenuServices;
- (NSString *)getMenuServiceForWindow:(unsigned long)windowId;
- (NSString *)getMenuObjectPathForWindow:(unsigned long)windowId;
- (void)cleanup;

// StatusNotifier specific methods
- (void)startHostingTrayIcons;
- (void)stopHostingTrayIcons;
- (StatusNotifierItem *)createTrayItemWithId:(NSString *)itemId title:(NSString *)title;
- (void)removeTrayItem:(StatusNotifierItem *)item;

// Scanning and discovery
- (void)scanForExistingStatusNotifierItems;
- (void)handleNewStatusNotifierItem:(NSString *)serviceName;
- (void)handleRemovedStatusNotifierItem:(NSString *)serviceName;

@end

/**
 * StatusNotifierItemProxy
 * 
 * Proxy object for remote StatusNotifierItems
 * Represents items created by other applications
 */
@interface StatusNotifierItemProxy : NSObject
{
    NSString *_serviceName;
    NSString *_objectPath;
    NSString *_itemId;
    NSString *_title;
    NSString *_iconName;
    NSData *_iconPixmap;
    NSString *_status;
    NSString *_category;
    NSString *_menuObjectPath;
    NSMenu *_contextMenu;
}

@property (nonatomic, readonly) NSString *serviceName;
@property (nonatomic, readonly) NSString *objectPath;
@property (nonatomic, readonly) NSString *itemId;
@property (nonatomic, readonly) NSString *title;
@property (nonatomic, readonly) NSString *iconName;
@property (nonatomic, readonly) NSData *iconPixmap;
@property (nonatomic, readonly) NSString *status;
@property (nonatomic, readonly) NSString *category;
@property (nonatomic, readonly) NSString *menuObjectPath;
@property (nonatomic, readonly) NSMenu *contextMenu;

- (instancetype)initWithService:(NSString *)serviceName objectPath:(NSString *)objectPath;

// Property fetching
- (void)refreshProperties;
- (void)refreshMenu;

// Activation
- (void)activate:(int)x y:(int)y;
- (void)secondaryActivate:(int)x y:(int)y;
- (void)contextMenu:(int)x y:(int)y;
- (void)scroll:(int)delta orientation:(NSString *)orientation;

@end
