/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */


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
    NSDebugLog(@"GTKMenuParser: ===== PARSING GTK MENU STRUCTURE =====");
    NSDebugLog(@"GTKMenuParser: Service: %@", serviceName);
    NSDebugLog(@"GTKMenuParser: Action path: %@", actionPath);
    NSDebugLog(@"GTKMenuParser: Result type: %@", [result class]);
    NSDebugLog(@"GTKMenuParser: Result: %@", result);
    
    if (![result isKindOfClass:[NSArray class]]) {
        NSDebugLog(@"GTKMenuParser: ERROR: Expected array but got %@", [result class]);
        return nil;
    }
    
    NSArray *resultArray = (NSArray *)result;
    if ([resultArray count] == 0) {
        NSDebugLog(@"GTKMenuParser: Empty result array");
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
            
            NSDebugLog(@"GTKMenuParser: Menu ID %@ (revision %@) has %lu items", 
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
        NSDebugLog(@"GTKMenuParser: Could not create root menu, creating placeholder");
        rootMenu = [[NSMenu alloc] initWithTitle:@"GTK App Menu"];
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
    NSDebugLog(@"GTKMenuParser: Exploring GTK menu %@ with labels %@", menuId, labelList);
    
    NSArray *menuItems = [menuDict objectForKey:menuId];
    if (!menuItems) {
        NSDebugLog(@"GTKMenuParser: No menu items found for menu ID %@", menuId);
        return nil;
    }
    
    NSString *menuTitle = ([labelList count] > 0) ? [labelList lastObject] : @"GTK Menu";
    NSMenu *menu = [[NSMenu alloc] initWithTitle:menuTitle];
    
    NSDebugLog(@"GTKMenuParser: Processing %lu menu items for menu %@", 
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
            NSDebugLog(@"GTKMenuParser: Skipping invalid menu item: %@ (class: %@)", 
                  menuItemData, [menuItemData class]);
            continue;
        }
        
        NSDebugLog(@"GTKMenuParser: Processing merged menu item: %@", menuItem);
        NSString *label = [menuItem objectForKey:@"label"];
        NSString *action = [menuItem objectForKey:@"action"];
        NSString *accel = [menuItem objectForKey:@"accel"];
        if (!accel) {
            accel = [menuItem objectForKey:@"x-canonical-accel"];
            if (accel) {
                NSDebugLog(@"GTKMenuParser: Found x-canonical-accel='%@' for label='%@'", accel, label);
            }
        } else {
            NSDebugLog(@"GTKMenuParser: Found accel='%@' for label='%@'", accel, label);
        }
        
        // Handle sections - these don't create menu items but contain other items
        id sectionData = [menuItem objectForKey:@":section"];
        id submenuData = [menuItem objectForKey:@":submenu"];
        if (sectionData && [sectionData isKindOfClass:[NSArray class]]) {
            NSArray *sectionArray = (NSArray *)sectionData;
            if ([sectionArray count] >= 2) {
                NSArray *sectionMenuId = @[[sectionArray objectAtIndex:0], [sectionArray objectAtIndex:1]];
                NSDebugLog(@"GTKMenuParser: Following section reference from %@ to %@", menuId, sectionMenuId);
                NSMenu *sectionMenu = [self exploreGTKMenu:sectionMenuId
                                                withLabels:labelList
                                                  menuDict:menuDict
                                               serviceName:serviceName
                                                actionPath:actionPath
                                            dbusConnection:dbusConnection];
                
                if (sectionMenu) {
                    NSDebugLog(@"GTKMenuParser: Section menu %@ has %lu items, adding to parent", 
                          sectionMenuId, (unsigned long)[[sectionMenu itemArray] count]);
                    
                    // Add a separator before this section if there are already items in the menu
                    if ([menu numberOfItems] > 0) {
                        [menu addItem:[NSMenuItem separatorItem]];
                        NSDebugLog(@"GTKMenuParser: Added separator before section %@", sectionMenuId);
                    }
                    
                    // Add all items from the section to our menu
                    for (NSMenuItem *item in [sectionMenu itemArray]) {
                        [menu addItem:[item copy]];
                    }
                } else {
                    NSDebugLog(@"GTKMenuParser: Section menu %@ not found", sectionMenuId);
                }
            }
            continue;
        }
        
        // Handle regular menu items
        if (label) {
            // Remove mnemonic underscores from label (all occurrences, not just leading)
            NSString *displayLabel = label;
            if ([displayLabel containsString:@"_"]) {
                displayLabel = [displayLabel stringByReplacingOccurrencesOfString:@"_" withString:@""];
                NSDebugLog(@"GTKMenuParser: Transformed label '%@' -> '%@' (removed mnemonics)", label, displayLabel);
            }
            
            NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:displayLabel action:nil keyEquivalent:@""];
            
            // Add keyboard shortcut if available
            if (accel && [accel length] > 0) {
                NSString *keyEquivalent = [self parseKeyboardShortcut:accel];
                if (keyEquivalent && [keyEquivalent length] > 0) {
                    [item setKeyEquivalent:keyEquivalent];
                    NSUInteger modifierMask = [self parseKeyboardModifiers:accel];
                    
                    // WORKAROUND: GNUstep doesn't display Control shortcuts properly in menus
                    // For display: Convert NSControlKeyMask to NSCommandKeyMask 
                    NSUInteger displayModifierMask = modifierMask;
                    BOOL hasControlKey = (modifierMask & NSControlKeyMask) != 0;
                    
                    if (hasControlKey) {
                        // Display as Command in menu (which GNUstep renders properly)
                        displayModifierMask = (modifierMask & ~NSControlKeyMask) | NSCommandKeyMask;
                        NSDebugLog(@"GTKMenuParser: Converting Control to Command for display");
                    }
                    
                    [item setKeyEquivalentModifierMask:displayModifierMask];
                    NSDebugLog(@"GTKMenuParser: Added shortcut '%@' to menu item '%@' (keyEq='%@', modifiers=%lu, display=%lu)", 
                          accel, displayLabel, keyEquivalent, (unsigned long)modifierMask, (unsigned long)displayModifierMask);
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
                        NSDebugLog(@"GTKMenuParser: Submenu data for '%@' already available, creating immediately", displayLabel);
                        
                        NSMenu *submenu = [self exploreGTKMenu:submenuMenuId
                                                    withLabels:newLabelList
                                                      menuDict:menuDict
                                                   serviceName:serviceName
                                                    actionPath:actionPath
                                                dbusConnection:dbusConnection];
                        
                        if (submenu) {
                            [item setSubmenu:submenu];
                            NSDebugLog(@"GTKMenuParser: Added immediate submenu to item '%@'", displayLabel);
                        } else {
                            NSDebugLog(@"GTKMenuParser: Failed to create immediate submenu for item '%@'", displayLabel);
                        }
                    } else {
                        // Data not available - try to load it, then decide on lazy loading
                        NSNumber *groupId = [submenuArray objectAtIndex:0];
                        NSDebugLog(@"GTKMenuParser: Submenu data for '%@' not available, attempting to load group %@", displayLabel, groupId);
                        
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
                            NSDebugLog(@"GTKMenuParser: Successfully loaded additional menu group %@", groupId);
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
                                NSDebugLog(@"GTKMenuParser: Added loaded submenu to item '%@'", displayLabel);
                            } else {
                                NSDebugLog(@"GTKMenuParser: Failed to create loaded submenu for item '%@', falling back to lazy loading", displayLabel);
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
                            }
                        } else {
                            NSDebugLog(@"GTKMenuParser: Failed to load additional menu group %@, setting up lazy loading", groupId);
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
                            NSDebugLog(@"GTKMenuParser: Set up lazy-loaded submenu for item '%@'", displayLabel);
                        }
                    }
                }
            }
            
            [menu addItem:item];
            
            NSDebugLog(@"GTKMenuParser: Added GTK menu item: '%@' (action: %@)", displayLabel, action ?: @"none");
        }
    }
    
    NSDebugLog(@"GTKMenuParser: Created GTK menu '%@' with %lu items", menuTitle, (unsigned long)[menu numberOfItems]);
    return menu;
}

+ (void)parseMenuData:(NSArray *)menuData intoDict:(NSMutableDictionary *)menuDict
{
    NSDebugLog(@"GTKMenuParser: Parsing additional menu data with %lu items", (unsigned long)[menuData count]);
    
    for (id item in menuData) {
        if ([item isKindOfClass:[NSArray class]] && [item count] >= 3) {
            NSArray *menuEntry = (NSArray *)item;
            NSNumber *menuId0 = [menuEntry objectAtIndex:0];
            NSNumber *menuId1 = [menuEntry objectAtIndex:1];
            NSArray *menuId = @[menuId0, menuId1];
            id menuItems = [menuEntry objectAtIndex:2];
            
            [menuDict setObject:menuItems forKey:menuId];
            NSDebugLog(@"GTKMenuParser: Added menu (%@, %@) with %lu items to dict", 
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
    NSDebugLog(@"GTKMenuParser: Parsing GMenuModel item %@ (root: %@)", modelItem, isRoot ? @"YES" : @"NO");
    
    if (![modelItem isKindOfClass:[NSArray class]]) {
        NSDebugLog(@"GTKMenuParser: ERROR: Expected array for GMenuModel item");
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
    
    NSDebugLog(@"GTKMenuParser: Created GMenuModel menu with %lu items", (unsigned long)[menu numberOfItems]);
    return menu;
}

+ (NSMenuItem *)createMenuItemFromGModelItem:(id)modelItem 
                                 serviceName:(NSString *)serviceName 
                                  actionPath:(NSString *)actionPath 
                              dbusConnection:(GNUDBusConnection *)dbusConnection
{
    NSDebugLog(@"GTKMenuParser: Creating menu item from GTK model item: %@ (%@)", modelItem, [modelItem class]);
    
    if (![modelItem isKindOfClass:[NSArray class]]) {
        NSDebugLog(@"GTKMenuParser: ERROR: Expected array for GTK model item");
        return nil;
    }
    
    NSArray *itemArray = (NSArray *)modelItem;
    if ([itemArray count] == 0) {
        NSDebugLog(@"GTKMenuParser: Empty GTK model item array");
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
        NSDebugLog(@"GTKMenuParser: No properties dictionary found in GTK item");
        return nil;
    }
    
    NSDebugLog(@"GTKMenuParser: GTK item properties: %@", properties);
    
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
    
    // Remove mnemonic underscores from label (all occurrences)
    NSString *displayLabel = label;
    if ([label containsString:@"_"]) {
        displayLabel = [label stringByReplacingOccurrencesOfString:@"_" withString:@""];
        NSDebugLog(@"GTKMenuParser: Transformed GModel label '%@' -> '%@' (removed mnemonics)", label, displayLabel);
    }
    
    // Extract action
    NSString *action = [properties objectForKey:@"action"];
    
    // Extract other properties
    NSNumber *enabled = [properties objectForKey:@"enabled"];
    NSNumber *visible = [properties objectForKey:@"visible"];
    // NSString *iconName = [properties objectForKey:@"icon"]; // TODO: Handle icons
    NSString *keyEquiv = [properties objectForKey:@"accel"];
    
    NSDebugLog(@"GTKMenuParser: Creating GTK menu item - label='%@', action='%@', enabled=%@, visible=%@", 
          displayLabel, action ?: @"none", enabled ?: @"default", visible ?: @"default");
    
    // Create the menu item
    NSMenuItem *menuItem = [[NSMenuItem alloc] initWithTitle:displayLabel 
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
        NSDebugLog(@"GTKMenuParser: Set up GTK action for menu item '%@' (action=%@)", label, action);
    }
    
    // Handle submenus
    if (submenuItems && [submenuItems count] > 0) {
        NSDebugLog(@"GTKMenuParser: Creating GTK submenu for '%@' with %lu items", 
              label, (unsigned long)[submenuItems count]);
        
        NSMenu *submenu = [self parseGMenuModelItem:submenuItems 
                                             isRoot:NO 
                                        serviceName:serviceName 
                                         actionPath:actionPath 
                                     dbusConnection:dbusConnection];
        
        if (!submenu) {
            // Create placeholder submenu
            submenu = [[NSMenu alloc] initWithTitle:label];
        }
        
        [menuItem setSubmenu:submenu];
    }
    
    return menuItem;
}

+ (NSDictionary *)parseActionGroupFromResult:(id)result
{
    NSDebugLog(@"GTKMenuParser: Parsing GTK action group from result: %@ (%@)", result, [result class]);
    
    if (![result isKindOfClass:[NSArray class]] && ![result isKindOfClass:[NSDictionary class]]) {
        NSDebugLog(@"GTKMenuParser: Unexpected action group result type");
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
    
    NSDebugLog(@"GTKMenuParser: Parsed %lu GTK actions", (unsigned long)[actionGroup count]);
    return [NSDictionary dictionaryWithDictionary:actionGroup];
}

+ (NSString *)parseKeyboardShortcut:(NSString *)accel
{
    if (!accel || [accel length] == 0) {
        return @"";
    }
    
    NSString *key = accel;
    
    // Handle x-canonical-accel format: "Ctrl+O", "Shift+Ctrl+V", etc.
    if ([accel containsString:@"+"]) {
        // Split by + and get the last component (the actual key)
        NSArray *components = [accel componentsSeparatedByString:@"+"];
        if ([components count] > 0) {
            key = [components lastObject];
        }
    } else {
        // Handle GTK accelerator format: <Control>o, <Primary><Shift>n, <Alt>F4, etc.
        // Remove modifier prefixes (case-insensitive)
        key = [key stringByReplacingOccurrencesOfString:@"<Control>" withString:@"" options:NSCaseInsensitiveSearch range:NSMakeRange(0, [key length])];
        key = [key stringByReplacingOccurrencesOfString:@"<Primary>" withString:@"" options:NSCaseInsensitiveSearch range:NSMakeRange(0, [key length])];
        key = [key stringByReplacingOccurrencesOfString:@"<Shift>" withString:@"" options:NSCaseInsensitiveSearch range:NSMakeRange(0, [key length])];
        key = [key stringByReplacingOccurrencesOfString:@"<Alt>" withString:@"" options:NSCaseInsensitiveSearch range:NSMakeRange(0, [key length])];
        key = [key stringByReplacingOccurrencesOfString:@"<Meta>" withString:@"" options:NSCaseInsensitiveSearch range:NSMakeRange(0, [key length])];
        key = [key stringByReplacingOccurrencesOfString:@"<Super>" withString:@"" options:NSCaseInsensitiveSearch range:NSMakeRange(0, [key length])];
    }
    
    // Convert special keys - case-insensitive
    NSString *lowerKey = [key lowercaseString];
    if ([lowerKey isEqualToString:@"return"] || [lowerKey isEqualToString:@"enter"] ||
        [lowerKey isEqualToString:@"kp_enter"]) {
        return @"\r";
    }
    if ([lowerKey isEqualToString:@"tab"] || [lowerKey isEqualToString:@"kpad_tab"]) {
        return @"\t";
    }
    if ([lowerKey isEqualToString:@"backspace"] || [lowerKey isEqualToString:@"back_space"] ||
        [lowerKey isEqualToString:@"back"]) {
        return @"\b";
    }
    if ([lowerKey isEqualToString:@"delete"] || [lowerKey isEqualToString:@"delete_key"]) {
        return @"\x7f";
    }
    if ([lowerKey isEqualToString:@"escape"] || [lowerKey isEqualToString:@"esc"]) {
        return @"\x1b";
    }
    if ([lowerKey isEqualToString:@"space"]) {
        return @" ";
    }
    
    // Function keys
    if ([lowerKey hasPrefix:@"f"] && [lowerKey length] <= 4) {
        NSString *fNumStr = [lowerKey substringFromIndex:1];
        if ([fNumStr length] > 0) {
            BOOL isNumeric = YES;
            for (NSUInteger i = 0; i < [fNumStr length]; i++) {
                if (![[NSCharacterSet decimalDigitCharacterSet] characterIsMember:[fNumStr characterAtIndex:i]]) {
                    isNumeric = NO;
                    break;
                }
            }
            if (isNumeric) {
                int fNum = [fNumStr intValue];
                if (fNum >= 1 && fNum <= 24) {
                    return lowerKey;
                }
            }
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
    
    // Case-insensitive matching for modifier names from Canonical AppMenu / GTK
    NSString *lower = [accel lowercaseString];
    
    if ([lower containsString:@"<control>"] || [lower containsString:@"<primary>"] || 
        [lower containsString:@"ctrl+"]) {
        modifiers |= NSControlKeyMask;
    }
    if ([lower containsString:@"<shift>"] || [lower containsString:@"shift+"]) {
        modifiers |= NSShiftKeyMask;
    }
    if ([lower containsString:@"<alt>"] || [lower containsString:@"alt+"]) {
        modifiers |= NSAlternateKeyMask;
    }
    if ([lower containsString:@"<meta>"] || [lower containsString:@"<super>"] || 
        [lower containsString:@"meta+"] || [lower containsString:@"super+"]) {
        modifiers |= NSCommandKeyMask;
    }
    
    return modifiers;
}

@end
