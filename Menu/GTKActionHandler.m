#import "GTKActionHandler.h"
#import "DBusConnection.h"

// Static storage for GTK action information
static NSMutableDictionary *gtkMenuItemToActionMap = nil;
static NSMutableDictionary *gtkMenuItemToServiceMap = nil;
static NSMutableDictionary *gtkMenuItemToActionPathMap = nil;
static NSMutableDictionary *gtkMenuItemToConnectionMap = nil;

@implementation GTKActionHandler

+ (void)initialize
{
    if (self == [GTKActionHandler class]) {
        gtkMenuItemToActionMap = [[NSMutableDictionary alloc] init];
        gtkMenuItemToServiceMap = [[NSMutableDictionary alloc] init];
        gtkMenuItemToActionPathMap = [[NSMutableDictionary alloc] init];
        gtkMenuItemToConnectionMap = [[NSMutableDictionary alloc] init];
        
        NSLog(@"GTKActionHandler: Initialized GTK action handler");
    }
}

+ (void)setupActionForMenuItem:(NSMenuItem *)menuItem
                    actionName:(NSString *)actionName
                   serviceName:(NSString *)serviceName
                    actionPath:(NSString *)actionPath
                dbusConnection:(GNUDBusConnection *)dbusConnection
{
    if (!menuItem || !actionName || !serviceName || !actionPath || !dbusConnection) {
        NSLog(@"GTKActionHandler: ERROR: Missing required parameters for GTK action setup");
        return;
    }
    
    [menuItem setTarget:[GTKActionHandler class]];
    [menuItem setAction:@selector(gtkMenuItemAction:)];
    
    // Store GTK action information for this menu item using a stable key
    // Use both title and action name to create a unique identifier
    NSString *menuItemKey = [NSString stringWithFormat:@"%@|%@", [menuItem title], actionName];
    [gtkMenuItemToActionMap setObject:actionName forKey:menuItemKey];
    [gtkMenuItemToServiceMap setObject:serviceName forKey:menuItemKey];
    [gtkMenuItemToActionPathMap setObject:actionPath forKey:menuItemKey];
    [gtkMenuItemToConnectionMap setObject:dbusConnection forKey:menuItemKey];
    
    NSLog(@"GTKActionHandler: Set up GTK action for menu item '%@' (action=%@, service=%@, path=%@)", 
          [menuItem title], actionName, serviceName, actionPath);
    
    // Query initial action state for stateful actions
    NSDictionary *actionState = [self getActionState:actionName 
                                         serviceName:serviceName 
                                          actionPath:actionPath 
                                      dbusConnection:dbusConnection];
    
    if (actionState) {
        NSNumber *enabled = [actionState objectForKey:@"enabled"];
        if (enabled) {
            [menuItem setEnabled:[enabled boolValue]];
            NSLog(@"GTKActionHandler: Set initial enabled state to %@", enabled);
        }
        
        // Handle toggle/checkbox state for stateful actions
        id state = [actionState objectForKey:@"state"];
        if (state && [state isKindOfClass:[NSNumber class]]) {
            NSNumber *stateNum = (NSNumber *)state;
            [menuItem setState:[stateNum boolValue] ? NSOnState : NSOffState];
            NSLog(@"GTKActionHandler: Set initial toggle state to %@", stateNum);
        }
    }
}

// Legacy method for compatibility with old code
+ (void)setupActionForMenuItem:(NSMenuItem *)menuItem
{
    NSLog(@"GTKActionHandler: Set up GTK action for menu item '%@' (action=unity.-Quit, service=:1.63, path=/org/appmenu/gtk/window/0)", 
          [menuItem title]);
    
    // This method is called by old code that doesn't pass all parameters
    // We need to find a way to get the connection info
    // For now, set up basic click handler
    [menuItem setTarget:[GTKActionHandler class]];
    [menuItem setAction:@selector(gtkMenuItemAction:)];
}

+ (void)gtkMenuItemAction:(id)sender
{
    NSMenuItem *menuItem = (NSMenuItem *)sender;
    
    NSLog(@"GTKActionHandler: Menu item action triggered for '%@'", [menuItem title]);
    
    // Try to find the action by searching through stored actions
    NSString *actionName = nil;
    NSString *serviceName = nil;
    NSString *actionPath = nil;
    GNUDBusConnection *dbusConnection = nil;
    
    // Search through all stored actions to find one that matches this menu item
    for (NSString *key in [gtkMenuItemToActionMap allKeys]) {
        NSArray *keyParts = [key componentsSeparatedByString:@"|"];
        if ([keyParts count] == 2) {
            NSString *storedTitle = [keyParts objectAtIndex:0];
            
            // Match by title (remove underscore accelerators for comparison)
            NSString *cleanMenuTitle = [[menuItem title] stringByReplacingOccurrencesOfString:@"_" withString:@""];
            NSString *cleanStoredTitle = [storedTitle stringByReplacingOccurrencesOfString:@"_" withString:@""];
            
            if ([cleanMenuTitle isEqualToString:cleanStoredTitle]) {
                actionName = [gtkMenuItemToActionMap objectForKey:key];
                serviceName = [gtkMenuItemToServiceMap objectForKey:key];
                actionPath = [gtkMenuItemToActionPathMap objectForKey:key];
                dbusConnection = [gtkMenuItemToConnectionMap objectForKey:key];
                NSLog(@"GTKActionHandler: Found matching action '%@' for menu item '%@'", actionName, [menuItem title]);
                break;
            }
        }
    }
    
    if (!actionName || !serviceName || !actionPath || !dbusConnection) {
        NSLog(@"GTKActionHandler: ERROR: Missing GTK action info for menu item '%@'", [menuItem title]);
        NSLog(@"GTKActionHandler: actionName=%@, serviceName=%@, actionPath=%@, dbusConnection=%@", 
              actionName, serviceName, actionPath, dbusConnection);
        
        // Debug: show all stored keys
        NSLog(@"GTKActionHandler: Available stored keys: %@", [gtkMenuItemToActionMap allKeys]);
        return;
    }
    
    NSLog(@"GTKActionHandler: Triggering GTK action '%@' for menu item '%@' (service=%@, path=%@)", 
          actionName, [menuItem title], serviceName, actionPath);
    
    // Strip "unity." prefix from action name for actual D-Bus call
    // The menu contains "unity.-Quit" but the actual action is "-Quit"
    NSString *actualActionName = actionName;
    if ([actionName hasPrefix:@"unity."]) {
        actualActionName = [actionName substringFromIndex:6]; // Remove "unity." prefix
        NSLog(@"GTKActionHandler: Stripped unity prefix: '%@' -> '%@'", actionName, actualActionName);
    }
    
    // Check if this is Unity protocol (protocol 0) vs GTK protocol (protocol 1)
    // Even if the action name has "unity." prefix, modern applications like leafpad
    // still use GTK Actions interface, NOT the Unity Event interface
    BOOL isUnityProtocol = [actionPath containsString:@"/com/canonical/dbusmenu"] && ![actionPath containsString:@"/org/appmenu/gtk"];
    
    if (isUnityProtocol) {
        // True Unity protocol - use Event method on com.canonical.dbusmenu
        NSLog(@"GTKActionHandler: Calling Unity Event method for action: %@", actualActionName);
        
        // Unity actions are triggered by sending "clicked" events to menu items
        // The actualActionName should be the menu item ID (negative integer)
        NSInteger menuItemId = [actualActionName integerValue];
        
        id result = [dbusConnection callMethod:@"Event"
                                     onService:serviceName
                                    objectPath:@"/com/canonical/dbusmenu"
                                     interface:@"com.canonical.dbusmenu"
                                     arguments:@[@(menuItemId),     // menu item id
                                               @"clicked",         // event type
                                               @{},               // empty data dictionary
                                               @((NSUInteger)time(NULL))]]; // timestamp
        
        if (result) {
            NSLog(@"GTKActionHandler: Unity Event activation succeeded, result: %@", result);
        } else {
            NSLog(@"GTKActionHandler: Unity Event activation failed");
        }
        return;
    }
    
    // GTK protocol handling (this includes leafpad which has "unity." action names but uses GTK Actions interface)
    
    // Determine the correct action path based on the service
    NSString *actualActionPath = actionPath;
    
    // Check if this is a gedit-style service (different path structure)
    if ([serviceName hasPrefix:@":1."] && [actionPath containsString:@"/org/gnome/gedit/menus/menubar"]) {
        // For gedit, actions are handled on different paths depending on action scope
        if ([actualActionName hasPrefix:@"app."]) {
            // App-scoped actions (like app.quit, app.about) go to the application path
            actualActionPath = @"/org/gnome/gedit";
            // Strip the "app." prefix since gedit registers actions without prefixes
            actualActionName = [actualActionName substringFromIndex:4]; // Remove "app." prefix
            NSLog(@"GTKActionHandler: Using gedit application path for app action: %@ (stripped to: %@)", actualActionPath, actualActionName);
        } else if ([actualActionName hasPrefix:@"win."]) {
            // Window-scoped actions go to the window path
            actualActionPath = @"/org/gnome/gedit/window/1";
            // Strip the "win." prefix since gedit registers actions without prefixes
            actualActionName = [actualActionName substringFromIndex:4]; // Remove "win." prefix
            NSLog(@"GTKActionHandler: Using gedit window path for win action: %@ (stripped to: %@)", actualActionPath, actualActionName);
        } else {
            // Other actions, try the window path first
            actualActionPath = @"/org/gnome/gedit/window/1";
            NSLog(@"GTKActionHandler: Using gedit window path for other action: %@", actualActionPath);
        }
    }
    
    // Prepare platform data (for focus/activation context)
    NSMutableDictionary *platformData = [NSMutableDictionary dictionary];
    [platformData setObject:@"" forKey:@"desktop-startup-id"]; // Empty string, not number
    
    // For most actions, use empty parameter list (no variants)
    NSArray *parameter = [NSArray array]; // Empty variant array for parameterless actions
    
    // Only add parameters for stateful actions (checkboxes/radio buttons)
    // Most menu actions like "Quit", "About", etc. should have no parameters
    if ([menuItem state] != NSMixedState && 
        ([actualActionName containsString:@"toggle"] || [actualActionName containsString:@"check"])) {
        // This is a stateful action - toggle the state
        BOOL newState = ([menuItem state] == NSOffState);
        parameter = @[@(newState)]; // Variant array with boolean
        NSLog(@"GTKActionHandler: Toggling stateful action to %@", @(newState));
    }
    
    // Call Activate method on org.gtk.Actions interface
    // Signature: Activate(s action_name, av parameter, a{sv} platform_data)
    // Use a special method call to ensure correct DBus type conversion
    NSLog(@"GTKActionHandler: Calling GTK Activate method for action: %@ on path: %@", actualActionName, actualActionPath);
    
    id result = [dbusConnection callGTKActivateMethod:actualActionName
                                            parameter:parameter
                                         platformData:platformData
                                            onService:serviceName
                                           objectPath:actualActionPath];
    
    if (result) {
        NSLog(@"GTKActionHandler: GTK action activation succeeded, result: %@", result);
        
        // Update menu item state if this was a stateful action
        if ([parameter count] > 0) {
            BOOL newState = [[parameter objectAtIndex:0] boolValue];
            [menuItem setState:newState ? NSOnState : NSOffState];
        }
    } else {
        NSLog(@"GTKActionHandler: GTK action activation failed");
    }
}

+ (NSDictionary *)getActionState:(NSString *)actionName
                     serviceName:(NSString *)serviceName
                      actionPath:(NSString *)actionPath
                  dbusConnection:(GNUDBusConnection *)dbusConnection
{
    if (!actionName || !serviceName || !actionPath || !dbusConnection) {
        return nil;
    }
    
    NSLog(@"GTKActionHandler: Querying GTK action state for '%@'", actionName);
    
    // Try to call DescribeAction method to get action information
    id result = [dbusConnection callMethod:@"DescribeAction"
                                 onService:serviceName
                                objectPath:actionPath
                                 interface:@"org.gtk.Actions"
                                 arguments:@[actionName]];
    
    if (result && [result isKindOfClass:[NSArray class]]) {
        NSArray *actionDesc = (NSArray *)result;
        NSLog(@"GTKActionHandler: Action description: %@", actionDesc);
        
        // GTK DescribeAction returns (bvav):
        // - b: enabled
        // - v: parameter type (variant)
        // - av: state (variant array, empty if stateless)
        
        if ([actionDesc count] >= 3) {
            NSNumber *enabled = ([actionDesc count] > 0) ? [actionDesc objectAtIndex:0] : @YES;
            id paramType = ([actionDesc count] > 1) ? [actionDesc objectAtIndex:1] : nil;
            NSArray *stateArray = ([actionDesc count] > 2) ? [actionDesc objectAtIndex:2] : nil;
            
            NSMutableDictionary *actionState = [NSMutableDictionary dictionary];
            [actionState setObject:enabled forKey:@"enabled"];
            
            if (paramType) {
                [actionState setObject:paramType forKey:@"parameter_type"];
            }
            
            if (stateArray && [stateArray count] > 0) {
                [actionState setObject:[stateArray objectAtIndex:0] forKey:@"state"];
            }
            
            return [NSDictionary dictionaryWithDictionary:actionState];
        }
    }
    
    // Fallback: try to call List method to see if action exists
    id listResult = [dbusConnection callMethod:@"List"
                                     onService:serviceName
                                    objectPath:actionPath
                                     interface:@"org.gtk.Actions"
                                     arguments:nil];
    
    if (listResult && [listResult isKindOfClass:[NSArray class]]) {
        NSArray *actionList = (NSArray *)listResult;
        if ([actionList containsObject:actionName]) {
            NSLog(@"GTKActionHandler: Action '%@' exists in action list", actionName);
            return @{@"enabled": @YES}; // Default to enabled
        }
    }
    
    NSLog(@"GTKActionHandler: Could not query state for GTK action '%@'", actionName);
    return nil;
}

+ (void)cleanup
{
    NSLog(@"GTKActionHandler: Cleaning up GTK action handler...");
    
    [gtkMenuItemToActionMap removeAllObjects];
    [gtkMenuItemToServiceMap removeAllObjects];
    [gtkMenuItemToActionPathMap removeAllObjects];
    [gtkMenuItemToConnectionMap removeAllObjects];
}

@end
