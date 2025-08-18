#import "GTKMenuParser.h"
#import "DBusConnection.h"
#import "GTKActionHandler.h"
#import "GTKSubmenuManager.h"

@implementation GTKMenuParser

+ (NSMenu *)parseGTKMenuFromDBusResult:(id)result 
                           serviceName:(NSString *)serviceName 
                            actionPath:(NSString *)actionPath 
                        dbusConnection:(GNUDBusConnection *)dbusConnection
{
    NSLog(@"GTKMenuParser: ===== PARSING GTK MENU STRUCTURE =====");
    NSLog(@"GTKMenuParser: Service: %@", serviceName);
    NSLog(@"GTKMenuParser: Action path: %@", actionPath);
    NSLog(@"GTKMenuParser: Result type: %@", [result class]);
    NSLog(@"GTKMenuParser: Result: %@", result);
    
    if (![result isKindOfClass:[NSArray class]]) {
        NSLog(@"GTKMenuParser: ERROR: Expected array but got %@", [result class]);
        return nil;
    }
    
    NSArray *resultArray = (NSArray *)result;
    if ([resultArray count] == 0) {
        NSLog(@"GTKMenuParser: Empty result array");
        return nil;
    }
    
    // GTK Start method returns an array of results, each with format (uaa{sv}):
    // - u: menu ID (subscription ID)
    // - aa{sv}: array of menu items, each item is array of properties
    
    // Build a dictionary of menu_id -> menu_items for easy lookup
    NSMutableDictionary *menuDict = [NSMutableDictionary dictionary];
    
    for (id menuResult in resultArray) {
        if ([menuResult isKindOfClass:[NSArray class]] && [menuResult count] >= 3) {
            NSArray *menuResultArray = (NSArray *)menuResult;
            NSNumber *menuId = [menuResultArray objectAtIndex:0];
            NSNumber *revision = [menuResultArray objectAtIndex:1];  // Menu revision number
            NSArray *menuItems = [menuResultArray objectAtIndex:2];
            
            // Store as tuple key (menu_id, revision) - this is what the data actually represents
            NSArray *menuKey = @[menuId, revision];
            [menuDict setObject:menuItems forKey:menuKey];
            
            NSLog(@"GTKMenuParser: Menu ID %@ (revision %@) has %lu items", 
                  menuId, revision, (unsigned long)[menuItems count]);
        }
    }
    
    // Start exploring from root menu (0, 0)
    NSMenu *rootMenu = [self exploreGTKMenu:@[@0, @0] 
                                 withLabels:@[] 
                                   menuDict:menuDict 
                                serviceName:serviceName 
                                 actionPath:actionPath 
                             dbusConnection:dbusConnection];
    
    if (!rootMenu) {
        NSLog(@"GTKMenuParser: Could not create root menu, creating placeholder");
        rootMenu = [[NSMenu alloc] initWithTitle:@"GTK App Menu"];
        [rootMenu autorelease];
    }
    
    return rootMenu;
}

+ (NSMenu *)exploreGTKMenu:(NSArray *)menuId
                withLabels:(NSArray *)labelList
                  menuDict:(NSMutableDictionary *)menuDict
               serviceName:(NSString *)serviceName
                actionPath:(NSString *)actionPath
            dbusConnection:(GNUDBusConnection *)dbusConnection
{
    NSLog(@"GTKMenuParser: Exploring GTK menu %@ with labels %@", menuId, labelList);
    
    NSArray *menuItems = [menuDict objectForKey:menuId];
    if (!menuItems) {
        NSLog(@"GTKMenuParser: No menu items found for menu ID %@", menuId);
        return nil;
    }
    
    NSString *menuTitle = ([labelList count] > 0) ? [labelList lastObject] : @"GTK Menu";
    NSMenu *menu = [[NSMenu alloc] initWithTitle:menuTitle];
    
    NSLog(@"GTKMenuParser: Processing %lu menu items for menu %@", 
          (unsigned long)[menuItems count], menuId);

    for (id menuItemData in menuItems) {
        NSMutableDictionary *menuItem = [NSMutableDictionary dictionary];
        
        // Menu items can be either:
        // 1. Direct dictionary: {":section" = (0, 1); }
        // 2. Array containing multiple dictionaries: ({action = "unity.-File"; }, {label = "_File"; }, ...)
        if ([menuItemData isKindOfClass:[NSDictionary class]]) {
            [menuItem addEntriesFromDictionary:(NSDictionary *)menuItemData];
        } else if ([menuItemData isKindOfClass:[NSArray class]]) {
            NSArray *itemArray = (NSArray *)menuItemData;
            // Merge all dictionaries in the array into one complete menu item
            for (id dictItem in itemArray) {
                if ([dictItem isKindOfClass:[NSDictionary class]]) {
                    [menuItem addEntriesFromDictionary:(NSDictionary *)dictItem];
                }
            }
        }
        
        if ([menuItem count] == 0) {
            NSLog(@"GTKMenuParser: Skipping invalid menu item: %@ (class: %@)", 
                  menuItemData, [menuItemData class]);
            continue;
        }
        
        NSLog(@"GTKMenuParser: Processing merged menu item: %@", menuItem);
        NSString *label = [menuItem objectForKey:@"label"];
        NSString *action = [menuItem objectForKey:@"action"];
        NSString *accel = [menuItem objectForKey:@"accel"];
        if (!accel) {
            accel = [menuItem objectForKey:@"x-canonical-accel"];
        }
        
        // Handle sections - these don't create menu items but contain other items
        id sectionData = [menuItem objectForKey:@":section"];
        id submenuData = [menuItem objectForKey:@":submenu"];
        if (sectionData && [sectionData isKindOfClass:[NSArray class]]) {
            NSArray *sectionArray = (NSArray *)sectionData;
            if ([sectionArray count] >= 2) {
                NSArray *sectionMenuId = @[[sectionArray objectAtIndex:0], [sectionArray objectAtIndex:1]];
                NSLog(@"GTKMenuParser: Following section reference from %@ to %@", menuId, sectionMenuId);
                NSMenu *sectionMenu = [self exploreGTKMenu:sectionMenuId
                                                withLabels:labelList
                                                  menuDict:menuDict
                                               serviceName:serviceName
                                                actionPath:actionPath
                                            dbusConnection:dbusConnection];
                
                if (sectionMenu) {
                    NSLog(@"GTKMenuParser: Section menu %@ has %lu items, adding to parent", 
                          sectionMenuId, (unsigned long)[[sectionMenu itemArray] count]);
                    // Add all items from the section to our menu
                    for (NSMenuItem *item in [sectionMenu itemArray]) {
                        [menu addItem:[[item copy] autorelease]];
                    }
                } else {
                    NSLog(@"GTKMenuParser: Section menu %@ not found", sectionMenuId);
                }
            }
            continue;
        }
        
        // Handle regular menu items
        if (label) {
            // Remove mnemonic underscore from label  
            NSString *displayLabel = label;
            if ([displayLabel hasPrefix:@"_"]) {
                displayLabel = [displayLabel substringFromIndex:1];
            }
            
            NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:displayLabel action:nil keyEquivalent:@""];
            
            // Add keyboard shortcut if available
            if (accel && [accel length] > 0) {
                NSString *keyEquivalent = [self parseKeyboardShortcut:accel];
                if (keyEquivalent && [keyEquivalent length] > 0) {
                    [item setKeyEquivalent:keyEquivalent];
                    NSUInteger modifierMask = [self parseKeyboardModifiers:accel];
                    [item setKeyEquivalentModifierMask:modifierMask];
                    NSLog(@"GTKMenuParser: Added shortcut '%@' to menu item '%@'", accel, displayLabel);
                }
            }
            
            if (action) {
                [GTKActionHandler setupActionForMenuItem:item
                                             actionName:action
                                            serviceName:serviceName
                                             actionPath:actionPath
                                         dbusConnection:dbusConnection];
            }
            
            // Handle submenus if present
            if (submenuData && [submenuData isKindOfClass:[NSArray class]]) {
                NSArray *submenuArray = (NSArray *)submenuData;
                if ([submenuArray count] >= 2) {
                    NSArray *submenuMenuId = @[[submenuArray objectAtIndex:0], [submenuArray objectAtIndex:1]];
                    NSArray *newLabelList = [labelList arrayByAddingObject:displayLabel];
                    
                    // Check if we already have the submenu data in our menuDict
                    if ([menuDict objectForKey:submenuMenuId]) {
                        // Data is already available - create submenu immediately (not lazy)
                        NSLog(@"GTKMenuParser: Submenu data for '%@' already available, creating immediately", displayLabel);
                        
                        NSMenu *submenu = [self exploreGTKMenu:submenuMenuId
                                                    withLabels:newLabelList
                                                      menuDict:menuDict
                                                   serviceName:serviceName
                                                    actionPath:actionPath
                                                dbusConnection:dbusConnection];
                        
                        if (submenu) {
                            [item setSubmenu:submenu];
                            NSLog(@"GTKMenuParser: Added immediate submenu to item '%@'", displayLabel);
                        } else {
                            NSLog(@"GTKMenuParser: Failed to create immediate submenu for item '%@'", displayLabel);
                        }
                    } else {
                        // Data not available - try to load it, then decide on lazy loading
                        NSNumber *groupId = [submenuArray objectAtIndex:0];
                        NSLog(@"GTKMenuParser: Submenu data for '%@' not available, attempting to load group %@", displayLabel, groupId);
                        
                        // Use the actual menu path for loading
                        NSString *menuPath = actionPath;
                        if ([actionPath containsString:@"/org/gtk/Actions"]) {
                            // Convert from action path back to menu path
                            menuPath = [actionPath stringByReplacingOccurrencesOfString:@"/org/gtk/Actions" 
                                                                             withString:@"/org/gtk/Menus"];
                        } else if ([actionPath hasSuffix:@"/menubar"]) {
                            // This is likely already a menu path
                            menuPath = actionPath;
                        }
                        
                        // Try to load the additional group immediately
                        id additionalResult = [dbusConnection callMethod:@"Start"
                                                               onService:serviceName
                                                             objectPath:menuPath
                                                              interface:@"org.gtk.Menus"
                                                              arguments:@[@[groupId]]];
                        
                        if (additionalResult && [additionalResult isKindOfClass:[NSArray class]]) {
                            NSLog(@"GTKMenuParser: Successfully loaded additional menu group %@", groupId);
                            // Parse and add the new menu data to menuDict
                            [self parseMenuData:(NSArray *)additionalResult intoDict:menuDict];
                            
                            // Now try to create the submenu immediately
                            NSMenu *submenu = [self exploreGTKMenu:submenuMenuId
                                                        withLabels:newLabelList
                                                          menuDict:menuDict
                                                       serviceName:serviceName
                                                        actionPath:actionPath
                                                    dbusConnection:dbusConnection];
                            
                            if (submenu) {
                                [item setSubmenu:submenu];
                                NSLog(@"GTKMenuParser: Added loaded submenu to item '%@'", displayLabel);
                            } else {
                                NSLog(@"GTKMenuParser: Failed to create loaded submenu for item '%@', falling back to lazy loading", displayLabel);
                                // Fall back to lazy loading
                                NSMenu *lazySubmenu = [[NSMenu alloc] initWithTitle:displayLabel];
                                [GTKSubmenuManager setupSubmenu:lazySubmenu
                                                     forMenuItem:item
                                                     serviceName:serviceName
                                                        menuPath:menuPath
                                                      actionPath:actionPath
                                                  dbusConnection:dbusConnection
                                                         groupId:groupId
                                                        menuDict:menuDict];
                                [lazySubmenu release];
                            }
                        } else {
                            NSLog(@"GTKMenuParser: Failed to load additional menu group %@, setting up lazy loading", groupId);
                            // Set up lazy loading as fallback
                            NSMenu *lazySubmenu = [[NSMenu alloc] initWithTitle:displayLabel];
                            [GTKSubmenuManager setupSubmenu:lazySubmenu
                                                 forMenuItem:item
                                                 serviceName:serviceName
                                                    menuPath:menuPath
                                                  actionPath:actionPath
                                              dbusConnection:dbusConnection
                                                     groupId:groupId
                                                    menuDict:menuDict];
                            [lazySubmenu release];
                            NSLog(@"GTKMenuParser: Set up lazy-loaded submenu for item '%@'", displayLabel);
                        }
                    }
                }
            }
            
            [menu addItem:item];
            [item release];
            
            NSLog(@"GTKMenuParser: Added GTK menu item: '%@' (action: %@)", displayLabel, action ?: @"none");
        }
    }
    
    NSLog(@"GTKMenuParser: Created GTK menu '%@' with %lu items", menuTitle, (unsigned long)[menu numberOfItems]);
    return [menu autorelease];
}

+ (void)parseMenuData:(NSArray *)menuData intoDict:(NSMutableDictionary *)menuDict
{
    NSLog(@"GTKMenuParser: Parsing additional menu data with %lu items", (unsigned long)[menuData count]);
    
    for (id item in menuData) {
        if ([item isKindOfClass:[NSArray class]] && [item count] >= 3) {
            NSArray *menuEntry = (NSArray *)item;
            NSNumber *menuId0 = [menuEntry objectAtIndex:0];
            NSNumber *menuId1 = [menuEntry objectAtIndex:1];
            NSArray *menuId = @[menuId0, menuId1];
            id menuItems = [menuEntry objectAtIndex:2];
            
            [menuDict setObject:menuItems forKey:menuId];
            NSLog(@"GTKMenuParser: Added menu (%@, %@) with %lu items to dict", 
                  menuId0, menuId1, 
                  [menuItems isKindOfClass:[NSArray class]] ? (unsigned long)[menuItems count] : 0);
        }
    }
}

+ (NSMenu *)parseGMenuModelItem:(id)modelItem 
                         isRoot:(BOOL)isRoot 
                    serviceName:(NSString *)serviceName 
                     actionPath:(NSString *)actionPath 
                 dbusConnection:(GNUDBusConnection *)dbusConnection
{
    NSLog(@"GTKMenuParser: Parsing GMenuModel item %@ (root: %@)", modelItem, isRoot ? @"YES" : @"NO");
    
    if (![modelItem isKindOfClass:[NSArray class]]) {
        NSLog(@"GTKMenuParser: ERROR: Expected array for GMenuModel item");
        return nil;
    }
    
    NSArray *itemArray = (NSArray *)modelItem;
    NSString *menuTitle = isRoot ? @"GTK Menu" : @"Submenu";
    NSMenu *menu = [[NSMenu alloc] initWithTitle:menuTitle];
    
    for (id item in itemArray) {
        NSMenuItem *menuItem = [self createMenuItemFromGModelItem:item 
                                                      serviceName:serviceName 
                                                       actionPath:actionPath 
                                                   dbusConnection:dbusConnection];
        if (menuItem) {
            [menu addItem:menuItem];
        }
    }
    
    NSLog(@"GTKMenuParser: Created GMenuModel menu with %lu items", (unsigned long)[menu numberOfItems]);
    return [menu autorelease];
}

+ (NSMenuItem *)createMenuItemFromGModelItem:(id)modelItem 
                                 serviceName:(NSString *)serviceName 
                                  actionPath:(NSString *)actionPath 
                              dbusConnection:(GNUDBusConnection *)dbusConnection
{
    NSLog(@"GTKMenuParser: Creating menu item from GTK model item: %@ (%@)", modelItem, [modelItem class]);
    
    if (![modelItem isKindOfClass:[NSArray class]]) {
        NSLog(@"GTKMenuParser: ERROR: Expected array for GTK model item");
        return nil;
    }
    
    NSArray *itemArray = (NSArray *)modelItem;
    if ([itemArray count] == 0) {
        NSLog(@"GTKMenuParser: Empty GTK model item array");
        return nil;
    }
    
    // GTK menu items typically have format: [id, properties_dict, submenu_array]
    // or [properties_dict] for simpler items
    
    NSDictionary *properties = nil;
    NSArray *submenuItems = nil;
    
    // Try to find the properties dictionary
    for (id element in itemArray) {
        if ([element isKindOfClass:[NSDictionary class]]) {
            properties = (NSDictionary *)element;
            break;
        }
    }
    
    // Try to find submenu array
    for (id element in itemArray) {
        if ([element isKindOfClass:[NSArray class]] && element != itemArray) {
            submenuItems = (NSArray *)element;
            break;
        }
    }
    
    if (!properties) {
        NSLog(@"GTKMenuParser: No properties dictionary found in GTK item");
        return nil;
    }
    
    NSLog(@"GTKMenuParser: GTK item properties: %@", properties);
    
    // Extract label
    NSString *label = [properties objectForKey:@"label"];
    if (!label) {
        // Try alternative keys
        label = [properties objectForKey:@"title"];
        if (!label) {
            label = [properties objectForKey:@"text"];
        }
    }
    
    if (!label || [label length] == 0) {
        label = @"GTK Menu Item";
    }
    
    // Extract action
    NSString *action = [properties objectForKey:@"action"];
    
    // Extract other properties
    NSNumber *enabled = [properties objectForKey:@"enabled"];
    NSNumber *visible = [properties objectForKey:@"visible"];
    // NSString *iconName = [properties objectForKey:@"icon"]; // TODO: Handle icons
    NSString *keyEquiv = [properties objectForKey:@"accel"];
    
    NSLog(@"GTKMenuParser: Creating GTK menu item - label='%@', action='%@', enabled=%@, visible=%@", 
          label, action ?: @"none", enabled ?: @"default", visible ?: @"default");
    
    // Create the menu item
    NSMenuItem *menuItem = [[NSMenuItem alloc] initWithTitle:label 
                                                      action:nil 
                                               keyEquivalent:@""];
    
    // Set enabled state
    if (enabled) {
        [menuItem setEnabled:[enabled boolValue]];
    }
    
    // Set visibility (GNUstep doesn't have setHidden, so we'll disable instead)
    if (visible && ![visible boolValue]) {
        [menuItem setEnabled:NO];
    }
    
    // Set key equivalent if available
    if (keyEquiv && [keyEquiv length] > 0) {
        // TODO: Parse GTK-style accelerator format (e.g., "<Control>s")
        // For now, just use first character
        NSString *key = [keyEquiv substringToIndex:1];
        [menuItem setKeyEquivalent:[key lowercaseString]];
    }
    
    // Set up action if we have one
    if (action && serviceName && actionPath && dbusConnection) {
        [GTKActionHandler setupActionForMenuItem:menuItem 
                                     actionName:action 
                                    serviceName:serviceName 
                                     actionPath:actionPath 
                                 dbusConnection:dbusConnection];
        NSLog(@"GTKMenuParser: Set up GTK action for menu item '%@' (action=%@)", label, action);
    }
    
    // Handle submenus
    if (submenuItems && [submenuItems count] > 0) {
        NSLog(@"GTKMenuParser: Creating GTK submenu for '%@' with %lu items", 
              label, (unsigned long)[submenuItems count]);
        
        NSMenu *submenu = [self parseGMenuModelItem:submenuItems 
                                             isRoot:NO 
                                        serviceName:serviceName 
                                         actionPath:actionPath 
                                     dbusConnection:dbusConnection];
        
        if (!submenu) {
            // Create placeholder submenu
            submenu = [[NSMenu alloc] initWithTitle:label];
            [submenu autorelease];
        }
        
        [menuItem setSubmenu:submenu];
    }
    
    return [menuItem autorelease];
}

+ (NSDictionary *)parseActionGroupFromResult:(id)result
{
    NSLog(@"GTKMenuParser: Parsing GTK action group from result: %@ (%@)", result, [result class]);
    
    if (![result isKindOfClass:[NSArray class]] && ![result isKindOfClass:[NSDictionary class]]) {
        NSLog(@"GTKMenuParser: Unexpected action group result type");
        return nil;
    }
    
    // GTK action groups typically contain:
    // - Action names
    // - Action states (for stateful actions)
    // - Action parameters
    
    NSMutableDictionary *actionGroup = [NSMutableDictionary dictionary];
    
    if ([result isKindOfClass:[NSArray class]]) {
        NSArray *actionArray = (NSArray *)result;
        for (NSUInteger i = 0; i < [actionArray count]; i++) {
            id actionItem = [actionArray objectAtIndex:i];
            if ([actionItem isKindOfClass:[NSString class]]) {
                // Simple action name
                [actionGroup setObject:@{@"enabled": @YES} forKey:actionItem];
            } else if ([actionItem isKindOfClass:[NSDictionary class]]) {
                // Action with properties
                NSDictionary *actionDict = (NSDictionary *)actionItem;
                NSString *actionName = [actionDict objectForKey:@"name"];
                if (actionName) {
                    [actionGroup setObject:actionDict forKey:actionName];
                }
            }
        }
    } else if ([result isKindOfClass:[NSDictionary class]]) {
        // Already a dictionary of actions
        [actionGroup addEntriesFromDictionary:(NSDictionary *)result];
    }
    
    NSLog(@"GTKMenuParser: Parsed %lu GTK actions", (unsigned long)[actionGroup count]);
    return [NSDictionary dictionaryWithDictionary:actionGroup];
}

+ (NSString *)parseKeyboardShortcut:(NSString *)accel
{
    if (!accel || [accel length] == 0) {
        return @"";
    }
    
    // GTK accelerator format: <Control>o, <Primary><Shift>n, <Alt>F4, etc.
    // Convert to NSMenuItem key equivalent (just the key part)
    NSString *key = accel;
    
    // Remove modifier prefixes
    key = [key stringByReplacingOccurrencesOfString:@"<Control>" withString:@""];
    key = [key stringByReplacingOccurrencesOfString:@"<Primary>" withString:@""];
    key = [key stringByReplacingOccurrencesOfString:@"<Shift>" withString:@""];
    key = [key stringByReplacingOccurrencesOfString:@"<Alt>" withString:@""];
    key = [key stringByReplacingOccurrencesOfString:@"<Meta>" withString:@""];
    key = [key stringByReplacingOccurrencesOfString:@"<Super>" withString:@""];
    
    // Convert special keys
    if ([key isEqualToString:@"Return"]) return @"\r";
    if ([key isEqualToString:@"Tab"]) return @"\t";
    if ([key isEqualToString:@"BackSpace"]) return @"\b";
    if ([key isEqualToString:@"Delete"]) return @"\x7f";
    if ([key isEqualToString:@"Escape"]) return @"\x1b";
    if ([key isEqualToString:@"Space"]) return @" ";
    
    // Function keys
    if ([key hasPrefix:@"F"]) {
        NSString *fNumber = [key substringFromIndex:1];
        if ([fNumber intValue] >= 1 && [fNumber intValue] <= 24) {
            // NSMenuItem uses NSF1FunctionKey, etc. but for simplicity, return empty for now
            return @"";
        }
    }
    
    // Return lowercase key for normal keys
    return [key lowercaseString];
}

+ (NSUInteger)parseKeyboardModifiers:(NSString *)accel
{
    if (!accel || [accel length] == 0) {
        return 0;
    }
    
    NSUInteger modifiers = 0;
    
    if ([accel containsString:@"<Control>"] || [accel containsString:@"<Primary>"]) {
        modifiers |= NSEventModifierFlagCommand;  // Primary/Control maps to Cmd on macOS
    }
    if ([accel containsString:@"<Shift>"]) {
        modifiers |= NSEventModifierFlagShift;
    }
    if ([accel containsString:@"<Alt>"]) {
        modifiers |= NSEventModifierFlagOption;
    }
    if ([accel containsString:@"<Meta>"] || [accel containsString:@"<Super>"]) {
        modifiers |= NSEventModifierFlagControl;  // Meta/Super maps to Ctrl on macOS
    }
    
    return modifiers;
}

@end
