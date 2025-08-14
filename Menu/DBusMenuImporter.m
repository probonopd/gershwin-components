#import "DBusMenuImporter.h"
#import "MenuUtils.h"
#import <dbus/dbus.h>

// Forward declare the sendReply method to avoid header issues
@interface GNUDBusConnection (Reply)
- (BOOL)sendReply:(void *)reply;
@end

@implementation DBusMenuImporter

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
    _dbusConnection = [GNUDBusConnection sessionBus];
    if (![_dbusConnection isConnected]) {
        NSLog(@"DBusMenuImporter: Failed to get DBus connection");
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
    
    // Check cache first
    NSMenu *cachedMenu = [_menuCache objectForKey:windowKey];
    if (cachedMenu) {
        NSLog(@"DBusMenuImporter: Returning cached menu for window %lu", windowId);
        return cachedMenu;
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
            
            // Only create test menu for debugging purposes and specific cases
            // Don't show fallback menus for regular applications that don't export menus
            return nil;
        }
    }
    
    NSLog(@"DBusMenuImporter: Loading menu for window %lu from %@%@", windowId, serviceName, objectPath);
    
    // Get the menu layout from DBus
    NSMenu *menu = [self loadMenuFromDBus:serviceName objectPath:objectPath];
    if (menu) {
        [_menuCache setObject:menu forKey:windowKey];
        NSLog(@"DBusMenuImporter: Successfully loaded menu with %lu items", (unsigned long)[[menu itemArray] count]);
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
    // Call GetLayout method on the dbusmenu interface
    NSArray *arguments = [NSArray arrayWithObjects:
                         [NSNumber numberWithInt:0],    // parentId (0 = root)
                         [NSNumber numberWithInt:-1],   // recursionDepth (-1 = full tree)
                         [NSArray array],               // propertyNames (empty = all properties)
                         nil];
    
    id result = [_dbusConnection callMethod:@"GetLayout"
                                  onService:serviceName
                                 objectPath:objectPath
                                  interface:@"com.canonical.dbusmenu"
                                  arguments:arguments];
    
    if (!result) {
        NSLog(@"DBusMenuImporter: Failed to get menu layout from %@%@", serviceName, objectPath);
        return nil;
    }
    
    NSLog(@"DBusMenuImporter: Received menu layout from %@%@", serviceName, objectPath);
    
    // Parse the menu structure and create NSMenu
    // The result should be a structure containing menu items with their properties
    NSMenu *menu = [self parseMenuFromDBusResult:result serviceName:serviceName];
    
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

- (NSMenu *)parseMenuFromDBusResult:(id)result serviceName:(NSString *)serviceName
{
    NSLog(@"DBusMenuImporter: Parsing menu structure from %@", serviceName);
    NSLog(@"DBusMenuImporter: Menu result type: %@", [result class]);
    NSLog(@"DBusMenuImporter: Menu result content: %@", result);
    
    // TODO: Implement proper DBus menu structure parsing
    // The DBus menu format is complex and requires parsing a nested structure
    // For now, we'll return nil to use the fallback menu
    
    return nil;
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
    
    // Clear cached menu for this window
    [_menuCache removeObjectForKey:windowKey];
    
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
}

- (void)unregisterWindow:(unsigned long)windowId
{
    NSNumber *windowKey = [NSNumber numberWithUnsignedLong:windowId];
    
    [_registeredWindows removeObjectForKey:windowKey];
    [_windowMenuPaths removeObjectForKey:windowKey];
    [_menuCache removeObjectForKey:windowKey];
    
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
            
            // Send empty reply for NOREPLY method
            DBusMessage *reply = dbus_message_new_method_return(message);
            if (reply) {
                [_dbusConnection sendReply:reply];
                dbus_message_unref(reply);
            }
        }
    } else if ([method isEqualToString:@"UnregisterWindow"]) {
        if ([arguments count] >= 1) {
            unsigned long windowId = [[arguments objectAtIndex:0] unsignedLongValue];
            
            NSLog(@"DBusMenuImporter: UnregisterWindow called by %@ for window %lu", 
                  serviceName, windowId);
            
            [self unregisterWindow:windowId];
            
            // Send empty reply for NOREPLY method
            DBusMessage *reply = dbus_message_new_method_return(message);
            if (reply) {
                [_dbusConnection sendReply:reply];
                dbus_message_unref(reply);
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
                
                [_dbusConnection sendReply:reply];
                dbus_message_unref(reply);
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
    NSLog(@"DBusMenuImporter: Scanning for existing menu services...");
    
    // Scan all windows for menu properties
    NSArray *allWindows = [MenuUtils getAllWindows];
    int foundMenus = 0;
    
    for (NSNumber *windowIdNum in allWindows) {
        unsigned long windowId = [windowIdNum unsignedLongValue];
        
        // Check if this window has menu properties
        NSString *serviceName = [self getMenuServiceForWindow:windowId];
        NSString *objectPath = [self getMenuObjectPathForWindow:windowId];
        
        if (serviceName && objectPath) {
            NSLog(@"DBusMenuImporter: Found menu service for window %lu: %@ %@", 
                  windowId, serviceName, objectPath);
            
            [self registerWindow:windowId serviceName:serviceName objectPath:objectPath];
            foundMenus++;
        }
    }
    
    NSLog(@"DBusMenuImporter: Menu service scanning completed - found %d windows with menus", foundMenus);
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
