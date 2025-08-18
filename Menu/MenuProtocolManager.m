#import "MenuProtocolManager.h"
#import "AppMenuWidget.h"
#import "DBusConnection.h"

@implementation MenuProtocolManager

static MenuProtocolManager *sharedInstance = nil;

+ (instancetype)sharedManager
{
    if (!sharedInstance) {
        sharedInstance = [[MenuProtocolManager alloc] init];
    }
    return sharedInstance;
}

- (id)init
{
    self = [super init];
    if (self) {
        _protocolHandlers = [[NSMutableArray alloc] initWithCapacity:2];
        _windowToProtocolMap = [[NSMutableDictionary alloc] init];
        _appMenuWidget = nil;
        
        NSLog(@"MenuProtocolManager: Initialized protocol manager");
    }
    return self;
}

- (void)dealloc
{
    [self cleanup];
    [_protocolHandlers release];
    [_windowToProtocolMap release];
    [super dealloc];
}

#pragma mark - Protocol Management

- (void)registerProtocolHandler:(id<MenuProtocolHandler>)handler forType:(MenuProtocolType)type
{
    if (!handler) {
        NSLog(@"MenuProtocolManager: ERROR: Cannot register nil handler");
        return;
    }
    
    // Ensure we have enough space in the array
    while ([_protocolHandlers count] <= (NSUInteger)type) {
        [_protocolHandlers addObject:[NSNull null]];
    }
    
    [_protocolHandlers replaceObjectAtIndex:type withObject:handler];
    
    // Set app menu widget reference if we have one
    if (_appMenuWidget && [handler respondsToSelector:@selector(setAppMenuWidget:)]) {
        [handler setAppMenuWidget:_appMenuWidget];
    }
    
    NSLog(@"MenuProtocolManager: Registered handler for protocol type %ld", (long)type);
}

- (id<MenuProtocolHandler>)handlerForType:(MenuProtocolType)type
{
    if ((NSUInteger)type >= [_protocolHandlers count]) {
        return nil;
    }
    
    id handler = [_protocolHandlers objectAtIndex:type];
    if ([handler isKindOfClass:[NSNull class]]) {
        return nil;
    }
    
    return handler;
}

- (BOOL)initializeAllProtocols
{
    NSLog(@"MenuProtocolManager: Initializing all registered protocols...");
    
    BOOL anySucceeded = NO;
    for (NSUInteger i = 0; i < [_protocolHandlers count]; i++) {
        id handler = [_protocolHandlers objectAtIndex:i];
        if (![handler isKindOfClass:[NSNull class]]) {
            NSLog(@"MenuProtocolManager: Initializing protocol %lu...", (unsigned long)i);
            if ([handler connectToDBus]) {
                NSLog(@"MenuProtocolManager: Protocol %lu initialized successfully", (unsigned long)i);
                anySucceeded = YES;
            } else {
                NSLog(@"MenuProtocolManager: Protocol %lu failed to initialize", (unsigned long)i);
            }
        }
    }
    
    if (anySucceeded) {
        // Scan for existing menus after all protocols are initialized
        [self scanForExistingMenuServices];
    }
    
    return anySucceeded;
}

#pragma mark - Unified Menu Interface

- (BOOL)hasMenuForWindow:(unsigned long)windowId
{
    NSNumber *windowKey = [NSNumber numberWithUnsignedLong:windowId];
    NSNumber *protocolTypeNum = [_windowToProtocolMap objectForKey:windowKey];
    
    if (protocolTypeNum) {
        // We know which protocol handles this window
        MenuProtocolType protocolType = [protocolTypeNum integerValue];
        id<MenuProtocolHandler> handler = [self handlerForType:protocolType];
        if (handler) {
            return [handler hasMenuForWindow:windowId];
        }
    }
    
    // Check all protocols to see if any can handle this window
    for (NSUInteger i = 0; i < [_protocolHandlers count]; i++) {
        id handler = [_protocolHandlers objectAtIndex:i];
        if (![handler isKindOfClass:[NSNull class]]) {
            if ([handler hasMenuForWindow:windowId]) {
                // Cache which protocol handles this window
                [_windowToProtocolMap setObject:[NSNumber numberWithUnsignedLong:i] forKey:windowKey];
                return YES;
            }
        }
    }
    
    return NO;
}

- (NSMenu *)getMenuForWindow:(unsigned long)windowId
{
    NSNumber *windowKey = [NSNumber numberWithUnsignedLong:windowId];
    NSNumber *protocolTypeNum = [_windowToProtocolMap objectForKey:windowKey];
    
    if (protocolTypeNum) {
        // We know which protocol handles this window
        MenuProtocolType protocolType = [protocolTypeNum integerValue];
        id<MenuProtocolHandler> handler = [self handlerForType:protocolType];
        if (handler) {
            return [handler getMenuForWindow:windowId];
        }
    }
    
    // Try all protocols to find one that can provide a menu
    for (NSUInteger i = 0; i < [_protocolHandlers count]; i++) {
        id handler = [_protocolHandlers objectAtIndex:i];
        if (![handler isKindOfClass:[NSNull class]]) {
            NSMenu *menu = [handler getMenuForWindow:windowId];
            if (menu) {
                // Cache which protocol handles this window
                [_windowToProtocolMap setObject:[NSNumber numberWithUnsignedLong:i] forKey:windowKey];
                NSLog(@"MenuProtocolManager: Window %lu handled by protocol %lu", windowId, (unsigned long)i);
                return menu;
            }
        }
    }
    
    NSLog(@"MenuProtocolManager: No protocol could provide menu for window %lu", windowId);
    return nil;
}

- (void)activateMenuItem:(NSMenuItem *)menuItem forWindow:(unsigned long)windowId
{
    NSNumber *windowKey = [NSNumber numberWithUnsignedLong:windowId];
    NSNumber *protocolTypeNum = [_windowToProtocolMap objectForKey:windowKey];
    
    if (protocolTypeNum) {
        MenuProtocolType protocolType = [protocolTypeNum integerValue];
        id<MenuProtocolHandler> handler = [self handlerForType:protocolType];
        if (handler) {
            [handler activateMenuItem:menuItem forWindow:windowId];
            return;
        }
    }
    
    NSLog(@"MenuProtocolManager: No protocol handler found for window %lu menu activation", windowId);
}

- (void)scanForExistingMenuServices
{
    // Reduced logging to avoid spam - only log significant events
    static int scanCount = 0;
    scanCount++;
    
    // Only log every 20th scan to avoid spam
    if (scanCount % 20 == 1) {
        NSLog(@"MenuProtocolManager: Periodic scan #%d - checking for menu services...", scanCount);
    }
    
    for (NSUInteger i = 0; i < [_protocolHandlers count]; i++) {
        id handler = [_protocolHandlers objectAtIndex:i];
        if (![handler isKindOfClass:[NSNull class]]) {
            // Only log protocol scanning on first few scans
            if (scanCount <= 3) {
                NSLog(@"MenuProtocolManager: Scanning protocol %lu for existing services...", (unsigned long)i);
            }
            [handler scanForExistingMenuServices];
        }
    }
}

#pragma mark - Window Registration

- (void)registerWindow:(unsigned long)windowId 
           serviceName:(NSString *)serviceName 
            objectPath:(NSString *)objectPath
{
    if (!serviceName || !objectPath) {
        NSLog(@"MenuProtocolManager: ERROR: Invalid service name or object path");
        return;
    }
    
    // Detect which protocol this service uses
    MenuProtocolType protocolType = [self detectProtocolTypeForService:serviceName objectPath:objectPath];
    
    id<MenuProtocolHandler> handler = [self handlerForType:protocolType];
    if (!handler) {
        NSLog(@"MenuProtocolManager: ERROR: No handler available for protocol type %ld", (long)protocolType);
        return;
    }
    
    // Register with the appropriate protocol handler
    [handler registerWindow:windowId serviceName:serviceName objectPath:objectPath];
    
    // Cache which protocol handles this window
    NSNumber *windowKey = [NSNumber numberWithUnsignedLong:windowId];
    [_windowToProtocolMap setObject:[NSNumber numberWithInteger:protocolType] forKey:windowKey];
    
    NSLog(@"MenuProtocolManager: Registered window %lu with protocol %ld (service: %@, path: %@)", 
          windowId, (long)protocolType, serviceName, objectPath);
}

- (void)unregisterWindow:(unsigned long)windowId
{
    NSNumber *windowKey = [NSNumber numberWithUnsignedLong:windowId];
    NSNumber *protocolTypeNum = [_windowToProtocolMap objectForKey:windowKey];
    
    if (protocolTypeNum) {
        MenuProtocolType protocolType = [protocolTypeNum integerValue];
        id<MenuProtocolHandler> handler = [self handlerForType:protocolType];
        if (handler) {
            [handler unregisterWindow:windowId];
        }
        
        [_windowToProtocolMap removeObjectForKey:windowKey];
    }
    
    NSLog(@"MenuProtocolManager: Unregistered window %lu", windowId);
}

#pragma mark - Protocol Detection

- (MenuProtocolType)detectProtocolTypeForService:(NSString *)serviceName objectPath:(NSString *)objectPath
{
    // GTK applications typically use service names like:
    // :1.234 (unique name) with object paths like /com/canonical/menu/ABC123
    // But they also export org.gtk.Menus and org.gtk.Actions interfaces
    
    // Canonical applications use service names ending with numbers and paths starting with /com/canonical/menu
    // They export com.canonical.dbusmenu interface
    
    if ([objectPath hasPrefix:@"/org/gtk/Menus"] || 
        [serviceName hasPrefix:@"org.gtk."] ||
        [serviceName containsString:@".gtk."]) {
        NSLog(@"MenuProtocolManager: Detected GTK protocol for service %@ path %@", serviceName, objectPath);
        return MenuProtocolTypeGTK;
    }
    
    // Default to Canonical for compatibility with existing applications
    NSLog(@"MenuProtocolManager: Defaulting to Canonical protocol for service %@ path %@", serviceName, objectPath);
    return MenuProtocolTypeCanonical;
}

#pragma mark - App Menu Widget

- (void)setAppMenuWidget:(AppMenuWidget *)appMenuWidget
{
    _appMenuWidget = appMenuWidget;
    
    // Update all protocol handlers with the new widget reference
    for (NSUInteger i = 0; i < [_protocolHandlers count]; i++) {
        id handler = [_protocolHandlers objectAtIndex:i];
        if (![handler isKindOfClass:[NSNull class]] && 
            [handler respondsToSelector:@selector(setAppMenuWidget:)]) {
            [handler setAppMenuWidget:appMenuWidget];
        }
    }
}

- (AppMenuWidget *)appMenuWidget
{
    return _appMenuWidget;
}

#pragma mark - Cleanup

- (void)cleanup
{
    NSLog(@"MenuProtocolManager: Cleaning up all protocol handlers...");
    
    for (NSUInteger i = 0; i < [_protocolHandlers count]; i++) {
        id handler = [_protocolHandlers objectAtIndex:i];
        if (![handler isKindOfClass:[NSNull class]] && 
            [handler respondsToSelector:@selector(cleanup)]) {
            [handler cleanup];
        }
    }
    
    [_windowToProtocolMap removeAllObjects];
}

@end
