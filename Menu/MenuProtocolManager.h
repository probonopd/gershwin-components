/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */


#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

@class AppMenuWidget;

// Abstract protocol manager interface
@protocol MenuProtocolHandler <NSObject>

@required
- (BOOL)connectToDBus;
- (BOOL)registerService;
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
- (void)processDBusMessages;
// Re-register the global (X11-grabbed) shortcuts for a window's menu after
// they have been cleared (e.g. on an app switch).  Implemented by the DBus
// and GTK importers.
- (void)reregisterShortcutsForMenu:(NSMenu *)menu windowId:(unsigned long)windowId;
// Synchronously refresh menu item enabled/state from the client just before
// a submenu is displayed.  Implemented only by GNUStepMenuImporter.
- (BOOL)refreshMenuStateForWindow:(unsigned long)windowId;
// Returns YES when the window's enabled/checkmark states are known to be
// current (pulled or pushed within the TTL).  Implemented only by
// GNUStepMenuImporter; the click path uses it to skip the synchronous pull.
- (BOOL)menuStatesAreFreshForWindow:(unsigned long)windowId withinTTL:(NSTimeInterval)ttl;

@end

typedef NS_ENUM(NSInteger, MenuProtocolType) {
    MenuProtocolTypeCanonical = 0,  // com.canonical.dbusmenu
    MenuProtocolTypeGTK = 1,        // org.gtk.Menus + org.gtk.Actions
    MenuProtocolTypeGNUstep = 2     // GNUstep-native IPC
};

/**
 * MenuProtocolManager
 * 
 * Central coordinator for different menu protocols (Canonical vs GTK).
 * Provides a unified interface while maintaining clear separation between implementations.
 */
@interface MenuProtocolManager : NSObject

@property (nonatomic, strong) NSMutableArray *protocolHandlers;  // Array of protocol handlers
@property (nonatomic, weak) AppMenuWidget *appMenuWidget;        // Reference to the menu widget
@property (nonatomic, strong) NSMutableDictionary *windowToProtocolMap; // windowId -> protocol type that handles it

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

// DBus integration
- (int)getDBusFileDescriptor;
- (void)processDBusMessages;

// AppMenuWidget management
- (void)updateAllHandlersWithAppMenuWidget:(AppMenuWidget *)appMenuWidget;

// Cleanup
- (void)cleanup;

// Synchronously refresh item enabled/state for windowId from the owning client.
// Forwards to the protocol handler that manages the given window.
- (BOOL)refreshMenuStateForWindow:(unsigned long)windowId;

// Returns YES when the window's enabled/checkmark states are known to be
// current within the TTL, so callers can skip the synchronous pull.
- (BOOL)menuStatesAreFreshForWindow:(unsigned long)windowId withinTTL:(NSTimeInterval)ttl;

// Re-register the global shortcuts for the given window's menu by delegating
// to the protocol handler that manages the window.
- (void)reregisterShortcutsForMenu:(NSMenu *)menu windowId:(unsigned long)windowId;

@end
