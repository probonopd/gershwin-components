#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import "DBusConnection.h"
#import "MenuProtocolManager.h"

@class DBusMenuServer;
@class StatusNotifierWatcher;

// StatusNotifierItem Category types
typedef NS_ENUM(NSInteger, SNICategory) {
    SNICategoryApplicationStatus = 0,
    SNICategorySystemServices = 1,
    SNICategoryHardware = 2,
    SNICategoryCommunications = 3
};

// StatusNotifierItem Status types
typedef NS_ENUM(NSInteger, SNIStatus) {
    SNIStatusPassive = 0,
    SNIStatusActive = 1,
    SNIStatusNeedsAttention = 2
};

/**
 * StatusNotifierItem
 * 
 * Implements the org.kde.StatusNotifierItem D-Bus interface
 * Manages system tray icons following the freedesktop.org specification
 */
@interface StatusNotifierItem : NSObject
{
    NSString *_serviceName;
    NSString *_objectPath;
    NSString *_id;
    NSString *_title;
    NSString *_iconName;
    NSString *_iconThemePath;
    NSData *_iconPixmap;
    NSString *_overlayIconName;
    NSData *_overlayIconPixmap;
    NSString *_attentionIconName;
    NSData *_attentionIconPixmap;
    NSString *_attentionMovieName;
    NSString *_toolTipTitle;
    NSString *_toolTipSubTitle;
    NSData *_toolTipIcon;
    SNICategory _category;
    SNIStatus _status;
    unsigned long _windowId;
    DBusMenuServer *_menuServer;
    NSMenu *_contextMenu;
    BOOL _isRegistered;
}

@property (nonatomic, readonly) NSString *serviceName;
@property (nonatomic, readonly) NSString *objectPath;
@property (nonatomic, copy) NSString *id;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *iconName;
@property (nonatomic, copy) NSString *iconThemePath;
@property (nonatomic, copy) NSData *iconPixmap;
@property (nonatomic, copy) NSString *overlayIconName;
@property (nonatomic, copy) NSData *overlayIconPixmap;
@property (nonatomic, copy) NSString *attentionIconName;
@property (nonatomic, copy) NSData *attentionIconPixmap;
@property (nonatomic, copy) NSString *attentionMovieName;
@property (nonatomic, copy) NSString *toolTipTitle;
@property (nonatomic, copy) NSString *toolTipSubTitle;
@property (nonatomic, copy) NSData *toolTipIcon;
@property (nonatomic, assign) SNICategory category;
@property (nonatomic, assign) SNIStatus status;
@property (nonatomic, assign) unsigned long windowId;
@property (nonatomic, retain) NSMenu *contextMenu;

// Initialization
- (instancetype)initWithId:(NSString *)itemId 
                     title:(NSString *)title
                  category:(SNICategory)category;

// Registration
- (BOOL)registerWithWatcher;
- (void)unregister;

// Icon management
- (void)setIconFromImage:(NSImage *)image;
- (void)setAttentionIconFromImage:(NSImage *)image;
- (void)setOverlayIconFromImage:(NSImage *)image;
- (void)setToolTipIconFromImage:(NSImage *)image;

// Status updates
- (void)updateStatus:(SNIStatus)newStatus;
- (void)updateTitle:(NSString *)newTitle;
- (void)updateToolTip:(NSString *)title subtitle:(NSString *)subtitle;

// Menu management
- (void)setContextMenu:(NSMenu *)menu;
- (NSString *)menuObjectPath;

// D-Bus method implementations (called by D-Bus system)
- (void)activate:(int)x y:(int)y;
- (void)secondaryActivate:(int)x y:(int)y;
- (void)contextMenu:(int)x y:(int)y;
- (void)scroll:(int)delta orientation:(NSString *)orientation;

// Property change notifications
- (void)emitPropertyChanged:(NSString *)propertyName;

@end

/**
 * StatusNotifierWatcher
 * 
 * Monitors StatusNotifierItems on the system
 * Usually implemented by the desktop environment, but we may need a fallback
 */
@interface StatusNotifierWatcher : NSObject <GNUDBusNameOwnerListener>
{
    NSMutableArray *_registeredItems;
    NSMutableArray *_registeredHosts;
    BOOL _isStatusNotifierHostRegistered;
}

@property (nonatomic, readonly) NSArray *registeredStatusNotifierItems;
@property (nonatomic, readonly) BOOL isStatusNotifierHostRegistered;
@property (nonatomic, readonly) NSArray *statusNotifierHosts;

+ (instancetype)sharedWatcher;

// Item registration
- (void)registerStatusNotifierItem:(NSString *)service;
- (void)registerStatusNotifierHost:(NSString *)service;

// Signals
- (void)statusNotifierItemRegistered:(NSString *)service;
- (void)statusNotifierItemUnregistered:(NSString *)service;
- (void)statusNotifierHostRegistered;
- (void)statusNotifierHostUnregistered;

@end

/**
 * StatusNotifierHost
 * 
 * Displays StatusNotifierItems (system tray area)
 * This is what our Menu.app will implement to show tray icons
 */
@interface StatusNotifierHost : NSObject
{
    NSMutableArray *_trayItems;
    NSView *_trayView;
    StatusNotifierWatcher *_watcher;
}

@property (nonatomic, retain) NSView *trayView;

- (instancetype)initWithTrayView:(NSView *)trayView;

// Item management
- (void)addTrayItem:(StatusNotifierItem *)item;
- (void)removeTrayItem:(StatusNotifierItem *)item;
- (void)updateTrayLayout;

// Watcher integration
- (void)startMonitoring;
- (void)stopMonitoring;

@end
