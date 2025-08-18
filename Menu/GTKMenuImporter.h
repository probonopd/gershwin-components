#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <X11/Xlib.h>
#import <X11/Xatom.h>
#import "MenuProtocolManager.h"

@class AppMenuWidget;
@class GNUDBusConnection;

/**
 * GTKMenuImporter
 * 
 * Handles GTK-style menu protocol using org.gtk.Menus and org.gtk.Actions interfaces.
 * This is separate from the Canonical dbusmenu implementation to maintain clean separation.
 */
@interface GTKMenuImporter : NSObject <MenuProtocolHandler>
{
    GNUDBusConnection *_dbusConnection;
    NSMutableDictionary *_registeredWindows;     // windowId -> service name
    NSMutableDictionary *_windowMenuPaths;      // windowId -> menu object path
    NSMutableDictionary *_windowActionPaths;    // windowId -> action group object path
    NSMutableDictionary *_menuCache;            // windowId -> NSMenu
    NSMutableDictionary *_actionGroupCache;     // windowId -> action group info
    NSTimer *_cleanupTimer;
    AppMenuWidget *_appMenuWidget;
}

@property (nonatomic, assign) AppMenuWidget *appMenuWidget;

// MenuProtocolHandler conformance
- (BOOL)connectToDBus;
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
- (void)cleanup;

// GTK-specific methods
- (NSString *)getActionGroupPathForWindow:(unsigned long)windowId;
- (BOOL)introspectGTKService:(NSString *)serviceName;
- (NSMenu *)loadGTKMenuFromDBus:(NSString *)serviceName 
                       menuPath:(NSString *)menuPath 
                     actionPath:(NSString *)actionPath;

@end
