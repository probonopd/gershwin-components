#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

@class AppMenuWidget;

// Abstract protocol manager interface
@protocol MenuProtocolHandler <NSObject>

@required
- (BOOL)connectToDBus;
- (BOOL)hasMenuForWindow:(unsigned long)windowId;
- (NSMenu *)getMenuForWindow:(unsigned long)windowId;
- (void)activateMenuItem:(NSMenuItem *)menuItem forWindow:(unsigned long)windowId;
- (void)registerWindow:(unsigned long)windowId serviceName:(NSString *)serviceName objectPath:(NSString *)objectPath;
- (void)unregisterWindow:(unsigned long)windowId;
- (void)scanForExistingMenuServices;
- (NSString *)getMenuServiceForWindow:(unsigned long)windowId;
- (NSString *)getMenuObjectPathForWindow:(unsigned long)windowId;

@optional
- (void)setAppMenuWidget:(AppMenuWidget *)widget;
- (void)cleanup;

@end

typedef NS_ENUM(NSInteger, MenuProtocolType) {
    MenuProtocolTypeCanonical = 0,  // com.canonical.dbusmenu
    MenuProtocolTypeGTK = 1         // org.gtk.Menus + org.gtk.Actions
};

/**
 * MenuProtocolManager
 * 
 * Central coordinator for different menu protocols (Canonical vs GTK).
 * Provides a unified interface while maintaining clear separation between implementations.
 */
@interface MenuProtocolManager : NSObject
{
    NSMutableArray *_protocolHandlers;  // Array of protocol handlers
    AppMenuWidget *_appMenuWidget;      // Reference to the menu widget
    NSMutableDictionary *_windowToProtocolMap; // windowId -> protocol type that handles it
}

@property (nonatomic, assign) AppMenuWidget *appMenuWidget;

// Singleton instance
+ (instancetype)sharedManager;

// Protocol management
- (void)registerProtocolHandler:(id<MenuProtocolHandler>)handler forType:(MenuProtocolType)type;
- (id<MenuProtocolHandler>)handlerForType:(MenuProtocolType)type;
- (BOOL)initializeAllProtocols;

// Unified menu interface (delegates to appropriate protocol handler)
- (BOOL)hasMenuForWindow:(unsigned long)windowId;
- (NSMenu *)getMenuForWindow:(unsigned long)windowId;
- (void)activateMenuItem:(NSMenuItem *)menuItem forWindow:(unsigned long)windowId;
- (void)scanForExistingMenuServices;

// Window registration (auto-detects protocol type)
- (void)registerWindow:(unsigned long)windowId 
           serviceName:(NSString *)serviceName 
            objectPath:(NSString *)objectPath;
- (void)unregisterWindow:(unsigned long)windowId;

// Protocol detection
- (MenuProtocolType)detectProtocolTypeForService:(NSString *)serviceName objectPath:(NSString *)objectPath;

// Cleanup
- (void)cleanup;

@end
