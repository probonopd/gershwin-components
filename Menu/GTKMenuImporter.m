#import "GTKMenuImporter.h"
#import "GTKMenuParser.h"
#import "GTKSubmenuManager.h"
#import "GTKActionHandler.h"
#import "DBusConnection.h"
#import "AppMenuWidget.h"
#import "MenuUtils.h"
#import "MenuCacheManager.h"
#import <X11/Xlib.h>

// Set to 1 to enable verbose debug logging
#define GTKMENU_DEBUG_LOGGING 0

// Thread-local storage for X11 error tracking
static __thread BOOL gtk_x11_error_occurred = NO;

// Custom X11 error handler that prevents crashes on BadWindow
static int handleGTKX11Error(Display *display, XErrorEvent *event)
{
    (void)display;
    gtk_x11_error_occurred = YES;
    
#if GTKMENU_DEBUG_LOGGING
    NSLog(@"GTKMenuImporter: X11 error caught (code %d, request %d) - window may have been destroyed",
          event->error_code, event->request_code);
#else
    (void)event;
#endif
    
    return 0;
}

// Helper to begin safe X11 operation
static void beginSafeGTKX11Operation(void)
{
    gtk_x11_error_occurred = NO;
    XSetErrorHandler(handleGTKX11Error);
}

// Helper to check if X11 error occurred
static BOOL checkGTKX11Error(Display *display)
{
    if (display) {
        XSync(display, False);
    }
    return gtk_x11_error_occurred;
}

@implementation GTKMenuImporter

- (id)init
{
    self = [super init];
    if (self) {
        self.dbusConnection = nil;
        self.registeredWindows = [[NSMutableDictionary alloc] init];
        self.windowMenuPaths = [[NSMutableDictionary alloc] init];
        self.windowActionPaths = [[NSMutableDictionary alloc] init];
        self.menuCache = [[NSMutableDictionary alloc] init];
        self.actionGroupCache = [[NSMutableDictionary alloc] init];
        self.registryLock = [[NSLock alloc] init];
        
        // Don't set up the cleanup timer during init - do it later when the run loop is ready
        self.cleanupTimer = nil;
        
#if GTKMENU_DEBUG_LOGGING
        NSLog(@"GTKMenuImporter: Initialized GTK menu protocol handler");
#endif
    }
    return self;
}

#pragma mark - MenuProtocolHandler Implementation

- (BOOL)connectToDBus
{
#if GTKMENU_DEBUG_LOGGING
    NSLog(@"GTKMenuImporter: Attempting to connect to DBus session bus...");
#endif
    
    self.dbusConnection = [GNUDBusConnection sessionBus];
    
    if (![self.dbusConnection isConnected]) {
        NSLog(@"GTKMenuImporter: Failed to get DBus connection");
        return NO;
    }
    
#if GTKMENU_DEBUG_LOGGING
    NSLog(@"GTKMenuImporter: Successfully connected to DBus session bus");
#endif
    
    // Now that we're connected and the run loop is running, set up the cleanup timer
    if (!self.cleanupTimer) {
#if GTKMENU_DEBUG_LOGGING
        NSLog(@"GTKMenuImporter: Setting up cleanup timer...");
#endif
        self.cleanupTimer = [NSTimer scheduledTimerWithTimeInterval:30.0
                                                        target:self
                                                      selector:@selector(cleanupStaleEntries:)
                                                      userInfo:nil
                                                       repeats:YES];
#if GTKMENU_DEBUG_LOGGING
        NSLog(@"GTKMenuImporter: Cleanup timer scheduled");
#endif
    }
    
#if GTKMENU_DEBUG_LOGGING
    NSLog(@"GTKMenuImporter: About to call scanForExistingMenuServices");
#endif
    [self scanForExistingMenuServices];
#if GTKMENU_DEBUG_LOGGING
    NSLog(@"GTKMenuImporter: Finished calling scanForExistingMenuServices");
#endif
    
    // Note: GTK applications don't require us to register as a specific service
    // They expose their menus directly via org.gtk.Menus and org.gtk.Actions
    
    return YES;
}

- (BOOL)hasMenuForWindow:(unsigned long)windowId
{
    NSNumber *windowKey = [NSNumber numberWithUnsignedLong:windowId];
    
    [_registryLock lock];
    // Check if we have this window registered
    NSString *serviceName = [_registeredWindows objectForKey:windowKey];
    if (serviceName) {
        [_registryLock unlock];
        return YES;
    }
    
    // Check cache
    if ([_menuCache objectForKey:windowKey]) {
        [_registryLock unlock];
        return YES;
    }
    [_registryLock unlock];
    
    return NO;
}

- (NSMenu *)getMenuForWindow:(unsigned long)windowId
{
    NSNumber *windowKey = [NSNumber numberWithUnsignedLong:windowId];
    
#if GTKMENU_DEBUG_LOGGING
    NSLog(@"GTKMenuImporter: Getting GTK menu for window %lu", windowId);
#endif
    
    // Check enhanced cache first
    MenuCacheManager *cacheManager = [MenuCacheManager sharedManager];
    NSMenu *cachedMenu = [cacheManager getCachedMenuForWindow:windowId];
    if (cachedMenu) {
#if GTKMENU_DEBUG_LOGGING
        NSLog(@"GTKMenuImporter: Returning enhanced cached GTK menu for window %lu - re-registering shortcuts", windowId);
#endif
        
        // Re-register shortcuts for cached menu since they may have been unregistered
        // when the window lost focus
        [self reregisterShortcutsForMenu:cachedMenu windowId:windowId];
        
        // Notify cache manager that window became active
        [cacheManager windowBecameActive:windowId];
        
        return cachedMenu;
    }
    
    // Fall back to legacy cache check for backward compatibility - with thread safety
    [_registryLock lock];
    NSMenu *legacyCachedMenu = [_menuCache objectForKey:windowKey];
    if (legacyCachedMenu) {
#if GTKMENU_DEBUG_LOGGING
        NSLog(@"GTKMenuImporter: Found menu in legacy cache, migrating to enhanced cache");
#endif
        
        // Get application name for this window
        NSString *appName = [MenuUtils getApplicationNameForWindow:windowId];
        NSString *serviceName = [[_registeredWindows objectForKey:windowKey] copy];
        NSString *menuPath = [[_windowMenuPaths objectForKey:windowKey] copy];
        
        // Remove from legacy cache while holding lock
        [_menuCache removeObjectForKey:windowKey];
        [_registryLock unlock];
        
        // Migrate to enhanced cache (outside lock)
        [cacheManager cacheMenu:legacyCachedMenu
                      forWindow:windowId
                    serviceName:serviceName
                     objectPath:menuPath
                applicationName:appName];
        
        // Re-register shortcuts
        [self reregisterShortcutsForMenu:legacyCachedMenu windowId:windowId];
        
        return legacyCachedMenu;
    }
    
    NSString *serviceName = [[_registeredWindows objectForKey:windowKey] copy];
    NSString *menuPath = [[_windowMenuPaths objectForKey:windowKey] copy];
    NSString *actionPath = [[_windowActionPaths objectForKey:windowKey] copy];
    [_registryLock unlock];
    
    if (!serviceName || !menuPath) {
        // Try immediate scan for this specific window before giving up
#if GTKMENU_DEBUG_LOGGING
        NSLog(@"GTKMenuImporter: No service/menu path found for window %lu, trying immediate scan", windowId);
#endif
        [self scanSpecificWindow:windowId];
        
        // Check again after immediate scan - with thread safety
        [_registryLock lock];
        serviceName = [[_registeredWindows objectForKey:windowKey] copy];
        menuPath = [[_windowMenuPaths objectForKey:windowKey] copy];
        actionPath = [[_windowActionPaths objectForKey:windowKey] copy];
        [_registryLock unlock];
        
        if (!serviceName || !menuPath) {
#if GTKMENU_DEBUG_LOGGING
            NSLog(@"GTKMenuImporter: Still no service/menu path found for window %lu after immediate scan", windowId);
#endif
            return nil;
        }
    }
    
#if GTKMENU_DEBUG_LOGGING
    NSLog(@"GTKMenuImporter: Loading GTK menu for window %lu from %@%@ (actions: %@)", 
          windowId, serviceName, menuPath, actionPath ?: @"none");
#endif
    
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
        
#if GTKMENU_DEBUG_LOGGING
        NSLog(@"GTKMenuImporter: Successfully loaded and cached GTK menu with %lu items", 
              (unsigned long)[[menu itemArray] count]);
#endif
    } else {
#if GTKMENU_DEBUG_LOGGING
        NSLog(@"GTKMenuImporter: Failed to load GTK menu for window %lu", windowId);
#endif
    }
    
    return menu;
}

- (void)activateMenuItem:(NSMenuItem *)menuItem forWindow:(unsigned long)windowId
{
#if GTKMENU_DEBUG_LOGGING
    NSLog(@"GTKMenuImporter: Activating GTK menu item '%@' for window %lu", [menuItem title], windowId);
#endif
    
    NSNumber *windowKey = [NSNumber numberWithUnsignedLong:windowId];
    
    [_registryLock lock];
    NSString *serviceName = [[_registeredWindows objectForKey:windowKey] copy];
    NSString *actionPath = [[_windowActionPaths objectForKey:windowKey] copy];
    [_registryLock unlock];
    
    if (!serviceName || !actionPath) {
#if GTKMENU_DEBUG_LOGGING
        NSLog(@"GTKMenuImporter: No service/action path found for window %lu", windowId);
#endif
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
#if GTKMENU_DEBUG_LOGGING
        NSLog(@"GTKMenuImporter: No action name found for menu item '%@'", [menuItem title]);
#endif
        return;
    }
    
#if GTKMENU_DEBUG_LOGGING
    NSLog(@"GTKMenuImporter: Activating GTK action '%@' via %@%@", actionName, serviceName, actionPath);
#endif
    
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
    
#if GTKMENU_DEBUG_LOGGING
    if (result) {
        NSLog(@"GTKMenuImporter: GTK action activation succeeded, result: %@", result);
    } else {
        NSLog(@"GTKMenuImporter: GTK action activation failed");
    }
#else
    (void)result;
#endif
}

- (void)registerWindow:(unsigned long)windowId 
           serviceName:(NSString *)serviceName 
            objectPath:(NSString *)objectPath
{
    NSNumber *windowKey = [NSNumber numberWithUnsignedLong:windowId];
    
    [_registryLock lock];
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
    [_registryLock unlock];
    
    [[MenuCacheManager sharedManager] invalidateCacheForWindow:windowId];
    
#if GTKMENU_DEBUG_LOGGING
    NSLog(@"GTKMenuImporter: Registered GTK window %lu with service=%@ menuPath=%@ actionPath=%@", 
          windowId, serviceName, objectPath, actionPath);
#endif
}

- (void)unregisterWindow:(unsigned long)windowId
{
    NSNumber *windowKey = [NSNumber numberWithUnsignedLong:windowId];
    
    [_registryLock lock];
    [_registeredWindows removeObjectForKey:windowKey];
    [_windowMenuPaths removeObjectForKey:windowKey];
    [_windowActionPaths removeObjectForKey:windowKey];
    [_menuCache removeObjectForKey:windowKey];
    [_actionGroupCache removeObjectForKey:windowKey];
    [_registryLock unlock];
    
    [[MenuCacheManager sharedManager] invalidateCacheForWindow:windowId];
    
#if GTKMENU_DEBUG_LOGGING
    NSLog(@"GTKMenuImporter: Unregistered GTK window %lu", windowId);
#endif
}

- (void)scanSpecificWindow:(unsigned long)windowId
{
#if GTKMENU_DEBUG_LOGGING
    NSLog(@"GTKMenuImporter: Performing immediate scan for window %lu", windowId);
#endif
    
    if (windowId == 0) {
#if GTKMENU_DEBUG_LOGGING
        NSLog(@"GTKMenuImporter: Cannot scan window 0");
#endif
        return;
    }
    
    Display *display = XOpenDisplay(NULL);
    if (!display) {
#if GTKMENU_DEBUG_LOGGING
        NSLog(@"GTKMenuImporter: Cannot open X11 display for immediate window scan");
#endif
        return;
    }
    
    // Install error handler to prevent crashes on BadWindow
    beginSafeGTKX11Operation();
    
    Window window = (Window)windowId;
    
    // First check if window still exists
    XWindowAttributes attrs;
    if (XGetWindowAttributes(display, window, &attrs) == 0 || checkGTKX11Error(display)) {
#if GTKMENU_DEBUG_LOGGING
        NSLog(@"GTKMenuImporter: Window %lu no longer exists, skipping scan", windowId);
#endif
        XCloseDisplay(display);
        return;
    }
    
    // Create atoms for GTK menu properties
    Atom busNameAtom = XInternAtom(display, "_GTK_UNIQUE_BUS_NAME", False);
    Atom objectPathAtom = XInternAtom(display, "_GTK_MENUBAR_OBJECT_PATH", False);
    
    unsigned char *busNameProp = NULL;
    unsigned char *objectPathProp = NULL;
    
    // Get bus name property
    Atom propType;
    int propFormat;
    unsigned long propItems, propBytesAfter;
    int result = XGetWindowProperty(display, window, busNameAtom, 0, 1024, False, AnyPropertyType,
                          &propType, &propFormat, &propItems, &propBytesAfter, &busNameProp);
    
    if (checkGTKX11Error(display)) {
        NSLog(@"GTKMenuImporter: Window %lu was destroyed during property access", windowId);
        if (busNameProp) XFree(busNameProp);
        XCloseDisplay(display);
        return;
    }
    
    if (result == Success && busNameProp) {
#if GTKMENU_DEBUG_LOGGING
        NSLog(@"GTKMenuImporter: Window %lu has _GTK_UNIQUE_BUS_NAME: %s", windowId, busNameProp);
#endif
        
        // Get object path property
        if (XGetWindowProperty(display, window, objectPathAtom, 0, 1024, False, AnyPropertyType,
                              &propType, &propFormat, &propItems, &propBytesAfter, &objectPathProp) == Success && objectPathProp) {
            
#if GTKMENU_DEBUG_LOGGING
            NSLog(@"GTKMenuImporter: Window %lu has _GTK_MENUBAR_OBJECT_PATH: %s", windowId, objectPathProp);
#endif
            
            NSString *busName = [NSString stringWithUTF8String:(char *)busNameProp];
            NSString *objectPath = [NSString stringWithUTF8String:(char *)objectPathProp];
            
#if GTKMENU_DEBUG_LOGGING
            NSLog(@"GTKMenuImporter: Immediate scan found GTK window %lu with bus=%@ path=%@", windowId, busName, objectPath);
#endif
            
            // Register this window immediately
            [self registerWindow:windowId serviceName:busName objectPath:objectPath];
            
            XFree(objectPathProp);
        } else {
#if GTKMENU_DEBUG_LOGGING
            NSLog(@"GTKMenuImporter: Window %lu has bus name but no object path", windowId);
#endif
        }
        
        XFree(busNameProp);
    } else {
#if GTKMENU_DEBUG_LOGGING
        NSLog(@"GTKMenuImporter: Window %lu has no GTK menu properties", windowId);
#endif
    }
    
    XCloseDisplay(display);
}

- (void)scanForExistingMenuServices
{
#if GTKMENU_DEBUG_LOGGING
    NSLog(@"GTKMenuImporter: scanForExistingMenuServices STARTED");
#endif
    
    static int gtkScans = 0;
    gtkScans++;
    
#if GTKMENU_DEBUG_LOGGING
    // Only log occasionally to avoid spam
    if (gtkScans % 20 == 1 || gtkScans <= 2) {
        NSLog(@"GTKMenuImporter: Scanning for existing GTK menu services... (scan #%d)", gtkScans);
    }
#endif
    
    // GTK applications set X11 properties when they export menus
    // Use a more comprehensive scanning approach
#if GTKMENU_DEBUG_LOGGING
    NSLog(@"GTKMenuImporter: About to open X11 display");
#endif
    Display *display = XOpenDisplay(NULL);
    if (!display) {
#if GTKMENU_DEBUG_LOGGING
        if (gtkScans <= 2) {
            NSLog(@"GTKMenuImporter: Cannot open X11 display for scanning");
        }
        NSLog(@"GTKMenuImporter: scanForExistingMenuServices FAILED (no display)");
#endif
        return;
    }
#if GTKMENU_DEBUG_LOGGING
    NSLog(@"GTKMenuImporter: X11 display opened successfully");
#endif
    
    // Install error handler to prevent crashes on BadWindow
    beginSafeGTKX11Operation();
    
    NSUInteger gtkWindows = 0;
    NSUInteger newWindows = 0;
    
    // Create atoms once for efficiency
#if GTKMENU_DEBUG_LOGGING
    NSLog(@"GTKMenuImporter: Creating X11 atoms");
#endif
    Atom busNameAtom = XInternAtom(display, "_GTK_UNIQUE_BUS_NAME", False);
    Atom objectPathAtom = XInternAtom(display, "_GTK_MENUBAR_OBJECT_PATH", False);
#if GTKMENU_DEBUG_LOGGING
    NSLog(@"GTKMenuImporter: X11 atoms created");
#endif
    
    // Get all windows on the display using _NET_CLIENT_LIST
#if GTKMENU_DEBUG_LOGGING
    NSLog(@"GTKMenuImporter: Getting root window");
#endif
    Window root = DefaultRootWindow(display);
    Atom clientListAtom = XInternAtom(display, "_NET_CLIENT_LIST", False);
#if GTKMENU_DEBUG_LOGGING
    NSLog(@"GTKMenuImporter: About to query window property");
#endif
    
    Atom actualType;
    int actualFormat;
    unsigned long numClientWindows, bytesAfter;
    Window *clientWindows = NULL;
    
    if (XGetWindowProperty(display, root, clientListAtom, 0, 1024, False, XA_WINDOW,
                          &actualType, &actualFormat, &numClientWindows, &bytesAfter,
                          (unsigned char**)&clientWindows) == Success && clientWindows) {
        
#if GTKMENU_DEBUG_LOGGING
        NSLog(@"GTKMenuImporter: Successfully got client window list");
        if (gtkScans <= 2) {
            NSLog(@"GTKMenuImporter: Found %lu client windows to scan", numClientWindows);
        }
        
        NSLog(@"GTKMenuImporter: About to iterate through %lu client windows", numClientWindows);
#endif
        for (unsigned long i = 0; i < numClientWindows; i++) {
#if GTKMENU_DEBUG_LOGGING
            if (i % 100 == 0 && i > 0) {
                NSLog(@"GTKMenuImporter: Processed %lu of %lu windows", i, numClientWindows);
            }
#endif
            
            Window window = clientWindows[i];
            
#if GTKMENU_DEBUG_LOGGING
            // Debug: log the window ID we're checking (only for first few scans)
            if (gtkScans <= 2) {
                NSLog(@"GTKMenuImporter: Checking client window %lu (0x%lx)", (unsigned long)window, (unsigned long)window);
            }
#endif
            
            // Reset error state for each window
            gtk_x11_error_occurred = NO;
            
            // Check this window for GTK menu properties
            unsigned char *busNameProp = NULL;
            unsigned char *objectPathProp = NULL;
            
            // Get bus name property (use separate variables to avoid overwriting numClientWindows)
            Atom propType;
            int propFormat;
            unsigned long propItems, propBytesAfter;
            int result = XGetWindowProperty(display, window, busNameAtom, 0, 1024, False, AnyPropertyType,
                                  &propType, &propFormat, &propItems, &propBytesAfter, &busNameProp);
            
            // Skip this window if it was destroyed during property access
            if (checkGTKX11Error(display)) {
                if (busNameProp) XFree(busNameProp);
                continue;
            }
            
            if (result == Success && busNameProp) {
#if GTKMENU_DEBUG_LOGGING
                if (gtkScans <= 2) {
                    NSLog(@"GTKMenuImporter: Window %lu has _GTK_UNIQUE_BUS_NAME: %s", (unsigned long)window, busNameProp);
                }
#endif
                
                // Get object path property  
                result = XGetWindowProperty(display, window, objectPathAtom, 0, 1024, False, AnyPropertyType,
                                      &propType, &propFormat, &propItems, &propBytesAfter, &objectPathProp);
                
                // Skip if window was destroyed
                if (checkGTKX11Error(display)) {
                    XFree(busNameProp);
                    if (objectPathProp) XFree(objectPathProp);
                    continue;
                }
                
                if (result == Success && objectPathProp) {
#if GTKMENU_DEBUG_LOGGING
                    if (gtkScans <= 2) {
                        NSLog(@"GTKMenuImporter: Window %lu has _GTK_MENUBAR_OBJECT_PATH: %s", (unsigned long)window, objectPathProp);
                    }
#endif
                    
                    NSString *busName = [NSString stringWithUTF8String:(char *)busNameProp];
                    NSString *objectPath = [NSString stringWithUTF8String:(char *)objectPathProp];
                    
                    // Check if this is a new window
                    NSNumber *windowKey = [NSNumber numberWithUnsignedLong:(unsigned long)window];
                    if (![_registeredWindows objectForKey:windowKey]) {
#if GTKMENU_DEBUG_LOGGING
                        NSLog(@"GTKMenuImporter: Found GTK window %lu with bus=%@ path=%@", (unsigned long)window, busName, objectPath);
#endif
                        newWindows++;
                    } else {
#if GTKMENU_DEBUG_LOGGING
                        // Only log this on first few scans to show what we have
                        if (gtkScans <= 2) {
                            NSLog(@"GTKMenuImporter: Registered GTK window %lu with service=%@ menuPath=%@ actionPath=%@", 
                                  (unsigned long)window, busName, objectPath, objectPath);
                        }
#endif
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
#if GTKMENU_DEBUG_LOGGING
        NSLog(@"GTKMenuImporter: Finished processing client windows, freed memory");
#endif
    } else {
        // Fallback to root window children if _NET_CLIENT_LIST is not available
#if GTKMENU_DEBUG_LOGGING
        NSLog(@"GTKMenuImporter: Client list query failed, using fallback method");
        if (gtkScans <= 2) {
            NSLog(@"GTKMenuImporter: _NET_CLIENT_LIST not available, falling back to root children");
        }
#endif
        
        Window parent, *children;
        unsigned int numChildren;
        
        // Reset error state before fallback method
        gtk_x11_error_occurred = NO;
        
        if (XQueryTree(display, root, &root, &parent, &children, &numChildren) == Success && children && !checkGTKX11Error(display)) {
            for (unsigned int i = 0; i < numChildren; i++) {
                Window window = children[i];
                
                // Reset error state for each window
                gtk_x11_error_occurred = NO;
                
                // Check for GTK menu properties
                unsigned char *busNameProp = NULL;
                unsigned char *objectPathProp = NULL;
                
                // Get bus name property (use separate variables)
                Atom propType;
                int propFormat;
                unsigned long propItems, propBytesAfter;
                int result = XGetWindowProperty(display, window, busNameAtom, 0, 1024, False, AnyPropertyType,
                                      &propType, &propFormat, &propItems, &propBytesAfter, &busNameProp);
                
                // Skip if window was destroyed
                if (checkGTKX11Error(display)) {
                    if (busNameProp) XFree(busNameProp);
                    continue;
                }
                
                if (result == Success && busNameProp) {
                    // Get object path property  
                    result = XGetWindowProperty(display, window, objectPathAtom, 0, 1024, False, AnyPropertyType,
                                          &propType, &propFormat, &propItems, &propBytesAfter, &objectPathProp);
                    
                    // Skip if window was destroyed
                    if (checkGTKX11Error(display)) {
                        XFree(busNameProp);
                        if (objectPathProp) XFree(objectPathProp);
                        continue;
                    }
                    
                    if (result == Success && objectPathProp) {
                        
                        NSString *busName = [NSString stringWithUTF8String:(char *)busNameProp];
                        NSString *objectPath = [NSString stringWithUTF8String:(char *)objectPathProp];
                        
                        // Check if this is a new window
                        NSNumber *windowKey = [NSNumber numberWithUnsignedLong:(unsigned long)window];
                        if (![_registeredWindows objectForKey:windowKey]) {
#if GTKMENU_DEBUG_LOGGING
                            NSLog(@"GTKMenuImporter: Found GTK window %lu with bus=%@ path=%@", (unsigned long)window, busName, objectPath);
#endif
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
    
#if GTKMENU_DEBUG_LOGGING
    NSLog(@"GTKMenuImporter: About to close X11 display");
#endif
    XCloseDisplay(display);
#if GTKMENU_DEBUG_LOGGING
    NSLog(@"GTKMenuImporter: X11 display closed");
    
    // Only log when we find new windows or on initial scans
    if (gtkScans <= 3 || newWindows > 0) {
        NSLog(@"GTKMenuImporter: Found %lu GTK windows with menus", (unsigned long)gtkWindows);
    }
    
    NSLog(@"GTKMenuImporter: scanForExistingMenuServices COMPLETED");
#else
    (void)gtkWindows;
    (void)newWindows;
#endif
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
#if GTKMENU_DEBUG_LOGGING
    NSLog(@"GTKMenuImporter: Cleaning up GTK menu protocol handler...");
#endif
    
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
#if GTKMENU_DEBUG_LOGGING
                NSLog(@"GTKMenuImporter: Service %@ exports GTK interfaces at path %@", serviceName, path);
#endif
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
#if GTKMENU_DEBUG_LOGGING
    NSLog(@"GTKMenuImporter: Loading GTK menu from service=%@ menuPath=%@ actionPath=%@", 
          serviceName, menuPath, actionPath);
#endif
    
    // First, introspect the menu path to see what's available
    id introspectResult = [_dbusConnection callMethod:@"Introspect"
                                            onService:serviceName
                                           objectPath:menuPath
                                            interface:@"org.freedesktop.DBus.Introspectable"
                                            arguments:nil];
    
    if (!introspectResult) {
#if GTKMENU_DEBUG_LOGGING
        NSLog(@"GTKMenuImporter: Failed to introspect GTK menu service");
#endif
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
#if GTKMENU_DEBUG_LOGGING
        NSLog(@"GTKMenuImporter: Failed to get GTK menu structure via Start method");
#endif
        
        // Try alternative: GetMenus method (less common)
        menuResult = [_dbusConnection callMethod:@"GetMenus"
                                       onService:serviceName
                                      objectPath:menuPath
                                       interface:@"org.gtk.Menus"
                                       arguments:nil];
    }
    
    if (!menuResult) {
#if GTKMENU_DEBUG_LOGGING
        NSLog(@"GTKMenuImporter: No GTK menu data available");
#endif
        return nil;
    }
    
#if GTKMENU_DEBUG_LOGGING
    NSLog(@"GTKMenuImporter: GTK menu result type: %@", [menuResult class]);
    NSLog(@"GTKMenuImporter: GTK menu result: %@", menuResult);
#endif
    
    // Parse the GTK menu structure
    // The format is different from canonical dbusmenu - it's a GMenuModel serialization
    NSMenu *menu = [GTKMenuParser parseGTKMenuFromDBusResult:menuResult 
                                                 serviceName:serviceName 
                                                  actionPath:actionPath 
                                              dbusConnection:_dbusConnection];
    
    if (!menu) {
#if GTKMENU_DEBUG_LOGGING
        NSLog(@"GTKMenuImporter: Failed to parse GTK menu structure, creating placeholder");
#endif
        menu = [[NSMenu alloc] initWithTitle:@"GTK App Menu"];
        
        // Add placeholder items to indicate this is a GTK app
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"GTK Application" 
                                                      action:nil 
                                               keyEquivalent:@""];
        [item setEnabled:NO];
        [menu addItem:item];
    }
    
    return menu;
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
#if GTKMENU_DEBUG_LOGGING
        NSLog(@"GTKMenuImporter: Cannot re-register shortcuts - missing service/action path");
#endif
        return;
    }
    
    // Get fresh DBus connection for cached menu shortcut re-registration
    if (!_dbusConnection || ![_dbusConnection isConnected]) {
#if GTKMENU_DEBUG_LOGGING
        NSLog(@"GTKMenuImporter: Refreshing DBus connection for cached menu shortcuts");
#endif
        if (![self connectToDBus]) {
#if GTKMENU_DEBUG_LOGGING
            NSLog(@"GTKMenuImporter: Failed to refresh DBus connection for shortcuts");
#endif
            return;
        }
    }
    
#if GTKMENU_DEBUG_LOGGING
    NSLog(@"GTKMenuImporter: Re-registering shortcuts for GTK menu (window %lu) with fresh DBus connection", windowId);
#endif
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
                
#if GTKMENU_DEBUG_LOGGING
                NSLog(@"GTKMenuImporter: Re-registering GTK shortcut: %@ (action: %@)", [item title], actionName);
#endif
                
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
    [_registryLock lock];
    NSUInteger count = [_registeredWindows count];
    [_registryLock unlock];
    
#if GTKMENU_DEBUG_LOGGING
    NSLog(@"GTKMenuImporter: Cleanup timer - %lu GTK windows registered", 
          (unsigned long)count);
#else
    (void)count;
#endif
    
    // In a full implementation, we would check if windows still exist
    // and remove entries for windows that have been closed
}

@end
