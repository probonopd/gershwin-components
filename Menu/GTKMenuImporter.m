/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */


#import "GTKMenuImporter.h"
#import "GTKMenuParser.h"
#import "GTKSubmenuManager.h"
#import "GTKActionHandler.h"
#import "DBusConnection.h"
#import "AppMenuWidget.h"
#import "MenuUtils.h"

// X11 error handler to prevent crashes when querying invalid/stale windows
static BOOL x11_error_occurred = NO;
static int last_error_code = 0;
static unsigned long last_error_resourceid = 0;

static int x11ErrorHandler(Display *display, XErrorEvent *error) {
    char errorText[256];
    XGetErrorText(display, error->error_code, errorText, sizeof(errorText));
    
    // Set global error state
    x11_error_occurred = YES;
    last_error_code = error->error_code;
    last_error_resourceid = error->resourceid;
    
    // Log the error but don't spam the log
    static NSTimeInterval lastLogTime = 0;
    NSTimeInterval currentTime = [[NSDate date] timeIntervalSince1970];
    if (currentTime - lastLogTime > 1.0) {  // Only log once per second
        NSDebugLog(@"GTKMenuImporter: X11 Error caught (non-fatal): %s (request: %d, resource: 0x%lx)", 
              errorText, error->request_code, error->resourceid);
        lastLogTime = currentTime;
    }
    
    // Return 0 to indicate error was handled and shouldn't crash
    return 0;
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
        
        // Don't set up the cleanup timer during init - do it later when the run loop is ready
        self.cleanupTimer = nil;
        
        NSDebugLog(@"GTKMenuImporter: Initialized GTK menu protocol handler");
    }
    return self;
}

#pragma mark - MenuProtocolHandler Implementation

- (BOOL)connectToDBus
{
    NSDebugLog(@"GTKMenuImporter: Attempting to connect to DBus session bus...");
    
    self.dbusConnection = [GNUDBusConnection sessionBus];
    
    if (![self.dbusConnection isConnected]) {
        NSDebugLog(@"GTKMenuImporter: Failed to get DBus connection");
        return NO;
    }
    
    NSDebugLog(@"GTKMenuImporter: Successfully connected to DBus session bus");
    
    // Now that we're connected and the run loop is running, set up the cleanup timer
    if (!self.cleanupTimer) {
        NSDebugLog(@"GTKMenuImporter: Setting up cleanup timer...");
        self.cleanupTimer = [NSTimer scheduledTimerWithTimeInterval:30.0
                                                        target:self
                                                      selector:@selector(cleanupStaleEntries:)
                                                      userInfo:nil
                                                       repeats:YES];
        NSDebugLog(@"GTKMenuImporter: Cleanup timer scheduled");
    }
    
    NSDebugLog(@"GTKMenuImporter: About to call scanForExistingMenuServices");
    [self scanForExistingMenuServices];
    NSDebugLog(@"GTKMenuImporter: Finished calling scanForExistingMenuServices");
    
    // Note: GTK applications don't require us to register as a specific service
    // They expose their menus directly via org.gtk.Menus and org.gtk.Actions
    
    return YES;
}

- (BOOL)registerService
{
    // GTK protocol doesn't register a central service - each app exposes its own
    // So this is a no-op for GTK importer
    NSDebugLog(@"GTKMenuImporter: registerService called (no-op for GTK protocol)");
    return YES;
}

- (BOOL)hasMenuForWindow:(unsigned long)windowId
{
    NSNumber *windowKey = [NSNumber numberWithUnsignedLong:windowId];
    
    // Check if we have this window registered
    NSString *serviceName = [_registeredWindows objectForKey:windowKey];
    if (serviceName) {
        /* Validate against the window's current GTK bus name: a relaunched app
           reuses the X window ID but gets a new bus name, so the old mapping is
           stale and must be re-scanned (not blindly trusted). */
        NSString *currentBus = [self gtkBusNameForWindow:windowId];
        if (currentBus && ![currentBus isEqualToString:serviceName]) {
            [_registeredWindows removeObjectForKey:windowKey];
            [_windowMenuPaths removeObjectForKey:windowKey];
            [_windowActionPaths removeObjectForKey:windowKey];
            [_menuCache removeObjectForKey:windowKey];
            serviceName = nil;
        }
    }
    if (serviceName) {
        return YES;
    }
    
    // Check cache
    if ([_menuCache objectForKey:windowKey]) {
        return YES;
    }

    // Try immediate scan for this specific window if not locally registered
    // This handles race conditions where the window appears before we've had a chance to scan it
    [self scanSpecificWindow:windowId];
    
    // Check if we have this window registered now after the scan
    serviceName = [_registeredWindows objectForKey:windowKey];
    if (serviceName) {
        return YES;
    }
    
    return NO;
}

/* Read the window's current _GTK_UNIQUE_BUS_NAME property, or nil if absent.
 * GTK apps set this on the window when they register their menu; on app
 * relaunch the window ID is reused but the bus name changes, which is how we
 * detect that a cached menu belongs to a dead process. */
- (NSString *)gtkBusNameForWindow:(unsigned long)windowId
{
    Display *display = [MenuUtils sharedDisplay];
    if (!display) return nil;

    XErrorHandler oldHandler = XSetErrorHandler(x11ErrorHandler);
    x11_error_occurred = NO;

    Window window = (Window)windowId;
    XWindowAttributes attrs;
    if (XGetWindowAttributes(display, window, &attrs) == 0 || x11_error_occurred) {
        XSetErrorHandler(oldHandler);
        return nil;
    }

    Atom busNameAtom = XInternAtom(display, "_GTK_UNIQUE_BUS_NAME", False);
    Atom propType;
    int propFormat;
    unsigned long propItems, propBytesAfter;
    unsigned char *prop = NULL;
    int result = XGetWindowProperty(display, window, busNameAtom, 0, 1024, False,
                                    AnyPropertyType, &propType, &propFormat,
                                    &propItems, &propBytesAfter, &prop);
    NSString *name = nil;
    if (result == Success && prop != NULL) {
        name = [NSString stringWithUTF8String:(const char *)prop];
        XFree(prop);
    }
    XSetErrorHandler(oldHandler);
    return name;
}

- (NSMenu *)getMenuForWindow:(unsigned long)windowId
{
    NSNumber *windowKey = [NSNumber numberWithUnsignedLong:windowId];
    
    NSDebugLog(@"GTKMenuImporter: Getting GTK menu for window %lu", windowId);
    
    // Get the currently registered service name for this window FIRST
    // This is critical for validating cached menus
    NSString *serviceName = [_registeredWindows objectForKey:windowKey];
    NSString *menuPath = [_windowMenuPaths objectForKey:windowKey];
    NSString *actionPath = [_windowActionPaths objectForKey:windowKey];
    
    // Check for cached menu
    NSMenu *legacyCachedMenu = [_menuCache objectForKey:windowKey];
    if (legacyCachedMenu) {
        /* Validate the cache against the window's CURRENT GTK bus name before
           returning it.  X reuses window IDs across app relaunches: a
           relaunched GTK app's window carries a new _GTK_UNIQUE_BUS_NAME, so a
           cached menu bound to the old (now dead) service must be discarded and
           rebuilt, otherwise the menu shows but every action targets a dead
           process. */
        NSString *currentBus = [self gtkBusNameForWindow:windowId];
        if (serviceName && currentBus && ![currentBus isEqualToString:serviceName]) {
            NSDebugLog(@"GTKMenuImporter: Cached menu stale (service %@ -> %@), re-scanning window %lu",
                  serviceName, currentBus, windowId);
            [_menuCache removeObjectForKey:windowKey];
            [_registeredWindows removeObjectForKey:windowKey];
            [_windowMenuPaths removeObjectForKey:windowKey];
            [_windowActionPaths removeObjectForKey:windowKey];
            legacyCachedMenu = nil;
            [self scanSpecificWindow:windowId];
            serviceName = [_registeredWindows objectForKey:windowKey];
            menuPath = [_windowMenuPaths objectForKey:windowKey];
            actionPath = [_windowActionPaths objectForKey:windowKey];
        }
    }
    if (legacyCachedMenu) {
        NSDebugLog(@"GTKMenuImporter: Returning cached GTK menu for window %lu", windowId);
        
        // Re-register shortcuts for cached menu since they may have been unregistered
        // when the window lost focus
        [self reregisterShortcutsForMenu:legacyCachedMenu windowId:windowId];
        
        return legacyCachedMenu;
    }
    if (!serviceName || !menuPath) {
        // Try immediate scan for this specific window before giving up
        NSDebugLog(@"GTKMenuImporter: No service/menu path found for window %lu, trying immediate scan", windowId);
        [self scanSpecificWindow:windowId];
        
        // Check again after immediate scan
        serviceName = [_registeredWindows objectForKey:windowKey];
        menuPath = [_windowMenuPaths objectForKey:windowKey];
        actionPath = [_windowActionPaths objectForKey:windowKey];
        
        if (!serviceName || !menuPath) {
            NSDebugLog(@"GTKMenuImporter: Still no service/menu path found for window %lu after immediate scan", windowId);
            return nil;
        }
    }
    
    NSDebugLog(@"GTKMenuImporter: Loading GTK menu for window %lu from %@%@ (actions: %@)", 
          windowId, serviceName, menuPath, actionPath ?: @"none");
    
    // Load the menu using GTK protocol
    NSMenu *menu = [self loadGTKMenuFromDBus:serviceName menuPath:menuPath actionPath:actionPath];
    if (menu) {
        NSDebugLog(@"GTKMenuImporter: Successfully loaded GTK menu with %lu items", 
              (unsigned long)[[menu itemArray] count]);
        // Cache the successfully loaded menu to avoid expensive re-parsing on window re-focus
        [_menuCache setObject:menu forKey:windowKey];
    } else {
        NSDebugLog(@"GTKMenuImporter: Failed to load GTK menu for window %lu", windowId);
    }
    
    return menu;
}

- (void)activateMenuItem:(NSMenuItem *)menuItem forWindow:(unsigned long)windowId
{
    NSDebugLog(@"GTKMenuImporter: Activating GTK menu item '%@' for window %lu", [menuItem title], windowId);
    
    NSNumber *windowKey = [NSNumber numberWithUnsignedLong:windowId];
    NSString *serviceName = [_registeredWindows objectForKey:windowKey];
    NSString *actionPath = [_windowActionPaths objectForKey:windowKey];
    
    if (!serviceName || !actionPath) {
        NSDebugLog(@"GTKMenuImporter: No service/action path found for window %lu", windowId);
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
        NSDebugLog(@"GTKMenuImporter: No action name found for menu item '%@'", [menuItem title]);
        return;
    }
    
    NSDebugLog(@"GTKMenuImporter: Activating GTK action '%@' via %@%@", actionName, serviceName, actionPath);
    
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
        NSDebugLog(@"GTKMenuImporter: GTK action activation succeeded, result: %@", result);
    } else {
        NSDebugLog(@"GTKMenuImporter: GTK action activation failed");
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
    
    NSDebugLog(@"GTKMenuImporter: Registered GTK window %lu with service=%@ menuPath=%@ actionPath=%@", 
          windowId, serviceName, objectPath, actionPath);
}

- (void)unregisterWindow:(unsigned long)windowId
{
    NSNumber *windowKey = [NSNumber numberWithUnsignedLong:windowId];
    
    // Get the service name before removing to clean up related delegates
    NSString *serviceName = [[_registeredWindows objectForKey:windowKey] copy];
    
    [_registeredWindows removeObjectForKey:windowKey];
    [_windowMenuPaths removeObjectForKey:windowKey];
    [_windowActionPaths removeObjectForKey:windowKey];
    [_menuCache removeObjectForKey:windowKey];
    [_actionGroupCache removeObjectForKey:windowKey];
    
    // Clean up submenu delegates associated with this service to prevent
    // crashes when trying to use stale DBus connections
    if (serviceName) {
        [GTKSubmenuManager cleanupDelegatesForService:serviceName];
    }
    
    NSDebugLog(@"GTKMenuImporter: Unregistered GTK window %lu", windowId);

    if (self.appMenuWidget && self.appMenuWidget.currentWindowId == windowId) {
        NSDebugLog(@"GTKMenuImporter: Current menu window %lu unregistered - refreshing menu", windowId);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.appMenuWidget updateForActiveWindow];
        });
    }
}

- (void)scanSpecificWindow:(unsigned long)windowId
{
    NSDebugLog(@"GTKMenuImporter: Performing immediate scan for window %lu", windowId);
    
    Display *display = [MenuUtils sharedDisplay];
    if (!display) {
        NSDebugLog(@"GTKMenuImporter: Cannot open X11 display for immediate window scan");
        return;
    }
    
    // DEFENSIVE: Install X11 error handler to catch errors from invalid windows
    XErrorHandler oldHandler = XSetErrorHandler(x11ErrorHandler);
    // DO NOT use XSynchronize - it causes blocking delays
    
    Window window = (Window)windowId;
    
    // DEFENSIVE: Verify window is valid before querying properties
    x11_error_occurred = NO;  // Reset error state before checking
    XWindowAttributes attrs;
    if (XGetWindowAttributes(display, window, &attrs) == 0 || x11_error_occurred) {
        static unsigned long lastLogWindow = 0;
        if (lastLogWindow != windowId) {
             NSDebugLLog(@"gwcomp", @"GTKMenuImporter: Window %lu not ready/valid%s in immediate scan, skipping", 
              windowId, x11_error_occurred ? " (X11 error)" : "");
             lastLogWindow = windowId;
        }
        XSetErrorHandler(oldHandler);
        return;
    }
    
    // Create atoms for GTK menu properties
    Atom busNameAtom = XInternAtom(display, "_GTK_UNIQUE_BUS_NAME", False);
    Atom objectPathAtom = XInternAtom(display, "_GTK_MENUBAR_OBJECT_PATH", False);
    
    unsigned char *busNameProp = NULL;
    unsigned char *objectPathProp = NULL;
    BOOL busNameSuccess = NO;
    BOOL objectPathSuccess = NO;
    
    // Get bus name property
    Atom propType;
    int propFormat;
    unsigned long propItems, propBytesAfter;
    
    // DEFENSIVE: Reset property pointer before X11 call
    busNameProp = NULL;
    int busResult = XGetWindowProperty(display, window, busNameAtom, 0, 1024, False, AnyPropertyType,
                          &propType, &propFormat, &propItems, &propBytesAfter, &busNameProp);
    if (busResult == Success && busNameProp != NULL) {
        busNameSuccess = YES;
        
        NSDebugLog(@"GTKMenuImporter: Window %lu has _GTK_UNIQUE_BUS_NAME: %s", windowId, busNameProp);
        
        // Get object path property
        // DEFENSIVE: Reset property pointer before X11 call
        objectPathProp = NULL;
        int pathResult = XGetWindowProperty(display, window, objectPathAtom, 0, 1024, False, AnyPropertyType,
                              &propType, &propFormat, &propItems, &propBytesAfter, &objectPathProp);
        if (pathResult == Success && objectPathProp != NULL) {
            objectPathSuccess = YES;
            
            NSDebugLog(@"GTKMenuImporter: Window %lu has _GTK_MENUBAR_OBJECT_PATH: %s", windowId, objectPathProp);
            
            NSString *busName = [NSString stringWithUTF8String:(char *)busNameProp];
            NSString *objectPath = [NSString stringWithUTF8String:(char *)objectPathProp];
            
            NSDebugLog(@"GTKMenuImporter: Immediate scan found GTK window %lu with bus=%@ path=%@", windowId, busName, objectPath);
            
            // Register this window immediately
            [self registerWindow:windowId serviceName:busName objectPath:objectPath];
        } else {
            NSDebugLog(@"GTKMenuImporter: Window %lu has bus name but no object path", windowId);
        }
    } else {
        // Log this clearly so we know why GTK import for GIMP etc might fail
        static unsigned long lastLogWindow = 0;
        if (lastLogWindow != windowId) {
             NSDebugLLog(@"gwcomp", @"GTKMenuImporter: Window %lu has no GTK menu properties (bus/path missing)", windowId);
             lastLogWindow = windowId;
        }
    }
    
    // DEFENSIVE: Only free if the properties were successfully retrieved
    if (objectPathSuccess && objectPathProp != NULL) {
        XFree(objectPathProp);
        objectPathProp = NULL;
    }
    
    if (busNameSuccess && busNameProp != NULL) {
        XFree(busNameProp);
        busNameProp = NULL;
    }
    
    // Restore error handler
    XSetErrorHandler(oldHandler);
}

- (void)scanForExistingMenuServices
{
    NSDebugLog(@"GTKMenuImporter: scanForExistingMenuServices STARTED");
    
    static int gtkScans = 0;
    gtkScans++;
    
    // Only log occasionally to avoid spam
    if (gtkScans % 20 == 1 || gtkScans <= 2) {
        NSDebugLog(@"GTKMenuImporter: Scanning for existing GTK menu services... (scan #%d)", gtkScans);
    }
    
    // GTK applications set X11 properties when they export menus
    // Use a more comprehensive scanning approach
    NSDebugLog(@"GTKMenuImporter: About to open X11 display");
    Display *display = [MenuUtils sharedDisplay];
    if (!display) {
        if (gtkScans <= 2) {
            NSDebugLog(@"GTKMenuImporter: Cannot open X11 display for scanning");
        }
        NSDebugLog(@"GTKMenuImporter: scanForExistingMenuServices FAILED (no display)");
        return;
    }
    NSDebugLog(@"GTKMenuImporter: X11 display opened successfully");
    
    // DEFENSIVE: Install X11 error handler to catch errors from invalid windows
    XErrorHandler oldHandler = XSetErrorHandler(x11ErrorHandler);
    // DO NOT use XSynchronize(display, True) - it causes 15 second blocking delays!
    // Asynchronous mode is fine with proper error handling
    
    NSUInteger gtkWindows = 0;
    NSUInteger newWindows = 0;
    
    // Create atoms once for efficiency
    NSDebugLog(@"GTKMenuImporter: Creating X11 atoms");
    Atom busNameAtom = XInternAtom(display, "_GTK_UNIQUE_BUS_NAME", False);
    Atom objectPathAtom = XInternAtom(display, "_GTK_MENUBAR_OBJECT_PATH", False);
    NSDebugLog(@"GTKMenuImporter: X11 atoms created");
    
    // Get all windows on the display using _NET_CLIENT_LIST
    NSDebugLog(@"GTKMenuImporter: Getting root window");
    Window root = DefaultRootWindow(display);
    Atom clientListAtom = XInternAtom(display, "_NET_CLIENT_LIST", False);
    NSDebugLog(@"GTKMenuImporter: About to query window property");
    
    Atom actualType;
    int actualFormat;
    unsigned long numClientWindows, bytesAfter;
    Window *clientWindows = NULL;
    
    if (XGetWindowProperty(display, root, clientListAtom, 0, 1024, False, XA_WINDOW,
                          &actualType, &actualFormat, &numClientWindows, &bytesAfter,
                          (unsigned char**)&clientWindows) == Success && clientWindows) {
        
        NSDebugLog(@"GTKMenuImporter: Successfully got client window list");
        if (gtkScans <= 2) {
            NSDebugLog(@"GTKMenuImporter: Found %lu client windows to scan", numClientWindows);
        }
        
        NSDebugLog(@"GTKMenuImporter: About to iterate through %lu client windows", numClientWindows);
        for (unsigned long i = 0; i < numClientWindows; i++) {
            if (i % 100 == 0 && i > 0) {
                NSDebugLog(@"GTKMenuImporter: Processed %lu of %lu windows", i, numClientWindows);
            }
            
            Window window = clientWindows[i];
            
            // Debug: log the window ID we're checking (only for first few scans)
            if (gtkScans <= 2) {
                NSDebugLog(@"GTKMenuImporter: Checking client window %lu (0x%lx)", (unsigned long)window, (unsigned long)window);
            }
            
            // DEFENSIVE: Verify window is valid before querying properties
            // This prevents interfering with windows that are still initializing
            x11_error_occurred = NO;  // Reset error state before checking
            XWindowAttributes attrs;
            if (XGetWindowAttributes(display, window, &attrs) == 0 || x11_error_occurred) {
                // Window is not valid/ready or caused an X11 error, skip it
                if (gtkScans <= 2) {
                    NSDebugLog(@"GTKMenuImporter: Window %lu not ready/valid%s, skipping", 
                          (unsigned long)window, x11_error_occurred ? " (X11 error)" : "");
                }
                x11_error_occurred = NO;  // Reset for next window
                continue;
            }
            
            // Check this window for GTK menu properties
            unsigned char *busNameProp = NULL;
            unsigned char *objectPathProp = NULL;
            BOOL busNameSuccess = NO;
            BOOL objectPathSuccess = NO;
            
            // Get bus name property (use separate variables to avoid overwriting numClientWindows)
            Atom propType;
            int propFormat;
            unsigned long propItems, propBytesAfter;
            
            // DEFENSIVE: Reset property pointer before X11 call
            busNameProp = NULL;
            x11_error_occurred = NO;  // Reset error state before call
            NSDebugLog(@"GTKMenuImporter: DEFENSIVE: property pointer initialized to NULL for busName scan");
            int busResult = XGetWindowProperty(display, window, busNameAtom, 0, 1024, False, AnyPropertyType,
                                  &propType, &propFormat, &propItems, &propBytesAfter, &busNameProp);
            if (busResult == Success && busNameProp != NULL && !x11_error_occurred) {
                busNameSuccess = YES;
                NSDebugLog(@"GTKMenuImporter: DEFENSIVE: success flag set for busName property retrieval");
                
                if (gtkScans <= 2) {
                    NSDebugLog(@"GTKMenuImporter: Window %lu has _GTK_UNIQUE_BUS_NAME: %s", (unsigned long)window, busNameProp);
                }
                
                // Get object path property
                // DEFENSIVE: Reset property pointer before X11 call
                objectPathProp = NULL;
                x11_error_occurred = NO;  // Reset error state before call
                NSDebugLog(@"GTKMenuImporter: DEFENSIVE: property pointer initialized to NULL for objectPath scan");
                int pathResult = XGetWindowProperty(display, window, objectPathAtom, 0, 1024, False, AnyPropertyType,
                                      &propType, &propFormat, &propItems, &propBytesAfter, &objectPathProp);
                if (pathResult == Success && objectPathProp != NULL && !x11_error_occurred) {
                    objectPathSuccess = YES;
                    NSDebugLog(@"GTKMenuImporter: DEFENSIVE: success flag set for objectPath property retrieval");
                    
                    if (gtkScans <= 2) {
                        NSDebugLog(@"GTKMenuImporter: Window %lu has _GTK_MENUBAR_OBJECT_PATH: %s", (unsigned long)window, objectPathProp);
                    }
                    
                    NSString *busName = [NSString stringWithUTF8String:(char *)busNameProp];
                    NSString *objectPath = [NSString stringWithUTF8String:(char *)objectPathProp];
                    
                    // Check if this is a new window
                    NSNumber *windowKey = [NSNumber numberWithUnsignedLong:(unsigned long)window];
                    if (![_registeredWindows objectForKey:windowKey]) {
                        NSDebugLog(@"GTKMenuImporter: Found GTK window %lu with bus=%@ path=%@", (unsigned long)window, busName, objectPath);
                        newWindows++;
                    } else {
                        // Only log this on first few scans to show what we have
                        if (gtkScans <= 2) {
                            NSDebugLog(@"GTKMenuImporter: Registered GTK window %lu with service=%@ menuPath=%@ actionPath=%@", 
                                  (unsigned long)window, busName, objectPath, objectPath);
                        }
                    }
                    
                    // Register this window
                    [self registerWindow:(unsigned long)window serviceName:busName objectPath:objectPath];
                    gtkWindows++;
                }
                
                // DEFENSIVE: Only free if the property was successfully retrieved
                if (objectPathSuccess && objectPathProp != NULL) {
                    NSDebugLog(@"GTKMenuImporter: DEFENSIVE: freeing objectPath property safely");
                    XFree(objectPathProp);
                    objectPathProp = NULL;
                }
            }
            
            // DEFENSIVE: Only free if the property was successfully retrieved
            if (busNameSuccess && busNameProp != NULL) {
                NSDebugLog(@"GTKMenuImporter: DEFENSIVE: freeing busName property safely");
                XFree(busNameProp);
                busNameProp = NULL;
            }
        }
        XFree(clientWindows);
        NSDebugLog(@"GTKMenuImporter: Finished processing client windows, freed memory");
    } else {
        // Fallback to root window children if _NET_CLIENT_LIST is not available
        NSDebugLog(@"GTKMenuImporter: Client list query failed, using fallback method");
        if (gtkScans <= 2) {
            NSDebugLog(@"GTKMenuImporter: _NET_CLIENT_LIST not available, falling back to root children");
        }
        
        Window parent, *children;
        unsigned int numChildren;
        
        if (XQueryTree(display, root, &root, &parent, &children, &numChildren) == Success && children) {
            for (unsigned int i = 0; i < numChildren; i++) {
                Window window = children[i];
                
                // Check for GTK menu properties
                unsigned char *busNameProp = NULL;
                unsigned char *objectPathProp = NULL;
                BOOL busNameSuccess = NO;
                BOOL objectPathSuccess = NO;
                
                // Get bus name property (use separate variables)
                Atom propType;
                int propFormat;
                unsigned long propItems, propBytesAfter;
                
                // DEFENSIVE: Reset property pointer before X11 call
                busNameProp = NULL;
                int busResult = XGetWindowProperty(display, window, busNameAtom, 0, 1024, False, AnyPropertyType,
                                      &propType, &propFormat, &propItems, &propBytesAfter, &busNameProp);
                if (busResult == Success && busNameProp != NULL) {
                    busNameSuccess = YES;
                    
                    // Get object path property
                    // DEFENSIVE: Reset property pointer before X11 call
                    objectPathProp = NULL;
                    int pathResult = XGetWindowProperty(display, window, objectPathAtom, 0, 1024, False, AnyPropertyType,
                                          &propType, &propFormat, &propItems, &propBytesAfter, &objectPathProp);
                    if (pathResult == Success && objectPathProp != NULL) {
                        objectPathSuccess = YES;
                        
                        NSString *busName = [NSString stringWithUTF8String:(char *)busNameProp];
                        NSString *objectPath = [NSString stringWithUTF8String:(char *)objectPathProp];
                        
                        // Check if this is a new window
                        NSNumber *windowKey = [NSNumber numberWithUnsignedLong:(unsigned long)window];
                        if (![_registeredWindows objectForKey:windowKey]) {
                            NSDebugLog(@"GTKMenuImporter: Found GTK window %lu with bus=%@ path=%@", (unsigned long)window, busName, objectPath);
                            newWindows++;
                        }
                        
                        // Register this window
                        [self registerWindow:(unsigned long)window serviceName:busName objectPath:objectPath];
                        gtkWindows++;
                    }
                    
                    // DEFENSIVE: Only free if the property was successfully retrieved
                    if (objectPathSuccess && objectPathProp != NULL) {
                        XFree(objectPathProp);
                        objectPathProp = NULL;
                    }
                }
                
                // DEFENSIVE: Only free if the property was successfully retrieved
                if (busNameSuccess && busNameProp != NULL) {
                    XFree(busNameProp);
                    busNameProp = NULL;
                }
            }
            XFree(children);
        }
    }
    
    // Restore error handler
    XSetErrorHandler(oldHandler);
    
    // Only log when we find new windows or on initial scans
    if (gtkScans <= 3 || newWindows > 0) {
        NSDebugLog(@"GTKMenuImporter: Found %lu GTK windows with menus", (unsigned long)gtkWindows);
    }
    
    NSDebugLog(@"GTKMenuImporter: scanForExistingMenuServices COMPLETED");
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
    NSDebugLog(@"GTKMenuImporter: Cleaning up GTK menu protocol handler...");
    
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
                NSDebugLog(@"GTKMenuImporter: Service %@ exports GTK interfaces at path %@", serviceName, path);
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
    NSDebugLog(@"GTKMenuImporter: Loading GTK menu from service=%@ menuPath=%@ actionPath=%@", 
          serviceName, menuPath, actionPath);
    
    // First, introspect the menu path to see what's available
    id introspectResult = [_dbusConnection callMethod:@"Introspect"
                                            onService:serviceName
                                           objectPath:menuPath
                                            interface:@"org.freedesktop.DBus.Introspectable"
                                            arguments:nil];
    
    if (!introspectResult) {
        NSDebugLog(@"GTKMenuImporter: Failed to introspect GTK menu service");
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
        NSDebugLog(@"GTKMenuImporter: Failed to get GTK menu structure via Start method");
        
        // Try alternative: GetMenus method (less common)
        menuResult = [_dbusConnection callMethod:@"GetMenus"
                                       onService:serviceName
                                      objectPath:menuPath
                                       interface:@"org.gtk.Menus"
                                       arguments:nil];
    }
    
    if (!menuResult) {
        NSDebugLog(@"GTKMenuImporter: No GTK menu data available");
        return nil;
    }
    
    NSDebugLog(@"GTKMenuImporter: GTK menu result type: %@", [menuResult class]);
    NSDebugLog(@"GTKMenuImporter: GTK menu result: %@", menuResult);
    
    // Parse the GTK menu structure
    // The format is different from canonical dbusmenu - it's a GMenuModel serialization
    NSMenu *menu = [GTKMenuParser parseGTKMenuFromDBusResult:menuResult 
                                                 serviceName:serviceName 
                                                  actionPath:actionPath 
                                              dbusConnection:_dbusConnection];
    
    if (!menu) {
        NSDebugLog(@"GTKMenuImporter: Failed to parse GTK menu structure, creating placeholder");
        menu = [[NSMenu alloc] initWithTitle:@"GTK App Menu"];
        [menu setAutoenablesItems:NO];
        
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
        NSDebugLog(@"GTKMenuImporter: Cannot re-register shortcuts - missing service/action path");
        return;
    }
    
    // Get fresh DBus connection for cached menu shortcut re-registration
    if (!_dbusConnection || ![_dbusConnection isConnected]) {
        NSDebugLog(@"GTKMenuImporter: Refreshing DBus connection for cached menu shortcuts");
        if (![self connectToDBus]) {
            NSDebugLog(@"GTKMenuImporter: Failed to refresh DBus connection for shortcuts");
            return;
        }
    }
    
    NSDebugLog(@"GTKMenuImporter: Re-registering shortcuts for GTK menu (window %lu) with fresh DBus connection", windowId);
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
                
                NSDebugLog(@"GTKMenuImporter: Re-registering GTK shortcut: %@ (action: %@)", [item title], actionName);
                
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
    NSDebugLog(@"GTKMenuImporter: Cleanup timer - %lu GTK windows registered", 
          (unsigned long)[_registeredWindows count]);
    
    // In a full implementation, we would check if windows still exist
    // and remove entries for windows that have been closed
}

@end
