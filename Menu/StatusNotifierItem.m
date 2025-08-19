#import "StatusNotifierItem.h"
#import "DBusConnection.h"
#import "DBusMenuServer.h"
#import <X11/Xlib.h>
#import <dbus/dbus.h>

// D-Bus constants
static NSString * const SNI_DBUS_INTERFACE = @"org.kde.StatusNotifierItem";
static NSString * const SNI_WATCHER_SERVICE = @"org.kde.StatusNotifierWatcher";
static NSString * const SNI_WATCHER_OBJECT_PATH = @"/StatusNotifierWatcher";
static NSString * const SNI_WATCHER_INTERFACE = @"org.kde.StatusNotifierWatcher";

@implementation StatusNotifierItem

- (instancetype)initWithId:(NSString *)itemId 
                     title:(NSString *)title
                  category:(SNICategory)category
{
    self = [super init];
    if (self) {
        _id = [itemId copy];
        _title = [title copy];
        _category = category;
        _status = SNIStatusActive;
        _isRegistered = NO;
        
        // Generate unique service name and object path
        NSString *processName = [[NSProcessInfo processInfo] processName];
        int pid = [[NSProcessInfo processInfo] processIdentifier];
        _serviceName = [NSString stringWithFormat:@"org.kde.StatusNotifierItem-%d-%@", pid, processName];
        _objectPath = [NSString stringWithFormat:@"/StatusNotifierItem/%@", itemId];
        
        NSLog(@"StatusNotifierItem: Created with id=%@ service=%@ path=%@", 
              _id, _serviceName, _objectPath);
    }
    return self;
}

- (void)dealloc
{
    [self unregister];
    [_serviceName release];
    [_objectPath release];
    [_id release];
    [_title release];
    [_iconName release];
    [_iconThemePath release];
    [_iconPixmap release];
    [_overlayIconName release];
    [_overlayIconPixmap release];
    [_attentionIconName release];
    [_attentionIconPixmap release];
    [_attentionMovieName release];
    [_toolTipTitle release];
    [_toolTipSubTitle release];
    [_toolTipIcon release];
    [_contextMenu release];
    [_menuServer release];
    [super dealloc];
}

#pragma mark - Registration

- (BOOL)registerWithWatcher
{
    if (_isRegistered) {
        NSLog(@"StatusNotifierItem: Already registered");
        return YES;
    }
    
    GNUDBusConnection *connection = [GNUDBusConnection sessionBus];
    if (![connection isConnected] && ![connection connect]) {
        NSLog(@"StatusNotifierItem: Failed to connect to D-Bus");
        return NO;
    }
    
    // Register our service name
    if (![connection registerService:_serviceName]) {
        NSLog(@"StatusNotifierItem: Failed to register service %@", _serviceName);
        return NO;
    }
    
    // Register our object path with the StatusNotifierItem interface
    if (![connection registerObjectPath:_objectPath 
                              interface:SNI_DBUS_INTERFACE 
                                handler:self]) {
        NSLog(@"StatusNotifierItem: Failed to register object path %@", _objectPath);
        return NO;
    }
    
    // Register with the StatusNotifierWatcher
    NSArray *args = @[_serviceName];
    id result = [connection callMethod:@"RegisterStatusNotifierItem"
                             onService:SNI_WATCHER_SERVICE
                            objectPath:SNI_WATCHER_OBJECT_PATH
                             interface:SNI_WATCHER_INTERFACE
                             arguments:args];
    
    if (!result) {
        NSLog(@"StatusNotifierItem: Failed to register with watcher");
        return NO;
    }
    
    _isRegistered = YES;
    NSLog(@"StatusNotifierItem: Successfully registered %@ with watcher", _serviceName);
    
    // Create menu server if we have a context menu
    if (_contextMenu) {
        [self _createMenuServer];
    }
    
    return YES;
}

- (void)unregister
{
    if (!_isRegistered) {
        return;
    }
    
    GNUDBusConnection *connection = [GNUDBusConnection sessionBus];
    if ([connection isConnected]) {
        // Unregister from watcher
        NSArray *args = @[_serviceName];
        [connection callMethod:@"UnregisterStatusNotifierItem"
                     onService:SNI_WATCHER_SERVICE
                    objectPath:SNI_WATCHER_OBJECT_PATH
                     interface:SNI_WATCHER_INTERFACE
                     arguments:args];
    }
    
    [_menuServer release];
    _menuServer = nil;
    _isRegistered = NO;
    
    NSLog(@"StatusNotifierItem: Unregistered %@", _serviceName);
}

#pragma mark - Icon Management

- (void)setIconFromImage:(NSImage *)image
{
    if (!image) return;
    
    _iconPixmap = [[self _imageToPixmapData:image] retain];
    [self emitPropertyChanged:@"IconPixmap"];
}

- (void)setAttentionIconFromImage:(NSImage *)image
{
    if (!image) return;
    
    _attentionIconPixmap = [[self _imageToPixmapData:image] retain];
    [self emitPropertyChanged:@"AttentionIconPixmap"];
}

- (void)setOverlayIconFromImage:(NSImage *)image
{
    if (!image) return;
    
    _overlayIconPixmap = [[self _imageToPixmapData:image] retain];
    [self emitPropertyChanged:@"OverlayIconPixmap"];
}

- (void)setToolTipIconFromImage:(NSImage *)image
{
    if (!image) return;
    
    _toolTipIcon = [[self _imageToPixmapData:image] retain];
    [self emitPropertyChanged:@"ToolTip"];
}

- (NSData *)_imageToPixmapData:(NSImage *)image
{
    // Convert NSImage to raw ARGB pixel data for D-Bus
    // This is a simplified implementation - real version would handle different formats
    NSSize size = [image size];
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] 
                                initWithBitmapDataPlanes:NULL
                                              pixelsWide:size.width
                                              pixelsHigh:size.height
                                           bitsPerSample:8
                                         samplesPerPixel:4
                                                hasAlpha:YES
                                                isPlanar:NO
                                          colorSpaceName:NSDeviceRGBColorSpace
                                             bytesPerRow:0
                                            bitsPerPixel:32];
    
    // Draw image into bitmap
    NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:context];
    [image drawInRect:NSMakeRect(0, 0, size.width, size.height)];
    [NSGraphicsContext restoreGraphicsState];
    
    NSData *data = [NSData dataWithBytes:[bitmap bitmapData] 
                                  length:[bitmap bytesPerRow] * size.height];
    [bitmap release];
    return data;
}

#pragma mark - Status Updates

- (void)updateStatus:(SNIStatus)newStatus
{
    if (_status != newStatus) {
        _status = newStatus;
        [self emitPropertyChanged:@"Status"];
    }
}

- (void)updateTitle:(NSString *)newTitle
{
    if (![_title isEqualToString:newTitle]) {
        [_title release];
        _title = [newTitle copy];
        [self emitPropertyChanged:@"Title"];
    }
}

- (void)updateToolTip:(NSString *)title subtitle:(NSString *)subtitle
{
    BOOL changed = NO;
    
    if (![_toolTipTitle isEqualToString:title]) {
        [_toolTipTitle release];
        _toolTipTitle = [title copy];
        changed = YES;
    }
    
    if (![_toolTipSubTitle isEqualToString:subtitle]) {
        [_toolTipSubTitle release];
        _toolTipSubTitle = [subtitle copy];
        changed = YES;
    }
    
    if (changed) {
        [self emitPropertyChanged:@"ToolTip"];
    }
}

#pragma mark - Menu Management

- (void)setContextMenu:(NSMenu *)menu
{
    if (_contextMenu != menu) {
        [_contextMenu release];
        _contextMenu = [menu retain];
        
        if (_isRegistered) {
            [self _createMenuServer];
            [self emitPropertyChanged:@"Menu"];
        }
    }
}

- (NSString *)menuObjectPath
{
    if (_menuServer) {
        return [_menuServer objectPath];
    }
    return @"/";
}

- (void)_createMenuServer
{
    if (_menuServer) {
        [_menuServer release];
    }
    
    if (_contextMenu) {
        NSString *menuPath = [NSString stringWithFormat:@"%@/menu", _objectPath];
        _menuServer = [[DBusMenuServer alloc] initWithMenu:_contextMenu objectPath:menuPath];
        NSLog(@"StatusNotifierItem: Created menu server at %@", menuPath);
    }
}

#pragma mark - D-Bus Method Implementations

- (void)activate:(int)x y:(int)y
{
    NSLog(@"StatusNotifierItem: Activate at (%d, %d)", x, y);
    
    // Send notification that item was activated
    [[NSNotificationCenter defaultCenter] 
     postNotificationName:@"StatusNotifierItemActivated"
                   object:self
                 userInfo:@{@"x": @(x), @"y": @(y)}];
}

- (void)secondaryActivate:(int)x y:(int)y
{
    NSLog(@"StatusNotifierItem: SecondaryActivate at (%d, %d)", x, y);
    
    // Typically shows context menu
    if (_contextMenu) {
        // Post notification to show context menu
        [[NSNotificationCenter defaultCenter] 
         postNotificationName:@"StatusNotifierItemSecondaryActivated"
                       object:self
                     userInfo:@{@"x": @(x), @"y": @(y), @"menu": _contextMenu}];
    }
}

- (void)contextMenu:(int)x y:(int)y
{
    NSLog(@"StatusNotifierItem: ContextMenu at (%d, %d)", x, y);
    
    if (_contextMenu) {
        [[NSNotificationCenter defaultCenter] 
         postNotificationName:@"StatusNotifierItemContextMenu"
                       object:self
                     userInfo:@{@"x": @(x), @"y": @(y), @"menu": _contextMenu}];
    }
}

- (void)scroll:(int)delta orientation:(NSString *)orientation
{
    NSLog(@"StatusNotifierItem: Scroll delta=%d orientation=%@", delta, orientation);
    
    [[NSNotificationCenter defaultCenter] 
     postNotificationName:@"StatusNotifierItemScroll"
                   object:self
                 userInfo:@{@"delta": @(delta), @"orientation": orientation}];
}

#pragma mark - Property Change Notifications

- (void)emitPropertyChanged:(NSString *)propertyName
{
    if (!_isRegistered) return;
    
    GNUDBusConnection *connection = [GNUDBusConnection sessionBus];
    if ([connection isConnected]) {
        // Emit PropertiesChanged signal
        NSArray *args = @[SNI_DBUS_INTERFACE, @{propertyName: [self _getPropertyValue:propertyName]}, @[]];
        [connection callMethod:@"PropertiesChanged"
                     onService:_serviceName
                    objectPath:_objectPath
                     interface:@"org.freedesktop.DBus.Properties"
                     arguments:args];
    }
}

- (id)_getPropertyValue:(NSString *)propertyName
{
    // Map property names to actual values
    if ([propertyName isEqualToString:@"Id"]) return _id;
    if ([propertyName isEqualToString:@"Title"]) return _title;
    if ([propertyName isEqualToString:@"Status"]) return [self _statusToString:_status];
    if ([propertyName isEqualToString:@"Category"]) return [self _categoryToString:_category];
    if ([propertyName isEqualToString:@"IconName"]) return _iconName ?: @"";
    if ([propertyName isEqualToString:@"IconPixmap"]) return _iconPixmap ?: [NSData data];
    if ([propertyName isEqualToString:@"Menu"]) return [self menuObjectPath];
    if ([propertyName isEqualToString:@"ToolTip"]) {
        return @[_toolTipIcon ?: [NSData data], _toolTipTitle ?: @"", _toolTipSubTitle ?: @""];
    }
    return @"";
}

- (NSString *)_statusToString:(SNIStatus)status
{
    switch (status) {
        case SNIStatusPassive: return @"Passive";
        case SNIStatusActive: return @"Active";
        case SNIStatusNeedsAttention: return @"NeedsAttention";
        default: return @"Active";
    }
}

- (NSString *)_categoryToString:(SNICategory)category
{
    switch (category) {
        case SNICategoryApplicationStatus: return @"ApplicationStatus";
        case SNICategorySystemServices: return @"SystemServices";
        case SNICategoryHardware: return @"Hardware";
        case SNICategoryCommunications: return @"Communications";
        default: return @"ApplicationStatus";
    }
}

@end

#pragma mark - StatusNotifierWatcher Implementation

@implementation StatusNotifierWatcher

+ (instancetype)sharedWatcher
{
    static StatusNotifierWatcher *sharedInstance = nil;
    @synchronized(self) {
        if (!sharedInstance) {
            sharedInstance = [[StatusNotifierWatcher alloc] init];
        }
    }
    return sharedInstance;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _registeredItems = [[NSMutableArray alloc] init];
        _registeredHosts = [[NSMutableArray alloc] init];
        _isStatusNotifierHostRegistered = NO;
        
        // Register ourselves as the StatusNotifierWatcher D-Bus service
        [self _registerAsDBusService];
    }
    return self;
}

- (void)_registerAsDBusService
{
    GNUDBusConnection *connection = [GNUDBusConnection sessionBus];
    if (![connection isConnected] && ![connection connect]) {
        NSLog(@"StatusNotifierWatcher: Failed to connect to D-Bus");
        return;
    }
    
    // Register our service name
    if ([connection registerService:SNI_WATCHER_SERVICE]) {
        NSLog(@"StatusNotifierWatcher: Successfully registered D-Bus service %@", SNI_WATCHER_SERVICE);
        
        // Register our object path with the StatusNotifierWatcher interface
        if ([connection registerObjectPath:SNI_WATCHER_OBJECT_PATH 
                                 interface:SNI_WATCHER_INTERFACE 
                                   handler:self]) {
            NSLog(@"StatusNotifierWatcher: Successfully registered object path %@", SNI_WATCHER_OBJECT_PATH);
        } else {
            NSLog(@"StatusNotifierWatcher: Failed to register object path %@", SNI_WATCHER_OBJECT_PATH);
        }
    } else {
        NSLog(@"StatusNotifierWatcher: Failed to register D-Bus service %@", SNI_WATCHER_SERVICE);
    }
}

- (void)dealloc
{
    [_registeredItems release];
    [_registeredHosts release];
    [super dealloc];
}

#pragma mark - D-Bus Method Handling

- (void)handleDBusMethodCall:(NSDictionary *)callInfo
{
    NSString *method = [callInfo objectForKey:@"method"];
    NSString *interface = [callInfo objectForKey:@"interface"];
    void *message = [[callInfo objectForKey:@"message"] pointerValue];
    
    if (![interface isEqualToString:SNI_WATCHER_INTERFACE]) {
        return;
    }
    
    NSLog(@"StatusNotifierWatcher: Handling D-Bus method call: %@", method);
    
    if ([method isEqualToString:@"RegisterStatusNotifierItem"]) {
        [self _handleRegisterStatusNotifierItem:message];
    } else if ([method isEqualToString:@"RegisterStatusNotifierHost"]) {
        [self _handleRegisterStatusNotifierHost:message];
    } else if ([method isEqualToString:@"RegisteredStatusNotifierItems"]) {
        [self _handleRegisteredStatusNotifierItems:message];
    } else {
        NSLog(@"StatusNotifierWatcher: Unknown method: %@", method);
    }
}

- (void)_handleRegisterStatusNotifierItem:(void *)message
{
    // Extract service name from D-Bus message
    DBusMessageIter iter;
    if (!dbus_message_iter_init((DBusMessage *)message, &iter)) {
        NSLog(@"StatusNotifierWatcher: Failed to init message iterator for RegisterStatusNotifierItem");
        return;
    }
    
    if (dbus_message_iter_get_arg_type(&iter) != DBUS_TYPE_STRING) {
        NSLog(@"StatusNotifierWatcher: Expected string argument for RegisterStatusNotifierItem");
        return;
    }
    
    char *serviceName;
    dbus_message_iter_get_basic(&iter, &serviceName);
    
    NSString *serviceNameStr = [NSString stringWithUTF8String:serviceName];
    [self registerStatusNotifierItem:serviceNameStr];
    
    // Send reply
    DBusMessage *reply = dbus_message_new_method_return((DBusMessage *)message);
    if (reply) {
        GNUDBusConnection *connection = [GNUDBusConnection sessionBus];
        [connection sendReply:reply];
        dbus_message_unref(reply);
    }
    
    NSLog(@"StatusNotifierWatcher: Registered StatusNotifierItem: %@", serviceNameStr);
}

- (void)_handleRegisterStatusNotifierHost:(void *)message
{
    // Extract service name from D-Bus message
    DBusMessageIter iter;
    if (!dbus_message_iter_init((DBusMessage *)message, &iter)) {
        NSLog(@"StatusNotifierWatcher: Failed to init message iterator for RegisterStatusNotifierHost");
        return;
    }
    
    if (dbus_message_iter_get_arg_type(&iter) != DBUS_TYPE_STRING) {
        NSLog(@"StatusNotifierWatcher: Expected string argument for RegisterStatusNotifierHost");
        return;
    }
    
    char *serviceName;
    dbus_message_iter_get_basic(&iter, &serviceName);
    
    NSString *serviceNameStr = [NSString stringWithUTF8String:serviceName];
    [self registerStatusNotifierHost:serviceNameStr];
    
    // Send reply
    DBusMessage *reply = dbus_message_new_method_return((DBusMessage *)message);
    if (reply) {
        GNUDBusConnection *connection = [GNUDBusConnection sessionBus];
        [connection sendReply:reply];
        dbus_message_unref(reply);
    }
    
    NSLog(@"StatusNotifierWatcher: Registered StatusNotifierHost: %@", serviceNameStr);
}

- (void)_handleRegisteredStatusNotifierItems:(void *)message
{
    // Return array of registered items
    DBusMessage *reply = dbus_message_new_method_return((DBusMessage *)message);
    if (!reply) {
        NSLog(@"StatusNotifierWatcher: Failed to create reply message");
        return;
    }
    
    DBusMessageIter iter, arrayIter;
    dbus_message_iter_init_append(reply, &iter);
    dbus_message_iter_open_container(&iter, DBUS_TYPE_ARRAY, "s", &arrayIter);
    
    for (NSString *serviceName in _registeredItems) {
        const char *str = [serviceName UTF8String];
        dbus_message_iter_append_basic(&arrayIter, DBUS_TYPE_STRING, &str);
    }
    
    dbus_message_iter_close_container(&iter, &arrayIter);
    
    GNUDBusConnection *connection = [GNUDBusConnection sessionBus];
    [connection sendReply:reply];
    dbus_message_unref(reply);
    
    NSLog(@"StatusNotifierWatcher: Returned %lu registered items", (unsigned long)[_registeredItems count]);
}

- (void)registerStatusNotifierItem:(NSString *)service
{
    if (![_registeredItems containsObject:service]) {
        [_registeredItems addObject:service];
        [self statusNotifierItemRegistered:service];
        NSLog(@"StatusNotifierWatcher: Registered item %@", service);
    }
}

- (void)registerStatusNotifierHost:(NSString *)service
{
    if (![_registeredHosts containsObject:service]) {
        [_registeredHosts addObject:service];
        _isStatusNotifierHostRegistered = YES;
        [self statusNotifierHostRegistered];
        NSLog(@"StatusNotifierWatcher: Registered host %@", service);
    }
}

- (void)statusNotifierItemRegistered:(NSString *)service
{
    [[NSNotificationCenter defaultCenter] 
     postNotificationName:@"StatusNotifierItemRegistered"
                   object:self
                 userInfo:@{@"service": service}];
}

- (void)statusNotifierItemUnregistered:(NSString *)service
{
    [_registeredItems removeObject:service];
    [[NSNotificationCenter defaultCenter] 
     postNotificationName:@"StatusNotifierItemUnregistered"
                   object:self
                 userInfo:@{@"service": service}];
}

- (void)statusNotifierHostRegistered
{
    [[NSNotificationCenter defaultCenter] 
     postNotificationName:@"StatusNotifierHostRegistered"
                   object:self];
}

- (void)statusNotifierHostUnregistered
{
    _isStatusNotifierHostRegistered = NO;
    [[NSNotificationCenter defaultCenter] 
     postNotificationName:@"StatusNotifierHostUnregistered"
                   object:self];
}

- (NSArray *)registeredStatusNotifierItems
{
    return [NSArray arrayWithArray:_registeredItems];
}

- (NSArray *)statusNotifierHosts
{
    return [NSArray arrayWithArray:_registeredHosts];
}

@end

#pragma mark - StatusNotifierHost Implementation

@implementation StatusNotifierHost

- (instancetype)initWithTrayView:(NSView *)trayView
{
    self = [super init];
    if (self) {
        _trayView = [trayView retain];
        _trayItems = [[NSMutableArray alloc] init];
        _watcher = [[StatusNotifierWatcher sharedWatcher] retain];
    }
    return self;
}

- (void)dealloc
{
    [self stopMonitoring];
    [_trayView release];
    [_trayItems release];
    [_watcher release];
    [super dealloc];
}

- (void)addTrayItem:(StatusNotifierItem *)item
{
    if (![_trayItems containsObject:item]) {
        [_trayItems addObject:item];
        [self updateTrayLayout];
        NSLog(@"StatusNotifierHost: Added tray item %@", [item id]);
    }
}

- (void)removeTrayItem:(StatusNotifierItem *)item
{
    if ([_trayItems containsObject:item]) {
        [_trayItems removeObject:item];
        [self updateTrayLayout];
        NSLog(@"StatusNotifierHost: Removed tray item %@", [item id]);
    }
}

- (void)updateTrayLayout
{
    // Remove all existing subviews
    NSArray *subviews = [NSArray arrayWithArray:[_trayView subviews]];
    for (NSView *subview in subviews) {
        [subview removeFromSuperview];
    }
    
    // Add views for each tray item
    CGFloat x = 0;
    for (StatusNotifierItem *item in _trayItems) {
        NSView *itemView = [self _createViewForItem:item];
        [itemView setFrame:NSMakeRect(x, 0, 24, 24)];
        [_trayView addSubview:itemView];
        x += 28; // 24px icon + 4px spacing
    }
    
    // Resize tray view to fit items
    NSRect frame = [_trayView frame];
    frame.size.width = x;
    [_trayView setFrame:frame];
}

- (NSView *)_createViewForItem:(StatusNotifierItem *)item
{
    NSButton *button = [[NSButton alloc] init];
    [button setButtonType:NSMomentaryPushInButton];
    [button setBordered:NO];
    [button setImagePosition:NSImageOnly];
    
    // Try to load icon
    NSImage *icon = nil;
    if ([item iconName]) {
        icon = [NSImage imageNamed:[item iconName]];
    }
    
    if (!icon && [item iconPixmap]) {
        // Convert pixmap data back to NSImage
        icon = [self _pixmapDataToImage:[item iconPixmap]];
    }
    
    if (!icon) {
        // Use default icon
        icon = [NSImage imageNamed:@"NSApplicationIcon"];
    }
    
    [button setImage:icon];
    
    // Set up click handling
    [button setTarget:self];
    [button setAction:@selector(_itemClicked:)];
    
    // Store reference to StatusNotifierItem using tag and a dictionary
    static NSMutableDictionary *tagToItemMap = nil;
    if (!tagToItemMap) {
        tagToItemMap = [[NSMutableDictionary alloc] init];
    }
    
    NSInteger tag = (NSInteger)item; // Use pointer as unique tag
    [button setTag:tag];
    [tagToItemMap setObject:item forKey:@(tag)];
    
    return [button autorelease];
}

- (NSImage *)_pixmapDataToImage:(NSData *)pixmapData
{
    // This is a simplified conversion - real implementation would parse the pixmap format
    return nil;
}

- (void)_itemClicked:(id)sender
{
    static NSMutableDictionary *tagToItemMap = nil;
    if (!tagToItemMap) {
        tagToItemMap = [[NSMutableDictionary alloc] init];
    }
    
    NSInteger tag = [sender tag];
    StatusNotifierItem *item = [tagToItemMap objectForKey:@(tag)];
    if (item) {
        [item activate:0 y:0]; // Use actual mouse coordinates in real implementation
    }
}

- (void)startMonitoring
{
    [[NSNotificationCenter defaultCenter] 
     addObserver:self
        selector:@selector(_itemRegistered:)
            name:@"StatusNotifierItemRegistered"
          object:_watcher];
    
    [[NSNotificationCenter defaultCenter] 
     addObserver:self
        selector:@selector(_itemUnregistered:)
            name:@"StatusNotifierItemUnregistered"
          object:_watcher];
}

- (void)stopMonitoring
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)_itemRegistered:(NSNotification *)notification
{
    NSString *service = [[notification userInfo] objectForKey:@"service"];
    NSLog(@"StatusNotifierHost: New item registered: %@", service);
    
    // TODO: Create StatusNotifierItem proxy object for the service
    // and add it to our tray
}

- (void)_itemUnregistered:(NSNotification *)notification
{
    NSString *service = [[notification userInfo] objectForKey:@"service"];
    NSLog(@"StatusNotifierHost: Item unregistered: %@", service);
    
    // TODO: Find and remove the item from our tray
}

@end
