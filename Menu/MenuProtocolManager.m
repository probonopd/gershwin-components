#import "MenuProtocolManager.h"
#import "AppMenuWidget.h"
#import "DBusConnection.h"

@implementation MenuProtocolManager {
    __weak AppMenuWidget *_appMenuWidget;
}

+ (instancetype)sharedManager
{
    static MenuProtocolManager *sharedInstance = nil;
    @synchronized(self) {
        if (!sharedInstance) {
            sharedInstance = [[MenuProtocolManager alloc] init];
        }
    }
    return sharedInstance;
}

- (id)init
{
    self = [super init];
    if (self) {
        self.protocolHandlers = [[NSMutableArray alloc] initWithCapacity:2];
        self.windowToProtocolMap = [[NSMutableDictionary alloc] init];
        // Don't explicitly set weak property to nil - ARC will handle it
        
        NSLog(@"MenuProtocolManager: Initialized protocol manager");
    }
    return self;
}

#pragma mark - Protocol Management

- (void)registerProtocolHandler:(id<MenuProtocolHandler>)handler forType:(MenuProtocolType)type
{
    NSLog(@"MenuProtocolManager: registerProtocolHandler STARTING for type %d", (int)type);
    
    if (!handler) {
        NSLog(@"MenuProtocolManager: ERROR: Cannot register nil handler");
        return;
    }
    
    NSLog(@"MenuProtocolManager: Handler is not nil, proceeding...");
    
    // Ensure we have enough space in the array
    while ([self.protocolHandlers count] <= (NSUInteger)type) {
        [self.protocolHandlers addObject:[NSNull null]];
    }
    
    NSLog(@"MenuProtocolManager: About to replace object at index %d", (int)type);
    [self.protocolHandlers replaceObjectAtIndex:type withObject:handler];
    
    NSLog(@"MenuProtocolManager: About to check for appMenuWidget");
    // Defer AppMenuWidget setup until after it's created - check will be done later
    NSLog(@"MenuProtocolManager: Deferring appMenuWidget setup until after widget creation");
    
    NSLog(@"MenuProtocolManager: registerProtocolHandler COMPLETED for type %d", (int)type);
    
    NSLog(@"MenuProtocolManager: Registered handler for protocol type %ld", (long)type);
}

- (id<MenuProtocolHandler>)handlerForType:(MenuProtocolType)type
{
    if ((NSUInteger)type >= [self.protocolHandlers count]) {
        return nil;
    }
    
    id handler = [self.protocolHandlers objectAtIndex:type];
    if ([handler isKindOfClass:[NSNull class]]) {
        return nil;
    }
    
    return handler;
}

- (BOOL)initializeAllProtocols
{
    NSLog(@"MenuProtocolManager: Initializing all registered protocols...");
    
    BOOL anySucceeded = NO;
    for (NSUInteger i = 0; i < [self.protocolHandlers count]; i++) {
        id handler = [self.protocolHandlers objectAtIndex:i];
        if (![handler isKindOfClass:[NSNull class]]) {
            NSLog(@"MenuProtocolManager: Initializing protocol %lu...", (unsigned long)i);
            NSLog(@"MenuProtocolManager: About to call connectToDBus on protocol %lu", (unsigned long)i);
            if ([handler connectToDBus]) {
                NSLog(@"MenuProtocolManager: Protocol %lu initialized successfully", (unsigned long)i);
                anySucceeded = YES;
            } else {
                NSLog(@"MenuProtocolManager: Protocol %lu failed to initialize", (unsigned long)i);
            }
            NSLog(@"MenuProtocolManager: Finished with protocol %lu", (unsigned long)i);
        }
    }
    
    if (anySucceeded) {
        NSLog(@"MenuProtocolManager: About to scan for existing menu services...");
        // Scan for existing menus after all protocols are initialized
        [self scanForExistingMenuServices];
        NSLog(@"MenuProtocolManager: Finished scanning for existing menu services");
    }
    
    return anySucceeded;
}

#pragma mark - Unified Menu Interface

- (BOOL)hasMenuForWindow:(unsigned long)windowId
{
    NSNumber *windowKey = [NSNumber numberWithUnsignedLong:windowId];
    NSNumber *protocolTypeNum = [self.windowToProtocolMap objectForKey:windowKey];
    
    if (protocolTypeNum) {
        // We know which protocol handles this window
        MenuProtocolType protocolType = [protocolTypeNum integerValue];
        id<MenuProtocolHandler> handler = [self handlerForType:protocolType];
        if (handler) {
            return [handler hasMenuForWindow:windowId];
        }
    }
    
    // Check all protocols to see if any can handle this window
    for (NSUInteger i = 0; i < [self.protocolHandlers count]; i++) {
        id handler = [self.protocolHandlers objectAtIndex:i];
        if (![handler isKindOfClass:[NSNull class]]) {
            if ([handler hasMenuForWindow:windowId]) {
                // Cache which protocol handles this window
                [self.windowToProtocolMap setObject:[NSNumber numberWithUnsignedLong:i] forKey:windowKey];
                return YES;
            }
        }
    }
    
    return NO;
}

- (NSMenu *)getMenuForWindow:(unsigned long)windowId
{
    NSNumber *windowKey = [NSNumber numberWithUnsignedLong:windowId];
    NSNumber *protocolTypeNum = [self.windowToProtocolMap objectForKey:windowKey];
    
    if (protocolTypeNum) {
        // We know which protocol handles this window
        MenuProtocolType protocolType = [protocolTypeNum integerValue];
        id<MenuProtocolHandler> handler = [self handlerForType:protocolType];
        if (handler) {
            return [handler getMenuForWindow:windowId];
        }
    }
    
    // Try all protocols to find one that can provide a menu
    for (NSUInteger i = 0; i < [self.protocolHandlers count]; i++) {
        id handler = [self.protocolHandlers objectAtIndex:i];
        if (![handler isKindOfClass:[NSNull class]]) {
            NSMenu *menu = [handler getMenuForWindow:windowId];
            if (menu) {
                // Cache which protocol handles this window
                [self.windowToProtocolMap setObject:[NSNumber numberWithUnsignedLong:i] forKey:windowKey];
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
    NSNumber *protocolTypeNum = [self.windowToProtocolMap objectForKey:windowKey];
    
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
    
    // TEMPORARY DEBUG: Log every scan to identify busy loop
    NSLog(@"MenuProtocolManager: SCAN #%d - scanForExistingMenuServices called", scanCount);
    
    // Only log every 20th scan to avoid spam
    if (scanCount % 20 == 1) {
        NSLog(@"MenuProtocolManager: Periodic scan #%d - checking for menu services...", scanCount);
    }
    
    for (NSUInteger i = 0; i < [self.protocolHandlers count]; i++) {
        id handler = [self.protocolHandlers objectAtIndex:i];
        if (![handler isKindOfClass:[NSNull class]]) {
            // Only log protocol scanning on first few scans
            if (scanCount <= 3) {
                NSLog(@"MenuProtocolManager: Scanning protocol %lu for existing services...", (unsigned long)i);
            }
            [handler scanForExistingMenuServices];
        }
    }
    NSLog(@"MenuProtocolManager: SCAN #%d - scanForExistingMenuServices completed", scanCount);
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
    [self.windowToProtocolMap setObject:[NSNumber numberWithInteger:protocolType] forKey:windowKey];
    
    NSLog(@"MenuProtocolManager: Registered window %lu with protocol %ld (service: %@, path: %@)", 
          windowId, (long)protocolType, serviceName, objectPath);
}

- (void)unregisterWindow:(unsigned long)windowId
{
    NSNumber *windowKey = [NSNumber numberWithUnsignedLong:windowId];
    NSNumber *protocolTypeNum = [self.windowToProtocolMap objectForKey:windowKey];
    
    if (protocolTypeNum) {
        MenuProtocolType protocolType = [protocolTypeNum integerValue];
        id<MenuProtocolHandler> handler = [self handlerForType:protocolType];
        if (handler) {
            [handler unregisterWindow:windowId];
        }
        
        [self.windowToProtocolMap removeObjectForKey:windowKey];
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
    static BOOL settingAppMenuWidget = NO;
    if (settingAppMenuWidget) return;
    
    settingAppMenuWidget = YES;
    _appMenuWidget = appMenuWidget;
    settingAppMenuWidget = NO;
    
    // Update all protocol handlers with the new widget reference
    for (NSUInteger i = 0; i < [self.protocolHandlers count]; i++) {
        id handler = [self.protocolHandlers objectAtIndex:i];
        if (![handler isKindOfClass:[NSNull class]] && 
            [handler respondsToSelector:@selector(setAppMenuWidget:)]) {
            [handler setAppMenuWidget:appMenuWidget];
        }
    }
}

- (AppMenuWidget *)appMenuWidget
{
    // Return the weak reference - may be nil if widget was deallocated
    return _appMenuWidget;
}

#pragma mark - DBus Integration

- (int)getDBusFileDescriptor
{
    // Get the DBus file descriptor from the canonical handler (DBusMenuImporter)
    // since that's the one that manages the AppMenu.Registrar service
    id<MenuProtocolHandler> canonicalHandler = [self handlerForType:MenuProtocolTypeCanonical];
    
    if (!canonicalHandler) {
        NSLog(@"MenuProtocolManager: No canonical handler available for DBus file descriptor");
        return -1;
    }
    
    // Use defensive programming to avoid potential crashes
    @try {
        if ([canonicalHandler respondsToSelector:@selector(getDBusFileDescriptor)]) {
            NSLog(@"MenuProtocolManager: Calling getDBusFileDescriptor on canonical handler");
            int fd = [(id)canonicalHandler getDBusFileDescriptor];
            NSLog(@"MenuProtocolManager: Got file descriptor %d from canonical handler", fd);
            return fd;
        } else {
            NSLog(@"MenuProtocolManager: Canonical handler doesn't respond to getDBusFileDescriptor");
            return -1;
        }
    } @catch (NSException *exception) {
        NSLog(@"MenuProtocolManager: Exception getting DBus file descriptor: %@", exception);
        return -1;
    }
}

- (void)updateAllHandlersWithAppMenuWidget:(AppMenuWidget *)appMenuWidget
{
    NSLog(@"MenuProtocolManager: Updating all handlers with AppMenuWidget");
    
    for (NSUInteger i = 0; i < [self.protocolHandlers count]; i++) {
        id<MenuProtocolHandler> handler = [self.protocolHandlers objectAtIndex:i];
        if (handler && [handler respondsToSelector:@selector(setAppMenuWidget:)]) {
            NSLog(@"MenuProtocolManager: Setting AppMenuWidget on handler %lu", (unsigned long)i);
            @try {
                [handler setAppMenuWidget:appMenuWidget];
            } @catch (NSException *exception) {
                NSLog(@"MenuProtocolManager: Exception setting AppMenuWidget on handler %lu: %@", (unsigned long)i, exception);
            }
        } else {
            NSLog(@"MenuProtocolManager: Handler %lu doesn't support setAppMenuWidget", (unsigned long)i);
        }
    }
}

#pragma mark - DBus Message Processing

- (void)processDBusMessages
{
    // Process messages for the canonical DBus menu handler
    id<MenuProtocolHandler> canonicalHandler = [self handlerForType:MenuProtocolTypeCanonical];
    if (canonicalHandler && [canonicalHandler respondsToSelector:@selector(processDBusMessages)]) {
        [canonicalHandler processDBusMessages];
    }
}

#pragma mark - Cleanup

- (void)cleanup
{
    NSLog(@"MenuProtocolManager: Cleaning up all protocol handlers...");
    
    for (NSUInteger i = 0; i < [self.protocolHandlers count]; i++) {
        id handler = [self.protocolHandlers objectAtIndex:i];
        if (![handler isKindOfClass:[NSNull class]] && 
            [handler respondsToSelector:@selector(cleanup)]) {
            [handler cleanup];
        }
    }
    
    [self.windowToProtocolMap removeAllObjects];
}

@end
