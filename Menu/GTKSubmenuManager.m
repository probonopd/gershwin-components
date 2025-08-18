#import "GTKSubmenuManager.h"
#import "DBusConnection.h"
#import "GTKMenuParser.h"

// Static variables for GTK submenu management
static NSMutableDictionary *gtkSubmenuDelegates = nil;
static NSMutableSet *loadedGroups = nil;

@implementation GTKSubmenuManager

+ (void)initialize
{
    if (self == [GTKSubmenuManager class]) {
        gtkSubmenuDelegates = [[NSMutableDictionary alloc] init];
        loadedGroups = [[NSMutableSet alloc] init];
    }
}

+ (void)setupSubmenu:(NSMenu *)submenu
         forMenuItem:(NSMenuItem *)menuItem
         serviceName:(NSString *)serviceName
            menuPath:(NSString *)menuPath
          actionPath:(NSString *)actionPath
      dbusConnection:(GNUDBusConnection *)dbusConnection
             groupId:(NSNumber *)groupId
            menuDict:(NSMutableDictionary *)menuDict
{
    if (!submenu || !menuItem || !serviceName || !menuPath || !dbusConnection || !groupId || !menuDict) {
        NSLog(@"GTKSubmenuManager: ERROR: Missing required parameters for GTK submenu setup");
        return;
    }
    
    NSLog(@"GTKSubmenuManager: ===== SETTING UP GTK SUBMENU DELEGATE =====");
    NSLog(@"GTKSubmenuManager: Setting up GTK submenu delegate for group ID %@", groupId);
    NSLog(@"GTKSubmenuManager: Menu item title: '%@'", [menuItem title]);
    NSLog(@"GTKSubmenuManager: Service: %@", serviceName);
    NSLog(@"GTKSubmenuManager: Menu path: %@", menuPath);
    NSLog(@"GTKSubmenuManager: Action path: %@", actionPath);
    NSLog(@"GTKSubmenuManager: Submenu has %lu existing items", (unsigned long)[[submenu itemArray] count]);
    
    // Set up submenu delegate for lazy loading
    GTKSubmenuDelegate *delegate = [[GTKSubmenuDelegate alloc]
                                   initWithServiceName:serviceName
                                              menuPath:menuPath
                                            actionPath:actionPath
                                        dbusConnection:dbusConnection
                                               groupId:groupId
                                              menuDict:menuDict];
    
    [submenu setDelegate:delegate];
    NSLog(@"GTKSubmenuManager: Successfully set GTK delegate for submenu");
    
    // Store the delegate to prevent it from being deallocated
    NSString *submenuKey = [NSString stringWithFormat:@"gtk_submenu_%p", submenu];
    [gtkSubmenuDelegates setObject:delegate forKey:submenuKey];
    [delegate release]; // The dictionary retains it
    
    NSLog(@"GTKSubmenuManager: Stored GTK delegate with key '%@' for lazy loading (groupId=%@)", submenuKey, groupId);
    
    // Attach the submenu to the menu item
    [menuItem setSubmenu:submenu];
    
    NSLog(@"GTKSubmenuManager: ===== GTK SUBMENU DELEGATE SETUP COMPLETE =====");
}

+ (void)cleanup
{
    NSLog(@"GTKSubmenuManager: Performing GTK submenu cleanup...");
    [gtkSubmenuDelegates removeAllObjects];
    [loadedGroups removeAllObjects];
}

@end

// MARK: - GTKSubmenuDelegate Implementation

@implementation GTKSubmenuDelegate

- (id)initWithServiceName:(NSString *)serviceName
                 menuPath:(NSString *)menuPath
               actionPath:(NSString *)actionPath
           dbusConnection:(GNUDBusConnection *)dbusConnection
                  groupId:(NSNumber *)groupId
                 menuDict:(NSMutableDictionary *)menuDict
{
    self = [super init];
    if (self) {
        NSLog(@"GTKSubmenuDelegate: ===== INITIALIZING GTK DELEGATE =====");
        NSLog(@"GTKSubmenuDelegate: Creating GTK delegate for group ID %@", groupId);
        NSLog(@"GTKSubmenuDelegate: Service: %@", serviceName);
        NSLog(@"GTKSubmenuDelegate: Menu path: %@", menuPath);
        NSLog(@"GTKSubmenuDelegate: Action path: %@", actionPath);
        
        _serviceName = [serviceName retain];
        _menuPath = [menuPath retain];
        _actionPath = [actionPath retain];
        _dbusConnection = dbusConnection; // Weak reference
        _groupId = [groupId retain];
        _menuDict = [menuDict retain]; // Keep reference to shared menu dictionary
        
        NSLog(@"GTKSubmenuDelegate: GTK delegate initialization complete for group ID %@", _groupId);
    }
    return self;
}

- (void)dealloc
{
    [_serviceName release];
    [_menuPath release];
    [_actionPath release];
    [_groupId release];
    [_menuDict release];
    [super dealloc];
}

- (void)menuWillOpen:(NSMenu *)menu
{
    NSLog(@"GTKSubmenuDelegate: ===== GTK MENU WILL OPEN =====");
    NSLog(@"GTKSubmenuDelegate: GTK menuWillOpen called for menu: '%@'", [menu title] ?: @"(no title)");
    NSLog(@"GTKSubmenuDelegate: Menu has %lu items currently", (unsigned long)[[menu itemArray] count]);
    NSLog(@"GTKSubmenuDelegate: Delegate group ID: %@", _groupId);
    NSLog(@"GTKSubmenuDelegate: Delegate service: %@", _serviceName);
    NSLog(@"GTKSubmenuDelegate: Delegate menu path: %@", _menuPath);
    
    if (!_serviceName || !_menuPath || !_dbusConnection || !_groupId) {
        NSLog(@"GTKSubmenuDelegate: ERROR: Missing GTK submenu info, cannot load submenu");
        return;
    }
    
    // Check if this group was already loaded
    NSString *groupKey = [NSString stringWithFormat:@"group_%@_%@", _serviceName, _groupId];
    if ([loadedGroups containsObject:groupKey]) {
        NSLog(@"GTKSubmenuDelegate: Group already loaded, skipping duplicate load");
        return;
    }
    
    // Check if menu already has content
    if ([[menu itemArray] count] > 0) {
        NSLog(@"GTKSubmenuDelegate: Menu already has %lu items, skipping reload", (unsigned long)[[menu itemArray] count]);
        return;
    }
    
    NSLog(@"GTKSubmenuDelegate: ===== LOADING GTK MENU GROUP =====");
    NSLog(@"GTKSubmenuDelegate: Loading GTK menu group %@ from service %@", _groupId, _serviceName);
    
    // Load the additional group using GTK Start method
    NSArray *subscriptionIds = @[_groupId];
    
    id result = [_dbusConnection callMethod:@"Start"
                                  onService:_serviceName
                                 objectPath:_menuPath
                                  interface:@"org.gtk.Menus"
                                  arguments:@[subscriptionIds]];
    
    if (result && [result isKindOfClass:[NSArray class]]) {
        NSLog(@"GTKSubmenuDelegate: Successfully loaded GTK menu group %@", _groupId);
        
        // Parse and add the new menu data to our menu dictionary
        [GTKMenuParser parseMenuData:(NSArray *)result intoDict:_menuDict];
        
        // Mark this group as loaded
        [loadedGroups addObject:groupKey];
        
        // Now rebuild this submenu with the newly loaded data
        [self refreshSubmenu:menu];
        
    } else {
        NSLog(@"GTKSubmenuDelegate: Failed to load GTK menu group %@", _groupId);
    }
    
    NSLog(@"GTKSubmenuDelegate: ===== GTK MENU WILL OPEN COMPLETE =====");
}

- (void)refreshSubmenu:(NSMenu *)submenu
{
    NSLog(@"GTKSubmenuDelegate: ===== REFRESHING GTK SUBMENU =====");
    NSLog(@"GTKSubmenuDelegate: Refreshing GTK submenu for group %@", _groupId);
    
    // Look up the menu items for this group in the menu dictionary
    NSArray *menuId = @[_groupId, @0]; // GTK menus use (group_id, revision) as key
    NSArray *menuItems = [_menuDict objectForKey:menuId];
    
    if (!menuItems) {
        // Try with revision 1 if revision 0 doesn't exist
        menuId = @[_groupId, @1];
        menuItems = [_menuDict objectForKey:menuId];
    }
    
    if (!menuItems) {
        NSLog(@"GTKSubmenuDelegate: No menu items found for group %@ in dictionary", _groupId);
        // Log available keys for debugging
        NSLog(@"GTKSubmenuDelegate: Available menu keys: %@", [_menuDict allKeys]);
        return;
    }
    
    NSLog(@"GTKSubmenuDelegate: Found %lu menu items for group %@", (unsigned long)[menuItems count], _groupId);
    
    // Clear existing menu items
    [submenu removeAllItems];
    
    // Create new menu items from the loaded data
    NSUInteger itemCount = 0;
    for (id menuItemData in menuItems) {
        NSMutableDictionary *menuItem = [NSMutableDictionary dictionary];
        
        // Handle different menu item data formats
        if ([menuItemData isKindOfClass:[NSDictionary class]]) {
            [menuItem addEntriesFromDictionary:(NSDictionary *)menuItemData];
        } else if ([menuItemData isKindOfClass:[NSArray class]]) {
            NSArray *itemArray = (NSArray *)menuItemData;
            for (id dictItem in itemArray) {
                if ([dictItem isKindOfClass:[NSDictionary class]]) {
                    [menuItem addEntriesFromDictionary:(NSDictionary *)dictItem];
                }
            }
        }
        
        if ([menuItem count] == 0) {
            continue;
        }
        
        NSString *label = [menuItem objectForKey:@"label"];
        NSString *action = [menuItem objectForKey:@"action"];
        
        if (label) {
            // Remove mnemonic underscores from label (all occurrences, not just leading)
            NSString *displayLabel = label;
            if ([displayLabel containsString:@"_"]) {
                displayLabel = [displayLabel stringByReplacingOccurrencesOfString:@"_" withString:@""];
                NSLog(@"GTKSubmenuManager: Transformed label '%@' -> '%@' (removed mnemonics)", label, displayLabel);
            }
            
            NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:displayLabel action:nil keyEquivalent:@""];
            
            // Set up action if available
            if (action) {
                // Set up GTK action for this menu item
                [item setTarget:self];
                [item setAction:@selector(gtkMenuItemAction:)];
                [item setRepresentedObject:action];
            }
            
            [submenu addItem:item];
            [item release];
            itemCount++;
        }
    }
    
    NSLog(@"GTKSubmenuDelegate: Added %lu items to refreshed GTK submenu", itemCount);
    NSLog(@"GTKSubmenuDelegate: ===== GTK SUBMENU REFRESH COMPLETE =====");
}

- (void)menuDidClose:(NSMenu *)menu
{
    NSLog(@"GTKSubmenuDelegate: GTK menuDidClose called for menu: %@", [menu title]);
    // Nothing special needed on close for now
}

- (void)menu:(NSMenu *)menu willHighlightItem:(NSMenuItem *)item
{
    // Called when an item is about to be highlighted
    // This could be used for additional dynamic loading if needed
    if (item) {
        NSLog(@"GTKSubmenuDelegate: GTK menu will highlight item: '%@'", [item title]);
    }
}

- (NSRect)confinementRectForMenu:(NSMenu *)menu onScreen:(NSScreen *)screen
{
    // Return the screen frame - let the menu display anywhere on screen
    return [screen frame];
}

- (void)gtkMenuItemAction:(NSMenuItem *)sender
{
    NSString *action = [sender representedObject];
    if (!action) {
        NSLog(@"GTKSubmenuDelegate: No action found for GTK menu item '%@'", [sender title]);
        return;
    }
    
    NSLog(@"GTKSubmenuDelegate: Triggering GTK action '%@' for menu item '%@'", action, [sender title]);
    
    // Use the GTK Actions interface to trigger the action
    NSArray *arguments = @[action, @[], @{}]; // action, parameters, platform_data
    
    id result = [_dbusConnection callMethod:@"Activate"
                                  onService:_serviceName
                                 objectPath:_actionPath
                                  interface:@"org.gtk.Actions"
                                  arguments:arguments];
    
    if (result) {
        NSLog(@"GTKSubmenuDelegate: GTK action activation succeeded");
    } else {
        NSLog(@"GTKSubmenuDelegate: GTK action activation failed");
    }
}

@end
