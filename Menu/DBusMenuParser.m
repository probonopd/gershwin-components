#import "DBusMenuParser.h"

@implementation DBusMenuParser

+ (NSMenu *)parseMenuFromDBusResult:(id)result serviceName:(NSString *)serviceName
{
    NSLog(@"DBusMenuParser: ===== PARSING MENU STRUCTURE =====");
    NSLog(@"DBusMenuParser: Parsing menu structure from service: %@", serviceName);
    NSLog(@"DBusMenuParser: Menu result type: %@", [result class]);
    NSLog(@"DBusMenuParser: Menu result object: %@", result);
    NSLog(@"DBusMenuParser: Menu result description: %@", [result description]);
    
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
    
    NSMenu *menu = [self parseLayoutItem:layoutItem isRoot:YES];
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

+ (NSMenuItem *)createMenuItemFromLayoutItem:(id)layoutItem
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
    
    NSLog(@"DBusMenuParser: Created menu item: '%@' (ID=%@, enabled=%@, children=%lu)",
          label, itemId, enabled, (unsigned long)[children count]);
    
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

@end
