#import "DBusMenuImporter.h"
#import "DBusMenuParser.h"
#import "DBusMenuActionHandler.h"
#import "MenuUtils.h"
#import "AppMenuWidget.h"
#import "MenuCacheManager.h"
#import <dbus/dbus.h>

// Forward declare the sendReply method to avoid header issues
@interface GNUDBusConnection (Reply)
- (BOOL)sendReply:(void *)reply;
@end

@implementation DBusMenuImporter

@synthesize appMenuWidget = _appMenuWidget;

- (id)init
{
    self = [super init];
    if (self) {
        _dbusConnection = nil;
        _registeredWindows = [[NSMutableDictionary alloc] init];
        _windowMenuPaths = [[NSMutableDictionary alloc] init];
        _menuCache = [[NSMutableDictionary alloc] init];
        
        // Set up cleanup timer to remove stale entries
        _cleanupTimer = [NSTimer scheduledTimerWithTimeInterval:30.0
                                                        target:self
                                                      selector:@selector(cleanupStaleEntries:)
                                                      userInfo:nil
                                                       repeats:YES];
    }
    return self;
}

- (BOOL)connectToDBus
{
    NSLog(@"DBusMenuImporter: Attempting to connect to DBus session bus...");
    _dbusConnection = [GNUDBusConnection sessionBus];
    
    NSLog(@"DBusMenuImporter: DBus connection object: %@", _dbusConnection);
    
    if (![_dbusConnection isConnected]) {
        NSLog(@"DBusMenuImporter: Failed to get DBus connection");
        NSLog(@"DBusMenuImporter: DBus session bus address: %@", 
              [[NSProcessInfo processInfo] environment][@"DBUS_SESSION_BUS_ADDRESS"]);
        
        [self showDBusErrorAndExit];
        return NO;
    }
    
    // Try to register the AppMenu.Registrar service
    if ([_dbusConnection registerService:@"com.canonical.AppMenu.Registrar"]) {
        NSLog(@"DBusMenuImporter: Successfully registered as AppMenu.Registrar service");
        
        // Register object path for the registrar interface
        if (![_dbusConnection registerObjectPath:@"/com/canonical/AppMenu/Registrar"
                                       interface:@"com.canonical.AppMenu.Registrar"
                                         handler:self]) {
            NSLog(@"DBusMenuImporter: Failed to register object path");
            return NO;
        }
        
        NSLog(@"DBusMenuImporter: Successfully connected to DBus and registered service");
        [self scanForExistingMenuServices];
        return YES;
    } else {
        NSLog(@"DBusMenuImporter: Could not register as primary AppMenu.Registrar");
        NSLog(@"DBusMenuImporter: Another application is likely providing this service");
        NSLog(@"DBusMenuImporter: Continuing in monitoring mode...");
        
        // Even if we can't register as the primary service, we can still monitor
        // and display menus by watching for applications that export menus
        [self scanForExistingMenuServices];
        return YES; // Return YES to continue operating
    }
}

- (BOOL)hasMenuForWindow:(unsigned long)windowId
{
    NSNumber *windowKey = [NSNumber numberWithUnsignedLong:windowId];
    return [_registeredWindows objectForKey:windowKey] != nil;
}

- (NSMenu *)getMenuForWindow:(unsigned long)windowId
{
    NSNumber *windowKey = [NSNumber numberWithUnsignedLong:windowId];
    
    NSLog(@"DBusMenuImporter: Looking for menu for window %lu", windowId);
    NSLog(@"DBusMenuImporter: Currently registered windows: %@", _registeredWindows);
    NSLog(@"DBusMenuImporter: Window menu paths: %@", _windowMenuPaths);
    
    // Check enhanced cache first
    MenuCacheManager *cacheManager = [MenuCacheManager sharedManager];
    NSMenu *cachedMenu = [cacheManager getCachedMenuForWindow:windowId];
    if (cachedMenu) {
        NSLog(@"DBusMenuImporter: Returning enhanced cached menu for window %lu - re-registering shortcuts", windowId);
        
        // Re-register shortcuts for cached menu since they may have been unregistered
        // when the window lost focus
        [self reregisterShortcutsForMenu:cachedMenu windowId:windowId];
        
        // Notify cache manager that window became active
        [cacheManager windowBecameActive:windowId];
        
        return cachedMenu;
    }
    
    // Fall back to legacy cache check for backward compatibility
    NSMenu *legacyCachedMenu = [_menuCache objectForKey:windowKey];
    if (legacyCachedMenu) {
        NSLog(@"DBusMenuImporter: Found menu in legacy cache, migrating to enhanced cache");
        
        // Get application name for this window
        NSString *appName = [MenuUtils getApplicationNameForWindow:windowId];
        NSString *serviceName = [_registeredWindows objectForKey:windowKey];
        NSString *objectPath = [_windowMenuPaths objectForKey:windowKey];
        
        // Migrate to enhanced cache
        [cacheManager cacheMenu:legacyCachedMenu
                      forWindow:windowId
                    serviceName:serviceName
                     objectPath:objectPath
                applicationName:appName];
        
        // Remove from legacy cache
        [_menuCache removeObjectForKey:windowKey];
        
        // Re-register shortcuts
        [self reregisterShortcutsForMenu:legacyCachedMenu windowId:windowId];
        
        return legacyCachedMenu;
    }
    
    NSString *serviceName = [_registeredWindows objectForKey:windowKey];
    NSString *objectPath = [_windowMenuPaths objectForKey:windowKey];
    
    if (!serviceName || !objectPath) {
        // Check X11 properties as fallback - applications might have set them
        // without registering through DBus yet
        NSString *x11Service = [MenuUtils getWindowMenuService:windowId];
        NSString *x11Path = [MenuUtils getWindowMenuPath:windowId];
        
        if (x11Service && x11Path) {
            NSLog(@"DBusMenuImporter: Found X11 properties for window %lu: service=%@ path=%@", 
                  windowId, x11Service, x11Path);
            
            // Register this window with the discovered properties
            [self registerWindow:windowId serviceName:x11Service objectPath:x11Path];
            serviceName = x11Service;
            objectPath = x11Path;
        } else {
            NSLog(@"DBusMenuImporter: No service/path found for window %lu (checked both DBus registry and X11 properties)", windowId);

        }
    }
    
    NSLog(@"DBusMenuImporter: Loading menu for window %lu from %@%@", windowId, serviceName, objectPath);
    
    // Get the menu layout from DBus
    NSMenu *menu = [self loadMenuFromDBus:serviceName objectPath:objectPath];
    if (menu) {
        // Get application name for enhanced caching
        NSString *appName = [MenuUtils getApplicationNameForWindow:windowId];
        
        // Cache in enhanced cache manager
        [cacheManager cacheMenu:menu
                      forWindow:windowId
                    serviceName:serviceName
                     objectPath:objectPath
                applicationName:appName];
        
        NSLog(@"DBusMenuImporter: Successfully loaded and cached menu with %lu items", 
              (unsigned long)[[menu itemArray] count]);
    } else {
        NSLog(@"DBusMenuImporter: Failed to load menu for registered window %lu from %@%@", windowId, serviceName, objectPath);
        // For registered windows that fail to load, return nil instead of fallback
        // This indicates the application should handle its own menus
        return nil;
    }
    
    return menu;
}

- (NSMenu *)loadMenuFromDBus:(NSString *)serviceName objectPath:(NSString *)objectPath
{
    NSLog(@"DBusMenuImporter: Attempting to load menu from service=%@ path=%@", serviceName, objectPath);
    
    // First, try to introspect the service to see what interfaces it supports
    id introspectResult = [_dbusConnection callMethod:@"Introspect"
                                            onService:serviceName
                                           objectPath:objectPath
                                            interface:@"org.freedesktop.DBus.Introspectable"
                                            arguments:nil];
    
    if (introspectResult) {
        NSLog(@"DBusMenuImporter: Service introspection successful");
    } else {
        NSLog(@"DBusMenuImporter: Service introspection failed - service may not be available");
    }
    
    // Call GetLayout method on the dbusmenu interface
    // The DBus menu spec requires: GetLayout(parentId: int32, recursionDepth: int32, propertyNames: array of strings)
    NSArray *arguments = [NSArray arrayWithObjects:
                         [NSNumber numberWithInt:0],    // parentId (0 = root)
                         [NSNumber numberWithInt:-1],   // recursionDepth (-1 = full tree)
                         [NSArray array],               // propertyNames (empty = all properties)
                         nil];
    
    NSLog(@"DBusMenuImporter: Calling GetLayout with parentId=0, recursionDepth=-1, propertyNames=[]");
    
    id result = [_dbusConnection callMethod:@"GetLayout"
                                  onService:serviceName
                                 objectPath:objectPath
                                  interface:@"com.canonical.dbusmenu"
                                  arguments:arguments];
    
    if (!result) {
        NSLog(@"DBusMenuImporter: Failed to get menu layout from %@%@ - DBus call failed", serviceName, objectPath);
        NSLog(@"DBusMenuImporter: Application registered for menus but GetLayout call failed");
        NSLog(@"DBusMenuImporter: This may indicate a problem with the application's menu export");
        return nil;
    }
    
    NSLog(@"DBusMenuImporter: Received menu layout from %@%@", serviceName, objectPath);
    NSLog(@"DBusMenuImporter: Raw result object: %@", result);
    NSLog(@"DBusMenuImporter: Raw result class: %@", [result class]);
    NSLog(@"DBusMenuImporter: Raw result description: %@", [result description]);
    
    // Log the result in detail
    if ([result respondsToSelector:@selector(count)]) {
        NSLog(@"DBusMenuImporter: Result has count: %lu", (unsigned long)[result count]);
    }
    if ([result respondsToSelector:@selector(objectAtIndex:)] && [result count] > 0) {
        for (NSUInteger i = 0; i < [result count]; i++) {
            id item = [result objectAtIndex:i];
            NSLog(@"DBusMenuImporter: Result[%lu]: %@ (%@)", i, item, [item class]);
        }
    }
    
    // Parse the menu structure and create NSMenu
    // The result should be a structure containing menu items with their properties
    NSMenu *menu = [DBusMenuParser parseMenuFromDBusResult:result 
                                               serviceName:serviceName 
                                                objectPath:objectPath 
                                            dbusConnection:_dbusConnection];
    
    if (!menu) {
        // Fallback: create a simple placeholder menu if parsing fails
        NSLog(@"DBusMenuImporter: Failed to parse menu structure, creating placeholder");
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
        
        [fileItem release];
        [editItem release];
        [viewItem release];
    }
    
    return [menu autorelease];
}

- (void)activateMenuItem:(NSMenuItem *)menuItem forWindow:(unsigned long)windowId
{
    NSLog(@"DBusMenuImporter: Activating menu item '%@' for window %lu", [menuItem title], windowId);
    
    NSNumber *windowKey = [NSNumber numberWithUnsignedLong:windowId];
    NSString *serviceName = [_registeredWindows objectForKey:windowKey];
    NSString *objectPath = [_windowMenuPaths objectForKey:windowKey];
    
    if (!serviceName || !objectPath) {
        NSLog(@"DBusMenuImporter: No service/path found for window %lu", windowId);
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
    
    [_dbusConnection callMethod:@"Event"
                      onService:serviceName
                     objectPath:objectPath
                      interface:@"com.canonical.dbusmenu"
                      arguments:arguments];
}

- (void)registerWindow:(unsigned long)windowId 
           serviceName:(NSString *)serviceName 
            objectPath:(NSString *)objectPath
{
    NSNumber *windowKey = [NSNumber numberWithUnsignedLong:windowId];
    
    [_registeredWindows setObject:serviceName forKey:windowKey];
    [_windowMenuPaths setObject:objectPath forKey:windowKey];
    
    // Clear cached menu for this window in both legacy and enhanced cache
    [_menuCache removeObjectForKey:windowKey];
    [[MenuCacheManager sharedManager] invalidateCacheForWindow:windowId];
    
    // Set X11 properties for Chrome/Firefox compatibility
    // This is the key fix that was missing - these properties tell applications
    // that we support DBus menus and they should export theirs
    if ([objectPath hasPrefix:@"/com/canonical/menu"]) {
        BOOL success = [MenuUtils setWindowMenuService:serviceName 
                                                  path:objectPath 
                                             forWindow:windowId];
        if (success) {
            NSLog(@"DBusMenuImporter: Set X11 properties for Chrome/Firefox compatibility on window %lu", windowId);
        } else {
            NSLog(@"DBusMenuImporter: Failed to set X11 properties for window %lu", windowId);
        }
    }
    
    NSLog(@"DBusMenuImporter: Registered window %lu with service %@ path %@", 
          windowId, serviceName, objectPath);
    
    // Check if this newly registered window is the currently active window
    // and display its menu immediately if so
    if (_appMenuWidget) {
        [_appMenuWidget checkAndDisplayMenuForNewlyRegisteredWindow:windowId];
    } else {
        NSLog(@"DBusMenuImporter: AppMenuWidget not set, cannot check for immediate menu display");
    }
}

- (void)unregisterWindow:(unsigned long)windowId
{
    NSNumber *windowKey = [NSNumber numberWithUnsignedLong:windowId];
    
    [_registeredWindows removeObjectForKey:windowKey];
    [_windowMenuPaths removeObjectForKey:windowKey];
    [_menuCache removeObjectForKey:windowKey];
    [[MenuCacheManager sharedManager] invalidateCacheForWindow:windowId];
    
    NSLog(@"DBusMenuImporter: Unregistered window %lu", windowId);
}

- (void)cleanupStaleEntries:(NSTimer *)timer
{
    // In a real implementation, we would check if windows still exist
    // and remove entries for windows that have been closed
    NSLog(@"DBusMenuImporter: Cleanup timer - %lu windows registered", 
          (unsigned long)[_registeredWindows count]);
}

// DBus method handlers
- (void)handleDBusMethodCall:(NSDictionary *)callInfo
{
    NSString *method = [callInfo objectForKey:@"method"];
    NSString *interface = [callInfo objectForKey:@"interface"];
    DBusMessage *message = (DBusMessage *)[[callInfo objectForKey:@"message"] pointerValue];
    
    NSLog(@"DBusMenuImporter: Handling method call: %@.%@", interface, method);
    
    if (![interface isEqualToString:@"com.canonical.AppMenu.Registrar"]) {
        NSLog(@"DBusMenuImporter: Unknown interface: %@", interface);
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
            
            NSLog(@"DBusMenuImporter: RegisterWindow called by %@ for window %lu with path %@", 
                  serviceName, windowId, objectPath);
            
            [self registerWindow:windowId serviceName:serviceName objectPath:objectPath];
            
            // Send empty reply
            DBusMessage *reply = dbus_message_new_method_return(message);
            if (reply) {
                dbus_connection_send([_dbusConnection rawConnection], reply, NULL);
                dbus_connection_flush([_dbusConnection rawConnection]);
                dbus_message_unref(reply);
                NSLog(@"DBusMenuImporter: Sent reply for RegisterWindow");
            } else {
                NSLog(@"DBusMenuImporter: Failed to create reply for RegisterWindow");
            }
        }
    } else if ([method isEqualToString:@"UnregisterWindow"]) {
        if ([arguments count] >= 1) {
            unsigned long windowId = [[arguments objectAtIndex:0] unsignedLongValue];
            
            NSLog(@"DBusMenuImporter: UnregisterWindow called by %@ for window %lu", 
                  serviceName, windowId);
            
            [self unregisterWindow:windowId];
            
            // Send empty reply
            DBusMessage *reply = dbus_message_new_method_return(message);
            if (reply) {
                dbus_connection_send([_dbusConnection rawConnection], reply, NULL);
                dbus_connection_flush([_dbusConnection rawConnection]);
                dbus_message_unref(reply);
                NSLog(@"DBusMenuImporter: Sent reply for UnregisterWindow");
            } else {
                NSLog(@"DBusMenuImporter: Failed to create reply for UnregisterWindow");
            }
        }
    } else if ([method isEqualToString:@"GetMenuForWindow"]) {
        if ([arguments count] >= 1) {
            unsigned long windowId = [[arguments objectAtIndex:0] unsignedLongValue];
            NSNumber *windowKey = [NSNumber numberWithUnsignedLong:windowId];
            
            NSString *service = [_registeredWindows objectForKey:windowKey];
            NSString *path = [_windowMenuPaths objectForKey:windowKey];
            
            NSLog(@"DBusMenuImporter: GetMenuForWindow called for window %lu, returning service=%@ path=%@", 
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
                NSLog(@"DBusMenuImporter: Sent reply for GetMenuForWindow");
            } else {
                NSLog(@"DBusMenuImporter: Failed to create reply for GetMenuForWindow");
            }
        }
    } else {
        NSLog(@"DBusMenuImporter: Unknown method: %@", method);
    }
}

- (void)handleRegisterWindow:(NSArray *)arguments
{
    if ([arguments count] < 2) {
        NSLog(@"DBusMenuImporter: Invalid RegisterWindow arguments");
        return;
    }
    
    unsigned long windowId = [[arguments objectAtIndex:0] unsignedLongValue];
    NSString *objectPath = [arguments objectAtIndex:1];
    
    // Get the calling service name from DBus context
    NSString *serviceName = @"unknown"; // In a real implementation, get from DBus message
    
    [self registerWindow:windowId serviceName:serviceName objectPath:objectPath];
}

- (void)handleUnregisterWindow:(NSArray *)arguments
{
    if ([arguments count] < 1) {
        NSLog(@"DBusMenuImporter: Invalid UnregisterWindow arguments");
        return;
    }
    
    unsigned long windowId = [[arguments objectAtIndex:0] unsignedLongValue];
    [self unregisterWindow:windowId];
}

- (NSString *)handleGetMenuForWindow:(NSArray *)arguments
{
    if ([arguments count] < 1) {
        NSLog(@"DBusMenuImporter: Invalid GetMenuForWindow arguments");
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
    static int dbusScans = 0;
    dbusScans++;
    
    // Only log occasionally to avoid spam
    if (dbusScans % 20 == 1 || dbusScans <= 2) {
        NSLog(@"DBusMenuImporter: Scanning for existing menu services... (scan #%d)", dbusScans);
    }
    
    // Scan all windows for menu properties
    NSArray *allWindows = [MenuUtils getAllWindows];
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
                NSLog(@"DBusMenuImporter: Found NEW menu service for window %lu: %@ %@", 
                      windowId, serviceName, objectPath);
            }
            
            [self registerWindow:windowId serviceName:serviceName objectPath:objectPath];
            foundMenus++;
        }
    }
    
    // Only log completion on first few scans or when we find menus
    if (dbusScans <= 3 || foundMenus > 0) {
        NSLog(@"DBusMenuImporter: Menu service scanning completed - found %d windows with menus", foundMenus);
    }
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

- (NSMenu *)createTestMenu
{
    NSLog(@"DBusMenuImporter: Creating test menu for demonstration");
    
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
    NSLog(@"DBusMenuImporter: Created test menu with titles: %@, %@, %@, %@", 
          [fileItem title], [editItem title], [viewItem title], [helpItem title]);
    
    [fileItem release];
    [editItem release];
    [viewItem release];
    [helpItem release];
    
    return [menu autorelease];
}

- (int)getDBusFileDescriptor
{
    if (_dbusConnection) {
        return [_dbusConnection getFileDescriptor];
    }
    return -1;
}

- (void)processDBusMessages
{
    if (_dbusConnection) {
        [_dbusConnection processMessages];
    }
}

- (void)showDBusErrorAndExit
{
    NSLog(@"DBusMenuImporter: Showing error alert...");
    
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:NSLocalizedString(@"DBus Connection Error", @"DBus error dialog title")];
    [alert setInformativeText:NSLocalizedString(@"Failed to connect to DBus session bus. The global menu service cannot function without DBus.", @"DBus error dialog message")];
    [alert addButtonWithTitle:NSLocalizedString(@"OK", @"OK button")];
    [alert setAlertStyle:NSCriticalAlertStyle];
    
    NSLog(@"DBusMenuImporter: Running modal alert...");
    [alert runModal];
    [alert release];
    
    NSLog(@"DBusMenuImporter: Alert dismissed, exiting application...");
    exit(1);
}

- (void)reregisterShortcutsForMenu:(NSMenu *)menu windowId:(unsigned long)windowId
{
    if (!menu) {
        return;
    }
    
    NSNumber *windowKey = [NSNumber numberWithUnsignedLong:windowId];
    NSString *serviceName = [_registeredWindows objectForKey:windowKey];
    NSString *objectPath = [_windowMenuPaths objectForKey:windowKey];
    
    if (!serviceName || !objectPath) {
        NSLog(@"DBusMenuImporter: Cannot re-register shortcuts - missing service/object path");
        return;
    }
    
    NSLog(@"DBusMenuImporter: Re-registering shortcuts for DBus menu (window %lu)", windowId);
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
                NSLog(@"DBusMenuImporter: Re-registering DBus shortcut: %@", [item title]);
                
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

- (void)dealloc
{
    [_cleanupTimer invalidate];
    [_cleanupTimer release];
    [_registeredWindows release];
    [_windowMenuPaths release];
    [_menuCache release];
    [super dealloc];
}

@end
