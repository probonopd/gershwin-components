#import "DBusMenuParser.h"
#import "DBusConnection.h"
#import "X11ShortcutManager.h"
#import "DBusMenuShortcutParser.h"
#import "DBusMenuActionHandler.h"
#import "DBusSubmenuManager.h"

@implementation DBusMenuParser

+ (void)initialize
{
    if (self == [DBusMenuParser class]) {
        // The subsystem initialize methods will be called automatically by the runtime
        // when the classes are first accessed, so we don't need to call them explicitly
    }
}

+ (NSMenu *)parseMenuFromDBusResult:(id)result serviceName:(NSString *)serviceName
{
    // Backward compatibility method - call the new method with nil parameters
    return [self parseMenuFromDBusResult:result serviceName:serviceName objectPath:nil dbusConnection:nil];
}

+ (NSMenu *)parseMenuFromDBusResult:(id)result 
                        serviceName:(NSString *)serviceName 
                         objectPath:(NSString *)objectPath 
                     dbusConnection:(GNUDBusConnection *)dbusConnection
{
    NSLog(@"DBusMenuParser: ===== PARSING MENU STRUCTURE (with actions) =====");
    NSLog(@"DBusMenuParser: Parsing menu structure from service: %@", serviceName);
    NSLog(@"DBusMenuParser: Object path: %@", objectPath);
    NSLog(@"DBusMenuParser: DBus connection: %@", dbusConnection);
    NSLog(@"DBusMenuParser: Menu result type: %@", [result class]);
    NSLog(@"DBusMenuParser: Menu result object: %@", result);
    NSLog(@"DBusMenuParser: Menu result description: %@", [result description]);
    
    // Unregister any existing global shortcuts before parsing new menu
    [[X11ShortcutManager sharedManager] unregisterAllShortcuts];
    
    // Check if result is a number (error case)
    if ([result isKindOfClass:[NSNumber class]]) {
        NSLog(@"DBusMenuParser: ERROR: Received NSNumber instead of array structure!");
        NSLog(@"DBusMenuParser: This suggests the DBus method call failed or returned an error code");
        NSLog(@"DBusMenuParser: Number value: %@", result);
        return nil;
    }
    
    if (![result isKindOfClass:[NSArray class]]) {
        NSLog(@"DBusMenuParser: ERROR: Expected array result, got %@", [result class]);
        NSLog(@"DBusMenuParser: Raw object details:");
        NSLog(@"DBusMenuParser:   - Class: %@", [result class]);
        NSLog(@"DBusMenuParser:   - Superclass: %@", [[result class] superclass]);
        NSLog(@"DBusMenuParser:   - Description: %@", [result description]);
        if ([result respondsToSelector:@selector(stringValue)]) {
            NSLog(@"DBusMenuParser:   - String value: %@", [result stringValue]);
        }
        return nil;
    }
    
    NSArray *resultArray = (NSArray *)result;
    NSLog(@"DBusMenuParser: Result array has %lu elements", (unsigned long)[resultArray count]);
    
    if ([resultArray count] < 2) {
        NSLog(@"DBusMenuParser: ERROR: GetLayout result should have at least 2 elements (revision + layout)");
        NSLog(@"DBusMenuParser: Actual count: %lu", (unsigned long)[resultArray count]);
        for (NSUInteger i = 0; i < [resultArray count]; i++) {
            id item = [resultArray objectAtIndex:i];
            NSLog(@"DBusMenuParser: Element[%lu]: %@ (%@)", i, item, [item class]);
        }
        return nil;
    }
    
    // First element is revision number (uint32)
    NSNumber *revision = [resultArray objectAtIndex:0];
    NSLog(@"DBusMenuParser: Menu revision: %@ (class: %@)", revision, [revision class]);
    
    // Second element is the layout item structure: (ia{sv}av)
    id layoutItem = [resultArray objectAtIndex:1];
    NSLog(@"DBusMenuParser: Layout item type: %@", [layoutItem class]);
    NSLog(@"DBusMenuParser: Layout item content: %@", layoutItem);
    NSLog(@"DBusMenuParser: Layout item description: %@", [layoutItem description]);
    
    NSMenu *menu = [self parseLayoutItem:layoutItem 
                                  isRoot:YES 
                             serviceName:serviceName 
                              objectPath:objectPath 
                          dbusConnection:dbusConnection];
    if (menu) {
        NSLog(@"DBusMenuParser: ===== MENU PARSING SUCCESS =====");
        NSLog(@"DBusMenuParser: Successfully parsed menu with %lu items", 
              (unsigned long)[[menu itemArray] count]);
        
        // Log each menu item
        NSArray *items = [menu itemArray];
        for (NSUInteger i = 0; i < [items count]; i++) {
            NSMenuItem *item = [items objectAtIndex:i];
            NSLog(@"DBusMenuParser: Menu[%lu]: '%@' (enabled: %@, hasSubmenu: %@)", 
                  i, [item title], [item isEnabled] ? @"YES" : @"NO", 
                  [item hasSubmenu] ? @"YES" : @"NO");
        }
    } else {
        NSLog(@"DBusMenuParser: ===== MENU PARSING FAILED =====");
        NSLog(@"DBusMenuParser: Failed to parse layout item");
    }
    
    return menu;
}

+ (NSMenu *)parseLayoutItem:(id)layoutItem isRoot:(BOOL)isRoot
{
    NSLog(@"DBusMenuParser: ===== PARSING LAYOUT ITEM (isRoot=%@) =====", isRoot ? @"YES" : @"NO");
    NSLog(@"DBusMenuParser: Layout item class: %@", [layoutItem class]);
    NSLog(@"DBusMenuParser: Layout item object: %@", layoutItem);
    
    if (![layoutItem isKindOfClass:[NSArray class]]) {
        NSLog(@"DBusMenuParser: ERROR: Layout item should be an array, got %@", [layoutItem class]);
        return nil;
    }
    
    NSArray *itemArray = (NSArray *)layoutItem;
    NSLog(@"DBusMenuParser: Layout item array has %lu elements", (unsigned long)[itemArray count]);
    
    if ([itemArray count] < 3) {
        NSLog(@"DBusMenuParser: ERROR: Layout item should have at least 3 elements (id, properties, children)");
        NSLog(@"DBusMenuParser: Actual count: %lu", (unsigned long)[itemArray count]);
        for (NSUInteger i = 0; i < [itemArray count]; i++) {
            id element = [itemArray objectAtIndex:i];
            NSLog(@"DBusMenuParser: Element[%lu]: %@ (%@)", i, element, [element class]);
        }
        return nil;
    }
    
    // Extract the layout item components: (ia{sv}av)
    NSNumber *itemId = [itemArray objectAtIndex:0];
    id propertiesObj = [itemArray objectAtIndex:1];
    id childrenObj = [itemArray objectAtIndex:2];
    
    NSLog(@"DBusMenuParser: Item ID: %@ (class: %@)", itemId, [itemId class]);
    NSLog(@"DBusMenuParser: Properties object: %@ (class: %@)", propertiesObj, [propertiesObj class]);
    NSLog(@"DBusMenuParser: Children object: %@ (class: %@)", childrenObj, [childrenObj class]);
    
    // Convert properties to dictionary
    NSDictionary *properties = [self convertPropertiesToDictionary:propertiesObj];
    
    // Convert children to array if needed
    NSArray *children = nil;
    if ([childrenObj isKindOfClass:[NSArray class]]) {
        children = (NSArray *)childrenObj;
    } else {
        NSLog(@"DBusMenuParser: WARNING: Children is not an array, creating empty one");
        children = [NSArray array];
    }
    
    NSLog(@"DBusMenuParser: Properties dict has %lu entries:", (unsigned long)[properties count]);
    for (NSString *key in [properties allKeys]) {
        id value = [properties objectForKey:key];
        NSLog(@"DBusMenuParser:   %@ = %@ (%@)", key, value, [value class]);
    }
    
    NSLog(@"DBusMenuParser: Children array has %lu elements", (unsigned long)[children count]);
    
    // For root item, create the main menu
    NSMenu *menu = nil;
    if (isRoot) {
        NSString *menuTitle = [properties objectForKey:@"label"];
        if (!menuTitle || [menuTitle length] == 0) {
            menuTitle = @"App Menu";
        }
        NSLog(@"DBusMenuParser: Creating root menu with title: '%@'", menuTitle);
        menu = [[NSMenu alloc] initWithTitle:menuTitle];
        
        // Process children of root item
        NSLog(@"DBusMenuParser: Processing %lu children of root item", (unsigned long)[children count]);
        for (NSUInteger i = 0; i < [children count]; i++) {
            id childItem = [children objectAtIndex:i];
            NSLog(@"DBusMenuParser: Processing child %lu: %@ (%@)", i, childItem, [childItem class]);
            
            NSMenuItem *menuItem = [self createMenuItemFromLayoutItem:childItem];
            if (menuItem) {
                [menu addItem:menuItem];
                NSLog(@"DBusMenuParser: Added menu item: '%@'", [menuItem title]);
            } else {
                NSLog(@"DBusMenuParser: Failed to create menu item from child %lu", i);
            }
        }
        
        NSLog(@"DBusMenuParser: Root menu created with %lu items", (unsigned long)[[menu itemArray] count]);
    } else {
        // This shouldn't happen for root parsing, but handle it
        NSLog(@"DBusMenuParser: ERROR: parseLayoutItem called with isRoot=NO");
        return nil;
    }
    
    return [menu autorelease];
}

+ (NSMenu *)parseLayoutItem:(id)layoutItem 
                     isRoot:(BOOL)isRoot 
                serviceName:(NSString *)serviceName 
                 objectPath:(NSString *)objectPath 
             dbusConnection:(GNUDBusConnection *)dbusConnection
{
    NSLog(@"DBusMenuParser: ===== PARSING LAYOUT ITEM (isRoot=%@) =====", isRoot ? @"YES" : @"NO");
    NSLog(@"DBusMenuParser: Layout item class: %@", [layoutItem class]);
    NSLog(@"DBusMenuParser: Layout item object: %@", layoutItem);
    
    if (![layoutItem isKindOfClass:[NSArray class]]) {
        NSLog(@"DBusMenuParser: ERROR: Layout item should be an array, got %@", [layoutItem class]);
        return nil;
    }
    
    NSArray *itemArray = (NSArray *)layoutItem;
    NSLog(@"DBusMenuParser: Layout item array has %lu elements", (unsigned long)[itemArray count]);
    
    if ([itemArray count] < 3) {
        NSLog(@"DBusMenuParser: ERROR: Layout item should have at least 3 elements (id, properties, children)");
        NSLog(@"DBusMenuParser: Actual count: %lu", (unsigned long)[itemArray count]);
        for (NSUInteger i = 0; i < [itemArray count]; i++) {
            id element = [itemArray objectAtIndex:i];
            NSLog(@"DBusMenuParser: Element[%lu]: %@ (%@)", i, element, [element class]);
        }
        return nil;
    }
    
    // Extract the layout item components: (ia{sv}av)
    NSNumber *itemId = [itemArray objectAtIndex:0];
    id propertiesObj = [itemArray objectAtIndex:1];
    id childrenObj = [itemArray objectAtIndex:2];
    
    NSLog(@"DBusMenuParser: Item ID: %@ (class: %@)", itemId, [itemId class]);
    NSLog(@"DBusMenuParser: Properties object: %@ (class: %@)", propertiesObj, [propertiesObj class]);
    NSLog(@"DBusMenuParser: Children object: %@ (class: %@)", childrenObj, [childrenObj class]);
    
    // Convert properties to dictionary
    NSDictionary *properties = [self convertPropertiesToDictionary:propertiesObj];
    
    // Convert children to array if needed
    NSArray *children = nil;
    if ([childrenObj isKindOfClass:[NSArray class]]) {
        children = (NSArray *)childrenObj;
    } else {
        NSLog(@"DBusMenuParser: WARNING: Children is not an array, creating empty one");
        children = [NSArray array];
    }
    
    NSLog(@"DBusMenuParser: Properties dict has %lu entries:", (unsigned long)[properties count]);
    for (NSString *key in [properties allKeys]) {
        id value = [properties objectForKey:key];
        NSLog(@"DBusMenuParser:   %@ = %@ (%@)", key, value, [value class]);
    }
    
    NSLog(@"DBusMenuParser: Children array has %lu elements", (unsigned long)[children count]);
    
    // For root item, create the main menu
    NSMenu *menu = nil;
    if (isRoot) {
        NSString *menuTitle = [properties objectForKey:@"label"];
        if (!menuTitle || [menuTitle length] == 0) {
            menuTitle = @"App Menu";
        }
        NSLog(@"DBusMenuParser: Creating root menu with title: '%@'", menuTitle);
        menu = [[NSMenu alloc] initWithTitle:menuTitle];
        
        // Process children of root item
        NSLog(@"DBusMenuParser: Processing %lu children of root item", (unsigned long)[children count]);
        for (NSUInteger i = 0; i < [children count]; i++) {
            id childItem = [children objectAtIndex:i];
            NSLog(@"DBusMenuParser: Processing child %lu: %@ (%@)", i, childItem, [childItem class]);
            
            NSMenuItem *menuItem = [self createMenuItemFromLayoutItem:childItem 
                                                          serviceName:serviceName 
                                                           objectPath:objectPath 
                                                       dbusConnection:dbusConnection];
            if (menuItem) {
                [menu addItem:menuItem];
                NSLog(@"DBusMenuParser: Added menu item: '%@'", [menuItem title]);
            } else {
                NSLog(@"DBusMenuParser: Failed to create menu item from child %lu", i);
            }
        }
        
        NSLog(@"DBusMenuParser: Root menu created with %lu items", (unsigned long)[[menu itemArray] count]);
    } else {
        // This shouldn't happen for root parsing, but handle it
        NSLog(@"DBusMenuParser: ERROR: parseLayoutItem called with isRoot=NO");
        return nil;
    }
    
    return [menu autorelease];
}

+ (NSMenuItem *)createMenuItemFromLayoutItem:(id)layoutItem
{
    // Backward compatibility method - call the new method with nil parameters
    return [self createMenuItemFromLayoutItem:layoutItem serviceName:nil objectPath:nil dbusConnection:nil];
}

+ (NSMenuItem *)createMenuItemFromLayoutItem:(id)layoutItem 
                                 serviceName:(NSString *)serviceName 
                                  objectPath:(NSString *)objectPath 
                              dbusConnection:(GNUDBusConnection *)dbusConnection
{
    if (![layoutItem isKindOfClass:[NSArray class]]) {
        NSLog(@"DBusMenuParser: Layout item should be an array");
        return nil;
    }
    
    NSArray *itemArray = (NSArray *)layoutItem;
    if ([itemArray count] < 3) {
        NSLog(@"DBusMenuParser: Layout item should have at least 3 elements");
        return nil;
    }
    
    NSNumber *itemId = [itemArray objectAtIndex:0];
    id propertiesObj = [itemArray objectAtIndex:1];
    id childrenObj = [itemArray objectAtIndex:2];
    
    // Convert properties to dictionary
    NSDictionary *properties = [self convertPropertiesToDictionary:propertiesObj];
    
    // Convert children to array if needed
    NSArray *children = nil;
    if ([childrenObj isKindOfClass:[NSArray class]]) {
        children = (NSArray *)childrenObj;
    } else {
        NSLog(@"DBusMenuParser: WARNING: Children is not an array in createMenuItemFromLayoutItem, creating empty one");
        children = [NSArray array];
    }
    
    // Get menu item properties
    NSString *label = [properties objectForKey:@"label"];
    NSString *type = [properties objectForKey:@"type"];
    NSNumber *visible = [properties objectForKey:@"visible"];
    NSNumber *enabled = [properties objectForKey:@"enabled"];
    NSString *childrenDisplay = [properties objectForKey:@"children-display"];
    
    // Get shortcut/accelerator properties
    NSArray *shortcut = [properties objectForKey:@"shortcut"];
    NSString *accel = [properties objectForKey:@"accel"];
    NSString *accelerator = [properties objectForKey:@"accelerator"];
    NSString *keyBinding = [properties objectForKey:@"key-binding"];
    
    // Log all properties to understand what's available
    if ([properties count] > 0) {
        NSLog(@"DBusMenuParser: All properties for '%@': %@", 
              label ?: @"(no label)", properties);
    }
    
    // Check if this is a submenu container
    BOOL hasChildren = ([children count] > 0);
    BOOL hasSubmenuDisplay = (childrenDisplay && [childrenDisplay isEqualToString:@"submenu"]);
    BOOL isSubmenu = hasChildren || hasSubmenuDisplay;
    
    NSLog(@"DBusMenuParser: ===== SUBMENU DETECTION FOR '%@' =====", label ?: @"(no label)");
    NSLog(@"DBusMenuParser: Item ID: %@", itemId);
    NSLog(@"DBusMenuParser: Children count: %lu", (unsigned long)[children count]);
    NSLog(@"DBusMenuParser: Children-display property: '%@'", childrenDisplay ?: @"(none)");
    NSLog(@"DBusMenuParser: Has children: %@", hasChildren ? @"YES" : @"NO");
    NSLog(@"DBusMenuParser: Has submenu display: %@", hasSubmenuDisplay ? @"YES" : @"NO");
    NSLog(@"DBusMenuParser: Final isSubmenu decision: %@", isSubmenu ? @"YES" : @"NO");
    
    if (hasChildren) {
        NSLog(@"DBusMenuParser: Children details:");
        for (NSUInteger i = 0; i < [children count]; i++) {
            id child = [children objectAtIndex:i];
            NSLog(@"DBusMenuParser:   Child[%lu]: %@ (%@)", i, child, [child class]);
        }
    }
    
    if (isSubmenu) {
        NSLog(@"DBusMenuParser: Item '%@' is a submenu (children=%lu, children-display=%@)", 
              label ?: @"(no label)", (unsigned long)[children count], childrenDisplay ?: @"(none)");
    } else {
        NSLog(@"DBusMenuParser: Item '%@' is NOT a submenu", label ?: @"(no label)");
    }
    
    // Skip invisible items
    if (visible && ![visible boolValue]) {
        return nil;
    }
    
    // Handle separators
    if (type && [type isEqualToString:@"separator"]) {
        return (NSMenuItem *)[NSMenuItem separatorItem];
    }
    
    // Process label - remove underscores (mnemonics) entirely
    if (!label) {
        label = @"";
    } else {
        // Check if the label contains underscores and log the transformation
        if ([label containsString:@"_"]) {
            NSString *originalLabel = label;
            label = [label stringByReplacingOccurrencesOfString:@"_" withString:@""];
            NSLog(@"DBusMenuParser: Transformed label '%@' -> '%@' (removed mnemonics)", originalLabel, label);
        }
    }
    
    // Process shortcut to get key equivalent
    NSString *keyEquivalent = @"";
    NSUInteger modifierMask = 0;
    
    if (shortcut && [shortcut isKindOfClass:[NSArray class]] && [shortcut count] > 0) {
        // DBus shortcut format is typically an array of keysyms and modifiers
        NSLog(@"DBusMenuParser: Found shortcut array for '%@': %@", label, shortcut);
        NSString *keyCombo = [DBusMenuShortcutParser parseShortcutArray:shortcut];
        if (keyCombo) {
            NSLog(@"DBusMenuParser: Parsed shortcut array to: %@", keyCombo);
            NSDictionary *parsedShortcut = [DBusMenuShortcutParser parseKeyCombo:keyCombo];
            keyEquivalent = [parsedShortcut objectForKey:@"key"] ?: @"";
            modifierMask = [[parsedShortcut objectForKey:@"modifiers"] unsignedIntegerValue];
        }
    } else if (accel && [accel isKindOfClass:[NSString class]] && [accel length] > 0) {
        // Alternative accelerator format (string-based)
        NSLog(@"DBusMenuParser: Found accel string for '%@': %@", label, accel);
        NSDictionary *parsedShortcut = [DBusMenuShortcutParser parseKeyCombo:accel];
        keyEquivalent = [parsedShortcut objectForKey:@"key"] ?: @"";
        modifierMask = [[parsedShortcut objectForKey:@"modifiers"] unsignedIntegerValue];
    } else if (accelerator && [accelerator isKindOfClass:[NSString class]] && [accelerator length] > 0) {
        // Another accelerator format
        NSLog(@"DBusMenuParser: Found accelerator string for '%@': %@", label, accelerator);
        NSDictionary *parsedShortcut = [DBusMenuShortcutParser parseKeyCombo:accelerator];
        keyEquivalent = [parsedShortcut objectForKey:@"key"] ?: @"";
        modifierMask = [[parsedShortcut objectForKey:@"modifiers"] unsignedIntegerValue];
    } else if (keyBinding && [keyBinding isKindOfClass:[NSString class]] && [keyBinding length] > 0) {
        // Key binding format
        NSLog(@"DBusMenuParser: Found key-binding string for '%@': %@", label, keyBinding);
        NSDictionary *parsedShortcut = [DBusMenuShortcutParser parseKeyCombo:keyBinding];
        keyEquivalent = [parsedShortcut objectForKey:@"key"] ?: @"";
        modifierMask = [[parsedShortcut objectForKey:@"modifiers"] unsignedIntegerValue];
    }
    
    NSMenuItem *menuItem = [[NSMenuItem alloc] initWithTitle:label
                                                      action:nil
                                               keyEquivalent:keyEquivalent];
    
    NSLog(@"DBusMenuParser: ===== CREATED MENU ITEM =====");
    NSLog(@"DBusMenuParser: Menu item object: %@", menuItem);
    NSLog(@"DBusMenuParser: Title: '%@'", [menuItem title]);
    NSLog(@"DBusMenuParser: Tag (item ID): %ld", (long)[menuItem tag]);
    NSLog(@"DBusMenuParser: Key equivalent: '%@'", [menuItem keyEquivalent]);
    NSLog(@"DBusMenuParser: Modifier mask: %lu", (unsigned long)[menuItem keyEquivalentModifierMask]);
    
    // Set enabled state
    if (enabled) {
        [menuItem setEnabled:[enabled boolValue]];
        NSLog(@"DBusMenuParser: Set enabled state to: %@", [enabled boolValue] ? @"YES" : @"NO");
    } else {
        NSLog(@"DBusMenuParser: No enabled property, using default");
    }
    
    // Set key equivalent modifier mask
    if (modifierMask > 0) {
        [menuItem setKeyEquivalentModifierMask:modifierMask];
        NSLog(@"DBusMenuParser: Set modifier mask to: %lu", (unsigned long)modifierMask);
    }
    
    // Store item ID for event handling
    [menuItem setTag:[itemId intValue]];
    NSLog(@"DBusMenuParser: Set tag (item ID) to: %ld", (long)[itemId intValue]);
    
    // Set up action for menu items if we have DBus connection info and this isn't a submenu
    if (serviceName && objectPath && dbusConnection && !isSubmenu) {
        [DBusMenuActionHandler setupActionForMenuItem:menuItem
                                          serviceName:serviceName
                                           objectPath:objectPath
                                       dbusConnection:dbusConnection];
        
        NSLog(@"DBusMenuParser: Set up action for menu item '%@' (ID=%@, service=%@, path=%@)", 
              label, itemId, serviceName, objectPath);
    } else if (isSubmenu) {
        NSLog(@"DBusMenuParser: Skipping action setup for submenu '%@'", label);
    }
    
    // Process children (submenu)
    if (isSubmenu) {
        NSLog(@"DBusMenuParser: ===== CREATING SUBMENU FOR '%@' =====", label ?: @"(no label)");
        NSLog(@"DBusMenuParser: Submenu detected - children count: %lu", (unsigned long)[children count]);
        NSLog(@"DBusMenuParser: Submenu detected - children-display: %@", childrenDisplay ?: @"(none)");
        NSLog(@"DBusMenuParser: Submenu detected - item ID: %@", itemId);
        NSLog(@"DBusMenuParser: Submenu detected - service: %@", serviceName ?: @"(none)");
        NSLog(@"DBusMenuParser: Submenu detected - object path: %@", objectPath ?: @"(none)");
        NSLog(@"DBusMenuParser: Submenu detected - dbus connection: %@", dbusConnection ? @"available" : @"none");
        
        NSMenu *submenu = [[NSMenu alloc] initWithTitle:label ? label : @""];
        NSLog(@"DBusMenuParser: Created NSMenu object for submenu: %@", submenu);
        
        // Create submenu items - but mark that we may need to refresh them via AboutToShow
        NSLog(@"DBusMenuParser: Adding %lu initial child items to submenu...", (unsigned long)[children count]);
        NSUInteger addedItems = 0;
        for (NSUInteger childIndex = 0; childIndex < [children count]; childIndex++) {
            id childItem = [children objectAtIndex:childIndex];
            NSLog(@"DBusMenuParser: Processing child item %lu: %@ (%@)", 
                  childIndex, childItem, [childItem class]);
            
            NSMenuItem *childMenuItem = [self createMenuItemFromLayoutItem:childItem 
                                                               serviceName:serviceName 
                                                                objectPath:objectPath 
                                                            dbusConnection:dbusConnection];
            if (childMenuItem) {
                [submenu addItem:childMenuItem];
                addedItems++;
                NSLog(@"DBusMenuParser: Added child menu item '%@' to submenu '%@' (total now: %lu)", 
                      [childMenuItem title], label, addedItems);
            } else {
                NSLog(@"DBusMenuParser: ERROR: Failed to create child menu item %lu for submenu '%@'", 
                      childIndex, label);
            }
        }
        
        NSLog(@"DBusMenuParser: Finished adding items to submenu - %lu added out of %lu attempted", 
              addedItems, (unsigned long)[children count]);
        
        // Set up submenu with delegate and attach it to the menu item
        [DBusSubmenuManager setupSubmenu:submenu
                             forMenuItem:menuItem
                             serviceName:serviceName
                              objectPath:objectPath
                          dbusConnection:dbusConnection
                                  itemId:itemId];
        
        [submenu release];
        NSLog(@"DBusMenuParser: ===== SUBMENU CREATION COMPLETE FOR '%@' =====", label ?: @"(no label)");
    } else {
        NSLog(@"DBusMenuParser: Item '%@' is NOT a submenu (children=%lu, children-display=%@)", 
              label ?: @"(no label)", (unsigned long)[children count], childrenDisplay ?: @"(none)");
    }
    
    NSLog(@"DBusMenuParser: Created menu item: '%@' (ID=%@, enabled=%@, children=%lu, shortcut=%@)",
          label, itemId, enabled, (unsigned long)[children count], 
          ([keyEquivalent length] > 0) ? [NSString stringWithFormat:@"%@+%@", 
           [DBusMenuShortcutParser modifierMaskToString:modifierMask], keyEquivalent] : @"none");
    
    return [menuItem autorelease];
}

+ (NSDictionary *)convertPropertiesToDictionary:(id)propertiesObj
{
    NSLog(@"DBusMenuParser: Converting properties object: %@ (class: %@)", propertiesObj, [propertiesObj class]);
    
    // If it's already a dictionary, return it
    if ([propertiesObj isKindOfClass:[NSDictionary class]]) {
        NSLog(@"DBusMenuParser: Properties is already a dictionary");
        return (NSDictionary *)propertiesObj;
    }
    
    // If it's an array of dictionaries (which is what we're seeing), merge them
    if ([propertiesObj isKindOfClass:[NSArray class]]) {
        NSArray *propsArray = (NSArray *)propertiesObj;
        NSMutableDictionary *mergedDict = [NSMutableDictionary dictionary];
        
        NSLog(@"DBusMenuParser: Properties is an array with %lu elements, merging...", (unsigned long)[propsArray count]);
        
        for (NSUInteger i = 0; i < [propsArray count]; i++) {
            id element = [propsArray objectAtIndex:i];
            NSLog(@"DBusMenuParser: Processing properties element[%lu]: %@ (%@)", i, element, [element class]);
            
            if ([element isKindOfClass:[NSDictionary class]]) {
                NSDictionary *elementDict = (NSDictionary *)element;
                NSLog(@"DBusMenuParser: Element is dictionary with %lu keys", (unsigned long)[elementDict count]);
                
                // Merge this dictionary into our result
                for (NSString *key in [elementDict allKeys]) {
                    id value = [elementDict objectForKey:key];
                    [mergedDict setObject:value forKey:key];
                    NSLog(@"DBusMenuParser: Added property: %@ = %@", key, value);
                }
            } else {
                NSLog(@"DBusMenuParser: WARNING: Properties array element is not a dictionary: %@ (%@)", 
                      element, [element class]);
            }
        }
        
        NSLog(@"DBusMenuParser: Merged properties dictionary has %lu entries", (unsigned long)[mergedDict count]);
        return mergedDict;
    }
    
    NSLog(@"DBusMenuParser: WARNING: Properties is neither dictionary nor array, creating empty one");
    NSLog(@"DBusMenuParser: Properties object class: %@", [propertiesObj class]);
    NSLog(@"DBusMenuParser: Properties object: %@", propertiesObj);
    return [NSDictionary dictionary];
}

+ (void)cleanup
{
    NSLog(@"DBusMenuParser: Performing cleanup...");
    [DBusMenuActionHandler cleanup];
    [DBusSubmenuManager cleanup];
}

@end
