/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */


#import "DBusMenuParser.h"
#import "DBusConnection.h"
#import "X11ShortcutManager.h"
#import "DBusMenuShortcutParser.h"
#import "DBusMenuActionHandler.h"
#import "DBusSubmenuManager.h"
#import "MenuProfiler.h"

/* ── Shortcut cache ────────────────────────────────────────────────
 *
 * Some applications (notably Chromium) omit shortcut properties from
 * certain window types (incognito, new-tab-page, popups).  We cache
 * shortcuts seen on one window and replay them onto sibling windows
 * from the same D-Bus service that are missing them.
 *
 * Cache structure:
 *   _shortcutCache[serviceName][itemId] = @{@"key": ..., @"modifiers": @(...)}
 */
static NSMutableDictionary *_shortcutCache = nil;

static NSDictionary *cachedShortcut(NSString *service, NSNumber *itemId)
{
    if (!_shortcutCache || !service || !itemId) return nil;
    NSMutableDictionary *byService = [_shortcutCache objectForKey:service];
    if (!byService) return nil;
    return [byService objectForKey:itemId];
}

static void cacheShortcut(NSString *service, NSNumber *itemId,
                          NSString *key, NSUInteger modifiers)
{
    if (!_shortcutCache) {
        _shortcutCache = [[NSMutableDictionary alloc] init];
    }
    NSMutableDictionary *byService = [_shortcutCache objectForKey:service];
    if (!byService) {
        byService = [[NSMutableDictionary alloc] init];
        [_shortcutCache setObject:byService forKey:service];
    }
    [byService setObject:@{@"key": key ?: @"", @"modifiers": @(modifiers)}
                  forKey:itemId];
}

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
    MENU_PROFILE_BEGIN(parseMenu);
    
    NSDebugLog(@"DBusMenuParser: ===== PARSING MENU STRUCTURE (with actions) =====");
    NSDebugLog(@"DBusMenuParser: Parsing menu structure from service: %@", serviceName);
    NSDebugLog(@"DBusMenuParser: Object path: %@", objectPath);
    NSDebugLog(@"DBusMenuParser: DBus connection: %@", dbusConnection);
    NSDebugLog(@"DBusMenuParser: Menu result type: %@", [result class]);
    NSDebugLog(@"DBusMenuParser: Menu result object: %@", result);
    NSDebugLog(@"DBusMenuParser: Menu result description: %@", [result description]);
    
    // Unregister any existing DBus-registered/global shortcuts (preserve direct app shortcuts)
    [[X11ShortcutManager sharedManager] unregisterNonDirectShortcuts];
    
    // Check if result is a number (error case)
    if ([result isKindOfClass:[NSNumber class]]) {
        NSDebugLog(@"DBusMenuParser: ERROR: Received NSNumber instead of array structure!");
        NSDebugLog(@"DBusMenuParser: This suggests the DBus method call failed or returned an error code");
        NSDebugLog(@"DBusMenuParser: Number value: %@", result);
        MENU_PROFILE_END(parseMenu);
        return nil;
    }
    
    if (![result isKindOfClass:[NSArray class]]) {
        NSDebugLog(@"DBusMenuParser: ERROR: Expected array result, got %@", [result class]);
        NSDebugLog(@"DBusMenuParser: Raw object details:");
        NSDebugLog(@"DBusMenuParser:   - Class: %@", [result class]);
        NSDebugLog(@"DBusMenuParser:   - Superclass: %@", [[result class] superclass]);
        NSDebugLog(@"DBusMenuParser:   - Description: %@", [result description]);
        if ([result respondsToSelector:@selector(stringValue)]) {
            NSDebugLog(@"DBusMenuParser:   - String value: %@", [result stringValue]);
        }
        MENU_PROFILE_END(parseMenu);
        return nil;
    }
    
    NSArray *resultArray = (NSArray *)result;
    NSDebugLog(@"DBusMenuParser: Result array has %lu elements", (unsigned long)[resultArray count]);
    
    if ([resultArray count] < 2) {
        NSDebugLog(@"DBusMenuParser: ERROR: GetLayout result should have at least 2 elements (revision + layout)");
        NSDebugLog(@"DBusMenuParser: Actual count: %lu", (unsigned long)[resultArray count]);
        for (NSUInteger i = 0; i < [resultArray count]; i++) {
            id item = [resultArray objectAtIndex:i];
            NSDebugLog(@"DBusMenuParser: Element[%lu]: %@ (%@)", i, item, [item class]);
        }
        MENU_PROFILE_END(parseMenu);
        return nil;
    }
    
    // First element is revision number (uint32). Guard against malformed
    // payloads that send a non-number here — sending numeric messages to
    // a string/variant below would dispatch via objc_msgSend_fpret and
    // crash on a freed/mistyped object.
    id revisionObj = [resultArray objectAtIndex:0];
    if (![revisionObj isKindOfClass:[NSNumber class]]) {
        NSDebugLog(@"DBusMenuParser: ERROR: revision is %@, not NSNumber",
                   [revisionObj class]);
        MENU_PROFILE_END(parseMenu);
        return nil;
    }
    NSNumber *revision = (NSNumber *)revisionObj;
    NSDebugLog(@"DBusMenuParser: Menu revision: %@ (class: %@)", revision, [revision class]);
    
    // Second element is the layout item structure: (ia{sv}av)
    id layoutItem = [resultArray objectAtIndex:1];
    NSDebugLog(@"DBusMenuParser: Layout item type: %@", [layoutItem class]);
    NSDebugLog(@"DBusMenuParser: Layout item content: %@", layoutItem);
    NSDebugLog(@"DBusMenuParser: Layout item description: %@", [layoutItem description]);
    
    NSMenu *menu = [self parseLayoutItem:layoutItem 
                                  isRoot:YES 
                             serviceName:serviceName 
                              objectPath:objectPath 
                          dbusConnection:dbusConnection];
    if (menu) {
        NSDebugLog(@"DBusMenuParser: ===== MENU PARSING SUCCESS =====");
        NSDebugLog(@"DBusMenuParser: Successfully parsed menu with %lu items", 
              (unsigned long)[[menu itemArray] count]);
        
        // Log each menu item
        NSArray *items = [menu itemArray];
        for (NSUInteger i = 0; i < [items count]; i++) {
            NSMenuItem *item = [items objectAtIndex:i];
            NSDebugLog(@"DBusMenuParser: Menu[%lu]: '%@' (enabled: %@, hasSubmenu: %@)", 
                  i, [item title], [item isEnabled] ? @"YES" : @"NO", 
                  [item hasSubmenu] ? @"YES" : @"NO");
        }
    } else {
        NSDebugLog(@"DBusMenuParser: ===== MENU PARSING FAILED =====");
        NSDebugLog(@"DBusMenuParser: Failed to parse layout item");
    }
    
    MENU_PROFILE_END(parseMenu);
    return menu;
}

+ (NSMenu *)parseLayoutItem:(id)layoutItem isRoot:(BOOL)isRoot
{
    NSDebugLog(@"DBusMenuParser: ===== PARSING LAYOUT ITEM (isRoot=%@) =====", isRoot ? @"YES" : @"NO");
    NSDebugLog(@"DBusMenuParser: Layout item class: %@", [layoutItem class]);
    NSDebugLog(@"DBusMenuParser: Layout item object: %@", layoutItem);
    
    if (![layoutItem isKindOfClass:[NSArray class]]) {
        NSDebugLog(@"DBusMenuParser: ERROR: Layout item should be an array, got %@", [layoutItem class]);
        return nil;
    }
    
    NSArray *itemArray = (NSArray *)layoutItem;
    NSDebugLog(@"DBusMenuParser: Layout item array has %lu elements", (unsigned long)[itemArray count]);
    
    if ([itemArray count] < 3) {
        NSDebugLog(@"DBusMenuParser: ERROR: Layout item should have at least 3 elements (id, properties, children)");
        NSDebugLog(@"DBusMenuParser: Actual count: %lu", (unsigned long)[itemArray count]);
        for (NSUInteger i = 0; i < [itemArray count]; i++) {
            id element = [itemArray objectAtIndex:i];
            NSDebugLog(@"DBusMenuParser: Element[%lu]: %@ (%@)", i, element, [element class]);
        }
        return nil;
    }
    
    // Extract the layout item components: (ia{sv}av). Reject non-number
    // itemId to avoid objc_msgSend_fpret on the wrong object type later.
    id itemIdObj = [itemArray objectAtIndex:0];
    if (![itemIdObj isKindOfClass:[NSNumber class]]) {
        NSDebugLog(@"DBusMenuParser: ERROR: itemId is %@, not NSNumber",
                   [itemIdObj class]);
        return nil;
    }
    NSNumber *itemId = (NSNumber *)itemIdObj;
    id propertiesObj = [itemArray objectAtIndex:1];
    id childrenObj = [itemArray objectAtIndex:2];

    NSDebugLog(@"DBusMenuParser: Item ID: %@ (class: %@)", itemId, [itemId class]);
    NSDebugLog(@"DBusMenuParser: Properties object: %@ (class: %@)", propertiesObj, [propertiesObj class]);
    NSDebugLog(@"DBusMenuParser: Children object: %@ (class: %@)", childrenObj, [childrenObj class]);

    // Convert properties to dictionary
    NSDictionary *properties = [self convertPropertiesToDictionary:propertiesObj];

    // Convert children to array if needed
    NSArray *children = nil;
    if ([childrenObj isKindOfClass:[NSArray class]]) {
        children = (NSArray *)childrenObj;
    } else {
        NSDebugLog(@"DBusMenuParser: WARNING: Children is not an array, creating empty one");
        children = [NSArray array];
    }

    NSDebugLog(@"DBusMenuParser: Properties dict has %lu entries:", (unsigned long)[properties count]);
    for (NSString *key in [properties allKeys]) {
        id value = [properties objectForKey:key];
        NSDebugLog(@"DBusMenuParser:   %@ = %@ (%@)", key, value, [value class]);
    }

    NSDebugLog(@"DBusMenuParser: Children array has %lu elements", (unsigned long)[children count]);

    // For root item, create the main menu
    NSMenu *menu = nil;
    if (isRoot) {
        NSString *menuTitle = [properties objectForKey:@"label"];
        if (!menuTitle || [menuTitle length] == 0) {
            menuTitle = @"App Menu";
        }
        NSDebugLog(@"DBusMenuParser: Creating root menu with title: '%@'", menuTitle);
        menu = [[NSMenu alloc] initWithTitle:menuTitle];

        // Process children of root item
        NSDebugLog(@"DBusMenuParser: Processing %lu children of root item", (unsigned long)[children count]);
        for (NSUInteger i = 0; i < [children count]; i++) {
            id childItem = [children objectAtIndex:i];
            NSDebugLog(@"DBusMenuParser: Processing child %lu: %@ (%@)", i, childItem, [childItem class]);

            NSMenuItem *menuItem = [self createMenuItemFromLayoutItem:childItem];
            if (menuItem) {
                [menu addItem:menuItem];
                NSDebugLog(@"DBusMenuParser: Added menu item: '%@'", [menuItem title]);
            } else {
                NSDebugLog(@"DBusMenuParser: Failed to create menu item from child %lu", i);
            }
        }
        
        NSDebugLog(@"DBusMenuParser: Root menu created with %lu items", (unsigned long)[[menu itemArray] count]);
    } else {
        // This shouldn't happen for root parsing, but handle it
        NSDebugLog(@"DBusMenuParser: ERROR: parseLayoutItem called with isRoot=NO");
        return nil;
    }
    
    return menu;
}

+ (NSMenu *)parseLayoutItem:(id)layoutItem 
                     isRoot:(BOOL)isRoot 
                serviceName:(NSString *)serviceName 
                 objectPath:(NSString *)objectPath 
             dbusConnection:(GNUDBusConnection *)dbusConnection
{
    NSDebugLog(@"DBusMenuParser: ===== PARSING LAYOUT ITEM (isRoot=%@) =====", isRoot ? @"YES" : @"NO");
    NSDebugLog(@"DBusMenuParser: Layout item class: %@", [layoutItem class]);
    NSDebugLog(@"DBusMenuParser: Layout item object: %@", layoutItem);
    
    if (![layoutItem isKindOfClass:[NSArray class]]) {
        NSDebugLog(@"DBusMenuParser: ERROR: Layout item should be an array, got %@", [layoutItem class]);
        return nil;
    }
    
    NSArray *itemArray = (NSArray *)layoutItem;
    NSDebugLog(@"DBusMenuParser: Layout item array has %lu elements", (unsigned long)[itemArray count]);
    
    if ([itemArray count] < 3) {
        NSDebugLog(@"DBusMenuParser: ERROR: Layout item should have at least 3 elements (id, properties, children)");
        NSDebugLog(@"DBusMenuParser: Actual count: %lu", (unsigned long)[itemArray count]);
        for (NSUInteger i = 0; i < [itemArray count]; i++) {
            id element = [itemArray objectAtIndex:i];
            NSDebugLog(@"DBusMenuParser: Element[%lu]: %@ (%@)", i, element, [element class]);
        }
        return nil;
    }
    
    // Extract the layout item components: (ia{sv}av). Reject non-number
    // itemId to avoid objc_msgSend_fpret on the wrong object type later.
    id itemIdObj = [itemArray objectAtIndex:0];
    if (![itemIdObj isKindOfClass:[NSNumber class]]) {
        NSDebugLog(@"DBusMenuParser: ERROR: itemId is %@, not NSNumber",
                   [itemIdObj class]);
        return nil;
    }
    NSNumber *itemId = (NSNumber *)itemIdObj;
    id propertiesObj = [itemArray objectAtIndex:1];
    id childrenObj = [itemArray objectAtIndex:2];

    NSDebugLog(@"DBusMenuParser: Item ID: %@ (class: %@)", itemId, [itemId class]);
    NSDebugLog(@"DBusMenuParser: Properties object: %@ (class: %@)", propertiesObj, [propertiesObj class]);
    NSDebugLog(@"DBusMenuParser: Children object: %@ (class: %@)", childrenObj, [childrenObj class]);
    
    // Convert properties to dictionary
    NSDictionary *properties = [self convertPropertiesToDictionary:propertiesObj];
    
    // Convert children to array if needed
    NSArray *children = nil;
    if ([childrenObj isKindOfClass:[NSArray class]]) {
        children = (NSArray *)childrenObj;
    } else {
        NSDebugLog(@"DBusMenuParser: WARNING: Children is not an array, creating empty one");
        children = [NSArray array];
    }
    
    NSDebugLog(@"DBusMenuParser: Properties dict has %lu entries:", (unsigned long)[properties count]);
    for (NSString *key in [properties allKeys]) {
        id value = [properties objectForKey:key];
        NSDebugLog(@"DBusMenuParser:   %@ = %@ (%@)", key, value, [value class]);
    }
    
    NSDebugLog(@"DBusMenuParser: Children array has %lu elements", (unsigned long)[children count]);
    
    // For root item, create the main menu
    NSMenu *menu = nil;
    if (isRoot) {
        NSString *menuTitle = [properties objectForKey:@"label"];
        if (!menuTitle || [menuTitle length] == 0) {
            menuTitle = @"App Menu";
        }
        NSDebugLog(@"DBusMenuParser: Creating root menu with title: '%@'", menuTitle);
        menu = [[NSMenu alloc] initWithTitle:menuTitle];
        
        // Process children of root item
        NSDebugLog(@"DBusMenuParser: Processing %lu children of root item", (unsigned long)[children count]);
        for (NSUInteger i = 0; i < [children count]; i++) {
            id childItem = [children objectAtIndex:i];
            NSDebugLog(@"DBusMenuParser: Processing child %lu: %@ (%@)", i, childItem, [childItem class]);
            
            NSMenuItem *menuItem = [self createMenuItemFromLayoutItem:childItem 
                                                          serviceName:serviceName 
                                                           objectPath:objectPath 
                                                       dbusConnection:dbusConnection];
            if (menuItem) {
                [menu addItem:menuItem];
                NSDebugLog(@"DBusMenuParser: Added menu item: '%@'", [menuItem title]);
            } else {
                NSDebugLog(@"DBusMenuParser: Failed to create menu item from child %lu", i);
            }
        }
        
        NSDebugLog(@"DBusMenuParser: Root menu created with %lu items", (unsigned long)[[menu itemArray] count]);
    } else {
        // This shouldn't happen for root parsing, but handle it
        NSDebugLog(@"DBusMenuParser: ERROR: parseLayoutItem called with isRoot=NO");
        return nil;
    }
    
    return menu;
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
        NSDebugLog(@"DBusMenuParser: Layout item should be an array");
        return nil;
    }
    
    NSArray *itemArray = (NSArray *)layoutItem;
    if ([itemArray count] < 3) {
        NSDebugLog(@"DBusMenuParser: Layout item should have at least 3 elements");
        return nil;
    }
    
    id itemIdObj = [itemArray objectAtIndex:0];
    if (![itemIdObj isKindOfClass:[NSNumber class]]) {
        NSDebugLLog(@"gwcomp", @"DBusMenuParser: ERROR: itemId is %@, not NSNumber",
                    [itemIdObj class]);
        return nil;
    }
    NSNumber *itemId = (NSNumber *)itemIdObj;
    id propertiesObj = [itemArray objectAtIndex:1];
    id childrenObj = [itemArray objectAtIndex:2];

    // Convert properties to dictionary
    NSDictionary *properties = [self convertPropertiesToDictionary:propertiesObj];
    
    // Convert children to array if needed
    NSArray *children = nil;
    if ([childrenObj isKindOfClass:[NSArray class]]) {
        children = (NSArray *)childrenObj;
    } else {
        NSDebugLog(@"DBusMenuParser: WARNING: Children is not an array in createMenuItemFromLayoutItem, creating empty one");
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
        NSDebugLog(@"DBusMenuParser: All properties for '%@': %@", 
              label ?: @"(no label)", properties);
    }
    
    // Enhanced shortcut property logging
    if (shortcut || accel || accelerator || keyBinding) {
        NSDebugLog(@"DBusMenuParser: *** SHORTCUT PROPERTIES FOUND for '%@' ***", label ?: @"(no label)");
        if (shortcut) NSDebugLog(@"DBusMenuParser:   shortcut=%@", shortcut);
        if (accel) NSDebugLog(@"DBusMenuParser:   accel=%@", accel);
        if (accelerator) NSDebugLog(@"DBusMenuParser:   accelerator=%@", accelerator);
        if (keyBinding) NSDebugLog(@"DBusMenuParser:   key-binding=%@", keyBinding);
    } else {
        NSDebugLog(@"DBusMenuParser: No shortcut properties for '%@'", label ?: @"(no label)");
    }
    
    // Check if this is a submenu container
    BOOL hasChildren = ([children count] > 0);
    BOOL hasSubmenuDisplay = (childrenDisplay && [childrenDisplay isEqualToString:@"submenu"]);
    BOOL isSubmenu = hasChildren || hasSubmenuDisplay;
    
    NSDebugLog(@"DBusMenuParser: ===== SUBMENU DETECTION FOR '%@' =====", label ?: @"(no label)");
    NSDebugLog(@"DBusMenuParser: Item ID: %@", itemId);
    NSDebugLog(@"DBusMenuParser: Children count: %lu", (unsigned long)[children count]);
    NSDebugLog(@"DBusMenuParser: Children-display property: '%@'", childrenDisplay ?: @"(none)");
    NSDebugLog(@"DBusMenuParser: Has children: %@", hasChildren ? @"YES" : @"NO");
    NSDebugLog(@"DBusMenuParser: Has submenu display: %@", hasSubmenuDisplay ? @"YES" : @"NO");
    NSDebugLog(@"DBusMenuParser: Final isSubmenu decision: %@", isSubmenu ? @"YES" : @"NO");
    
    if (hasChildren) {
        NSDebugLog(@"DBusMenuParser: Children details:");
        for (NSUInteger i = 0; i < [children count]; i++) {
            id child = [children objectAtIndex:i];
            NSDebugLog(@"DBusMenuParser:   Child[%lu]: %@ (%@)", i, child, [child class]);
        }
    }
    
    if (isSubmenu) {
        NSDebugLog(@"DBusMenuParser: Item '%@' is a submenu (children=%lu, children-display=%@)", 
              label ?: @"(no label)", (unsigned long)[children count], childrenDisplay ?: @"(none)");
    } else {
        NSDebugLog(@"DBusMenuParser: Item '%@' is NOT a submenu", label ?: @"(no label)");
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
            NSDebugLog(@"DBusMenuParser: Transformed label '%@' -> '%@' (removed mnemonics)", originalLabel, label);
        }
    }
    
    // Process shortcut to get key equivalent
    NSString *keyEquivalent = @"";
    NSUInteger modifierMask = 0;
    
    if (shortcut && [shortcut isKindOfClass:[NSArray class]] && [shortcut count] > 0) {
        // DBus shortcut format is typically an array of keysyms and modifiers
        NSDebugLog(@"DBusMenuParser: Found shortcut array for '%@': %@", label, shortcut);
        NSString *keyCombo = [DBusMenuShortcutParser parseShortcutArray:shortcut];
        if (keyCombo) {
            NSDebugLog(@"DBusMenuParser: Parsed shortcut array to: %@", keyCombo);
            NSDictionary *parsedShortcut = [DBusMenuShortcutParser parseKeyCombo:keyCombo];
            keyEquivalent = [parsedShortcut objectForKey:@"key"] ?: @"";
            modifierMask = [[parsedShortcut objectForKey:@"modifiers"] unsignedIntegerValue];
        }
    } else if (accel && [accel isKindOfClass:[NSString class]] && [accel length] > 0) {
        // Alternative accelerator format (string-based)
        NSDebugLog(@"DBusMenuParser: Found accel string for '%@': %@", label, accel);
        NSDictionary *parsedShortcut = [DBusMenuShortcutParser parseKeyCombo:accel];
        keyEquivalent = [parsedShortcut objectForKey:@"key"] ?: @"";
        modifierMask = [[parsedShortcut objectForKey:@"modifiers"] unsignedIntegerValue];
    } else if (accelerator && [accelerator isKindOfClass:[NSString class]] && [accelerator length] > 0) {
        // Another accelerator format
        NSDebugLog(@"DBusMenuParser: Found accelerator string for '%@': %@", label, accelerator);
        NSDictionary *parsedShortcut = [DBusMenuShortcutParser parseKeyCombo:accelerator];
        keyEquivalent = [parsedShortcut objectForKey:@"key"] ?: @"";
        modifierMask = [[parsedShortcut objectForKey:@"modifiers"] unsignedIntegerValue];
    } else if (keyBinding && [keyBinding isKindOfClass:[NSString class]] && [keyBinding length] > 0) {
        // Key binding format
        NSDebugLog(@"DBusMenuParser: Found key-binding string for '%@': %@", label, keyBinding);
        NSDictionary *parsedShortcut = [DBusMenuShortcutParser parseKeyCombo:keyBinding];
        keyEquivalent = [parsedShortcut objectForKey:@"key"] ?: @"";
        modifierMask = [[parsedShortcut objectForKey:@"modifiers"] unsignedIntegerValue];
    }
    
    // ── Shortcut cache fallback ──────────────────────────────────
    // If the application sent no shortcut for this item, try the cache.
    // Chromium omits shortcuts from incognito / new-tab-page windows.
    if ([keyEquivalent length] == 0 && serviceName && itemId) {
        NSDictionary *cached = cachedShortcut(serviceName, itemId);
        if (cached) {
            keyEquivalent = [cached objectForKey:@"key"] ?: @"";
            modifierMask = [[cached objectForKey:@"modifiers"] unsignedIntegerValue];
            NSDebugLog(@"DBusMenuParser: Applied cached shortcut for ID %@: '%@' mod=%lu",
                  itemId, keyEquivalent, (unsigned long)modifierMask);
        }
    }
    
    // Create menu item without keyEquivalent first (to avoid GNUstep auto-setting NSCommandKeyMask)
    NSMenuItem *menuItem = [[NSMenuItem alloc] initWithTitle:label
                                                      action:nil
                                               keyEquivalent:@""];
    
    // Store the DBus item ID in representedObject for later use in activation
    [menuItem setRepresentedObject:itemId];
    
    // Set enabled state BEFORE setting shortcuts
    if (enabled) {
        [menuItem setEnabled:[enabled boolValue]];
        NSDebugLog(@"DBusMenuParser: Set enabled state to: %@", [enabled boolValue] ? @"YES" : @"NO");
    } else {
        NSDebugLog(@"DBusMenuParser: No enabled property, using default");
    }
    
    // Now set key equivalent and modifier mask AFTER creation
    // This ensures we control the exact values without GNUstep auto-setting anything
    if ([keyEquivalent length] > 0) {
        [menuItem setKeyEquivalent:keyEquivalent];
        if (modifierMask > 0) {
            // WORKAROUND: GNUstep doesn't display Control shortcuts properly in menus
            // For display: Convert NSControlKeyMask to NSCommandKeyMask 
            // For X11 registration: Keep original NSControlKeyMask (X11ShortcutManager will convert to Alt)
            NSUInteger displayModifierMask = modifierMask;
            BOOL hasControlKey = (modifierMask & NSControlKeyMask) != 0;
            
            if (hasControlKey) {
                // Display as Command in menu
                displayModifierMask = (modifierMask & ~NSControlKeyMask) | NSCommandKeyMask;
                NSDebugLog(@"DBusMenuParser: Control shortcut will display as Command but register as Alt for X11");
                
                // Store ORIGINAL modifier (Control) in a way X11ShortcutManager can retrieve it
                // We'll use the menu item's tag to encode the original modifier
                // Tag format: upper 16 bits = original modifier flags, lower 16 bits = item ID
                NSUInteger originalModBits = (modifierMask >> 8) & 0xFFFF; // Extract relevant modifier bits
                NSUInteger itemIdBits = [[menuItem representedObject] intValue] & 0xFFFF;
                [menuItem setTag:(originalModBits << 16) | itemIdBits];
            }
            
            [menuItem setKeyEquivalentModifierMask:displayModifierMask];
        }
        NSDebugLog(@"DBusMenuParser: Set shortcut: key='%@', modifiers=%lu (display=%lu)", 
              keyEquivalent, (unsigned long)modifierMask, (unsigned long)[menuItem keyEquivalentModifierMask]);
        
        // Cache this shortcut so sibling windows from the same service
        // (e.g. incognito / new-tab-page) can inherit it.
        if (serviceName && itemId) {
            cacheShortcut(serviceName, itemId, keyEquivalent, modifierMask);
        }
    }
    
    NSDebugLog(@"DBusMenuParser: ===== CREATED MENU ITEM =====");
    NSDebugLog(@"DBusMenuParser: Menu item object: %@", menuItem);
    NSDebugLog(@"DBusMenuParser: Title: '%@'", [menuItem title]);
    NSDebugLog(@"DBusMenuParser: DBus item ID: %@", itemId);
    NSDebugLog(@"DBusMenuParser: Key equivalent: '%@'", [menuItem keyEquivalent]);
    NSDebugLog(@"DBusMenuParser: Modifier mask: %lu", (unsigned long)[menuItem keyEquivalentModifierMask]);
    
    // Enhanced shortcut logging
    if ([[menuItem keyEquivalent] length] > 0) {
        NSString *shortcutDesc = [NSString stringWithFormat:@"%@%@%@%@%@",
                                 ([menuItem keyEquivalentModifierMask] & NSControlKeyMask) ? @"Ctrl+" : @"",
                                 ([menuItem keyEquivalentModifierMask] & NSAlternateKeyMask) ? @"Alt+" : @"",
                                 ([menuItem keyEquivalentModifierMask] & NSShiftKeyMask) ? @"Shift+" : @"",
                                 ([menuItem keyEquivalentModifierMask] & NSCommandKeyMask) ? @"Cmd+" : @"",
                                 [menuItem keyEquivalent]];
        NSDebugLog(@"DBusMenuParser: *** SHORTCUT SET: '%@' ***", shortcutDesc);
    } else {
        NSDebugLog(@"DBusMenuParser: *** NO SHORTCUT (key equivalent is empty) ***");
    }
    
    // Store item ID for event handling
    [menuItem setTag:[itemId intValue]];
    NSDebugLog(@"DBusMenuParser: Set tag (item ID) to: %ld", (long)[itemId intValue]);
    
    // Set up action for menu items if we have DBus connection info and this isn't a submenu
    if (serviceName && objectPath && dbusConnection && !isSubmenu) {
        [DBusMenuActionHandler setupActionForMenuItem:menuItem
                                          serviceName:serviceName
                                           objectPath:objectPath
                                       dbusConnection:dbusConnection];
        
        NSDebugLog(@"DBusMenuParser: Set up action for menu item '%@' (ID=%@, service=%@, path=%@)", 
              label, itemId, serviceName, objectPath);
    } else if (isSubmenu) {
        NSDebugLog(@"DBusMenuParser: Skipping action setup for submenu '%@'", label);
    }
    
    // Process children (submenu)
    if (isSubmenu) {
        NSDebugLog(@"DBusMenuParser: ===== CREATING SUBMENU FOR '%@' =====", label ?: @"(no label)");
        NSDebugLog(@"DBusMenuParser: Submenu detected - children count: %lu", (unsigned long)[children count]);
        NSDebugLog(@"DBusMenuParser: Submenu detected - children-display: %@", childrenDisplay ?: @"(none)");
        NSDebugLog(@"DBusMenuParser: Submenu detected - item ID: %@", itemId);
        NSDebugLog(@"DBusMenuParser: Submenu detected - service: %@", serviceName ?: @"(none)");
        NSDebugLog(@"DBusMenuParser: Submenu detected - object path: %@", objectPath ?: @"(none)");
        NSDebugLog(@"DBusMenuParser: Submenu detected - dbus connection: %@", dbusConnection ? @"available" : @"none");
        
        NSMenu *submenu = [[NSMenu alloc] initWithTitle:label ? label : @""];
        NSDebugLog(@"DBusMenuParser: Created NSMenu object for submenu: %@", submenu);
        
        // Create submenu items - but mark that we may need to refresh them via AboutToShow
        NSDebugLog(@"DBusMenuParser: Adding %lu initial child items to submenu...", (unsigned long)[children count]);
        NSUInteger addedItems = 0;
        for (NSUInteger childIndex = 0; childIndex < [children count]; childIndex++) {
            id childItem = [children objectAtIndex:childIndex];
            NSDebugLog(@"DBusMenuParser: Processing child item %lu: %@ (%@)", 
                  childIndex, childItem, [childItem class]);
            
            NSMenuItem *childMenuItem = [self createMenuItemFromLayoutItem:childItem 
                                                               serviceName:serviceName 
                                                                objectPath:objectPath 
                                                            dbusConnection:dbusConnection];
            if (childMenuItem) {
                [submenu addItem:childMenuItem];
                addedItems++;
                NSDebugLog(@"DBusMenuParser: Added child menu item '%@' to submenu '%@' (total now: %lu)", 
                      [childMenuItem title], label, addedItems);
            } else {
                NSDebugLog(@"DBusMenuParser: ERROR: Failed to create child menu item %lu for submenu '%@'", 
                      childIndex, label);
            }
        }
        
        NSDebugLog(@"DBusMenuParser: Finished adding items to submenu - %lu added out of %lu attempted", 
              addedItems, (unsigned long)[children count]);
        
        // Set up submenu with delegate and attach it to the menu item
        [DBusSubmenuManager setupSubmenu:submenu
                             forMenuItem:menuItem
                             serviceName:serviceName
                              objectPath:objectPath
                          dbusConnection:dbusConnection
                                  itemId:itemId];
        
        // Force the submenu to update its layout now that all items and shortcuts are set
        // This is critical for GNUstep to recalculate menu item cell sizes including key equivalent widths
        [submenu update];
        [submenu sizeToFit];
        NSDebugLog(@"DBusMenuParser: Forced submenu update and sizeToFit for proper shortcut display");
        
        // DIAGNOSTIC: Log all submenu items and their shortcuts after submenu is fully set up
        NSDebugLog(@"DBusMenuParser: ===== SUBMENU '%@' FINAL STATE =====", label ?: @"(no label)");
        NSArray *submenuItems = [submenu itemArray];
        for (NSUInteger idx = 0; idx < [submenuItems count]; idx++) {
            NSMenuItem *subItem = [submenuItems objectAtIndex:idx];
            NSString *keyEq = [subItem keyEquivalent];
            NSUInteger modMask = [subItem keyEquivalentModifierMask];
            if ([keyEq length] > 0) {
                NSDebugLog(@"DBusMenuParser:   Item %lu: '%@' - shortcut: '%@' (modifiers=%lu)", 
                      idx, [subItem title], keyEq, (unsigned long)modMask);
            } else {
                NSDebugLog(@"DBusMenuParser:   Item %lu: '%@' - no shortcut", idx, [subItem title]);
            }
        }
        NSDebugLog(@"DBusMenuParser: ===== END SUBMENU FINAL STATE =====");
        
        NSDebugLog(@"DBusMenuParser: ===== SUBMENU CREATION COMPLETE FOR '%@' =====", label ?: @"(no label)");
    } else {
        NSDebugLog(@"DBusMenuParser: Item '%@' is NOT a submenu (children=%lu, children-display=%@)", 
              label ?: @"(no label)", (unsigned long)[children count], childrenDisplay ?: @"(none)");
    }
    
    // Final summary log
    NSString *shortcutSummary = @"none";
    if ([keyEquivalent length] > 0 && modifierMask > 0) {
        shortcutSummary = [NSString stringWithFormat:@"%@+%@", 
                          [DBusMenuShortcutParser modifierMaskToString:modifierMask], keyEquivalent];
    } else if ([keyEquivalent length] > 0) {
        shortcutSummary = keyEquivalent;
    }
    NSDebugLog(@"DBusMenuParser: Created menu item: '%@' (ID=%@, enabled=%@, children=%lu, shortcut=%@)",
          label, itemId, enabled, (unsigned long)[children count], shortcutSummary);
    
    // Additional warning if shortcut was supposed to be set but isn't on the menu item
    if ([[menuItem keyEquivalent] length] == 0 && ([keyEquivalent length] > 0 || modifierMask > 0)) {
        NSDebugLog(@"DBusMenuParser: *** WARNING: Shortcut was parsed but NOT set on menu item! ***");
        NSDebugLog(@"DBusMenuParser: ***   Parsed keyEquivalent='%@', modifierMask=%lu ***", keyEquivalent, (unsigned long)modifierMask);
        NSDebugLog(@"DBusMenuParser: ***   MenuItem keyEquivalent='%@', modifierMask=%lu ***", 
              [menuItem keyEquivalent], (unsigned long)[menuItem keyEquivalentModifierMask]);
    }
    
    return menuItem;
}

+ (NSDictionary *)convertPropertiesToDictionary:(id)propertiesObj
{
    NSDebugLog(@"DBusMenuParser: Converting properties object: %@ (class: %@)", propertiesObj, [propertiesObj class]);
    
    // If it's already a dictionary, return it
    if ([propertiesObj isKindOfClass:[NSDictionary class]]) {
        NSDebugLog(@"DBusMenuParser: Properties is already a dictionary");
        return (NSDictionary *)propertiesObj;
    }
    
    // If it's an array of dictionaries (which is what we're seeing), merge them
    if ([propertiesObj isKindOfClass:[NSArray class]]) {
        NSArray *propsArray = (NSArray *)propertiesObj;
        NSMutableDictionary *mergedDict = [NSMutableDictionary dictionary];
        
        NSDebugLog(@"DBusMenuParser: Properties is an array with %lu elements, merging...", (unsigned long)[propsArray count]);
        
        for (NSUInteger i = 0; i < [propsArray count]; i++) {
            id element = [propsArray objectAtIndex:i];
            NSDebugLog(@"DBusMenuParser: Processing properties element[%lu]: %@ (%@)", i, element, [element class]);
            
            if ([element isKindOfClass:[NSDictionary class]]) {
                NSDictionary *elementDict = (NSDictionary *)element;
                NSDebugLog(@"DBusMenuParser: Element is dictionary with %lu keys", (unsigned long)[elementDict count]);
                
                // Merge this dictionary into our result
                for (NSString *key in [elementDict allKeys]) {
                    id value = [elementDict objectForKey:key];
                    [mergedDict setObject:value forKey:key];
                    NSDebugLog(@"DBusMenuParser: Added property: %@ = %@", key, value);
                }
            } else {
                NSDebugLog(@"DBusMenuParser: WARNING: Properties array element is not a dictionary: %@ (%@)", 
                      element, [element class]);
            }
        }
        
        NSDebugLog(@"DBusMenuParser: Merged properties dictionary has %lu entries", (unsigned long)[mergedDict count]);
        return mergedDict;
    }
    
    NSDebugLog(@"DBusMenuParser: WARNING: Properties is neither dictionary nor array, creating empty one");
    NSDebugLog(@"DBusMenuParser: Properties object class: %@", [propertiesObj class]);
    NSDebugLog(@"DBusMenuParser: Properties object: %@", propertiesObj);
    return [NSDictionary dictionary];
}

+ (void)cleanup
{
    NSDebugLog(@"DBusMenuParser: Performing cleanup...");
    
    @try {
        [DBusMenuActionHandler cleanup];
        [DBusSubmenuManager cleanup];
        NSDebugLog(@"DBusMenuParser: Cleanup completed successfully");
    } @catch (NSException *exception) {
        NSDebugLog(@"DBusMenuParser: Exception during cleanup: %@", exception);
    }
}

@end
