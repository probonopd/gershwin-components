#import "StatusNotifierManager.h"
#import "StatusNotifierItem.h"
#import "DBusConnection.h"
#import "DBusMenuImporter.h"
#import "AppMenuWidget.h"

// D-Bus constants
static NSString * const SNI_WATCHER_SERVICE = @"org.kde.StatusNotifierWatcher";
static NSString * const SNI_WATCHER_OBJECT_PATH = @"/StatusNotifierWatcher";
static NSString * const SNI_WATCHER_INTERFACE = @"org.kde.StatusNotifierWatcher";
static NSString * const SNI_ITEM_INTERFACE = @"org.kde.StatusNotifierItem";

@implementation StatusNotifierManager

- (instancetype)initWithTrayView:(NSView *)trayView
{
    self = [super init];
    if (self) {
        _trayView = [trayView retain];
        _trackedItems = [[NSMutableDictionary alloc] init];
        _isConnected = NO;
        
        // Create host for displaying tray icons
        _host = [[StatusNotifierHost alloc] initWithTrayView:_trayView];
        
        // Get shared watcher
        _watcher = [[StatusNotifierWatcher sharedWatcher] retain];
        
        NSLog(@"StatusNotifierManager: Initialized with tray view");
    }
    return self;
}

- (void)dealloc
{
    [self cleanup];
    [_trayView release];
    [_trackedItems release];
    [_host release];
    [_watcher release];
    [super dealloc];
}

#pragma mark - MenuProtocolHandler Implementation

- (BOOL)connectToDBus
{
    if (_isConnected) {
        return YES;
    }
    
    GNUDBusConnection *connection = [GNUDBusConnection sessionBus];
    if (![connection connect]) {
        NSLog(@"StatusNotifierManager: Failed to connect to D-Bus");
        return NO;
    }
    
    _isConnected = YES;
    NSLog(@"StatusNotifierManager: Connected to D-Bus");
    
    // Initialize the shared StatusNotifierWatcher to register the D-Bus service
    StatusNotifierWatcher *watcher = [StatusNotifierWatcher sharedWatcher];
    (void)watcher; // Suppress unused variable warning
    NSLog(@"StatusNotifierManager: Initialized StatusNotifierWatcher");
    
    // Start hosting tray icons
    [self startHostingTrayIcons];
    
    // Scan for existing items
    [self scanForExistingStatusNotifierItems];
    
    return YES;
}

- (BOOL)hasMenuForWindow:(unsigned long)windowId
{
    // StatusNotifierItems don't have per-window menus
    // They have their own context menus
    return NO;
}

- (NSMenu *)getMenuForWindow:(unsigned long)windowId
{
    // StatusNotifierItems don't provide window-specific menus
    return nil;
}

- (void)activateMenuItem:(NSMenuItem *)menuItem forWindow:(unsigned long)windowId
{
    // Not applicable for StatusNotifierItems
    NSLog(@"StatusNotifierManager: activateMenuItem not applicable for SNI");
}

- (void)registerWindow:(unsigned long)windowId serviceName:(NSString *)serviceName objectPath:(NSString *)objectPath
{
    // StatusNotifierItems register themselves, not per-window
    NSLog(@"StatusNotifierManager: registerWindow not applicable for SNI (windowId=%lu, service=%@)", 
          windowId, serviceName);
}

- (void)unregisterWindow:(unsigned long)windowId
{
    // Not applicable for StatusNotifierItems
}

- (void)scanForExistingMenuServices
{
    // For SNI, we scan for StatusNotifierItems instead
    [self scanForExistingStatusNotifierItems];
}

- (NSString *)getMenuServiceForWindow:(unsigned long)windowId
{
    return nil; // Not applicable
}

- (NSString *)getMenuObjectPathForWindow:(unsigned long)windowId
{
    return nil; // Not applicable
}

- (void)cleanup
{
    [self stopHostingTrayIcons];
    _isConnected = NO;
    [_trackedItems removeAllObjects];
}

#pragma mark - StatusNotifier Specific Methods

- (void)startHostingTrayIcons
{
    NSLog(@"StatusNotifierManager: Starting to host tray icons");
    
    // Register as a StatusNotifierHost
    GNUDBusConnection *connection = [GNUDBusConnection sessionBus];
    if ([connection isConnected]) {
        NSString *hostService = @"org.kde.StatusNotifierHost-Menu";
        if ([connection registerService:hostService]) {
            // Since we ARE the StatusNotifierWatcher, register directly without D-Bus call
            StatusNotifierWatcher *watcher = [StatusNotifierWatcher sharedWatcher];
            [watcher registerStatusNotifierHost:hostService];
            
            NSLog(@"StatusNotifierManager: Registered as StatusNotifierHost: %@", hostService);
        }
    }
    
    // Start monitoring for new items
    [_host startMonitoring];
    
    // Listen for item registrations
    [[NSNotificationCenter defaultCenter] 
     addObserver:self
        selector:@selector(_handleItemRegistered:)
            name:@"StatusNotifierItemRegistered"
          object:_watcher];
    
    [[NSNotificationCenter defaultCenter] 
     addObserver:self
        selector:@selector(_handleItemUnregistered:)
            name:@"StatusNotifierItemUnregistered"
          object:_watcher];
}

- (void)stopHostingTrayIcons
{
    NSLog(@"StatusNotifierManager: Stopping tray icon hosting");
    
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_host stopMonitoring];
    
    // Unregister as host
    GNUDBusConnection *connection = [GNUDBusConnection sessionBus];
    if ([connection isConnected]) {
        NSString *hostService = @"org.kde.StatusNotifierHost-Menu";
        NSArray *args = @[hostService];
        [connection callMethod:@"UnregisterStatusNotifierHost"
                     onService:SNI_WATCHER_SERVICE
                    objectPath:SNI_WATCHER_OBJECT_PATH
                     interface:SNI_WATCHER_INTERFACE
                     arguments:args];
    }
}

- (StatusNotifierItem *)createTrayItemWithId:(NSString *)itemId title:(NSString *)title
{
    StatusNotifierItem *item = [[StatusNotifierItem alloc] 
                               initWithId:itemId 
                                    title:title 
                                 category:SNICategoryApplicationStatus];
    
    if ([item registerWithWatcher]) {
        [_host addTrayItem:item];
        NSLog(@"StatusNotifierManager: Created and registered tray item: %@", itemId);
        return [item autorelease];
    } else {
        [item release];
        NSLog(@"StatusNotifierManager: Failed to register tray item: %@", itemId);
        return nil;
    }
}

- (void)removeTrayItem:(StatusNotifierItem *)item
{
    [item unregister];
    [_host removeTrayItem:item];
    NSLog(@"StatusNotifierManager: Removed tray item: %@", [item id]);
}

#pragma mark - Scanning and Discovery

- (void)scanForExistingStatusNotifierItems
{
    NSLog(@"StatusNotifierManager: Scanning for existing StatusNotifierItems");
    
    GNUDBusConnection *connection = [GNUDBusConnection sessionBus];
    if (![connection isConnected]) {
        NSLog(@"StatusNotifierManager: Not connected to D-Bus, skipping scan");
        return;
    }
    
    // Since we ARE the StatusNotifierWatcher, we can skip the D-Bus call and check directly
    StatusNotifierWatcher *watcher = [StatusNotifierWatcher sharedWatcher];
    NSArray *itemServices = [watcher registeredStatusNotifierItems];
    
    NSLog(@"StatusNotifierManager: Found %lu existing items", (unsigned long)[itemServices count]);
    
    for (NSString *serviceName in itemServices) {
        [self handleNewStatusNotifierItem:serviceName];
    }
}

- (void)handleNewStatusNotifierItem:(NSString *)serviceName
{
    NSLog(@"StatusNotifierManager: Handling new StatusNotifierItem: %@", serviceName);
    
    // Check if we're already tracking this item
    if ([_trackedItems objectForKey:serviceName]) {
        NSLog(@"StatusNotifierManager: Already tracking item %@", serviceName);
        return;
    }
    
    // Determine object path - try standard paths
    NSArray *possiblePaths = @[
        @"/StatusNotifierItem",
        @"/org/kde/StatusNotifierItem"
    ];
    
    // Only add service-specific path if serviceName doesn't contain invalid characters
    if (![serviceName containsString:@":"]) {
        NSMutableArray *paths = [NSMutableArray arrayWithArray:possiblePaths];
        [paths addObject:[NSString stringWithFormat:@"/StatusNotifierItem/%@", serviceName]];
        possiblePaths = paths;
    }
    
    GNUDBusConnection *connection = [GNUDBusConnection sessionBus];
    NSString *objectPath = nil;
    
    for (NSString *path in possiblePaths) {
        // Try to introspect to see if the path exists
        id result = [connection callMethod:@"Introspect"
                                 onService:serviceName
                                objectPath:path
                                 interface:@"org.freedesktop.DBus.Introspectable"
                                 arguments:@[]];
        
        if (result && [result isKindOfClass:[NSString class]]) {
            NSString *introspectionXML = (NSString *)result;
            if ([introspectionXML containsString:SNI_ITEM_INTERFACE]) {
                objectPath = path;
                break;
            }
        }
    }
    
    if (!objectPath) {
        NSLog(@"StatusNotifierManager: Could not find object path for %@", serviceName);
        return;
    }
    
    // Create proxy object for the remote item
    StatusNotifierItemProxy *proxy = [[StatusNotifierItemProxy alloc] 
                                     initWithService:serviceName objectPath:objectPath];
    [proxy refreshProperties];
    
    [_trackedItems setObject:proxy forKey:serviceName];
    
    // Add to our host display
    // Note: This is a simplified approach - in a real implementation,
    // we'd need to create a visual representation of the proxy
    NSLog(@"StatusNotifierManager: Tracking new item %@ at %@", serviceName, objectPath);
    
    [proxy release];
}

- (void)handleRemovedStatusNotifierItem:(NSString *)serviceName
{
    NSLog(@"StatusNotifierManager: Handling removed StatusNotifierItem: %@", serviceName);
    
    StatusNotifierItemProxy *proxy = [_trackedItems objectForKey:serviceName];
    if (proxy) {
        [_trackedItems removeObjectForKey:serviceName];
        // Remove from visual display
        NSLog(@"StatusNotifierManager: Removed tracking for item %@", serviceName);
    }
}

#pragma mark - Notification Handlers

- (void)_handleItemRegistered:(NSNotification *)notification
{
    NSString *serviceName = [[notification userInfo] objectForKey:@"service"];
    if (serviceName) {
        [self handleNewStatusNotifierItem:serviceName];
    }
}

- (void)_handleItemUnregistered:(NSNotification *)notification
{
    NSString *serviceName = [[notification userInfo] objectForKey:@"service"];
    if (serviceName) {
        [self handleRemovedStatusNotifierItem:serviceName];
    }
}

@end

#pragma mark - StatusNotifierItemProxy Implementation

@implementation StatusNotifierItemProxy

- (instancetype)initWithService:(NSString *)serviceName objectPath:(NSString *)objectPath
{
    self = [super init];
    if (self) {
        _serviceName = [serviceName copy];
        _objectPath = [objectPath copy];
        NSLog(@"StatusNotifierItemProxy: Created proxy for %@ at %@", serviceName, objectPath);
    }
    return self;
}

- (void)dealloc
{
    [_serviceName release];
    [_objectPath release];
    [_itemId release];
    [_title release];
    [_iconName release];
    [_iconPixmap release];
    [_status release];
    [_category release];
    [_menuObjectPath release];
    [_contextMenu release];
    [super dealloc];
}

- (void)refreshProperties
{
    NSLog(@"StatusNotifierItemProxy: Refreshing properties for %@", _serviceName);
    
    GNUDBusConnection *connection = [GNUDBusConnection sessionBus];
    if (![connection isConnected]) {
        return;
    }
    
    // Get all properties
    NSArray *propertyNames = @[@"Id", @"Title", @"Status", @"Category", 
                              @"IconName", @"IconPixmap", @"Menu"];
    
    for (NSString *propertyName in propertyNames) {
        id result = [connection callMethod:@"Get"
                                 onService:_serviceName
                                objectPath:_objectPath
                                 interface:@"org.freedesktop.DBus.Properties"
                                 arguments:@[SNI_ITEM_INTERFACE, propertyName]];
        
        if (result) {
            [self _setProperty:propertyName value:result];
        }
    }
    
    // Refresh menu if we have a menu object path
    if (_menuObjectPath && ![_menuObjectPath isEqualToString:@"/"]) {
        [self refreshMenu];
    }
}

- (void)refreshMenu
{
    if (!_menuObjectPath || [_menuObjectPath isEqualToString:@"/"]) {
        return;
    }
    
    NSLog(@"StatusNotifierItemProxy: Refreshing menu for %@ at %@", _serviceName, _menuObjectPath);
    
    // Use existing DBusMenuImporter to load the menu
    DBusMenuImporter *importer = [[DBusMenuImporter alloc] init];
    NSMenu *menu = [importer loadMenuFromDBus:_serviceName objectPath:_menuObjectPath];
    
    if (menu) {
        [_contextMenu release];
        _contextMenu = [menu retain];
        NSLog(@"StatusNotifierItemProxy: Loaded menu with %ld items", (long)[[menu itemArray] count]);
    }
    
    [importer release];
}

- (void)_setProperty:(NSString *)propertyName value:(id)value
{
    if ([propertyName isEqualToString:@"Id"] && [value isKindOfClass:[NSString class]]) {
        [_itemId release];
        _itemId = [value copy];
    } else if ([propertyName isEqualToString:@"Title"] && [value isKindOfClass:[NSString class]]) {
        [_title release];
        _title = [value copy];
    } else if ([propertyName isEqualToString:@"Status"] && [value isKindOfClass:[NSString class]]) {
        [_status release];
        _status = [value copy];
    } else if ([propertyName isEqualToString:@"Category"] && [value isKindOfClass:[NSString class]]) {
        [_category release];
        _category = [value copy];
    } else if ([propertyName isEqualToString:@"IconName"] && [value isKindOfClass:[NSString class]]) {
        [_iconName release];
        _iconName = [value copy];
    } else if ([propertyName isEqualToString:@"IconPixmap"] && [value isKindOfClass:[NSData class]]) {
        [_iconPixmap release];
        _iconPixmap = [value copy];
    } else if ([propertyName isEqualToString:@"Menu"] && [value isKindOfClass:[NSString class]]) {
        [_menuObjectPath release];
        _menuObjectPath = [value copy];
    }
}

- (void)activate:(int)x y:(int)y
{
    NSLog(@"StatusNotifierItemProxy: Activating %@ at (%d, %d)", _serviceName, x, y);
    
    GNUDBusConnection *connection = [GNUDBusConnection sessionBus];
    if ([connection isConnected]) {
        NSArray *args = @[@(x), @(y)];
        [connection callMethod:@"Activate"
                     onService:_serviceName
                    objectPath:_objectPath
                     interface:SNI_ITEM_INTERFACE
                     arguments:args];
    }
}

- (void)secondaryActivate:(int)x y:(int)y
{
    NSLog(@"StatusNotifierItemProxy: SecondaryActivate %@ at (%d, %d)", _serviceName, x, y);
    
    GNUDBusConnection *connection = [GNUDBusConnection sessionBus];
    if ([connection isConnected]) {
        NSArray *args = @[@(x), @(y)];
        [connection callMethod:@"SecondaryActivate"
                     onService:_serviceName
                    objectPath:_objectPath
                     interface:SNI_ITEM_INTERFACE
                     arguments:args];
    }
}

- (void)contextMenu:(int)x y:(int)y
{
    NSLog(@"StatusNotifierItemProxy: ContextMenu %@ at (%d, %d)", _serviceName, x, y);
    
    GNUDBusConnection *connection = [GNUDBusConnection sessionBus];
    if ([connection isConnected]) {
        NSArray *args = @[@(x), @(y)];
        [connection callMethod:@"ContextMenu"
                     onService:_serviceName
                    objectPath:_objectPath
                     interface:SNI_ITEM_INTERFACE
                     arguments:args];
    }
}

- (void)scroll:(int)delta orientation:(NSString *)orientation
{
    NSLog(@"StatusNotifierItemProxy: Scroll %@ delta=%d orientation=%@", _serviceName, delta, orientation);
    
    GNUDBusConnection *connection = [GNUDBusConnection sessionBus];
    if ([connection isConnected]) {
        NSArray *args = @[@(delta), orientation];
        [connection callMethod:@"Scroll"
                     onService:_serviceName
                    objectPath:_objectPath
                     interface:SNI_ITEM_INTERFACE
                     arguments:args];
    }
}

@end
