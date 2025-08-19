#import "DBusMenuServer.h"
#import "DBusConnection.h"

// D-Bus constants
static NSString * const DBUSMENU_INTERFACE = @"org.freedesktop.DBus.Menu";
static NSString * const DBUSMENU_PROPERTIES_INTERFACE = @"org.freedesktop.DBus.Properties";

// Property constants
static NSString * const PROP_TYPE = @"type";
static NSString * const PROP_LABEL = @"label";
static NSString * const PROP_ENABLED = @"enabled";
static NSString * const PROP_VISIBLE = @"visible";
static NSString * const PROP_ICON_DATA = @"icon-data";
static NSString * const PROP_SHORTCUT = @"shortcut";
static NSString * const PROP_CHILDREN_DISPLAY = @"children-display";

@implementation DBusMenuServer

- (instancetype)initWithMenu:(NSMenu *)menu objectPath:(NSString *)objectPath
{
    self = [super init];
    if (self) {
        _objectPath = [objectPath copy];
        _menu = [menu retain];
        _menuItems = [[NSMutableDictionary alloc] init];
        _nextItemId = 1;
        _isRegistered = NO;
        
        // Build initial item mapping
        [self _buildItemMapping];
        
        // Listen for menu changes
        [[NSNotificationCenter defaultCenter] 
         addObserver:self
            selector:@selector(menuDidChange:)
                name:@"NSMenuDidChangeItem"
              object:_menu];
    }
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self unregister];
    [_objectPath release];
    [_menu release];
    [_menuItems release];
    [super dealloc];
}

#pragma mark - Registration

- (BOOL)registerWithDBus
{
    if (_isRegistered) {
        return YES;
    }
    
    _connection = [[GNUDBusConnection sessionBus] retain];
    if (![_connection isConnected] && ![_connection connect]) {
        NSLog(@"DBusMenuServer: Failed to connect to D-Bus");
        return NO;
    }
    
    // Register object path with DBusMenu interface
    if (![_connection registerObjectPath:_objectPath 
                               interface:DBUSMENU_INTERFACE 
                                 handler:self]) {
        NSLog(@"DBusMenuServer: Failed to register object path %@", _objectPath);
        return NO;
    }
    
    // Also register Properties interface
    if (![_connection registerObjectPath:_objectPath 
                               interface:DBUSMENU_PROPERTIES_INTERFACE 
                                 handler:self]) {
        NSLog(@"DBusMenuServer: Failed to register Properties interface at %@", _objectPath);
        return NO;
    }
    
    _isRegistered = YES;
    NSLog(@"DBusMenuServer: Registered menu server at %@", _objectPath);
    return YES;
}

- (void)unregister
{
    if (!_isRegistered) {
        return;
    }
    
    [_connection release];
    _connection = nil;
    _isRegistered = NO;
    
    NSLog(@"DBusMenuServer: Unregistered menu server at %@", _objectPath);
}

#pragma mark - Item Mapping

- (void)_buildItemMapping
{
    [_menuItems removeAllObjects];
    _nextItemId = 1;
    
    // Root item (id = 0) represents the menu itself
    [_menuItems setObject:_menu forKey:@(0)];
    
    // Map all menu items recursively
    [self _mapMenuItemsRecursively:[_menu itemArray] parentId:0];
}

- (void)_mapMenuItemsRecursively:(NSArray *)items parentId:(NSInteger)parentId
{
    for (NSMenuItem *item in items) {
        NSInteger itemId = _nextItemId++;
        [_menuItems setObject:item forKey:@(itemId)];
        
        // Store the D-Bus ID in the menu item for reverse lookup
        [item setRepresentedObject:@(itemId)];
        
        if ([item hasSubmenu]) {
            [self _mapMenuItemsRecursively:[[item submenu] itemArray] parentId:itemId];
        }
    }
}

- (NSInteger)_itemIdForMenuItem:(NSMenuItem *)item
{
    NSNumber *itemIdNumber = [item representedObject];
    if (itemIdNumber && [itemIdNumber isKindOfClass:[NSNumber class]]) {
        return [itemIdNumber integerValue];
    }
    return -1;
}

#pragma mark - D-Bus Method Implementations

- (NSArray *)getLayout:(NSInteger)parentId 
        recursionDepth:(NSInteger)depth 
         propertyNames:(NSArray *)propertyNames
{
    NSLog(@"DBusMenuServer: GetLayout parentId=%ld depth=%ld", (long)parentId, (long)depth);
    
    id parentItem = [_menuItems objectForKey:@(parentId)];
    if (!parentItem) {
        NSLog(@"DBusMenuServer: Parent item %ld not found", (long)parentId);
        return @[@(1), @{}]; // Return revision 1 and empty layout
    }
    
    NSDictionary *layout = [self _buildLayoutForItem:parentItem 
                                              itemId:parentId 
                                      recursionDepth:depth 
                                       propertyNames:propertyNames];
    
    return @[@(1), layout]; // Return revision 1 and layout
}

- (NSDictionary *)_buildLayoutForItem:(id)item 
                               itemId:(NSInteger)itemId 
                       recursionDepth:(NSInteger)depth 
                        propertyNames:(NSArray *)propertyNames
{
    NSMutableDictionary *layout = [NSMutableDictionary dictionary];
    
    // Set item ID
    [layout setObject:@(itemId) forKey:@"id"];
    
    // Get properties
    NSMutableDictionary *properties = [NSMutableDictionary dictionary];
    
    if ([item isKindOfClass:[NSMenuItem class]]) {
        NSMenuItem *menuItem = (NSMenuItem *)item;
        NSDictionary *allProps = [DBusMenuProperty propertiesForMenuItem:menuItem];
        
        if (propertyNames && [propertyNames count] > 0) {
            // Only include requested properties
            for (NSString *propName in propertyNames) {
                id value = [allProps objectForKey:propName];
                if (value) {
                    [properties setObject:value forKey:propName];
                }
            }
        } else {
            // Include all properties
            [properties addEntriesFromDictionary:allProps];
        }
    } else if ([item isKindOfClass:[NSMenu class]]) {
        // Root menu item
        [properties setObject:@"standard" forKey:PROP_CHILDREN_DISPLAY];
    }
    
    [layout setObject:properties forKey:@"properties"];
    
    // Add children if within recursion depth
    if (depth != 0) { // 0 means no recursion, -1 means infinite
        NSArray *children = [self _getChildrenForItem:item];
        NSMutableArray *childLayouts = [NSMutableArray array];
        
        for (NSMenuItem *child in children) {
            NSInteger childId = [self _itemIdForMenuItem:child];
            if (childId >= 0) {
                NSDictionary *childLayout = [self _buildLayoutForItem:child 
                                                               itemId:childId 
                                                       recursionDepth:(depth > 0) ? depth - 1 : depth 
                                                        propertyNames:propertyNames];
                [childLayouts addObject:childLayout];
            }
        }
        
        [layout setObject:childLayouts forKey:@"children"];
    }
    
    return layout;
}

- (NSArray *)_getChildrenForItem:(id)item
{
    if ([item isKindOfClass:[NSMenu class]]) {
        return [(NSMenu *)item itemArray];
    } else if ([item isKindOfClass:[NSMenuItem class]]) {
        NSMenuItem *menuItem = (NSMenuItem *)item;
        if ([menuItem hasSubmenu]) {
            return [[[menuItem submenu] itemArray] copy];
        }
    }
    return @[];
}

- (NSDictionary *)getGroupProperties:(NSArray *)itemIds propertyNames:(NSArray *)propertyNames
{
    NSLog(@"DBusMenuServer: GetGroupProperties itemIds=%@ properties=%@", itemIds, propertyNames);
    
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    
    for (NSNumber *itemIdNumber in itemIds) {
        NSInteger itemId = [itemIdNumber integerValue];
        id item = [_menuItems objectForKey:@(itemId)];
        
        if ([item isKindOfClass:[NSMenuItem class]]) {
            NSMenuItem *menuItem = (NSMenuItem *)item;
            NSDictionary *allProps = [DBusMenuProperty propertiesForMenuItem:menuItem];
            NSMutableDictionary *requestedProps = [NSMutableDictionary dictionary];
            
            if (propertyNames && [propertyNames count] > 0) {
                for (NSString *propName in propertyNames) {
                    id value = [allProps objectForKey:propName];
                    if (value) {
                        [requestedProps setObject:value forKey:propName];
                    }
                }
            } else {
                [requestedProps addEntriesFromDictionary:allProps];
            }
            
            [result setObject:requestedProps forKey:itemIdNumber];
        }
    }
    
    return result;
}

- (id)getProperty:(NSInteger)itemId propertyName:(NSString *)propertyName
{
    NSLog(@"DBusMenuServer: GetProperty itemId=%ld property=%@", (long)itemId, propertyName);
    
    id item = [_menuItems objectForKey:@(itemId)];
    if ([item isKindOfClass:[NSMenuItem class]]) {
        NSMenuItem *menuItem = (NSMenuItem *)item;
        NSDictionary *properties = [DBusMenuProperty propertiesForMenuItem:menuItem];
        return [properties objectForKey:propertyName];
    }
    
    return nil;
}

- (void)event:(NSInteger)itemId eventId:(NSString *)eventId data:(id)data timestamp:(NSUInteger)timestamp
{
    NSLog(@"DBusMenuServer: Event itemId=%ld eventId=%@ data=%@ timestamp=%lu", 
          (long)itemId, eventId, data, (unsigned long)timestamp);
    
    if ([eventId isEqualToString:@"clicked"]) {
        id item = [_menuItems objectForKey:@(itemId)];
        if ([item isKindOfClass:[NSMenuItem class]]) {
            NSMenuItem *menuItem = (NSMenuItem *)item;
            
            // Perform the menu item action on the main thread
            [self performSelectorOnMainThread:@selector(_performMenuItemAction:) 
                                   withObject:menuItem 
                                waitUntilDone:NO];
        }
    }
}

- (NSArray *)eventGroup:(NSArray *)events
{
    NSLog(@"DBusMenuServer: EventGroup events=%@", events);
    
    NSMutableArray *errors = [NSMutableArray array];
    
    for (NSDictionary *event in events) {
        NSInteger itemId = [[event objectForKey:@"id"] integerValue];
        NSString *eventId = [event objectForKey:@"event-id"];
        id data = [event objectForKey:@"data"];
        NSUInteger timestamp = [[event objectForKey:@"timestamp"] unsignedIntegerValue];
        
        @try {
            [self event:itemId eventId:eventId data:data timestamp:timestamp];
            [errors addObject:@""]; // No error
        } @catch (NSException *exception) {
            [errors addObject:[exception reason]];
        }
    }
    
    return errors;
}

- (void)_performMenuItemAction:(NSMenuItem *)menuItem
{
    if ([menuItem target] && [menuItem action]) {
        [[menuItem target] performSelector:[menuItem action] withObject:menuItem];
    } else {
        NSLog(@"DBusMenuServer: Menu item has no target/action");
    }
}

- (BOOL)aboutToShow:(NSInteger)itemId
{
    NSLog(@"DBusMenuServer: AboutToShow itemId=%ld", (long)itemId);
    
    id item = [_menuItems objectForKey:@(itemId)];
    if ([item isKindOfClass:[NSMenuItem class]]) {
        NSMenuItem *menuItem = (NSMenuItem *)item;
        
        // Notify that submenu is about to be shown
        if ([menuItem hasSubmenu]) {
            NSMenu *submenu = [menuItem submenu];
            
            // Send menuWillOpen notification
            [[NSNotificationCenter defaultCenter] 
             postNotificationName:@"NSMenuWillOpen"
                           object:submenu];
            
            return YES; // Menu was updated
        }
    }
    
    return NO; // No updates needed
}

- (NSArray *)aboutToShowGroup:(NSArray *)itemIds
{
    NSLog(@"DBusMenuServer: AboutToShowGroup itemIds=%@", itemIds);
    
    NSMutableArray *updatesNeeded = [NSMutableArray array];
    
    for (NSNumber *itemIdNumber in itemIds) {
        NSInteger itemId = [itemIdNumber integerValue];
        BOOL needsUpdate = [self aboutToShow:itemId];
        [updatesNeeded addObject:@(needsUpdate)];
    }
    
    return updatesNeeded;
}

#pragma mark - Menu Change Handling

- (void)menuDidChange:(NSNotification *)notification
{
    NSLog(@"DBusMenuServer: Menu changed, rebuilding item mapping");
    
    // Rebuild the item mapping since menu structure changed
    [self _buildItemMapping];
    
    // Emit layout updated signal
    [self emitLayoutUpdated:2 parentId:0]; // Increment revision to 2
}

- (void)emitLayoutUpdated:(NSInteger)revision parentId:(NSInteger)parentId
{
    if (!_isRegistered || !_connection) {
        return;
    }
    
    NSLog(@"DBusMenuServer: Emitting LayoutUpdated revision=%ld parentId=%ld", 
          (long)revision, (long)parentId);
    
    NSArray *args = @[@(revision), @(parentId)];
    [_connection callMethod:@"LayoutUpdated"
                  onService:nil // Signal, not method call
                 objectPath:_objectPath
                  interface:DBUSMENU_INTERFACE
                  arguments:args];
}

- (void)emitItemsPropertiesUpdated:(NSArray *)updatedProps removedProps:(NSArray *)removedProps
{
    if (!_isRegistered || !_connection) {
        return;
    }
    
    NSLog(@"DBusMenuServer: Emitting ItemsPropertiesUpdated");
    
    NSArray *args = @[updatedProps ?: @[], removedProps ?: @[]];
    [_connection callMethod:@"ItemsPropertiesUpdated"
                  onService:nil
                 objectPath:_objectPath
                  interface:DBUSMENU_INTERFACE
                  arguments:args];
}

@end

#pragma mark - DBusMenuProperty Implementation

@implementation DBusMenuProperty

+ (NSDictionary *)propertiesForMenuItem:(NSMenuItem *)item
{
    NSMutableDictionary *properties = [NSMutableDictionary dictionary];
    
    // Type
    [properties setObject:[self typeForMenuItem:item] forKey:PROP_TYPE];
    
    // Label
    NSString *label = [self labelForMenuItem:item];
    if (label) {
        [properties setObject:label forKey:PROP_LABEL];
    }
    
    // Enabled
    [properties setObject:@([self enabledForMenuItem:item]) forKey:PROP_ENABLED];
    
    // Visible
    [properties setObject:@([self visibleForMenuItem:item]) forKey:PROP_VISIBLE];
    
    // Icon
    NSData *iconData = [self iconDataForMenuItem:item];
    if (iconData) {
        [properties setObject:iconData forKey:PROP_ICON_DATA];
    }
    
    // Shortcut
    NSString *shortcut = [self shortcutForMenuItem:item];
    if (shortcut) {
        [properties setObject:@[shortcut] forKey:PROP_SHORTCUT];
    }
    
    // Children display (for submenus)
    if ([item hasSubmenu]) {
        [properties setObject:@"submenu" forKey:PROP_CHILDREN_DISPLAY];
    }
    
    return properties;
}

+ (NSString *)typeForMenuItem:(NSMenuItem *)item
{
    if ([item isSeparatorItem]) {
        return @"separator";
    } else if ([item hasSubmenu]) {
        return @"standard";
    } else {
        return @"standard";
    }
}

+ (NSString *)labelForMenuItem:(NSMenuItem *)item
{
    if ([item isSeparatorItem]) {
        return nil;
    }
    
    NSString *title = [item title];
    if (!title || [title length] == 0) {
        return nil;
    }
    
    // Remove mnemonics (underscores) from the title
    return [title stringByReplacingOccurrencesOfString:@"_" withString:@""];
}

+ (BOOL)enabledForMenuItem:(NSMenuItem *)item
{
    return [item isEnabled];
}

+ (BOOL)visibleForMenuItem:(NSMenuItem *)item
{
    // GNUstep NSMenuItem doesn't have isHidden, assume visible
    return YES;
}

+ (NSArray *)childrenDisplayForMenuItem:(NSMenuItem *)item
{
    if ([item hasSubmenu]) {
        return @[@"submenu"];
    }
    return nil;
}

+ (NSData *)iconDataForMenuItem:(NSMenuItem *)item
{
    NSImage *image = [item image];
    if (!image) {
        return nil;
    }
    
    // Convert NSImage to PNG data
    NSData *tiffData = [image TIFFRepresentation];
    if (!tiffData) {
        return nil;
    }
    
    NSBitmapImageRep *bitmap = [NSBitmapImageRep imageRepWithData:tiffData];
    if (!bitmap) {
        return nil;
    }
    
    NSData *pngData = [bitmap representationUsingType:NSPNGFileType properties:@{}];
    return pngData;
}

+ (NSString *)shortcutForMenuItem:(NSMenuItem *)item
{
    NSString *keyEquivalent = [item keyEquivalent];
    if (!keyEquivalent || [keyEquivalent length] == 0) {
        return nil;
    }
    
    NSUInteger modifierMask = [item keyEquivalentModifierMask];
    NSMutableArray *parts = [NSMutableArray array];
    
    if (modifierMask & NSControlKeyMask) {
        [parts addObject:@"Control"];
    }
    if (modifierMask & NSAlternateKeyMask) {
        [parts addObject:@"Alt"];
    }
    if (modifierMask & NSShiftKeyMask) {
        [parts addObject:@"Shift"];
    }
    if (modifierMask & NSCommandKeyMask) {
        [parts addObject:@"Super"];
    }
    
    // Add the key
    [parts addObject:keyEquivalent];
    
    return [parts componentsJoinedByString:@"+"];
}

@end
