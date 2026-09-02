/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */


#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import "DBusConnection.h"
#import "MenuProtocolManager.h"

@class AppMenuWidget;

@interface DBusMenuImporter : NSObject <MenuProtocolHandler>
{
    NSObject *_windowRegistryLock;  // Lock for thread-safe window registry access
}

@property (nonatomic, strong) GNUDBusConnection *dbusConnection;
@property (nonatomic, strong) NSMutableDictionary *registeredWindows; // windowId -> service name
@property (nonatomic, strong) NSMutableDictionary *windowMenuPaths;   // windowId -> object path
@property (nonatomic, strong) NSMutableDictionary *menuCache;         // windowId -> NSMenu
@property (nonatomic, strong) NSMutableDictionary *loadRetries;       // windowId -> retry count
@property (nonatomic, strong) NSMutableDictionary *failedWindows;     // windowId -> NSDate (failure time) - prevents re-register cycle
@property (nonatomic, strong) NSTimer *cleanupTimer;
@property (nonatomic, weak) AppMenuWidget *appMenuWidget;  // Reference to AppMenuWidget for immediate menu display
@property (atomic, assign) BOOL processingMessages;        // Guard to prevent re-entrant DBus processing

- (BOOL)connectToDBus;
- (void)showDBusErrorAndExit;
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
- (NSMenu *)createTestMenu;
- (int)getDBusFileDescriptor;
- (void)processDBusMessages;
- (NSUInteger)pendingMessageCount;

// DBus method handlers
- (void)handleDBusMethodCall:(NSDictionary *)callInfo;
- (void)handleRegisterWindow:(NSArray *)arguments;
- (void)handleUnregisterWindow:(NSArray *)arguments;
- (NSString *)handleGetMenuForWindow:(NSArray *)arguments;

@end
