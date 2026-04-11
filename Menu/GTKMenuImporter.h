/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */


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

@property (nonatomic, strong) GNUDBusConnection *dbusConnection;
@property (nonatomic, strong) NSMutableDictionary *registeredWindows;     // windowId -> service name
@property (nonatomic, strong) NSMutableDictionary *windowMenuPaths;      // windowId -> menu object path
@property (nonatomic, strong) NSMutableDictionary *windowActionPaths;    // windowId -> action group object path
@property (nonatomic, strong) NSMutableDictionary *menuCache;            // windowId -> NSMenu
@property (nonatomic, strong) NSMutableDictionary *actionGroupCache;     // windowId -> action group info
@property (nonatomic, strong) NSTimer *cleanupTimer;
@property (nonatomic, weak) AppMenuWidget *appMenuWidget;
// Service name for which keyboard shortcuts are currently grabbed.  Used to
// skip redundant re-registration when switching between windows of the same app.
@property (nonatomic, strong) NSString *lastRegisteredShortcutService;

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
