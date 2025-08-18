#import "DBusSubmenuManager.h"
#import "DBusConnection.h"
#import "DBusMenuParser.h"

// Static variables for submenu management
static NSMutableDictionary *submenuDelegates = nil;
static NSMutableSet *refreshedByAboutToShow = nil;

@implementation DBusSubmenuManager

+ (void)initialize
{
    if (self == [DBusSubmenuManager class]) {
        submenuDelegates = [[NSMutableDictionary alloc] init];
        refreshedByAboutToShow = [[NSMutableSet alloc] init];
    }
}

+ (void)setupSubmenu:(NSMenu *)submenu
         forMenuItem:(NSMenuItem *)menuItem
         serviceName:(NSString *)serviceName
          objectPath:(NSString *)objectPath
      dbusConnection:(GNUDBusConnection *)dbusConnection
              itemId:(NSNumber *)itemId
{
    if (!submenu || !menuItem || !serviceName || !objectPath || !dbusConnection || !itemId) {
        NSLog(@"DBusSubmenuManager: ERROR: Missing required parameters for submenu setup");
        return;
    }
    
    NSLog(@"DBusSubmenuManager: ===== SETTING UP SUBMENU DELEGATE =====");
    NSLog(@"DBusSubmenuManager: Setting up submenu delegate for item ID %@", itemId);
    NSLog(@"DBusSubmenuManager: Menu item title: '%@'", [menuItem title]);
    NSLog(@"DBusSubmenuManager: Service: %@", serviceName);
    NSLog(@"DBusSubmenuManager: Object path: %@", objectPath);
    NSLog(@"DBusSubmenuManager: DBus connection: %@", dbusConnection ? @"available" : @"nil");
    NSLog(@"DBusSubmenuManager: Submenu has %lu existing items", (unsigned long)[[submenu itemArray] count]);
    
    // Set up submenu delegate for AboutToShow handling
    DBusSubmenuDelegate *delegate = [[DBusSubmenuDelegate alloc] 
                                   initWithServiceName:serviceName 
                                            objectPath:objectPath 
                                        dbusConnection:dbusConnection 
                                                itemId:itemId];
    
    [submenu setDelegate:delegate];
    NSLog(@"DBusSubmenuManager: Successfully set delegate for submenu");
    
    // Store the delegate to prevent it from being deallocated
    NSString *submenuKey = [NSString stringWithFormat:@"submenu_%p", submenu];
    [submenuDelegates setObject:delegate forKey:submenuKey];
    [delegate release]; // The dictionary retains it
    
    NSLog(@"DBusSubmenuManager: Stored delegate with key '%@' for lazy loading (itemId=%@)", submenuKey, itemId);
    
    // Attach the submenu to the menu item
    [menuItem setSubmenu:submenu];
    
    // Verify the submenu was set
    NSMenu *verifySubmenu = [menuItem submenu];
    if (verifySubmenu) {
        NSLog(@"DBusSubmenuManager: SUCCESS: Submenu verified - attached submenu has %lu items", 
              (unsigned long)[[verifySubmenu itemArray] count]);
        NSLog(@"DBusSubmenuManager: Submenu delegate: %@", [verifySubmenu delegate]);
    } else {
        NSLog(@"DBusSubmenuManager: ERROR: setSubmenu failed - menu item has no submenu!");
    }
    NSLog(@"DBusSubmenuManager: ===== SUBMENU DELEGATE SETUP COMPLETE =====");
}

+ (void)cleanup
{
    NSLog(@"DBusSubmenuManager: Performing cleanup...");
    [submenuDelegates removeAllObjects];
    [refreshedByAboutToShow removeAllObjects];
}

@end

// MARK: - DBusSubmenuDelegate Implementation

@implementation DBusSubmenuDelegate

- (id)initWithServiceName:(NSString *)serviceName 
               objectPath:(NSString *)objectPath 
           dbusConnection:(GNUDBusConnection *)dbusConnection 
                   itemId:(NSNumber *)itemId
{
    self = [super init];
    if (self) {
        NSLog(@"DBusSubmenuDelegate: ===== INITIALIZING DELEGATE =====");
        NSLog(@"DBusSubmenuDelegate: Creating delegate for item ID %@", itemId);
        NSLog(@"DBusSubmenuDelegate: Service: %@", serviceName);
        NSLog(@"DBusSubmenuDelegate: Object path: %@", objectPath);
        NSLog(@"DBusSubmenuDelegate: DBus connection: %@", dbusConnection ? @"available" : @"nil");
        
        _serviceName = [serviceName retain];
        _objectPath = [objectPath retain];
        _dbusConnection = dbusConnection; // Weak reference
        _itemId = [itemId retain];
        
        NSLog(@"DBusSubmenuDelegate: Delegate initialization complete for item ID %@", _itemId);
        NSLog(@"DBusSubmenuDelegate: ===== DELEGATE READY FOR ABOUTTOSHOW =====");
    }
    return self;
}

- (void)dealloc
{
    [_serviceName release];
    [_objectPath release];
    [_dbusConnection release];
    [_itemId release];
    [super dealloc];
}

- (void)menuWillOpen:(NSMenu *)menu
{
    NSLog(@"DBusSubmenuDelegate: ===== MENU WILL OPEN =====");
    NSLog(@"DBusSubmenuDelegate: menuWillOpen called for menu: '%@'", [menu title] ?: @"(no title)");
    NSLog(@"DBusSubmenuDelegate: Menu object: %@", menu);
    NSLog(@"DBusSubmenuDelegate: Menu has %lu items currently", (unsigned long)[[menu itemArray] count]);
    NSLog(@"DBusSubmenuDelegate: Delegate item ID: %@", _itemId);
    NSLog(@"DBusSubmenuDelegate: Delegate service: %@", _serviceName);
    NSLog(@"DBusSubmenuDelegate: Delegate path: %@", _objectPath);
    NSLog(@"DBusSubmenuDelegate: Delegate connection: %@", _dbusConnection ? @"available" : @"nil");
    
    if (!_serviceName || !_objectPath || !_dbusConnection || !_itemId) {
        NSLog(@"DBusSubmenuDelegate: ERROR: Missing DBus info, cannot call AboutToShow");
        NSLog(@"DBusSubmenuDelegate:   serviceName: %@", _serviceName ?: @"MISSING");
        NSLog(@"DBusSubmenuDelegate:   objectPath: %@", _objectPath ?: @"MISSING");
        NSLog(@"DBusSubmenuDelegate:   dbusConnection: %@", _dbusConnection ? @"available" : @"MISSING");
        NSLog(@"DBusSubmenuDelegate:   itemId: %@", _itemId ?: @"MISSING");
        return;
    }
    
    // Check if this menu was already refreshed by AboutToShow to avoid duplicate calls
    NSString *itemIdKey = [NSString stringWithFormat:@"refreshed_%@", _itemId];
    if ([refreshedByAboutToShow containsObject:itemIdKey]) {
        NSLog(@"DBusSubmenuDelegate: Menu already refreshed by AboutToShow, skipping duplicate refresh");
        [refreshedByAboutToShow removeObject:itemIdKey];
        return;
    }
    
    NSLog(@"DBusSubmenuDelegate: ===== CALLING ABOUTTOSHOW =====");
    NSLog(@"DBusSubmenuDelegate: Calling AboutToShow for menu item ID %@ (service=%@, path=%@)", 
          _itemId, _serviceName, _objectPath);
    
    // Call AboutToShow method to notify the application that this submenu is about to be displayed
    NSArray *arguments = [NSArray arrayWithObjects:_itemId, nil];
    NSLog(@"DBusSubmenuDelegate: AboutToShow arguments: %@", arguments);
    
    NSLog(@"DBusSubmenuDelegate: Making DBus call...");
    id result = [_dbusConnection callMethod:@"AboutToShow"
                                  onService:_serviceName
                                 objectPath:_objectPath
                                  interface:@"com.canonical.dbusmenu"
                                  arguments:arguments];
    
    NSLog(@"DBusSubmenuDelegate: AboutToShow call completed");
    
    if (result) {
        NSLog(@"DBusSubmenuDelegate: AboutToShow call succeeded, result: %@ (%@)", result, [result class]);
        
        // The result should be a boolean indicating whether the menu structure has changed
        BOOL needsRefresh = NO;
        if ([result isKindOfClass:[NSNumber class]]) {
            needsRefresh = [result boolValue];
            NSLog(@"DBusSubmenuDelegate: Result is NSNumber, needsRefresh: %@", needsRefresh ? @"YES" : @"NO");
        } else if ([result isKindOfClass:[NSArray class]] && [result count] > 0) {
            // Some implementations might return an array with the boolean as first element
            id firstElement = [result objectAtIndex:0];
            NSLog(@"DBusSubmenuDelegate: Result is array, first element: %@ (%@)", firstElement, [firstElement class]);
            if ([firstElement isKindOfClass:[NSNumber class]]) {
                needsRefresh = [firstElement boolValue];
                NSLog(@"DBusSubmenuDelegate: First element is NSNumber, needsRefresh: %@", needsRefresh ? @"YES" : @"NO");
            }
        } else {
            NSLog(@"DBusSubmenuDelegate: Unexpected result type: %@", [result class]);
        }
        
        NSLog(@"DBusSubmenuDelegate: Final needsRefresh decision: %@", needsRefresh ? @"YES" : @"NO");
        NSLog(@"DBusSubmenuDelegate: Current menu item count: %lu", (unsigned long)[[menu itemArray] count]);
        
        if (needsRefresh || [[menu itemArray] count] == 0) {
            NSLog(@"DBusSubmenuDelegate: ===== MENU UPDATE NEEDED, REFRESHING SUBMENU =====");
            [refreshedByAboutToShow addObject:itemIdKey];
            [self refreshSubmenu:menu];
        } else {
            NSLog(@"DBusSubmenuDelegate: No menu update needed, using existing content");
        }
    } else {
        NSLog(@"DBusSubmenuDelegate: ERROR: AboutToShow call failed or returned nil");
        // If AboutToShow fails, still try to refresh if the menu is empty
        if ([[menu itemArray] count] == 0) {
            NSLog(@"DBusSubmenuDelegate: Menu is empty, attempting refresh anyway");
            [self refreshSubmenu:menu];
        } else {
            NSLog(@"DBusSubmenuDelegate: Menu has content (%lu items), not refreshing after failed AboutToShow", 
                  (unsigned long)[[menu itemArray] count]);
        }
    }
    
    NSLog(@"DBusSubmenuDelegate: ===== MENU WILL OPEN COMPLETE =====");
}

- (void)menuDidClose:(NSMenu *)menu
{
    NSLog(@"DBusSubmenuDelegate: menuDidClose called for menu: %@", [menu title]);
    // Nothing special needed on close for now
}

- (void)menu:(NSMenu *)menu willHighlightItem:(NSMenuItem *)item
{
    // Called when an item is about to be highlighted
    // This could be used for additional dynamic loading if needed
}

- (NSRect)confinementRectForMenu:(NSMenu *)menu onScreen:(NSScreen *)screen
{
    // Return the screen frame - let the menu display anywhere on screen
    return [screen frame];
}

- (void)refreshSubmenu:(NSMenu *)submenu
{
    NSLog(@"DBusSubmenuDelegate: ===== REFRESHING SUBMENU CONTENT =====");
    NSLog(@"DBusSubmenuDelegate: Refreshing submenu content for item ID %@", _itemId);
    NSLog(@"DBusSubmenuDelegate: Submenu object: %@", submenu);
    NSLog(@"DBusSubmenuDelegate: Submenu title: '%@'", [submenu title] ?: @"(no title)");
    NSLog(@"DBusSubmenuDelegate: Submenu current item count: %lu", (unsigned long)[[submenu itemArray] count]);
    NSLog(@"DBusSubmenuDelegate: Service: %@", _serviceName);
    NSLog(@"DBusSubmenuDelegate: Object path: %@", _objectPath);
    NSLog(@"DBusSubmenuDelegate: DBus connection: %@", _dbusConnection);
    
    // Call GetLayout specifically for this submenu item with optimized property filtering
    NSArray *essentialProperties = [NSArray arrayWithObjects:@"label", @"enabled", @"visible", @"type", nil];
    NSArray *arguments = [NSArray arrayWithObjects:
                         _itemId,                   // parentId (this submenu's ID)
                         [NSNumber numberWithInt:2], // recursionDepth (2 levels for lazy loading)
                         essentialProperties,       // propertyNames (filtered for performance)
                         nil];
    
    NSLog(@"DBusSubmenuDelegate: Calling GetLayout with optimized arguments: %@", arguments);
    NSLog(@"DBusSubmenuDelegate: GetLayout call details:");
    NSLog(@"DBusSubmenuDelegate:   method: GetLayout");
    NSLog(@"DBusSubmenuDelegate:   service: %@", _serviceName);
    NSLog(@"DBusSubmenuDelegate:   path: %@", _objectPath);
    NSLog(@"DBusSubmenuDelegate:   interface: com.canonical.dbusmenu");
    NSLog(@"DBusSubmenuDelegate:   using filtered properties for performance");
    
    id result = [_dbusConnection callMethod:@"GetLayout"
                                  onService:_serviceName
                                 objectPath:_objectPath
                                  interface:@"com.canonical.dbusmenu"
                                  arguments:arguments];
    
    NSLog(@"DBusSubmenuDelegate: GetLayout call completed");
    
    if (!result) {
        NSLog(@"DBusSubmenuDelegate: ERROR: Failed to refresh submenu layout from %@%@ - result is nil", _serviceName, _objectPath);
        return;
    }
    
    NSLog(@"DBusSubmenuDelegate: Received updated submenu layout: %@ (%@)", result, [result class]);
    
    // Parse the result and update the submenu
    if ([result isKindOfClass:[NSArray class]] && [result count] >= 2) {
        NSArray *resultArray = (NSArray *)result;
        NSLog(@"DBusSubmenuDelegate: Result is array with %lu elements", (unsigned long)[resultArray count]);
        
        // Extract the layout item from the result (skip revision number)
        NSNumber *revision = [resultArray objectAtIndex:0];
        id layoutItem = [resultArray objectAtIndex:1];
        
        NSLog(@"DBusSubmenuDelegate: GetLayout revision: %@", revision);
        NSLog(@"DBusSubmenuDelegate: GetLayout layout item: %@ (%@)", layoutItem, [layoutItem class]);
        
        // Parse the layout item to get the children
        if ([layoutItem isKindOfClass:[NSArray class]] && [layoutItem count] >= 3) {
            NSArray *layoutArray = (NSArray *)layoutItem;
            NSLog(@"DBusSubmenuDelegate: Layout item is array with %lu elements", (unsigned long)[layoutArray count]);
            
            NSNumber *layoutItemId = [layoutArray objectAtIndex:0];
            id layoutProperties = [layoutArray objectAtIndex:1];
            id childrenObj = [layoutArray objectAtIndex:2];
            
            NSLog(@"DBusSubmenuDelegate: Layout item ID: %@", layoutItemId);
            NSLog(@"DBusSubmenuDelegate: Layout properties: %@ (%@)", layoutProperties, [layoutProperties class]);
            NSLog(@"DBusSubmenuDelegate: Children object: %@ (%@)", childrenObj, [childrenObj class]);
            
            NSArray *children = nil;
            if ([childrenObj isKindOfClass:[NSArray class]]) {
                children = (NSArray *)childrenObj;
            } else {
                NSLog(@"DBusSubmenuDelegate: ERROR: Children object is not an array: %@ (%@)", 
                      childrenObj, [childrenObj class]);
                children = [NSArray array];
            }
            
            NSLog(@"DBusSubmenuDelegate: ===== UPDATING SUBMENU WITH %lu CHILDREN =====", (unsigned long)[children count]);
            
            // Store current items count for comparison
            NSUInteger oldItemCount = [[submenu itemArray] count];
            NSLog(@"DBusSubmenuDelegate: Clearing %lu existing submenu items", oldItemCount);
            
            // Clear existing submenu items
            [submenu removeAllItems];
            NSLog(@"DBusSubmenuDelegate: Submenu cleared, now has %lu items", (unsigned long)[[submenu itemArray] count]);
            
            // Create menu items from the updated children
            NSUInteger newItemCount = 0;
            NSUInteger failedItems = 0;
            for (NSUInteger childIndex = 0; childIndex < [children count]; childIndex++) {
                id childItem = [children objectAtIndex:childIndex];
                NSLog(@"DBusSubmenuDelegate: Processing refreshed child %lu: %@ (%@)", 
                      childIndex, childItem, [childItem class]);
                
                NSMenuItem *childMenuItem = [DBusMenuParser createMenuItemFromLayoutItem:childItem 
                                                                             serviceName:_serviceName 
                                                                              objectPath:_objectPath 
                                                                          dbusConnection:_dbusConnection];
                if (childMenuItem) {
                    [submenu addItem:childMenuItem];
                    newItemCount++;
                    NSLog(@"DBusSubmenuDelegate: Successfully added refreshed child menu item '%@' (total: %lu)", 
                          [childMenuItem title], newItemCount);
                } else {
                    failedItems++;
                    NSLog(@"DBusSubmenuDelegate: ERROR: Failed to create child menu item %lu from layout", childIndex);
                }
            }
            
            NSLog(@"DBusSubmenuDelegate: ===== SUBMENU REFRESH SUMMARY =====");
            NSLog(@"DBusSubmenuDelegate: %lu old items -> %lu new items", oldItemCount, newItemCount);
            NSLog(@"DBusSubmenuDelegate: %lu items created successfully, %lu failed", newItemCount, failedItems);
            NSLog(@"DBusSubmenuDelegate: Final submenu item count: %lu", (unsigned long)[[submenu itemArray] count]);
            
            // Log the final menu items
            if (newItemCount > 0) {
                NSLog(@"DBusSubmenuDelegate: Final submenu items:");
                NSArray *finalItems = [submenu itemArray];
                for (NSUInteger i = 0; i < [finalItems count]; i++) {
                    NSMenuItem *item = [finalItems objectAtIndex:i];
                    NSLog(@"DBusSubmenuDelegate:   [%lu] '%@' (submenu: %@)", 
                          i, [item title], [item submenu] ? @"YES" : @"NO");
                }
            }
        } else {
            NSLog(@"DBusSubmenuDelegate: ERROR: Invalid layout item structure: %@ (count: %lu)", 
                  layoutItem, [layoutItem isKindOfClass:[NSArray class]] ? (unsigned long)[layoutItem count] : 0UL);
        }
    } else {
        NSLog(@"DBusSubmenuDelegate: ERROR: Invalid layout result for submenu refresh: %@ (count: %lu)", 
              result, [result isKindOfClass:[NSArray class]] ? (unsigned long)[result count] : 0UL);
    }
    
    NSLog(@"DBusSubmenuDelegate: ===== SUBMENU REFRESH COMPLETE =====");
}

@end
