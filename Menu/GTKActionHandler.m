/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */


#import "GTKActionHandler.h"
#import "DBusConnection.h"
#import "X11ShortcutManager.h"
#import "MenuUtils.h"
#import "WindowMonitor.h"

// Static storage for GTK action information
static NSMutableDictionary *gtkMenuItemToActionMap = nil;
static NSMutableDictionary *gtkMenuItemToServiceMap = nil;
static NSMutableDictionary *gtkMenuItemToActionPathMap = nil;
static NSMutableDictionary *gtkMenuItemToConnectionMap = nil;

@implementation GTKActionHandler

// Static variable to track which services support DescribeAction
static NSMutableSet *_servicesWithDescribeAction = nil;
static NSMutableSet *_servicesWithoutDescribeAction = nil;

+ (void)initialize
{
    if (self == [GTKActionHandler class]) {
        _servicesWithDescribeAction = [[NSMutableSet alloc] init];
        _servicesWithoutDescribeAction = [[NSMutableSet alloc] init];
        gtkMenuItemToActionMap = [[NSMutableDictionary alloc] init];
        gtkMenuItemToServiceMap = [[NSMutableDictionary alloc] init];
        gtkMenuItemToActionPathMap = [[NSMutableDictionary alloc] init];
        gtkMenuItemToConnectionMap = [[NSMutableDictionary alloc] init];
        
        NSDebugLLog(@"gwcomp", @"GTKActionHandler: Initialized GTK action handler");
    }
}

+ (void)setupActionForMenuItem:(NSMenuItem *)menuItem
                    actionName:(NSString *)actionName
                   serviceName:(NSString *)serviceName
                    actionPath:(NSString *)actionPath
                dbusConnection:(GNUDBusConnection *)dbusConnection
{
    if (!menuItem || !actionName || !serviceName || !actionPath || !dbusConnection) {
        NSDebugLLog(@"gwcomp", @"GTKActionHandler: ERROR: Missing required parameters for GTK action setup");
        return;
    }
    
    [menuItem setTarget:[GTKActionHandler class]];
    [menuItem setAction:@selector(gtkMenuItemAction:)];
    
    // Store the action name in the menu item for later retrieval during re-registration
    [menuItem setRepresentedObject:actionName];
    
    // Store GTK action information for this menu item using a stable key
    // Use both title and action name to create a unique identifier
    NSString *menuItemKey = [NSString stringWithFormat:@"%@|%@", [menuItem title], actionName];
    [gtkMenuItemToActionMap setObject:actionName forKey:menuItemKey];
    [gtkMenuItemToServiceMap setObject:serviceName forKey:menuItemKey];
    [gtkMenuItemToActionPathMap setObject:actionPath forKey:menuItemKey];
    [gtkMenuItemToConnectionMap setObject:dbusConnection forKey:menuItemKey];
    
    NSDebugLog(@"GTKActionHandler: Set up GTK action for menu item '%@' (action=%@, service=%@, path=%@)", 
          [menuItem title], actionName, serviceName, actionPath);
    
    // Register shortcut with X11ShortcutManager if this menu item has a key equivalent
    NSString *keyEquivalent = [menuItem keyEquivalent];
    if (keyEquivalent && [keyEquivalent length] > 0) {
        NSUInteger modifierMask = [menuItem keyEquivalentModifierMask];
        NSDebugLog(@"GTKActionHandler: Registering shortcut for menu item '%@': key='%@' modifiers=%lu", 
              [menuItem title], keyEquivalent, (unsigned long)modifierMask);
        
        // Only register shortcuts that have meaningful modifier keys to prevent capturing
        // bare keys or Shift-only keys globally. Shift-only shortcuts should be handled
        // locally by the application, not globally intercepted.
        BOOL hasShiftOnly = (modifierMask == NSShiftKeyMask);
        BOOL hasNoModifiers = (modifierMask == 0);
        BOOL hasCtrl = (modifierMask & NSControlKeyMask) != 0;
        
        if (!hasNoModifiers && !hasShiftOnly) {
            // Transform Ctrl+key shortcuts to Alt+key for global registration
            // This allows GIMP's Ctrl-N to be accessible globally as Alt-N
            NSUInteger globalModifierMask = modifierMask;
            if (hasCtrl) {
                // Replace Ctrl with Alt for global registration
                globalModifierMask = (modifierMask & ~NSControlKeyMask) | NSAlternateKeyMask;
                NSDebugLog(@"GTKActionHandler: Transforming Ctrl+%@ to Alt+%@ for global access", 
                      keyEquivalent, keyEquivalent);
            }
            
            // Create a temporary menu item with the global shortcut for registration
            NSMenuItem *globalMenuItem = [[NSMenuItem alloc] initWithTitle:[menuItem title]
                                                                   action:[menuItem action]
                                                            keyEquivalent:keyEquivalent];
            [globalMenuItem setKeyEquivalentModifierMask:globalModifierMask];
            [globalMenuItem setTarget:[menuItem target]];
            
            [[X11ShortcutManager sharedManager] registerShortcutForMenuItem:globalMenuItem
                                                                serviceName:serviceName
                                                                 objectPath:actionPath
                                                                 actionName:actionName
                                                             dbusConnection:dbusConnection];
        } else {
            NSString *reason = hasNoModifiers ? @"no modifiers" : @"Shift-only modifier";
            NSDebugLog(@"GTKActionHandler: Skipping registration of key '%@' for menu item '%@' - %@", 
                  keyEquivalent, [menuItem title], reason);
        }
    }
    
    // Only query action state for known stateful actions to reduce D-Bus calls
    // and prevent unity-gtk-action-group warnings
    BOOL isKnownStatefulAction = [actionName containsString:@"toggle"] || 
                                [actionName containsString:@"check"] ||
                                [actionName containsString:@"radio"] ||
                                [actionName hasSuffix:@"_state"];
    
    if (isKnownStatefulAction) {
        NSDictionary *actionState = [self getActionState:actionName 
                                             serviceName:serviceName 
                                              actionPath:actionPath 
                                          dbusConnection:dbusConnection];
        
        if (actionState) {
            NSNumber *enabled = [actionState objectForKey:@"enabled"];
            if (enabled) {
                [menuItem setEnabled:[enabled boolValue]];
                NSDebugLog(@"GTKActionHandler: Set initial enabled state to %@", enabled);
            }
            
            // Handle toggle/checkbox state for stateful actions
            id state = [actionState objectForKey:@"state"];
            if (state && [state isKindOfClass:[NSNumber class]]) {
                NSNumber *stateNum = (NSNumber *)state;
                [menuItem setState:[stateNum boolValue] ? NSOnState : NSOffState];
                NSDebugLog(@"GTKActionHandler: Set initial toggle state to %@", stateNum);
            }
        }
    } else {
        // For simple actions, assume enabled and skip state queries
        [menuItem setEnabled:YES];
    }
}

// Legacy method for compatibility with old code
+ (void)setupActionForMenuItem:(NSMenuItem *)menuItem
{
    NSDebugLLog(@"gwcomp", @"GTKActionHandler: Set up GTK action for menu item '%@' (action=unity.-Quit, service=:1.63, path=/org/appmenu/gtk/window/0)", 
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
    
    NSDebugLLog(@"gwcomp", @"GTKActionHandler: Menu item action triggered for '%@'", [menuItem title]);
    
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
                NSDebugLLog(@"gwcomp", @"GTKActionHandler: Found matching action '%@' for menu item '%@'", actionName, [menuItem title]);
                break;
            }
        }
    }
    
    if (!actionName || !serviceName || !actionPath || !dbusConnection) {
        NSDebugLLog(@"gwcomp", @"GTKActionHandler: ERROR: Missing GTK action info for menu item '%@'", [menuItem title]);
        NSDebugLLog(@"gwcomp", @"GTKActionHandler: actionName=%@, serviceName=%@, actionPath=%@, dbusConnection=%@", 
              actionName, serviceName, actionPath, dbusConnection);
        
        // Debug: show all stored keys
        NSDebugLLog(@"gwcomp", @"GTKActionHandler: Available stored keys: %@", [gtkMenuItemToActionMap allKeys]);
        return;
    }
    
    NSDebugLLog(@"gwcomp", @"GTKActionHandler: Triggering GTK action '%@' for menu item '%@' (service=%@, path=%@)", 
          actionName, [menuItem title], serviceName, actionPath);
    
        // Refresh the bus name and action path from the current window's X11 properties.
        // The stored service name is a D-Bus unique name (":1.xx") captured at menu-import
        // time.  If the app has since reconnected to D-Bus it will have a new unique name;
        // calling the old one returns "ServiceUnknown".  Additionally, the stored actionPath
        // is typically the _GTK_MENUBAR_OBJECT_PATH (org.gtk.Menus), NOT the
        // _GTK_APPLICATION_OBJECT_PATH (org.gtk.Actions) — using the wrong path causes the
        // same error even when the service is reachable.
        unsigned long activeWindowId = [[WindowMonitor sharedMonitor] currentActiveWindow];
        if (activeWindowId != 0) {
            NSString *freshBusName = [MenuUtils getWindowProperty:activeWindowId
                                                         atomName:@"_GTK_UNIQUE_BUS_NAME"];
            if (freshBusName && [freshBusName length] > 0) {
                if (![freshBusName isEqualToString:serviceName]) {
                    NSDebugLLog(@"gwcomp", @"GTKActionHandler: Bus name refreshed from %@ to %@", serviceName, freshBusName);
                }
                serviceName = freshBusName;
            }
            // For Unity-style actions (prefixed with "unity."), the actions are
            // exported on the menu bar object path (_GTK_MENUBAR_OBJECT_PATH),
            // which also hosts an org.gtk.Actions interface with Unity-style
            // action names (e.g. "-Quit").  Using _GTK_APPLICATION_OBJECT_PATH
            // would fail because those action names only exist on the menu path's
            // org.gtk.Actions interface.
            if ([actionName hasPrefix:@"unity."]) {
                NSString *menuPath = [MenuUtils getWindowProperty:activeWindowId
                                                       atomName:@"_GTK_MENUBAR_OBJECT_PATH"];
                if (menuPath && [menuPath length] > 0) {
                    if (![menuPath isEqualToString:actionPath]) {
                        NSDebugLLog(@"gwcomp", @"GTKActionHandler: Action path refreshed from %@ to %@ (_GTK_MENUBAR_OBJECT_PATH for unity action)",
                              actionPath, menuPath);
                    }
                    actionPath = menuPath;
                }
            } else {
                // Prefer the application object path (org.gtk.Actions) over the menubar
                // object path (org.gtk.Menus) — they implement different D-Bus interfaces.
                NSString *appPath = [MenuUtils getWindowProperty:activeWindowId
                                                       atomName:@"_GTK_APPLICATION_OBJECT_PATH"];
                if (appPath && [appPath length] > 0) {
                    if (![appPath isEqualToString:actionPath]) {
                        NSDebugLLog(@"gwcomp", @"GTKActionHandler: Action path refreshed from %@ to %@ (_GTK_APPLICATION_OBJECT_PATH)",
                              actionPath, appPath);
                    }
                    actionPath = appPath;
                }
            }
        }

    // Strip "unity." prefix from action name for actual D-Bus call
    // The menu contains "unity.-Quit" but the actual action is "-Quit"
    NSString *actualActionName = actionName;
    if ([actionName hasPrefix:@"unity."]) {
        actualActionName = [actionName substringFromIndex:6]; // Remove "unity." prefix
        NSDebugLLog(@"gwcomp", @"GTKActionHandler: Stripped unity prefix: '%@' -> '%@'", actionName, actualActionName);
    }
    
    // Check if this is Unity protocol (protocol 0) vs GTK protocol (protocol 1)
    // Even if the action name has "unity." prefix, modern applications like leafpad
    // still use GTK Actions interface, NOT the Unity Event interface
    BOOL isUnityProtocol = [actionPath containsString:@"/com/canonical/dbusmenu"] && ![actionPath containsString:@"/org/appmenu/gtk"];
    
    if (isUnityProtocol) {
        // True Unity protocol - use Event method on com.canonical.dbusmenu
        NSDebugLLog(@"gwcomp", @"GTKActionHandler: Calling Unity Event method for action: %@", actualActionName);
        
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
            NSDebugLLog(@"gwcomp", @"GTKActionHandler: Unity Event activation succeeded, result: %@", result);
        } else {
            NSDebugLLog(@"gwcomp", @"GTKActionHandler: Unity Event activation failed");
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
            NSDebugLLog(@"gwcomp", @"GTKActionHandler: Using gedit application path for app action: %@ (stripped to: %@)", actualActionPath, actualActionName);
        } else if ([actualActionName hasPrefix:@"win."]) {
            // Window-scoped actions go to the window path
            actualActionPath = @"/org/gnome/gedit/window/1";
            // Strip the "win." prefix since gedit registers actions without prefixes
            actualActionName = [actualActionName substringFromIndex:4]; // Remove "win." prefix
            NSDebugLLog(@"gwcomp", @"GTKActionHandler: Using gedit window path for win action: %@ (stripped to: %@)", actualActionPath, actualActionName);
        } else {
            // Other actions, try the window path first
            actualActionPath = @"/org/gnome/gedit/window/1";
            NSDebugLLog(@"gwcomp", @"GTKActionHandler: Using gedit window path for other action: %@", actualActionPath);
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
        NSDebugLLog(@"gwcomp", @"GTKActionHandler: Toggling stateful action to %@", @(newState));
    }
    
    // Call Activate method on org.gtk.Actions interface
    // Signature: Activate(s action_name, av parameter, a{sv} platform_data)
    // Use a special method call to ensure correct DBus type conversion
    NSDebugLLog(@"gwcomp", @"GTKActionHandler: Calling GTK Activate method for action: %@ on path: %@", actualActionName, actualActionPath);
    
    id result = [dbusConnection callGTKActivateMethod:actualActionName
                                            parameter:parameter
                                         platformData:platformData
                                            onService:serviceName
                                           objectPath:actualActionPath];
    
    if (result) {
        NSDebugLLog(@"gwcomp", @"GTKActionHandler: GTK action activation succeeded, result: %@", result);
        
        // Update menu item state if this was a stateful action
        if ([parameter count] > 0) {
            BOOL newState = [[parameter objectAtIndex:0] boolValue];
            [menuItem setState:newState ? NSOnState : NSOffState];
        }
    } else {
        NSDebugLLog(@"gwcomp", @"GTKActionHandler: GTK action activation failed");
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
    
    // Check if we already know this service doesn't support action queries
    @synchronized(_servicesWithoutDescribeAction) {
        if ([_servicesWithoutDescribeAction containsObject:serviceName]) {
            // Skip D-Bus calls for services we know don't support them
            return @{@"enabled": @YES};
        }
    }
    
    // Check if we already know whether this service supports DescribeAction
    BOOL tryDescribeAction = NO;
    @synchronized(_servicesWithDescribeAction) {
        if ([_servicesWithDescribeAction containsObject:serviceName]) {
            tryDescribeAction = YES;
        } else {
            // Unknown - be conservative and try once
            tryDescribeAction = YES;
        }
    }
    
    if (tryDescribeAction) {
        // Try to call DescribeAction method to get action information
        // Wrap in exception handling to prevent unity-gtk-action-group warnings
        @try {
            id result = [dbusConnection callMethod:@"DescribeAction"
                                         onService:serviceName
                                        objectPath:actionPath
                                         interface:@"org.gtk.Actions"
                                         arguments:@[actionName]];
            
            if (result && [result isKindOfClass:[NSArray class]]) {
                NSArray *actionDesc = (NSArray *)result;
                
                // Mark this service as supporting DescribeAction
                @synchronized(_servicesWithDescribeAction) {
                    [_servicesWithDescribeAction addObject:serviceName];
                }
                
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
            } else {
                // DescribeAction failed - mark this service as not supporting it
                @synchronized(_servicesWithoutDescribeAction) {
                    [_servicesWithoutDescribeAction addObject:serviceName];
                }
            }
        }
        @catch (NSException *exception) {
            // D-Bus call failed - mark this service as not supporting it to avoid future errors
            @synchronized(_servicesWithoutDescribeAction) {
                [_servicesWithoutDescribeAction addObject:serviceName];
            }
        }
    }
    
    // Fallback: Assume action is enabled without making more D-Bus calls
    // This reduces the unity-gtk-action-group warnings significantly
    return @{@"enabled": @YES};
}

+ (void)cleanup
{
    NSDebugLLog(@"gwcomp", @"GTKActionHandler: Cleaning up GTK action handler...");
    
    [gtkMenuItemToActionMap removeAllObjects];
    [gtkMenuItemToServiceMap removeAllObjects];
    [gtkMenuItemToActionPathMap removeAllObjects];
    [gtkMenuItemToConnectionMap removeAllObjects];
    
    @synchronized(_servicesWithDescribeAction) {
        [_servicesWithDescribeAction removeAllObjects];
    }
    @synchronized(_servicesWithoutDescribeAction) {
        [_servicesWithoutDescribeAction removeAllObjects];
    }
}

@end
