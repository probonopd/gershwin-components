/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */


#import "DBusMenuImporter.h"
#import "DBusMenuParser.h"
#import "DBusMenuActionHandler.h"
#import "DBusSubmenuManager.h"
#import "MenuUtils.h"
#import "AppMenuWidget.h"
#import "MenuProfiler.h"
#import <dbus/dbus.h>
#import <dispatch/dispatch.h>

// Forward declare the sendReply method to avoid header issues
@interface GNUDBusConnection (Reply)
- (BOOL)sendReply:(void *)reply;
@end

@implementation DBusMenuImporter

- (id)init
{
    self = [super init];
    if (self) {
        _windowRegistryLock = [[NSObject alloc] init];  // Create lock for window registry access
        self.dbusConnection = nil;
        self.registeredWindows = [[NSMutableDictionary alloc] init];
        self.windowMenuPaths = [[NSMutableDictionary alloc] init];
        self.menuCache = [[NSMutableDictionary alloc] init];
        self.loadRetries = [[NSMutableDictionary alloc] init];
        self.failedWindows = [[NSMutableDictionary alloc] init];
        self.processingMessages = NO;
        
        // Don't set up the cleanup timer during init - do it later when the run loop is ready
        self.cleanupTimer = nil;
    }
    return self;
}

- (BOOL)connectToDBus
{
    NSDebugLog(@"DBusMenuImporter: Attempting to connect to DBus session bus...");
    self.dbusConnection = [GNUDBusConnection sessionBus];
    
    NSDebugLog(@"DBusMenuImporter: DBus connection object: %@", self.dbusConnection);
    
    if (![self.dbusConnection isConnected]) {
        NSDebugLog(@"DBusMenuImporter: Failed to get DBus connection");
        NSDebugLog(@"DBusMenuImporter: DBus session bus address: %@", 
              [[NSProcessInfo processInfo] environment][@"DBUS_SESSION_BUS_ADDRESS"]);
        
        [self showDBusErrorAndExit];
        return NO;
    }
    
    // DO NOT register service yet - we'll do that after full initialization
    // This prevents other applications from seeing us before we're ready
    NSDebugLog(@"DBusMenuImporter: Connected to DBus - deferring service registration until ready");
    
    return YES;
}

- (BOOL)registerService
{
    if (!self.dbusConnection || ![self.dbusConnection isConnected]) {
        NSDebugLLog(@"gwcomp", @"DBusMenuImporter: Cannot register service - not connected to DBus");
        return NO;
    }
    
    NSDebugLLog(@"gwcomp", @"DBusMenuImporter: Attempting to register AppMenu.Registrar service...");
    // Try to register the AppMenu.Registrar service
    if ([self.dbusConnection registerService:@"com.canonical.AppMenu.Registrar"]) {
        NSDebugLLog(@"gwcomp", @"DBusMenuImporter: ===== Successfully registered as AppMenu.Registrar service =====");
        
        // Register object path for the registrar interface
        if (![self.dbusConnection registerObjectPath:@"/com/canonical/AppMenu/Registrar"
                                       interface:@"com.canonical.AppMenu.Registrar"
                                         handler:self]) {
            NSDebugLLog(@"gwcomp", @"DBusMenuImporter: Failed to register object path");
            return NO;
        }
        
        NSDebugLLog(@"gwcomp", @"DBusMenuImporter: Successfully connected to DBus and registered service");
        
        // Now that we're connected and the run loop is running, set up the cleanup timer
        if (!self.cleanupTimer) {
            NSDebugLLog(@"gwcomp", @"DBusMenuImporter: Setting up cleanup timer...");
            self.cleanupTimer = [NSTimer scheduledTimerWithTimeInterval:30.0
                                                            target:self
                                                          selector:@selector(cleanupStaleEntries:)
                                                          userInfo:nil
                                                           repeats:YES];
            NSDebugLLog(@"gwcomp", @"DBusMenuImporter: Cleanup timer scheduled");
        }
        
        // DO NOT scan for menus here - it causes 15 seconds of blocking!
        // Menus will be discovered on-demand when windows become active
        NSDebugLLog(@"gwcomp", @"DBusMenuImporter: Skipping initial menu scan - menus discovered on-demand");
        return YES;
    } else {
        NSDebugLLog(@"gwcomp", @"DBusMenuImporter: *** Could not register as primary AppMenu.Registrar ***");
        NSDebugLLog(@"gwcomp", @"DBusMenuImporter: Another application is likely providing this service");
        NSDebugLLog(@"gwcomp", @"DBusMenuImporter: Continuing in monitoring mode...");
        
        // Set up cleanup timer for monitoring mode too
        if (!self.cleanupTimer) {
            NSDebugLLog(@"gwcomp", @"DBusMenuImporter: Setting up cleanup timer (monitoring mode)...");
            self.cleanupTimer = [NSTimer scheduledTimerWithTimeInterval:30.0
                                                            target:self
                                                          selector:@selector(cleanupStaleEntries:)
                                                          userInfo:nil
                                                           repeats:YES];
            NSDebugLog(@"DBusMenuImporter: Cleanup timer scheduled (monitoring mode)");
        }
        
        // Even if we can't register as the primary service, we can still monitor
        // and display menus by watching for applications that export menus
        NSDebugLog(@"DBusMenuImporter: About to scan for existing menu services (monitoring mode)...");
        [self scanForExistingMenuServices];
        NSDebugLog(@"DBusMenuImporter: Finished scanning for existing menu services (monitoring mode)");
        return YES; // Return YES to continue operating
    }
}

- (BOOL)hasMenuForWindow:(unsigned long)windowId
{
    NSNumber *windowKey = [NSNumber numberWithUnsignedLong:windowId];

    // TIGHT-LOOP GUARD: Skip windows whose DBus objects have been confirmed missing.
    // Entries expire after 30 seconds to allow eventual retry.
    NSDate *failTime = [self.failedWindows objectForKey:windowKey];
    if (failTime) {
        NSTimeInterval age = -[failTime timeIntervalSinceNow];
        if (age < 30.0) {
            return NO; // Still within suppression window
        }
        // Expired — allow retry
        [self.failedWindows removeObjectForKey:windowKey];
    }

    if ([self.registeredWindows objectForKey:windowKey] != nil) {
        // If we have a stale "unknown" service name from RegisterWindow,
        // try to upgrade it from X11 properties.
        NSString *svc = [self.registeredWindows objectForKey:windowKey];
        if ([svc isEqualToString:@"unknown"]) {
            NSString *x11Service = [MenuUtils getWindowMenuService:windowId];
            NSString *x11Path = [MenuUtils getWindowMenuPath:windowId];
            if (x11Service && x11Path) {
                [self registerWindow:windowId serviceName:x11Service objectPath:x11Path];
            }
        }
        return YES;
    }
    
    // Check X11 properties as fallback - applications might have set them
    // without registering through DBus yet
    NSString *x11Service = [MenuUtils getWindowMenuService:windowId];
    NSString *x11Path = [MenuUtils getWindowMenuPath:windowId];
    
    if (x11Service && x11Path) {
        NSDebugLog(@"DBusMenuImporter: Found X11 properties for window %lu in hasMenu check: service=%@ path=%@", 
              windowId, x11Service, x11Path);
        
        // Register this window with the discovered properties
        [self registerWindow:windowId serviceName:x11Service objectPath:x11Path];
        return YES;
    }
    
    return NO;
}

- (NSMenu *)getMenuForWindow:(unsigned long)windowId
{
    MENU_PROFILE_BEGIN(getMenuForWindow);

    // Early validation - skip only obvious invalid IDs (0). Some toolkits transiently
    // report windows as unmapped during creation, so don't hard-fail on isWindowValid.
    if (windowId == 0) {
        NSDebugLog(@"DBusMenuImporter: Window %lu is invalid (0), skipping menu lookup", windowId);
        MENU_PROFILE_END(getMenuForWindow);
        return nil;
    }
    
    NSNumber *windowKey = [NSNumber numberWithUnsignedLong:windowId];

    // TIGHT-LOOP GUARD: Skip windows whose DBus objects have been confirmed missing.
    NSDate *failTime = [self.failedWindows objectForKey:windowKey];
    if (failTime) {
        NSTimeInterval age = -[failTime timeIntervalSinceNow];
        if (age < 30.0) {
            MENU_PROFILE_END(getMenuForWindow);
            return nil; // Still within suppression window
        }
        [self.failedWindows removeObjectForKey:windowKey];
    }
    
    NSDebugLog(@"DBusMenuImporter: Looking for menu for window %lu", windowId);
    
    // Safely get registration info with minimal lock time
    NSString *serviceName = nil;
    NSString *objectPath = nil;
    NSMenu *legacyCachedMenu = nil;
    
    @synchronized(_windowRegistryLock) {
        NSDebugLog(@"DBusMenuImporter: Currently registered windows: %@", self.registeredWindows);
        NSDebugLog(@"DBusMenuImporter: Window menu paths: %@", self.windowMenuPaths);
        
        // Get copies to work with outside the lock
        NSString *svc = [self.registeredWindows objectForKey:windowKey];
        NSString *path = [self.windowMenuPaths objectForKey:windowKey];
        serviceName = svc ? [svc copy] : nil;
        objectPath = path ? [path copy] : nil;
        legacyCachedMenu = [self.menuCache objectForKey:windowKey];
    }
    
    if (legacyCachedMenu) {
        NSDebugLog(@"DBusMenuImporter: Returning cached menu for window %lu", windowId);
        
        // Re-register shortcuts
        [self reregisterShortcutsForMenu:legacyCachedMenu windowId:windowId];
        
        MENU_PROFILE_END(getMenuForWindow);
        return legacyCachedMenu;
    }
    
    // If we still don't have serviceName/objectPath, check X11 properties as fallback
    // Also override placeholder "unknown" service names that come from the
    // Registrar's RegisterWindow handler when the sender's bus name is unavailable.
    if (!serviceName || !objectPath || [serviceName isEqualToString:@"unknown"]) {
        // Check X11 properties as fallback - applications might have set them
        // without registering through DBus yet, or the DBus registration may
        // have arrived with a placeholder service name.
        NSString *x11Service = [MenuUtils getWindowMenuService:windowId];
        NSString *x11Path = [MenuUtils getWindowMenuPath:windowId];
        
        if (x11Service && x11Path) {
            NSDebugLog(@"DBusMenuImporter: Found X11 properties for window %lu: service=%@ path=%@", 
                  windowId, x11Service, x11Path);
            
            // Register this window with the discovered properties
            [self registerWindow:windowId serviceName:x11Service objectPath:x11Path];
            serviceName = x11Service;
            objectPath = x11Path;
        } else {
            NSDebugLog(@"DBusMenuImporter: No service/path found for window %lu (checked both DBus registry and X11 properties)", windowId);

        }
    }
    
    NSDebugLog(@"DBusMenuImporter: Loading menu for window %lu from %@%@", windowId, serviceName, objectPath);
    
    // Get the menu layout from DBus
    NSMenu *menu = [self loadMenuFromDBusForWindow:windowId serviceName:serviceName objectPath:objectPath];
    if (menu) {
        NSDebugLog(@"DBusMenuImporter: Successfully loaded menu with %lu items", 
              (unsigned long)[[menu itemArray] count]);
    } else {
        NSDebugLog(@"DBusMenuImporter: Failed to load menu for registered window %lu from %@%@", windowId, serviceName, objectPath);
        // Unregister this window since its DBus object is gone (likely the app closed the window)
        NSDebugLog(@"DBusMenuImporter: Unregistering window %lu due to failed menu load", windowId);
        [self unregisterWindow:windowId];
        // TIGHT-LOOP GUARD: Cache this failure to prevent hasMenuForWindow from
        // immediately re-discovering X11 properties and re-registering the window.
        NSNumber *windowKey = [NSNumber numberWithUnsignedLong:windowId];
        [self.failedWindows setObject:[NSDate date] forKey:windowKey];
        NSDebugLLog(@"gwcomp", @"DBusMenuImporter: Cached failure for window %lu (suppressed for 30s)", windowId);
        // For registered windows that fail to load, return nil instead of fallback
        // This indicates the application should handle its own menus
        MENU_PROFILE_END(getMenuForWindow);
        return nil;
    }

    MENU_PROFILE_END(getMenuForWindow);
    return menu;
}

- (NSMenu *)loadMenuFromDBusForWindow:(unsigned long)windowId serviceName:(NSString *)serviceName objectPath:(NSString *)objectPath
{
    MENU_PROFILE_BEGIN(loadMenuFromDBusForWindow);

    // Validate inputs before making DBus calls
    if (!serviceName || [serviceName length] == 0 || !objectPath || [objectPath length] == 0) {
        NSDebugLog(@"DBusMenuImporter: Cannot load menu - invalid service name or object path");
        MENU_PROFILE_END(loadMenuFromDBusForWindow);
        return nil;
    }
    
    if (!self.dbusConnection || ![self.dbusConnection isConnected]) {
        NSDebugLog(@"DBusMenuImporter: Cannot load menu - DBus connection not available");
        MENU_PROFILE_END(loadMenuFromDBusForWindow);
        return nil;
    }
    
    NSDebugLog(@"DBusMenuImporter: Attempting to load menu from service=%@ path=%@", serviceName, objectPath);
    
    id result = nil;
    
    // Wrap DBus calls in try/catch to handle service disappearing mid-call
    @try {
        // First, try to introspect the service to see what interfaces it supports
        id introspectResult = [self.dbusConnection callMethod:@"Introspect"
                                                onService:serviceName
                                               objectPath:objectPath
                                                interface:@"org.freedesktop.DBus.Introspectable"
                                                arguments:nil];
    
        if (introspectResult) {
            NSDebugLog(@"DBusMenuImporter: Service introspection successful");
            if ([introspectResult isKindOfClass:[NSString class]]) {
                NSDebugLog(@"DBusMenuImporter: Introspection XML:\n%@", introspectResult);
            } else {
                NSDebugLog(@"DBusMenuImporter: Introspection result (non-string): %@", introspectResult);
            }
        } else {
            NSDebugLog(@"DBusMenuImporter: Service introspection failed - service may not be available");
        }
    
        // Call GetLayout method on the dbusmenu interface
        // The DBus menu spec requires: GetLayout(parentId: int32, recursionDepth: int32, propertyNames: array of strings)
        NSArray *arguments = [NSArray arrayWithObjects:
                             [NSNumber numberWithInt:0],    // parentId (0 = root)
                             [NSNumber numberWithInt:-1],   // recursionDepth (-1 = full tree)
                             [NSArray array],               // propertyNames (empty = all properties)
                             nil];
    
        NSDebugLog(@"DBusMenuImporter: Calling GetLayout with parentId=0, recursionDepth=-1, propertyNames=[]");
    
        result = [self.dbusConnection callMethod:@"GetLayout"
                                      onService:serviceName
                                     objectPath:objectPath
                                      interface:@"com.canonical.dbusmenu"
                                      arguments:arguments];
    
        if (!result) {
            NSDebugLog(@"DBusMenuImporter: Failed to get menu layout from %@%@ - DBus call failed", serviceName, objectPath);
            NSDebugLog(@"DBusMenuImporter: Application registered for menus but GetLayout call failed");
            NSDebugLog(@"DBusMenuImporter: This may indicate a problem with the application's menu export");

            // Instead of immediately unregistering, allow the application a short time
            // to export the expected interface. Retry a few times with exponential backoff
            // before giving up. This addresses cases where applications set the X11
            // properties early but only export DBus interfaces a short time later.
            NSNumber *windowKey = [NSNumber numberWithUnsignedLong:windowId];
            NSNumber *attemptNum = [self.loadRetries objectForKey:windowKey];
            NSUInteger attempts = attemptNum ? [attemptNum unsignedIntegerValue] : 0;
            const NSUInteger maxAttempts = 5;

            if (attempts < maxAttempts) {
                attempts++;
                [self.loadRetries setObject:[NSNumber numberWithUnsignedInteger:attempts] forKey:windowKey];

                // Exponential backoff: base 0.2s
                NSTimeInterval delay = 0.2 * pow(2, attempts - 1);
                NSDebugLog(@"DBusMenuImporter: Scheduling retry %lu for window %lu in %.2fs", (unsigned long)attempts, windowId, delay);

                NSDictionary *userInfo = @{ @"windowId": windowKey };
                [NSTimer scheduledTimerWithTimeInterval:delay
                                                 target:self
                                               selector:@selector(retryMenuLoad:)
                                               userInfo:userInfo
                                                repeats:NO];
                                MENU_PROFILE_END(loadMenuFromDBusForWindow);
                return nil;
            } else {
                NSDebugLog(@"DBusMenuImporter: Exceeded retries for window %lu - unregistering", windowId);
                // Exceeded retries - unregister this window and stop waiting
                [self unregisterWindow:windowId];
                MENU_PROFILE_END(loadMenuFromDBusForWindow);
                return nil;
            }
        }
    }
    @catch (NSException *exception) {
        NSDebugLog(@"DBusMenuImporter: Exception during DBus menu load from %@%@: %@", serviceName, objectPath, exception);
        MENU_PROFILE_END(loadMenuFromDBusForWindow);
        return nil;
    }
    
    NSDebugLog(@"DBusMenuImporter: Received menu layout from %@%@", serviceName, objectPath);
    NSDebugLog(@"DBusMenuImporter: Raw result object: %@", result);
    NSDebugLog(@"DBusMenuImporter: Raw result class: %@", [result class]);
    NSDebugLog(@"DBusMenuImporter: Raw result description: %@", [result description]);
    
    // Log the result in detail
    if ([result respondsToSelector:@selector(count)]) {
        NSDebugLog(@"DBusMenuImporter: Result has count: %lu", (unsigned long)[result count]);
    }
    if ([result respondsToSelector:@selector(objectAtIndex:)] && [result count] > 0) {
        for (NSUInteger i = 0; i < [result count]; i++) {
            id item = [result objectAtIndex:i];
            NSDebugLog(@"DBusMenuImporter: Result[%lu]: %@ (%@)", i, item, [item class]);
        }
    }
    
    // Parse the menu structure and create NSMenu
    // The result should be a structure containing menu items with their properties
    NSMenu *menu = [DBusMenuParser parseMenuFromDBusResult:result 
                                               serviceName:serviceName 
                                                objectPath:objectPath 
                                            dbusConnection:self.dbusConnection];
    
    if (!menu) {
        // Fallback: create a simple placeholder menu if parsing fails
        NSDebugLog(@"DBusMenuImporter: Failed to parse menu structure, creating placeholder");
        menu = [[NSMenu alloc] initWithTitle:@"App Menu"];
        
        // Add some placeholder menu items
        NSMenuItem *fileItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"File", @"File menu")
                                                          action:nil
                                                   keyEquivalent:@""];
        NSMenuItem *editItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Edit", @"Edit menu")
                                                          action:nil
                                                   keyEquivalent:@""];
        NSMenuItem *viewItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"View", @"View menu")
                                                          action:nil
                                                   keyEquivalent:@""];
        
        [menu addItem:fileItem];
        [menu addItem:editItem];
        [menu addItem:viewItem];
    }

    MENU_PROFILE_END(loadMenuFromDBusForWindow);
    return menu;
}

- (void)activateMenuItem:(NSMenuItem *)menuItem forWindow:(unsigned long)windowId
{
    MENU_PROFILE_BEGIN(activateMenuItem);

    NSDebugLog(@"DBusMenuImporter: Activating menu item '%@' for window %lu", [menuItem title], windowId);
    NSNumber *windowKey = [NSNumber numberWithUnsignedLong:windowId];
    NSString *serviceName = [self.registeredWindows objectForKey:windowKey];
    NSString *objectPath = [self.windowMenuPaths objectForKey:windowKey];

    if (!serviceName || !objectPath) {
        NSDebugLog(@"DBusMenuImporter: No service/path found for window %lu", windowId);
        MENU_PROFILE_END(activateMenuItem);
        return;
    }
    
    // Send Event method call to activate the menu item
    // In a real implementation, we would track menu item IDs from the DBus structure
    NSArray *arguments = [NSArray arrayWithObjects:
                         [NSNumber numberWithInt:0],    // menu item ID (placeholder)
                         @"clicked",                     // event type
                         @"",                           // event data (empty)
                         [NSNumber numberWithUnsignedInt:0], // timestamp
                         nil];
    
    [self.dbusConnection callMethod:@"Event"
                      onService:serviceName
                     objectPath:objectPath
                      interface:@"com.canonical.dbusmenu"
                      arguments:arguments];

    MENU_PROFILE_END(activateMenuItem);
}

- (void)registerWindow:(unsigned long)windowId 
           serviceName:(NSString *)serviceName 
            objectPath:(NSString *)objectPath
{
    NSNumber *windowKey = [NSNumber numberWithUnsignedLong:windowId];
    
    // Clear any previous failure cache — the app has explicitly re-registered
    [self.failedWindows removeObjectForKey:windowKey];

    // Protect dictionary access with lock to prevent races during concurrent access
    @synchronized(_windowRegistryLock) {
        [self.registeredWindows setObject:serviceName forKey:windowKey];
        [self.windowMenuPaths setObject:objectPath forKey:windowKey];
        
        // Clear cached menu for this window in both legacy and enhanced cache
        [self.menuCache removeObjectForKey:windowKey];
    }
    
    // Set X11 properties for Chrome/Firefox compatibility
    // This is the key fix that was missing - these properties tell applications
    // that we support DBus menus and they should export theirs
    if ([objectPath hasPrefix:@"/com/canonical/menu"]) {
        BOOL success = [MenuUtils setWindowMenuService:serviceName 
                                                  path:objectPath 
                                             forWindow:windowId];
        if (success) {
            NSDebugLog(@"DBusMenuImporter: Set X11 properties for Chrome/Firefox compatibility on window %lu", windowId);
        } else {
            NSDebugLog(@"DBusMenuImporter: Failed to set X11 properties for window %lu", windowId);
        }
    }
    
    NSDebugLog(@"DBusMenuImporter: Registered window %lu with service %@ path %@", 
          windowId, serviceName, objectPath);
    
    // Check if this newly registered window is the currently active window
    // and display its menu after a short delay to let the window stabilize.
    // This prevents crashes when windows are opened and closed quickly.
    if (self.appMenuWidget) {
        // Defer menu loading by 150ms to allow window to stabilize
        // Using NSTimer for GNUstep compatibility
        NSDictionary *userInfo = @{@"windowId": [NSNumber numberWithUnsignedLong:windowId]};
        [NSTimer scheduledTimerWithTimeInterval:0.15
                                         target:self
                                       selector:@selector(deferredMenuCheck:)
                                       userInfo:userInfo
                                        repeats:NO];
    } else {
        NSDebugLog(@"DBusMenuImporter: AppMenuWidget not set, cannot check for immediate menu display");
    }
}

// Called after a delay to load menu for a newly registered window
// This delay prevents crashes when windows are closed immediately after opening
- (void)deferredMenuCheck:(NSTimer *)timer
{
    NSDictionary *userInfo = [timer userInfo];
    if (!userInfo) return;
    
    NSNumber *windowIdNum = [userInfo objectForKey:@"windowId"];
    if (!windowIdNum) return;
    
    unsigned long windowId = [windowIdNum unsignedLongValue];
    
    @try {
        // Re-check if window is still registered before loading menu
        NSString *svc = nil;
        @synchronized(_windowRegistryLock) {
            svc = [self.registeredWindows objectForKey:windowIdNum];
        }
        
        if (svc && self.appMenuWidget) {
            NSDebugLog(@"DBusMenuImporter: Deferred menu check for window %lu - window still registered", windowId);
            [self.appMenuWidget checkAndDisplayMenuForNewlyRegisteredWindow:windowId];
        } else if (!svc) {
            NSDebugLog(@"DBusMenuImporter: Window %lu was unregistered before menu could be loaded (closed quickly)", windowId);
        }
    }
    @catch (NSException *exception) {
        NSDebugLog(@"DBusMenuImporter: Exception in deferred menu check for window %lu: %@", windowId, exception);
    }
}

- (void)unregisterWindow:(unsigned long)windowId
{
    NSNumber *windowKey = [NSNumber numberWithUnsignedLong:windowId];
    NSString *serviceName = nil;
    
    @try {
        // Protect dictionary access with lock to prevent crashes when unregistering from background threads
        @synchronized(_windowRegistryLock) {
            // Get the service name before removing to clean up related delegates
            serviceName = [[self.registeredWindows objectForKey:windowKey] copy];
            
            [self.registeredWindows removeObjectForKey:windowKey];
            [self.windowMenuPaths removeObjectForKey:windowKey];
            [self.menuCache removeObjectForKey:windowKey];
            [self.loadRetries removeObjectForKey:windowKey];
        }
        
        // Clean up submenu delegates associated with this service to prevent
        // crashes when trying to use stale DBus connections
        if (serviceName) {
            [DBusSubmenuManager cleanupDelegatesForService:serviceName];
        }
        
        NSDebugLog(@"DBusMenuImporter: Unregistered window %lu", windowId);

        if (self.appMenuWidget && self.appMenuWidget.currentWindowId == windowId) {
            NSDebugLog(@"DBusMenuImporter: Current menu window %lu unregistered - refreshing menu", windowId);
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.appMenuWidget updateForActiveWindow];
            });
        }
    }
    @catch (NSException *exception) {
        NSDebugLog(@"DBusMenuImporter: Exception during unregisterWindow %lu: %@", windowId, exception);
    }
}

- (void)cleanupStaleEntries:(NSTimer *)timer
{
    // In a real implementation, we would check if windows still exist
    // and remove entries for windows that have been closed
    NSDebugLog(@"DBusMenuImporter: Cleanup timer - %lu windows registered", 
          (unsigned long)[self.registeredWindows count]);

    // Expire old failure cache entries (> 30s)
    NSMutableArray *expiredKeys = [NSMutableArray array];
    for (NSNumber *key in self.failedWindows) {
        NSDate *failTime = [self.failedWindows objectForKey:key];
        if (-[failTime timeIntervalSinceNow] > 30.0) {
            [expiredKeys addObject:key];
        }
    }
    if ([expiredKeys count] > 0) {
        [self.failedWindows removeObjectsForKeys:expiredKeys];
        NSDebugLog(@"DBusMenuImporter: Expired %lu failure cache entries", (unsigned long)[expiredKeys count]);
    }
}

// DBus method handlers
- (void)handleDBusMethodCall:(NSDictionary *)callInfo
{
    MENU_PROFILE_BEGIN(handleDBusMethodCall);

    NSString *method = [callInfo objectForKey:@"method"];
    NSString *interface = [callInfo objectForKey:@"interface"];
    DBusMessage *message = (DBusMessage *)[[callInfo objectForKey:@"message"] pointerValue];
    
    NSDebugLog(@"DBusMenuImporter: Handling method call: %@.%@", interface, method);
    
    if (![interface isEqualToString:@"com.canonical.AppMenu.Registrar"]) {
        NSDebugLog(@"DBusMenuImporter: Unknown interface: %@", interface);
        MENU_PROFILE_END(handleDBusMethodCall);
        return;
    }
    
    // Parse arguments from DBus message
    NSMutableArray *arguments = [NSMutableArray array];
    DBusMessageIter iter;
    if (dbus_message_iter_init(message, &iter)) {
        do {
            int argType = dbus_message_iter_get_arg_type(&iter);
            if (argType == DBUS_TYPE_UINT32) {
                dbus_uint32_t value;
                dbus_message_iter_get_basic(&iter, &value);
                [arguments addObject:[NSNumber numberWithUnsignedInt:value]];
            } else if (argType == DBUS_TYPE_OBJECT_PATH || argType == DBUS_TYPE_STRING) {
                char *value;
                dbus_message_iter_get_basic(&iter, &value);
                [arguments addObject:[NSString stringWithUTF8String:value]];
            }
        } while (dbus_message_iter_next(&iter));
    }
    
    // Get calling service name
    const char *sender = dbus_message_get_sender(message);
    NSString *serviceName = sender ? [NSString stringWithUTF8String:sender] : @"unknown";
    
    if ([method isEqualToString:@"RegisterWindow"]) {
        if ([arguments count] >= 2) {
            unsigned long windowId = [[arguments objectAtIndex:0] unsignedLongValue];
            NSString *objectPath = [arguments objectAtIndex:1];
            
            NSDebugLog(@"DBusMenuImporter: RegisterWindow called by %@ for window %lu with path %@", 
                  serviceName, windowId, objectPath);
            
            @try {
                [self registerWindow:windowId serviceName:serviceName objectPath:objectPath];
            }
            @catch (NSException *exception) {
                NSDebugLog(@"DBusMenuImporter: Exception during registerWindow: %@", exception);
            }
            
            // Send empty reply
            DBusMessage *reply = dbus_message_new_method_return(message);
            if (reply) {
                dbus_connection_send([_dbusConnection rawConnection], reply, NULL);
                dbus_connection_flush([_dbusConnection rawConnection]);
                dbus_message_unref(reply);
                NSDebugLog(@"DBusMenuImporter: Sent reply for RegisterWindow");
            } else {
                NSDebugLog(@"DBusMenuImporter: Failed to create reply for RegisterWindow");
            }
        }
    } else if ([method isEqualToString:@"UnregisterWindow"]) {
        if ([arguments count] >= 1) {
            unsigned long windowId = [[arguments objectAtIndex:0] unsignedLongValue];
            
            NSDebugLog(@"DBusMenuImporter: UnregisterWindow called by %@ for window %lu", 
                  serviceName, windowId);
            
            @try {
                [self unregisterWindow:windowId];
            }
            @catch (NSException *exception) {
                NSDebugLog(@"DBusMenuImporter: Exception during unregisterWindow: %@", exception);
            }
            
            // Send empty reply
            DBusMessage *reply = dbus_message_new_method_return(message);
            if (reply) {
                dbus_connection_send([_dbusConnection rawConnection], reply, NULL);
                dbus_connection_flush([_dbusConnection rawConnection]);
                dbus_message_unref(reply);
                NSDebugLog(@"DBusMenuImporter: Sent reply for UnregisterWindow");
            } else {
                NSDebugLog(@"DBusMenuImporter: Failed to create reply for UnregisterWindow");
            }
        }
    } else if ([method isEqualToString:@"GetMenuForWindow"]) {
        if ([arguments count] >= 1) {
            unsigned long windowId = [[arguments objectAtIndex:0] unsignedLongValue];
            NSNumber *windowKey = [NSNumber numberWithUnsignedLong:windowId];
            
            NSString *service = [_registeredWindows objectForKey:windowKey];
            NSString *path = [_windowMenuPaths objectForKey:windowKey];
            
            NSDebugLog(@"DBusMenuImporter: GetMenuForWindow called for window %lu, returning service=%@ path=%@", 
                  windowId, service ? service : @"(none)", path ? path : @"(none)");
            
            // Send reply with service name and object path
            DBusMessage *reply = dbus_message_new_method_return(message);
            if (reply) {
                const char *serviceStr = service ? [service UTF8String] : "";
                const char *pathStr = path ? [path UTF8String] : "/";
                
                dbus_message_append_args(reply, 
                                       DBUS_TYPE_STRING, &serviceStr,
                                       DBUS_TYPE_OBJECT_PATH, &pathStr,
                                       DBUS_TYPE_INVALID);
                
                dbus_connection_send([_dbusConnection rawConnection], reply, NULL);
                dbus_connection_flush([_dbusConnection rawConnection]);
                dbus_message_unref(reply);
                NSDebugLog(@"DBusMenuImporter: Sent reply for GetMenuForWindow");
            } else {
                NSDebugLog(@"DBusMenuImporter: Failed to create reply for GetMenuForWindow");
            }
        }
    } else {
        NSDebugLog(@"DBusMenuImporter: Unknown method: %@", method);
    }

    MENU_PROFILE_END(handleDBusMethodCall);
}

- (void)handleRegisterWindow:(NSArray *)arguments
{
    if ([arguments count] < 2) {
        NSDebugLog(@"DBusMenuImporter: Invalid RegisterWindow arguments");
        return;
    }
    
    unsigned long windowId = [[arguments objectAtIndex:0] unsignedLongValue];
    NSString *objectPath = [arguments objectAtIndex:1];
    
    // Get the calling service name from DBus context
    NSString *serviceName = @"unknown";
    // Try to get the real service from X11 properties — the DBus message's
    // sender field is not passed through to this handler by our current
    // DBus framework, so we fall back to the X11 _KDE_NET_WM_APPMENU_*
    // properties which Chrome sets on its windows.
    NSString *x11Service = [MenuUtils getWindowMenuService:windowId];
    if (x11Service) {
        serviceName = x11Service;
        NSDebugLog(@"DBusMenuImporter: Using X11 property service name '%@' for window %lu", 
              serviceName, windowId);
    } else {
        NSDebugLog(@"DBusMenuImporter: WARNING: No X11 service name for window %lu, using '%@'", 
              windowId, serviceName);
    }
    
    [self registerWindow:windowId serviceName:serviceName objectPath:objectPath];
}

- (void)handleUnregisterWindow:(NSArray *)arguments
{
    if ([arguments count] < 1) {
        NSDebugLog(@"DBusMenuImporter: Invalid UnregisterWindow arguments");
        return;
    }
    
    unsigned long windowId = [[arguments objectAtIndex:0] unsignedLongValue];
    [self unregisterWindow:windowId];
}

- (NSString *)handleGetMenuForWindow:(NSArray *)arguments
{
    if ([arguments count] < 1) {
        NSDebugLog(@"DBusMenuImporter: Invalid GetMenuForWindow arguments");
        return nil;
    }
    
    unsigned long windowId = [[arguments objectAtIndex:0] unsignedLongValue];
    NSNumber *windowKey = [NSNumber numberWithUnsignedLong:windowId];
    
    NSString *serviceName = [_registeredWindows objectForKey:windowKey];
    if (!serviceName) {
        return @"";
    }
    
    return serviceName;
}

- (void)scanForExistingMenuServices
{
    MENU_PROFILE_BEGIN(scanForExistingMenuServices);

    NSDebugLog(@"DBusMenuImporter: scanForExistingMenuServices STARTED");
    
    static int dbusScans = 0;
    dbusScans++;
    
    // Only log occasionally to avoid spam
    if (dbusScans % 20 == 1 || dbusScans <= 2) {
        NSDebugLog(@"DBusMenuImporter: Scanning for existing menu services... (scan #%d)", dbusScans);
    }
    
    // Scan all windows for menu properties
    NSDebugLog(@"DBusMenuImporter: About to get all windows via MenuUtils");
    NSArray *allWindows = [MenuUtils getAllWindows];
    NSDebugLog(@"DBusMenuImporter: Got %lu windows to scan", (unsigned long)[allWindows count]);
    int foundMenus = 0;
    
    for (NSNumber *windowIdNum in allWindows) {
        unsigned long windowId = [windowIdNum unsignedLongValue];
        
        // Check if this window has menu properties
        NSString *serviceName = [self getMenuServiceForWindow:windowId];
        NSString *objectPath = [self getMenuObjectPathForWindow:windowId];
        
        if (serviceName && objectPath) {
            // Only log when we actually find new menus
            NSNumber *windowKey = [NSNumber numberWithUnsignedLong:windowId];
            if (![_registeredWindows objectForKey:windowKey]) {
                NSDebugLog(@"DBusMenuImporter: Found NEW menu service for window %lu: %@ %@", 
                      windowId, serviceName, objectPath);
            }
            
            [self registerWindow:windowId serviceName:serviceName objectPath:objectPath];
            foundMenus++;
        }
    }
    
    NSDebugLog(@"DBusMenuImporter: Finished scanning %lu windows", (unsigned long)[allWindows count]);
    
    // Only log completion on first few scans or when we find menus
    if (dbusScans <= 3 || foundMenus > 0) {
        NSDebugLog(@"DBusMenuImporter: Menu service scanning completed - found %d windows with menus", foundMenus);
    }
    
    NSDebugLog(@"DBusMenuImporter: scanForExistingMenuServices COMPLETED");

    MENU_PROFILE_END(scanForExistingMenuServices);
}

- (NSString *)getMenuServiceForWindow:(unsigned long)windowId
{
    // Get the menu service name from window properties
    return [MenuUtils getWindowProperty:windowId atomName:@"_KDE_NET_WM_APPMENU_SERVICE_NAME"];
}

- (NSString *)getMenuObjectPathForWindow:(unsigned long)windowId
{
    // Get the menu object path from window properties
    return [MenuUtils getWindowProperty:windowId atomName:@"_KDE_NET_WM_APPMENU_OBJECT_PATH"];
}

- (void)retryMenuLoad:(NSTimer *)timer
{
    MENU_PROFILE_BEGIN(retryMenuLoad);

    NSDictionary *userInfo = [timer userInfo];
    if (!userInfo) {
        MENU_PROFILE_END(retryMenuLoad);
        return;
    }

    NSNumber *windowKey = [userInfo objectForKey:@"windowId"];
    if (!windowKey) {
        MENU_PROFILE_END(retryMenuLoad);
        return;
    }

    unsigned long windowId = [windowKey unsignedLongValue];

    // Re-check if window is still registered
    NSString *svc = nil;
    NSString *path = nil;
    @synchronized(_windowRegistryLock) {
        svc = [self.registeredWindows objectForKey:windowKey];
        path = [self.windowMenuPaths objectForKey:windowKey];
    }

    if (!svc || !path) {
        NSDebugLog(@"DBusMenuImporter: Retry for window %@ aborted - registration missing", windowKey);
        [self.loadRetries removeObjectForKey:windowKey];
        MENU_PROFILE_END(retryMenuLoad);
        return;
    }

    // TIGHT-LOOP GUARD: Don't retry if this window is in the failure cache
    if ([self.failedWindows objectForKey:windowKey]) {
        NSDebugLog(@"DBusMenuImporter: Retry for window %@ aborted - in failure cache", windowKey);
        [self.loadRetries removeObjectForKey:windowKey];
        MENU_PROFILE_END(retryMenuLoad);
        return;
    }

    NSDebugLog(@"DBusMenuImporter: Retry load for window %@ calling getMenuForWindow", windowKey);

    // Attempt to get menu again; this will re-schedule retry on failure
    NSMenu *menu = [self getMenuForWindow:windowId];
    if (menu) {
        NSDebugLog(@"DBusMenuImporter: Retry succeeded for window %@ - menu loaded", windowKey);
        [self.loadRetries removeObjectForKey:windowKey];
        // If this window is active, notify the app menu widget to display it
        if (self.appMenuWidget) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.appMenuWidget checkAndDisplayMenuForNewlyRegisteredWindow:windowId];
            });
        }
    }

    MENU_PROFILE_END(retryMenuLoad);
}

- (NSMenu *)createTestMenu
{
    NSDebugLog(@"DBusMenuImporter: Creating test menu for demonstration");
    
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Test App Menu"];
    
    // Add some test menu items
    NSMenuItem *fileItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"File", @"File menu")
                                                      action:nil
                                               keyEquivalent:@""];
    
    NSMenuItem *editItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Edit", @"Edit menu")
                                                      action:nil
                                               keyEquivalent:@""];
    
    NSMenuItem *viewItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"View", @"View menu")
                                                      action:nil
                                               keyEquivalent:@""];
    
    NSMenuItem *helpItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Help", @"Help menu")
                                                      action:nil
                                               keyEquivalent:@""];
    
    [menu addItem:fileItem];
    [menu addItem:editItem];
    [menu addItem:viewItem];
    [menu addItem:helpItem];
    
    // Log the menu titles we're creating
    NSDebugLog(@"DBusMenuImporter: Created test menu with titles: %@, %@, %@, %@", 
          [fileItem title], [editItem title], [viewItem title], [helpItem title]);
    
    return menu;
}

- (int)getDBusFileDescriptor
{
    if (self.dbusConnection) {
        return [self.dbusConnection getFileDescriptor];
    }
    return -1;
}

- (void)processDBusMessages
{
    MENU_PROFILE_BEGIN(processDBusMessages);

    // Always process DBus traffic on the main thread and avoid re-entrancy
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self processDBusMessages];
        });
        MENU_PROFILE_END(processDBusMessages);
        return;
    }

    if (self.processingMessages || !_dbusConnection) {
        MENU_PROFILE_END(processDBusMessages);
        return;
    }

    self.processingMessages = YES;
    [_dbusConnection processMessages];
    self.processingMessages = NO;

    MENU_PROFILE_END(processDBusMessages);
}

- (void)showDBusErrorAndExit
{
    static BOOL logged = NO;
    if (logged) {
        return;
    }
    logged = YES;

    NSDebugLLog(@"gwcomp", @"DBusMenuImporter: DBus session bus unavailable; continuing without DBus and waiting for environment recovery");
    NSDebugLLog(@"gwcomp", @"DBusMenuImporter: This is non-fatal to avoid supervisor restart loops");
}

- (void)reregisterShortcutsForMenu:(NSMenu *)menu windowId:(unsigned long)windowId
{
    if (!menu) {
        return;
    }
    
    NSNumber *windowKey = [NSNumber numberWithUnsignedLong:windowId];
    NSString *serviceName = [self.registeredWindows objectForKey:windowKey];
    NSString *objectPath = [self.windowMenuPaths objectForKey:windowKey];
    
    if (!serviceName || !objectPath) {
        NSDebugLog(@"DBusMenuImporter: Cannot re-register shortcuts - missing service/object path");
        return;
    }
    
    NSDebugLog(@"DBusMenuImporter: Re-registering shortcuts for DBus menu (window %lu)", windowId);
    [self reregisterShortcutsForMenuItems:[menu itemArray] serviceName:serviceName objectPath:objectPath];
}

- (void)reregisterShortcutsForMenuItems:(NSArray *)items serviceName:(NSString *)serviceName objectPath:(NSString *)objectPath
{
    for (NSMenuItem *item in items) {
        // Check if this item has a shortcut
        NSString *keyEquivalent = [item keyEquivalent];
        if (keyEquivalent && [keyEquivalent length] > 0) {
            NSUInteger modifierMask = [item keyEquivalentModifierMask];
            
            // Apply the same filtering as DBusMenuActionHandler
            BOOL hasShiftOnly = (modifierMask == NSShiftKeyMask);
            BOOL hasNoModifiers = (modifierMask == 0);
            
            if (!hasNoModifiers && !hasShiftOnly) {
                NSDebugLog(@"DBusMenuImporter: Re-registering DBus shortcut: %@", [item title]);
                
                // Re-register through DBusMenuActionHandler
                [DBusMenuActionHandler setupActionForMenuItem:item
                                                   serviceName:serviceName
                                                    objectPath:objectPath
                                                dbusConnection:_dbusConnection];
            }
        }
        
        // Process submenus recursively
        if ([item hasSubmenu]) {
            [self reregisterShortcutsForMenuItems:[[item submenu] itemArray] 
                                      serviceName:serviceName 
                                       objectPath:objectPath];
        }
    }
}

@end
