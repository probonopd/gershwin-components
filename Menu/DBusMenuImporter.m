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
    NSLog(@"DBusMenuImporter: Attempting to connect to DBus session bus...");
    _dbusConnection = [GNUDBusConnection sessionBus];
    
    NSLog(@"DBusMenuImporter: DBus connection object: %@", _dbusConnection);
    
    if (![_dbusConnection isConnected]) {
        NSLog(@"DBusMenuImporter: Failed to get DBus connection");
        NSLog(@"DBusMenuImporter: DBus session bus address: %@", 
              [[NSProcessInfo processInfo] environment][@"DBUS_SESSION_BUS_ADDRESS"]);
        
        // Show alert and exit the application
        NSLog(@"DBusMenuImporter: Showing error alert...");
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:NSLocalizedString(@"DBus Connection Failed", @"DBus connection error title")];
        [alert setInformativeText:NSLocalizedString(@"Could not connect to the DBus session bus. The global menu service requires DBus to be running.\n\nThe application will now exit.", @"DBus connection error message")];
        [alert setAlertStyle:NSCriticalAlertStyle];
        [alert addButtonWithTitle:NSLocalizedString(@"OK", @"OK button")];
        
        NSLog(@"DBusMenuImporter: Running modal alert...");
        [alert runModal];
        [alert release];
        NSLog(@"DBusMenuImporter: Alert dismissed, terminating application...");
        
        // Terminate the application gracefully
        [[NSApplication sharedApplication] terminate:nil];
        
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
    NSLog(@"DBusMenuImporter: ===== PARSING MENU STRUCTURE =====");
    NSLog(@"DBusMenuImporter: Parsing menu structure from service: %@", serviceName);
    NSLog(@"DBusMenuImporter: Menu result type: %@", [result class]);
    NSLog(@"DBusMenuImporter: Menu result object: %@", result);
    NSLog(@"DBusMenuImporter: Menu result description: %@", [result description]);
    
    // Check if result is a number (error case)
    if ([result isKindOfClass:[NSNumber class]]) {
        NSLog(@"DBusMenuImporter: ERROR: Received NSNumber instead of array structure!");
        NSLog(@"DBusMenuImporter: This suggests the DBus method call failed or returned an error code");
        NSLog(@"DBusMenuImporter: Number value: %@", result);
        return nil;
    }
    
    if (![result isKindOfClass:[NSArray class]]) {
        NSLog(@"DBusMenuImporter: ERROR: Expected array result, got %@", [result class]);
        NSLog(@"DBusMenuImporter: Raw object details:");
        NSLog(@"DBusMenuImporter:   - Class: %@", [result class]);
        NSLog(@"DBusMenuImporter:   - Superclass: %@", [[result class] superclass]);
        NSLog(@"DBusMenuImporter:   - Description: %@", [result description]);
        if ([result respondsToSelector:@selector(stringValue)]) {
            NSLog(@"DBusMenuImporter:   - String value: %@", [result stringValue]);
        }
        return nil;
    }
    
    NSArray *resultArray = (NSArray *)result;
    NSLog(@"DBusMenuImporter: Result array has %lu elements", (unsigned long)[resultArray count]);
    
    if ([resultArray count] < 2) {
        NSLog(@"DBusMenuImporter: ERROR: GetLayout result should have at least 2 elements (revision + layout)");
        NSLog(@"DBusMenuImporter: Actual count: %lu", (unsigned long)[resultArray count]);
        for (NSUInteger i = 0; i < [resultArray count]; i++) {
            id item = [resultArray objectAtIndex:i];
            NSLog(@"DBusMenuImporter: Element[%lu]: %@ (%@)", i, item, [item class]);
        }
        return nil;
    }
    
    // First element is revision number (uint32)
    NSNumber *revision = [resultArray objectAtIndex:0];
    NSLog(@"DBusMenuImporter: Menu revision: %@ (class: %@)", revision, [revision class]);
    
    // Second element is the layout item structure: (ia{sv}av)
    id layoutItem = [resultArray objectAtIndex:1];
    NSLog(@"DBusMenuImporter: Layout item type: %@", [layoutItem class]);
    NSLog(@"DBusMenuImporter: Layout item content: %@", layoutItem);
    NSLog(@"DBusMenuImporter: Layout item description: %@", [layoutItem description]);
    
    NSMenu *menu = [self parseLayoutItem:layoutItem isRoot:YES];
    if (menu) {
        NSLog(@"DBusMenuImporter: ===== MENU PARSING SUCCESS =====");
        NSLog(@"DBusMenuImporter: Successfully parsed menu with %lu items", 
              (unsigned long)[[menu itemArray] count]);
        
        // Log each menu item
        NSArray *items = [menu itemArray];
        for (NSUInteger i = 0; i < [items count]; i++) {
            NSMenuItem *item = [items objectAtIndex:i];
            NSLog(@"DBusMenuImporter: Menu[%lu]: '%@' (enabled: %@, hasSubmenu: %@)", 
                  i, [item title], [item isEnabled] ? @"YES" : @"NO", 
                  [item hasSubmenu] ? @"YES" : @"NO");
        }
    } else {
        NSLog(@"DBusMenuImporter: ===== MENU PARSING FAILED =====");
        NSLog(@"DBusMenuImporter: Failed to parse layout item");
    }
    
    return menu;
}

- (NSMenu *)parseLayoutItem:(id)layoutItem isRoot:(BOOL)isRoot
{
    NSLog(@"DBusMenuImporter: ===== PARSING LAYOUT ITEM (isRoot=%@) =====", isRoot ? @"YES" : @"NO");
    NSLog(@"DBusMenuImporter: Layout item class: %@", [layoutItem class]);
    NSLog(@"DBusMenuImporter: Layout item object: %@", layoutItem);
    
    if (![layoutItem isKindOfClass:[NSArray class]]) {
        NSLog(@"DBusMenuImporter: ERROR: Layout item should be an array, got %@", [layoutItem class]);
        return nil;
    }
    
    NSArray *itemArray = (NSArray *)layoutItem;
    NSLog(@"DBusMenuImporter: Layout item array has %lu elements", (unsigned long)[itemArray count]);
    
    if ([itemArray count] < 3) {
        NSLog(@"DBusMenuImporter: ERROR: Layout item should have at least 3 elements (id, properties, children)");
        NSLog(@"DBusMenuImporter: Actual count: %lu", (unsigned long)[itemArray count]);
        for (NSUInteger i = 0; i < [itemArray count]; i++) {
            id element = [itemArray objectAtIndex:i];
            NSLog(@"DBusMenuImporter: Element[%lu]: %@ (%@)", i, element, [element class]);
        }
        return nil;
    }
    
    // Extract the layout item components: (ia{sv}av)
    NSNumber *itemId = [itemArray objectAtIndex:0];
    id propertiesObj = [itemArray objectAtIndex:1];
    id childrenObj = [itemArray objectAtIndex:2];
    
    NSLog(@"DBusMenuImporter: Item ID: %@ (class: %@)", itemId, [itemId class]);
    NSLog(@"DBusMenuImporter: Properties object: %@ (class: %@)", propertiesObj, [propertiesObj class]);
    NSLog(@"DBusMenuImporter: Children object: %@ (class: %@)", childrenObj, [childrenObj class]);
    
    // Convert properties to dictionary if needed
    NSDictionary *properties = nil;
    if ([propertiesObj isKindOfClass:[NSDictionary class]]) {
        properties = (NSDictionary *)propertiesObj;
    } else {
        NSLog(@"DBusMenuImporter: WARNING: Properties is not a dictionary, creating empty one");
        properties = [NSDictionary dictionary];
    }
    
    // Convert children to array if needed
    NSArray *children = nil;
    if ([childrenObj isKindOfClass:[NSArray class]]) {
        children = (NSArray *)childrenObj;
    } else {
        NSLog(@"DBusMenuImporter: WARNING: Children is not an array, creating empty one");
        children = [NSArray array];
    }
    
    NSLog(@"DBusMenuImporter: Properties dict has %lu entries:", (unsigned long)[properties count]);
    for (NSString *key in [properties allKeys]) {
        id value = [properties objectForKey:key];
        NSLog(@"DBusMenuImporter:   %@ = %@ (%@)", key, value, [value class]);
    }
    
    NSLog(@"DBusMenuImporter: Children array has %lu elements", (unsigned long)[children count]);
    
    // For root item, create the main menu
    NSMenu *menu = nil;
    if (isRoot) {
        NSString *menuTitle = [properties objectForKey:@"label"];
        if (!menuTitle || [menuTitle length] == 0) {
            menuTitle = @"App Menu";
        }
        NSLog(@"DBusMenuImporter: Creating root menu with title: '%@'", menuTitle);
        menu = [[NSMenu alloc] initWithTitle:menuTitle];
        
        // Process children of root item
        NSLog(@"DBusMenuImporter: Processing %lu children of root item", (unsigned long)[children count]);
        for (NSUInteger i = 0; i < [children count]; i++) {
            id childItem = [children objectAtIndex:i];
            NSLog(@"DBusMenuImporter: Processing child %lu: %@ (%@)", i, childItem, [childItem class]);
            
            NSMenuItem *menuItem = [self createMenuItemFromLayoutItem:childItem];
            if (menuItem) {
                [menu addItem:menuItem];
                NSLog(@"DBusMenuImporter: Added menu item: '%@'", [menuItem title]);
            } else {
                NSLog(@"DBusMenuImporter: Failed to create menu item from child %lu", i);
            }
        }
        
        NSLog(@"DBusMenuImporter: Root menu created with %lu items", (unsigned long)[[menu itemArray] count]);
    } else {
        // This shouldn't happen for root parsing, but handle it
        NSLog(@"DBusMenuImporter: ERROR: parseLayoutItem called with isRoot=NO");
        return nil;
    }
    
    return [menu autorelease];
}

- (NSMenuItem *)createMenuItemFromLayoutItem:(id)layoutItem
{
    if (![layoutItem isKindOfClass:[NSArray class]]) {
        NSLog(@"DBusMenuImporter: Layout item should be an array");
        return nil;
    }
    
    NSArray *itemArray = (NSArray *)layoutItem;
    if ([itemArray count] < 3) {
        NSLog(@"DBusMenuImporter: Layout item should have at least 3 elements");
        return nil;
    }
    
    NSNumber *itemId = [itemArray objectAtIndex:0];
    NSDictionary *properties = [itemArray objectAtIndex:1];
    NSArray *children = [itemArray objectAtIndex:2];
    
    // Get menu item properties
    NSString *label = [properties objectForKey:@"label"];
    NSString *type = [properties objectForKey:@"type"];
    NSNumber *visible = [properties objectForKey:@"visible"];
    NSNumber *enabled = [properties objectForKey:@"enabled"];
    
    // Skip invisible items
    if (visible && ![visible boolValue]) {
        return nil;
    }
    
    // Handle separators
    if (type && [type isEqualToString:@"separator"]) {
        return (NSMenuItem *)[NSMenuItem separatorItem];
    }
    
    // Create menu item
    if (!label) {
        label = @"";
    }
    
    NSMenuItem *menuItem = [[NSMenuItem alloc] initWithTitle:label
                                                      action:nil
                                               keyEquivalent:@""];
    
    // Set enabled state
    if (enabled) {
        [menuItem setEnabled:[enabled boolValue]];
    }
    
    // Store item ID for event handling
    [menuItem setTag:[itemId intValue]];
    
    // Process children (submenu)
    if ([children count] > 0) {
        NSMenu *submenu = [[NSMenu alloc] initWithTitle:label];
        
        for (id childItem in children) {
            NSMenuItem *childMenuItem = [self createMenuItemFromLayoutItem:childItem];
            if (childMenuItem) {
                [submenu addItem:childMenuItem];
            }
        }
        
        [menuItem setSubmenu:submenu];
        [submenu release];
    }
    
    NSLog(@"DBusMenuImporter: Created menu item: '%@' (ID=%@, enabled=%@, children=%lu)",
          label, itemId, enabled, (unsigned long)[children count]);
    
    return [menuItem autorelease];
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
