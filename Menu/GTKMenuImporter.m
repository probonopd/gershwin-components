#import "GTKMenuImporter.h"
#import "GTKMenuParser.h"
#import "GTKSubmenuManager.h"
#import "GTKActionHandler.h"
#import "DBusConnection.h"
#import "AppMenuWidget.h"
#import "MenuUtils.h"
#import "MenuCacheManager.h"

@implementation GTKMenuImporter

@synthesize appMenuWidget = _appMenuWidget;

- (id)init
{
    self = [super init];
    if (self) {
        _dbusConnection = nil;
        _registeredWindows = [[NSMutableDictionary alloc] init];
        _windowMenuPaths = [[NSMutableDictionary alloc] init];
        _windowActionPaths = [[NSMutableDictionary alloc] init];
        _menuCache = [[NSMutableDictionary alloc] init];
        _actionGroupCache = [[NSMutableDictionary alloc] init];
        
        // Set up cleanup timer
        _cleanupTimer = [NSTimer scheduledTimerWithTimeInterval:30.0
                                                        target:self
                                                      selector:@selector(cleanupStaleEntries:)
                                                      userInfo:nil
                                                       repeats:YES];
        
        NSLog(@"GTKMenuImporter: Initialized GTK menu protocol handler");
    }
    return self;
}

- (void)dealloc
{
    [self cleanup];
    [_registeredWindows release];
    [_windowMenuPaths release];
    [_windowActionPaths release];
    [_menuCache release];
    [_actionGroupCache release];
    if (_cleanupTimer) {
        [_cleanupTimer invalidate];
        _cleanupTimer = nil;
    }
    [super dealloc];
}

#pragma mark - MenuProtocolHandler Implementation

- (BOOL)connectToDBus
{
    NSLog(@"GTKMenuImporter: Attempting to connect to DBus session bus...");
    
    _dbusConnection = [GNUDBusConnection sessionBus];
    
    if (![_dbusConnection isConnected]) {
        NSLog(@"GTKMenuImporter: Failed to get DBus connection");
        return NO;
    }
    
    NSLog(@"GTKMenuImporter: Successfully connected to DBus session bus");
    
    // Note: GTK applications don't require us to register as a specific service
    // They expose their menus directly via org.gtk.Menus and org.gtk.Actions
    
    return YES;
}

- (BOOL)hasMenuForWindow:(unsigned long)windowId
{
    NSNumber *windowKey = [NSNumber numberWithUnsignedLong:windowId];
    
    // Check if we have this window registered
    NSString *serviceName = [_registeredWindows objectForKey:windowKey];
    if (serviceName) {
        return YES;
    }
    
    // Check cache
    if ([_menuCache objectForKey:windowKey]) {
        return YES;
    }
    
    return NO;
}

- (NSMenu *)getMenuForWindow:(unsigned long)windowId
{
    NSNumber *windowKey = [NSNumber numberWithUnsignedLong:windowId];
    
    NSLog(@"GTKMenuImporter: Getting GTK menu for window %lu", windowId);
    
    // Check enhanced cache first
    MenuCacheManager *cacheManager = [MenuCacheManager sharedManager];
    NSMenu *cachedMenu = [cacheManager getCachedMenuForWindow:windowId];
    if (cachedMenu) {
        NSLog(@"GTKMenuImporter: Returning enhanced cached GTK menu for window %lu - re-registering shortcuts", windowId);
        
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
        NSLog(@"GTKMenuImporter: Found menu in legacy cache, migrating to enhanced cache");
        
        // Get application name for this window
        NSString *appName = [MenuUtils getApplicationNameForWindow:windowId];
        NSString *serviceName = [_registeredWindows objectForKey:windowKey];
        NSString *menuPath = [_windowMenuPaths objectForKey:windowKey];
        
        // Migrate to enhanced cache
        [cacheManager cacheMenu:legacyCachedMenu
                      forWindow:windowId
                    serviceName:serviceName
                     objectPath:menuPath
                applicationName:appName];
        
        // Remove from legacy cache
        [_menuCache removeObjectForKey:windowKey];
        
        // Re-register shortcuts
        [self reregisterShortcutsForMenu:legacyCachedMenu windowId:windowId];
        
        return legacyCachedMenu;
    }
    
    NSString *serviceName = [_registeredWindows objectForKey:windowKey];
    NSString *menuPath = [_windowMenuPaths objectForKey:windowKey];
    NSString *actionPath = [_windowActionPaths objectForKey:windowKey];
    
    if (!serviceName || !menuPath) {
        // Try immediate scan for this specific window before giving up
        NSLog(@"GTKMenuImporter: No service/menu path found for window %lu, trying immediate scan", windowId);
        [self scanSpecificWindow:windowId];
        
        // Check again after immediate scan
        serviceName = [_registeredWindows objectForKey:windowKey];
        menuPath = [_windowMenuPaths objectForKey:windowKey];
        actionPath = [_windowActionPaths objectForKey:windowKey];
        
        if (!serviceName || !menuPath) {
            NSLog(@"GTKMenuImporter: Still no service/menu path found for window %lu after immediate scan", windowId);
            return nil;
        }
    }
    
    NSLog(@"GTKMenuImporter: Loading GTK menu for window %lu from %@%@ (actions: %@)", 
          windowId, serviceName, menuPath, actionPath ?: @"none");
    
    // Load the menu using GTK protocol
    NSMenu *menu = [self loadGTKMenuFromDBus:serviceName menuPath:menuPath actionPath:actionPath];
    if (menu) {
        // Get application name for enhanced caching
        NSString *appName = [MenuUtils getApplicationNameForWindow:windowId];
        
        // Cache in enhanced cache manager
        [cacheManager cacheMenu:menu
                      forWindow:windowId
                    serviceName:serviceName
                     objectPath:menuPath
                applicationName:appName];
        
        NSLog(@"GTKMenuImporter: Successfully loaded and cached GTK menu with %lu items", 
              (unsigned long)[[menu itemArray] count]);
    } else {
        NSLog(@"GTKMenuImporter: Failed to load GTK menu for window %lu", windowId);
    }
    
    return menu;
}

- (void)activateMenuItem:(NSMenuItem *)menuItem forWindow:(unsigned long)windowId
{
    NSLog(@"GTKMenuImporter: Activating GTK menu item '%@' for window %lu", [menuItem title], windowId);
    
    NSNumber *windowKey = [NSNumber numberWithUnsignedLong:windowId];
    NSString *serviceName = [_registeredWindows objectForKey:windowKey];
    NSString *actionPath = [_windowActionPaths objectForKey:windowKey];
    
    if (!serviceName || !actionPath) {
        NSLog(@"GTKMenuImporter: No service/action path found for window %lu", windowId);
        return;
    }
    
    // In GTK protocol, we need to:
    // 1. Get the action name from the menu item (stored in representedObject or tag)
    // 2. Call the Activate method on org.gtk.Actions interface
    
    NSString *actionName = [menuItem representedObject];
    if (!actionName && [menuItem tag] != 0) {
        // Fallback: use tag as action identifier
        actionName = [NSString stringWithFormat:@"action_%ld", (long)[menuItem tag]];
    }
    
    if (!actionName) {
        NSLog(@"GTKMenuImporter: No action name found for menu item '%@'", [menuItem title]);
        return;
    }
    
    NSLog(@"GTKMenuImporter: Activating GTK action '%@' via %@%@", actionName, serviceName, actionPath);
    
    // Call Activate method on org.gtk.Actions interface
    // Signature: Activate(s action_name, av parameter, a{sv} platform_data)
    NSArray *arguments = [NSArray arrayWithObjects:
                         actionName,                    // action name
                         [NSArray array],              // parameter (empty array for variant)
                         [NSDictionary dictionary],    // platform data (empty)
                         nil];
    
    id result = [_dbusConnection callMethod:@"Activate"
                                  onService:serviceName
                                 objectPath:actionPath
                                  interface:@"org.gtk.Actions"
                                  arguments:arguments];
    
    if (result) {
        NSLog(@"GTKMenuImporter: GTK action activation succeeded, result: %@", result);
    } else {
        NSLog(@"GTKMenuImporter: GTK action activation failed");
    }
}

- (void)registerWindow:(unsigned long)windowId 
           serviceName:(NSString *)serviceName 
            objectPath:(NSString *)objectPath
{
    NSNumber *windowKey = [NSNumber numberWithUnsignedLong:windowId];
    
    [_registeredWindows setObject:serviceName forKey:windowKey];
    [_windowMenuPaths setObject:objectPath forKey:windowKey];
    
    // For GTK, try to determine the action group path
    // Typically it's the same as menu path but on org.gtk.Actions interface
    // Some applications use /org/gtk/Actions/... paths
    NSString *actionPath = objectPath;
    if ([objectPath hasPrefix:@"/org/gtk/Menus"]) {
        actionPath = [objectPath stringByReplacingOccurrencesOfString:@"/org/gtk/Menus" 
                                                           withString:@"/org/gtk/Actions"];
    }
    [_windowActionPaths setObject:actionPath forKey:windowKey];
    
    // Clear cached menu for this window in both legacy and enhanced cache
    [_menuCache removeObjectForKey:windowKey];
    [_actionGroupCache removeObjectForKey:windowKey];
    [[MenuCacheManager sharedManager] invalidateCacheForWindow:windowId];
    
    NSLog(@"GTKMenuImporter: Registered GTK window %lu with service=%@ menuPath=%@ actionPath=%@", 
          windowId, serviceName, objectPath, actionPath);
}

- (void)unregisterWindow:(unsigned long)windowId
{
    NSNumber *windowKey = [NSNumber numberWithUnsignedLong:windowId];
    
    [_registeredWindows removeObjectForKey:windowKey];
    [_windowMenuPaths removeObjectForKey:windowKey];
    [_windowActionPaths removeObjectForKey:windowKey];
    [_menuCache removeObjectForKey:windowKey];
    [_actionGroupCache removeObjectForKey:windowKey];
    [[MenuCacheManager sharedManager] invalidateCacheForWindow:windowId];
    
    NSLog(@"GTKMenuImporter: Unregistered GTK window %lu", windowId);
}

- (void)scanSpecificWindow:(unsigned long)windowId
{
    NSLog(@"GTKMenuImporter: Performing immediate scan for window %lu", windowId);
    
    Display *display = XOpenDisplay(NULL);
    if (!display) {
        NSLog(@"GTKMenuImporter: Cannot open X11 display for immediate window scan");
        return;
    }
    
    Window window = (Window)windowId;
    
    // Create atoms for GTK menu properties
    Atom busNameAtom = XInternAtom(display, "_GTK_UNIQUE_BUS_NAME", False);
    Atom objectPathAtom = XInternAtom(display, "_GTK_MENUBAR_OBJECT_PATH", False);
    
    unsigned char *busNameProp = NULL;
    unsigned char *objectPathProp = NULL;
    
    // Get bus name property
    Atom propType;
    int propFormat;
    unsigned long propItems, propBytesAfter;
    if (XGetWindowProperty(display, window, busNameAtom, 0, 1024, False, AnyPropertyType,
                          &propType, &propFormat, &propItems, &propBytesAfter, &busNameProp) == Success && busNameProp) {
        
        NSLog(@"GTKMenuImporter: Window %lu has _GTK_UNIQUE_BUS_NAME: %s", windowId, busNameProp);
        
        // Get object path property
        if (XGetWindowProperty(display, window, objectPathAtom, 0, 1024, False, AnyPropertyType,
                              &propType, &propFormat, &propItems, &propBytesAfter, &objectPathProp) == Success && objectPathProp) {
            
            NSLog(@"GTKMenuImporter: Window %lu has _GTK_MENUBAR_OBJECT_PATH: %s", windowId, objectPathProp);
            
            NSString *busName = [NSString stringWithUTF8String:(char *)busNameProp];
            NSString *objectPath = [NSString stringWithUTF8String:(char *)objectPathProp];
            
            NSLog(@"GTKMenuImporter: Immediate scan found GTK window %lu with bus=%@ path=%@", windowId, busName, objectPath);
            
            // Register this window immediately
            [self registerWindow:windowId serviceName:busName objectPath:objectPath];
            
            XFree(objectPathProp);
        } else {
            NSLog(@"GTKMenuImporter: Window %lu has bus name but no object path", windowId);
        }
        
        XFree(busNameProp);
    } else {
        NSLog(@"GTKMenuImporter: Window %lu has no GTK menu properties", windowId);
    }
    
    XCloseDisplay(display);
}

- (void)scanForExistingMenuServices
{
    static int gtkScans = 0;
    gtkScans++;
    
    // Only log occasionally to avoid spam
    if (gtkScans % 20 == 1 || gtkScans <= 2) {
        NSLog(@"GTKMenuImporter: Scanning for existing GTK menu services... (scan #%d)", gtkScans);
    }
    
    // GTK applications set X11 properties when they export menus
    // Use a more comprehensive scanning approach
    Display *display = XOpenDisplay(NULL);
    if (!display) {
        if (gtkScans <= 2) {
            NSLog(@"GTKMenuImporter: Cannot open X11 display for scanning");
        }
        return;
    }
    
    NSUInteger gtkWindows = 0;
    NSUInteger newWindows = 0;
    
    // Create atoms once for efficiency
    Atom busNameAtom = XInternAtom(display, "_GTK_UNIQUE_BUS_NAME", False);
    Atom objectPathAtom = XInternAtom(display, "_GTK_MENUBAR_OBJECT_PATH", False);
    
    // Get all windows on the display using _NET_CLIENT_LIST
    Window root = DefaultRootWindow(display);
    Atom clientListAtom = XInternAtom(display, "_NET_CLIENT_LIST", False);
    
    Atom actualType;
    int actualFormat;
    unsigned long numClientWindows, bytesAfter;
    Window *clientWindows = NULL;
    
    if (XGetWindowProperty(display, root, clientListAtom, 0, 1024, False, XA_WINDOW,
                          &actualType, &actualFormat, &numClientWindows, &bytesAfter,
                          (unsigned char**)&clientWindows) == Success && clientWindows) {
        
        if (gtkScans <= 2) {
            NSLog(@"GTKMenuImporter: Found %lu client windows to scan", numClientWindows);
        }
        
        for (unsigned long i = 0; i < numClientWindows; i++) {
            Window window = clientWindows[i];
            
            // Debug: log the window ID we're checking (only for first few scans)
            if (gtkScans <= 2) {
                NSLog(@"GTKMenuImporter: Checking client window %lu (0x%lx)", (unsigned long)window, (unsigned long)window);
            }
            
            // Check this window for GTK menu properties
            unsigned char *busNameProp = NULL;
            unsigned char *objectPathProp = NULL;
            
            // Get bus name property (use separate variables to avoid overwriting numClientWindows)
            Atom propType;
            int propFormat;
            unsigned long propItems, propBytesAfter;
            if (XGetWindowProperty(display, window, busNameAtom, 0, 1024, False, AnyPropertyType,
                                  &propType, &propFormat, &propItems, &propBytesAfter, &busNameProp) == Success && busNameProp) {
                
                if (gtkScans <= 2) {
                    NSLog(@"GTKMenuImporter: Window %lu has _GTK_UNIQUE_BUS_NAME: %s", (unsigned long)window, busNameProp);
                }
                
                // Get object path property  
                if (XGetWindowProperty(display, window, objectPathAtom, 0, 1024, False, AnyPropertyType,
                                      &propType, &propFormat, &propItems, &propBytesAfter, &objectPathProp) == Success && objectPathProp) {
                    
                    if (gtkScans <= 2) {
                        NSLog(@"GTKMenuImporter: Window %lu has _GTK_MENUBAR_OBJECT_PATH: %s", (unsigned long)window, objectPathProp);
                    }
                    
                    NSString *busName = [NSString stringWithUTF8String:(char *)busNameProp];
                    NSString *objectPath = [NSString stringWithUTF8String:(char *)objectPathProp];
                    
                    // Check if this is a new window
                    NSNumber *windowKey = [NSNumber numberWithUnsignedLong:(unsigned long)window];
                    if (![_registeredWindows objectForKey:windowKey]) {
                        NSLog(@"GTKMenuImporter: Found GTK window %lu with bus=%@ path=%@", (unsigned long)window, busName, objectPath);
                        newWindows++;
                    } else {
                        // Only log this on first few scans to show what we have
                        if (gtkScans <= 2) {
                            NSLog(@"GTKMenuImporter: Registered GTK window %lu with service=%@ menuPath=%@ actionPath=%@", 
                                  (unsigned long)window, busName, objectPath, objectPath);
                        }
                    }
                    
                    // Register this window
                    [self registerWindow:(unsigned long)window serviceName:busName objectPath:objectPath];
                    gtkWindows++;
                    
                    XFree(objectPathProp);
                }
                XFree(busNameProp);
            }
        }
        XFree(clientWindows);
    } else {
        // Fallback to root window children if _NET_CLIENT_LIST is not available
        if (gtkScans <= 2) {
            NSLog(@"GTKMenuImporter: _NET_CLIENT_LIST not available, falling back to root children");
        }
        
        Window parent, *children;
        unsigned int numChildren;
        
        if (XQueryTree(display, root, &root, &parent, &children, &numChildren) == Success && children) {
            for (unsigned int i = 0; i < numChildren; i++) {
                Window window = children[i];
                
                // Check for GTK menu properties
                unsigned char *busNameProp = NULL;
                unsigned char *objectPathProp = NULL;
                
                // Get bus name property (use separate variables)
                Atom propType;
                int propFormat;
                unsigned long propItems, propBytesAfter;
                if (XGetWindowProperty(display, window, busNameAtom, 0, 1024, False, AnyPropertyType,
                                      &propType, &propFormat, &propItems, &propBytesAfter, &busNameProp) == Success && busNameProp) {
                    
                    // Get object path property  
                    if (XGetWindowProperty(display, window, objectPathAtom, 0, 1024, False, AnyPropertyType,
                                          &propType, &propFormat, &propItems, &propBytesAfter, &objectPathProp) == Success && objectPathProp) {
                        
                        NSString *busName = [NSString stringWithUTF8String:(char *)busNameProp];
                        NSString *objectPath = [NSString stringWithUTF8String:(char *)objectPathProp];
                        
                        // Check if this is a new window
                        NSNumber *windowKey = [NSNumber numberWithUnsignedLong:(unsigned long)window];
                        if (![_registeredWindows objectForKey:windowKey]) {
                            NSLog(@"GTKMenuImporter: Found GTK window %lu with bus=%@ path=%@", (unsigned long)window, busName, objectPath);
                            newWindows++;
                        }
                        
                        // Register this window
                        [self registerWindow:(unsigned long)window serviceName:busName objectPath:objectPath];
                        gtkWindows++;
                        
                        XFree(objectPathProp);
                    }
                    XFree(busNameProp);
                }
            }
            XFree(children);
        }
    }
    
    XCloseDisplay(display);
    
    // Only log when we find new windows or on initial scans
    if (gtkScans <= 3 || newWindows > 0) {
        NSLog(@"GTKMenuImporter: Found %lu GTK windows with menus", (unsigned long)gtkWindows);
    }
}

- (NSString *)getMenuServiceForWindow:(unsigned long)windowId
{
    NSNumber *windowKey = [NSNumber numberWithUnsignedLong:windowId];
    return [_registeredWindows objectForKey:windowKey];
}

- (NSString *)getMenuObjectPathForWindow:(unsigned long)windowId
{
    NSNumber *windowKey = [NSNumber numberWithUnsignedLong:windowId];
    return [_windowMenuPaths objectForKey:windowKey];
}

- (void)cleanup
{
    NSLog(@"GTKMenuImporter: Cleaning up GTK menu protocol handler...");
    
    [_registeredWindows removeAllObjects];
    [_windowMenuPaths removeAllObjects];
    [_windowActionPaths removeAllObjects];
    [_menuCache removeAllObjects];
    [_actionGroupCache removeAllObjects];
    
    // Clean up GTK submenu manager
    [GTKSubmenuManager cleanup];
    
    if (_cleanupTimer) {
        [_cleanupTimer invalidate];
        _cleanupTimer = nil;
    }
}

#pragma mark - GTK-Specific Methods

- (NSString *)getActionGroupPathForWindow:(unsigned long)windowId
{
    NSNumber *windowKey = [NSNumber numberWithUnsignedLong:windowId];
    return [_windowActionPaths objectForKey:windowKey];
}

- (BOOL)introspectGTKService:(NSString *)serviceName
{
    // Skip system services and our own services
    if ([serviceName hasPrefix:@"org.freedesktop."] ||
        [serviceName hasPrefix:@"com.canonical."] ||
        [serviceName hasSuffix:@".Menu"]) {
        return NO;
    }
    
    // Try to introspect common GTK paths
    NSArray *commonPaths = @[@"/org/gtk/Menus", @"/org/gtk/Actions", @"/", @"/org/gtk"];
    
    for (NSString *path in commonPaths) {
        id introspectResult = [_dbusConnection callMethod:@"Introspect"
                                                onService:serviceName
                                               objectPath:path
                                                interface:@"org.freedesktop.DBus.Introspectable"
                                                arguments:nil];
        
        if (introspectResult && [introspectResult isKindOfClass:[NSString class]]) {
            NSString *xml = (NSString *)introspectResult;
            
            // Check if this service exports GTK menu interfaces
            if ([xml containsString:@"org.gtk.Menus"] || [xml containsString:@"org.gtk.Actions"]) {
                NSLog(@"GTKMenuImporter: Service %@ exports GTK interfaces at path %@", serviceName, path);
                return YES;
            }
        }
    }
    
    return NO;
}

- (NSMenu *)loadGTKMenuFromDBus:(NSString *)serviceName 
                       menuPath:(NSString *)menuPath 
                     actionPath:(NSString *)actionPath
{
    NSLog(@"GTKMenuImporter: Loading GTK menu from service=%@ menuPath=%@ actionPath=%@", 
          serviceName, menuPath, actionPath);
    
    // First, introspect the menu path to see what's available
    id introspectResult = [_dbusConnection callMethod:@"Introspect"
                                            onService:serviceName
                                           objectPath:menuPath
                                            interface:@"org.freedesktop.DBus.Introspectable"
                                            arguments:nil];
    
    if (!introspectResult) {
        NSLog(@"GTKMenuImporter: Failed to introspect GTK menu service");
        return nil;
    }
    
    // Try to call Start method on org.gtk.Menus interface
    // This method returns the menu structure: Start(au subscription_ids) -> (uaa{sv})
    // For menubar, typically subscribe to group 0 only
    NSArray *subscriptionIds = @[[NSNumber numberWithUnsignedInt:0]]; // Group 0 is the main menubar (unsigned int)
    
    id menuResult = [_dbusConnection callMethod:@"Start"
                                      onService:serviceName
                                     objectPath:menuPath
                                      interface:@"org.gtk.Menus"
                                      arguments:@[subscriptionIds]];
    
    if (!menuResult) {
        NSLog(@"GTKMenuImporter: Failed to get GTK menu structure via Start method");
        
        // Try alternative: GetMenus method (less common)
        menuResult = [_dbusConnection callMethod:@"GetMenus"
                                       onService:serviceName
                                      objectPath:menuPath
                                       interface:@"org.gtk.Menus"
                                       arguments:nil];
    }
    
    if (!menuResult) {
        NSLog(@"GTKMenuImporter: No GTK menu data available");
        return nil;
    }
    
    NSLog(@"GTKMenuImporter: GTK menu result type: %@", [menuResult class]);
    NSLog(@"GTKMenuImporter: GTK menu result: %@", menuResult);
    
    // Parse the GTK menu structure
    // The format is different from canonical dbusmenu - it's a GMenuModel serialization
    NSMenu *menu = [GTKMenuParser parseGTKMenuFromDBusResult:menuResult 
                                                 serviceName:serviceName 
                                                  actionPath:actionPath 
                                              dbusConnection:_dbusConnection];
    
    if (!menu) {
        NSLog(@"GTKMenuImporter: Failed to parse GTK menu structure, creating placeholder");
        menu = [[NSMenu alloc] initWithTitle:@"GTK App Menu"];
        
        // Add placeholder items to indicate this is a GTK app
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"GTK Application" 
                                                      action:nil 
                                               keyEquivalent:@""];
        [item setEnabled:NO];
        [menu addItem:item];
        [item release];
    }
    
    return [menu autorelease];
}

- (void)reregisterShortcutsForMenu:(NSMenu *)menu windowId:(unsigned long)windowId
{
    if (!menu) {
        return;
    }
    
    NSNumber *windowKey = [NSNumber numberWithUnsignedLong:windowId];
    NSString *serviceName = [_registeredWindows objectForKey:windowKey];
    NSString *actionPath = [_windowActionPaths objectForKey:windowKey];
    
    if (!serviceName || !actionPath) {
        NSLog(@"GTKMenuImporter: Cannot re-register shortcuts - missing service/action path");
        return;
    }
    
    // Get fresh DBus connection for cached menu shortcut re-registration
    if (!_dbusConnection || ![_dbusConnection isConnected]) {
        NSLog(@"GTKMenuImporter: Refreshing DBus connection for cached menu shortcuts");
        if (![self connectToDBus]) {
            NSLog(@"GTKMenuImporter: Failed to refresh DBus connection for shortcuts");
            return;
        }
    }
    
    NSLog(@"GTKMenuImporter: Re-registering shortcuts for GTK menu (window %lu) with fresh DBus connection", windowId);
    [self reregisterShortcutsForMenuItems:[menu itemArray] serviceName:serviceName actionPath:actionPath];
}

- (void)reregisterShortcutsForMenuItems:(NSArray *)items serviceName:(NSString *)serviceName actionPath:(NSString *)actionPath
{
    for (NSMenuItem *item in items) {
        // Check if this item has GTK action data and a shortcut
        NSString *keyEquivalent = [item keyEquivalent];
        if (keyEquivalent && [keyEquivalent length] > 0) {
            NSUInteger modifierMask = [item keyEquivalentModifierMask];
            
            // Apply the same filtering as GTKActionHandler
            BOOL hasShiftOnly = (modifierMask == NSShiftKeyMask);
            BOOL hasNoModifiers = (modifierMask == 0);
            
            if (!hasNoModifiers && !hasShiftOnly) {
                // Get the action name from the menu item's representedObject or title
                NSString *actionName = [item representedObject];
                if (!actionName) {
                    // Fallback to generating action name from title
                    actionName = [[item title] lowercaseString];
                    actionName = [actionName stringByReplacingOccurrencesOfString:@" " withString:@"-"];
                }
                
                NSLog(@"GTKMenuImporter: Re-registering GTK shortcut: %@ (action: %@)", [item title], actionName);
                
                // Re-register through GTKActionHandler
                [GTKActionHandler setupActionForMenuItem:item
                                              actionName:actionName
                                             serviceName:serviceName
                                              actionPath:actionPath
                                          dbusConnection:_dbusConnection];
            }
        }
        
        // Process submenus recursively
        if ([item hasSubmenu]) {
            [self reregisterShortcutsForMenuItems:[[item submenu] itemArray] 
                                      serviceName:serviceName 
                                       actionPath:actionPath];
        }
    }
}

#pragma mark - Private Methods

- (void)cleanupStaleEntries:(NSTimer *)timer
{
    NSLog(@"GTKMenuImporter: Cleanup timer - %lu GTK windows registered", 
          (unsigned long)[_registeredWindows count]);
    
    // In a full implementation, we would check if windows still exist
    // and remove entries for windows that have been closed
}

@end
