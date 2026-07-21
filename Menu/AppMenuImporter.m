/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "AppMenuImporter.h"
#import "DBusConnection.h"
#import "GTKMenuParser.h"
#import "DBusMenuParser.h"
#import "MenuProfiler.h"
#import <dispatch/dispatch.h>
#import <X11/Xlib.h>
#import <X11/Xatom.h>

@interface AppMenuImporter ()
{
    unsigned long _currentXID;
    NSMutableDictionary *_menuCache;
    NSMutableDictionary *_subscriptions;
    Display *_display;
    Atom _gstepAppAtom;
}
@end

@implementation AppMenuImporter

+ (instancetype)sharedImporter
{
    static AppMenuImporter *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _menuQueue = dispatch_queue_create("org.gnustep.appmenu.importer", DISPATCH_QUEUE_SERIAL);
        _currentXID = 0;
        _menuCache = [[NSMutableDictionary alloc] init];
        _subscriptions = [[NSMutableDictionary alloc] init];
        
        // Open X11 display for GNUstep window detection
        _display = XOpenDisplay(NULL);
        if (_display) {
            _gstepAppAtom = XInternAtom(_display, "_GNUSTEP_WM_ATTR", False);
        }
        
        // Connect to DBus
        self.dbusConnection = [GNUDBusConnection sessionBus];
        
        NSDebugLLog(@"gwcomp", @"AppMenuImporter: Initialized");
    }
    return self;
}

- (void)dealloc
{
    [self cleanup];
}

- (void)cleanup
{
    NSDebugLLog(@"gwcomp", @"AppMenuImporter: Cleaning up");
    
    [self cancelPendingImports];
    
    if (_display) {
        XCloseDisplay(_display);
        _display = NULL;
    }
    
    _menuCache = nil;
    _subscriptions = nil;
}

- (void)activeWindowChanged:(unsigned long)windowId
{
    MENU_PROFILE_BEGIN(AppMenuActiveWindowChanged);

    dispatch_async(_menuQueue, ^{
        self->_currentXID = windowId;
        [self _invalidateMenus];
        [self _scheduleImportForXID:windowId];
    });

    MENU_PROFILE_END(AppMenuActiveWindowChanged);
}

- (void)cancelPendingImports
{
    dispatch_sync(_menuQueue, ^{
        self->_currentXID = 0;
        [self _invalidateMenus];
    });
}

- (void)_invalidateMenus
{
    // Cancel all subscriptions
    [_subscriptions removeAllObjects];
    
    // Clear menu cache
    [_menuCache removeAllObjects];
    
    // Clear UI on main thread
    dispatch_async(dispatch_get_main_queue(), ^{
        // Notify that menus should be cleared
        [[NSNotificationCenter defaultCenter] postNotificationName:@"AppMenuShouldClear" object:nil];
    });
}

- (void)_scheduleImportForXID:(unsigned long)windowId
{
    MENU_PROFILE_BEGIN(scheduleImportForXID);

    // 100ms delay to avoid GTK race condition
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
        _menuQueue,
        ^{
            if (windowId != self->_currentXID) {
                NSDebugLLog(@"gwcomp", @"AppMenuImporter: XID %lu is stale (current: %lu), skipping import", 
                      windowId, self->_currentXID);
                return;
            }
            
            // Check if this is a GNUstep window
            if ([self isGNUstepWindow:windowId]) {
                NSDebugLLog(@"gwcomp", @"AppMenuImporter: XID %lu is a GNUstep window, using GNUstep IPC", windowId);
                [self _handleGNUstepWindow:windowId];
                return;
            }
            
            NSDebugLLog(@"gwcomp", @"AppMenuImporter: Trying Canonical AppMenu for XID %lu", windowId);
            [self _tryCanonicalForXID:windowId];
        }
    );

    MENU_PROFILE_END(scheduleImportForXID);
}

- (void)_handleGNUstepWindow:(unsigned long)windowId
{
    // Post notification that this is a GNUstep window
    dispatch_async(dispatch_get_main_queue(), ^{
        NSDictionary *userInfo = @{@"windowId": @(windowId)};
        [[NSNotificationCenter defaultCenter] postNotificationName:@"AppMenuGNUstepWindow" 
                                                          object:nil 
                                                        userInfo:userInfo];
    });
}

- (void)_tryCanonicalForXID:(unsigned long)windowId
{
    MENU_PROFILE_BEGIN(tryCanonicalForXID);

    // Try Canonical AppMenu Registrar using synchronous call
    // Note: This should be on a background queue already via _scheduleImportForXID
    NSArray *reply = nil;
    @try {
        reply = [self.dbusConnection callMethod:@"GetMenuForWindow"
                                        onService:@"com.canonical.AppMenu.Registrar"
                                      objectPath:@"/com/canonical/AppMenu/Registrar"
                                       interface:@"com.canonical.AppMenu.Registrar"
                                       arguments:@[@(windowId)]];
    }
    @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"AppMenuImporter: Exception calling Canonical AppMenu.Registrar: %@", exception);
        NSDebugLLog(@"gwcomp", @"AppMenuImporter: This is expected if Canonical AppMenu support is not available");
        // Fall through to fallback
    }
    
    dispatch_async(self->_menuQueue, ^{
        if (windowId != self->_currentXID) {
            NSDebugLLog(@"gwcomp", @"AppMenuImporter: XID %lu became stale during Canonical query", windowId);
            return;
        }
        
        if (reply && reply.count >= 2) {
            NSString *service = reply[0];
            NSString *path = reply[1];
            
            if (![service isKindOfClass:[NSString class]] || [service length] == 0 ||
                ![path isKindOfClass:[NSString class]] || [path length] == 0) {
                NSDebugLLog(@"gwcomp", @"AppMenuImporter: Canonical returned empty service/path, trying GTK fallback");
                [self _fallbackToGTKPropertiesForXID:windowId];
                return;
            }
            
            NSDebugLLog(@"gwcomp", @"AppMenuImporter: Canonical AppMenu found - service: %@, path: %@", service, path);
            [self _importGTKMenusWithService:service path:path forXID:windowId];
        } else {
            NSDebugLLog(@"gwcomp", @"AppMenuImporter: Canonical AppMenu not available, trying GTK fallback");
            [self _fallbackToGTKPropertiesForXID:windowId];
        }
    });

    MENU_PROFILE_END(tryCanonicalForXID);
}

- (void)_fallbackToGTKPropertiesForXID:(unsigned long)windowId
{
    NSDebugLLog(@"gwcomp", @"AppMenuImporter: Trying GTK properties fallback for XID %lu", windowId);
    
    // Read GTK properties from X11 window
    NSString *service = [self _readX11StringProperty:windowId atom:"_GTK_UNIQUE_BUS_NAME"];
    NSString *path = [self _readX11StringProperty:windowId atom:"_GTK_APPLICATION_OBJECT_PATH"];
    
    if (!service || !path) {
        NSDebugLLog(@"gwcomp", @"AppMenuImporter: No GTK menu properties found for XID %lu", windowId);
        
        // No menu available
        dispatch_async(dispatch_get_main_queue(), ^{
            NSDictionary *userInfo = @{@"windowId": @(windowId)};
            [[NSNotificationCenter defaultCenter] postNotificationName:@"AppMenuNotAvailable" 
                                                              object:nil 
                                                            userInfo:userInfo];
        });
        return;
    }
    
    NSDebugLLog(@"gwcomp", @"AppMenuImporter: GTK properties found - service: %@, path: %@", service, path);
    [self _importGTKMenusWithService:service path:path forXID:windowId];
}

- (void)_importGTKMenusWithService:(NSString *)service
                              path:(NSString *)path
                            forXID:(unsigned long)windowId
{
    MENU_PROFILE_BEGIN(importGTKMenusWithService);

    NSDebugLLog(@"gwcomp", @"AppMenuImporter: Importing GTK menus from service: %@, path: %@", service, path);
    
    // Start menu tracking (synchronous, but we're already on background queue)
    [self.dbusConnection callMethod:@"Start"
                          onService:service
                         objectPath:path
                          interface:@"org.gtk.Menus"
                          arguments:@[@[]]];
    
    // Fetch initial layout
    NSArray *reply = [self.dbusConnection callMethod:@"GetLayout"
                                            onService:service
                                           objectPath:path
                                            interface:@"org.gtk.Menus"
                                            arguments:@[@(0), @(3), @[]]];
    
    dispatch_async(self->_menuQueue, ^{
        if (windowId != self->_currentXID) {
            NSDebugLLog(@"gwcomp", @"AppMenuImporter: XID %lu became stale during layout fetch", windowId);
            return;
        }
        
        if (!reply) {
            NSDebugLLog(@"gwcomp", @"AppMenuImporter: Failed to get menu layout");
            return;
        }
        
        NSDebugLLog(@"gwcomp", @"AppMenuImporter: Received menu layout, building NSMenu");
        
        // Build NSMenu from GTK layout on main queue
        dispatch_async(dispatch_get_main_queue(), ^{
            NSMenu *menu = [self _buildNSMenuFromGTKLayout:reply];
            
            if (menu) {
                NSDebugLLog(@"gwcomp", @"AppMenuImporter: Menu built successfully with %ld items", [menu numberOfItems]);
                
                // Cache the menu
                self->_menuCache[@(windowId)] = menu;
                
                // Notify that menu is ready
                NSDictionary *userInfo = @{
                    @"windowId": @(windowId),
                    @"menu": menu
                };
                [[NSNotificationCenter defaultCenter] postNotificationName:@"AppMenuReady" 
                                                                  object:nil 
                                                                userInfo:userInfo];
            } else {
                NSDebugLLog(@"gwcomp", @"AppMenuImporter: Failed to build menu from layout");
            }
        });
    });
    
    // Subscribe to layout updates
    [self _subscribeToMenuUpdatesForService:service path:path windowId:windowId];

    MENU_PROFILE_END(importGTKMenusWithService);
}

- (void)_subscribeToMenuUpdatesForService:(NSString *)service
                                     path:(NSString *)path
                                 windowId:(unsigned long)windowId
{
    NSString *subscriptionKey = [NSString stringWithFormat:@"%@:%@", service, path];
    
    // Don't subscribe twice
    if (_subscriptions[subscriptionKey]) {
        NSDebugLLog(@"gwcomp", @"AppMenuImporter: Already subscribed to %@", subscriptionKey);
        return;
    }
    
    NSDebugLLog(@"gwcomp", @"AppMenuImporter: Subscribing to menu updates for %@", subscriptionKey);
    
    // TODO: Implement DBus signal subscription
    // For now, just mark as subscribed
    _subscriptions[subscriptionKey] = @(windowId);
}

- (NSMenu *)_buildNSMenuFromGTKLayout:(NSArray *)layout
{
    MENU_PROFILE_BEGIN(buildNSMenuFromGTKLayout);

    // For now, return a placeholder menu
    // The actual GTK menu parsing is handled by GTKMenuImporter
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Application"];
    [menu setAutoenablesItems:NO];
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"Menu Loading..." action:nil keyEquivalent:@""];
    [item setEnabled:NO];
    [menu addItem:item];
    MENU_PROFILE_END(buildNSMenuFromGTKLayout);
    return menu;
}

- (NSString *)_readX11StringProperty:(unsigned long)windowId atom:(const char *)atomName
{
    if (!_display || windowId == 0) {
        return nil;
    }
    
    Atom atom = XInternAtom(_display, atomName, False);
    Atom actualType;
    int actualFormat;
    unsigned long nItems, bytesAfter;
    unsigned char *prop = NULL;
    
    int result = XGetWindowProperty(_display, (Window)windowId, atom,
                                    0, 1024, False, AnyPropertyType,
                                    &actualType, &actualFormat, &nItems, &bytesAfter, &prop);
    
    if (result == Success && prop && nItems > 0) {
        NSString *value = [NSString stringWithUTF8String:(char *)prop];
        XFree(prop);
        return value;
    }
    
    return nil;
}

- (BOOL)isGNUstepWindow:(unsigned long)windowId
{
    if (!_display || windowId == 0) {
        return NO;
    }
    
    Atom actualType;
    int actualFormat;
    unsigned long nItems, bytesAfter;
    unsigned char *prop = NULL;
    
    int result = XGetWindowProperty(_display, (Window)windowId, _gstepAppAtom,
                                    0, 32, False, AnyPropertyType,
                                    &actualType, &actualFormat, &nItems, &bytesAfter, &prop);
    
    if (result == Success && prop) {
        XFree(prop);
        return YES;
    }
    
    return NO;
}

- (void)importMenuForWindow:(unsigned long)windowId
                 completion:(void(^)(NSMenu *menu, NSError *error))completion
{
    MENU_PROFILE_BEGIN(importMenuForWindow);

    // Check cache first
    NSMenu *cachedMenu = _menuCache[@(windowId)];
    if (cachedMenu) {
        NSDebugLLog(@"gwcomp", @"AppMenuImporter: Returning cached menu for XID %lu", windowId);
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(cachedMenu, nil);
            });
        }
        MENU_PROFILE_END(importMenuForWindow);
        return;
    }
    
    // Import async
    dispatch_async(_menuQueue, ^{
        self->_currentXID = windowId;
        [self _scheduleImportForXID:windowId];
        
        // Wait for import to complete or timeout
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
            dispatch_get_main_queue(),
            ^{
                NSMenu *menu = self->_menuCache[@(windowId)];
                if (completion) {
                    if (menu) {
                        completion(menu, nil);
                    } else {
                        NSError *error = [NSError errorWithDomain:@"AppMenuImporter"
                                                             code:1
                                                         userInfo:@{NSLocalizedDescriptionKey: @"Timeout importing menu"}];
                        completion(nil, error);
                    }
                }
            }
        );
    });

    MENU_PROFILE_END(importMenuForWindow);
}

@end
