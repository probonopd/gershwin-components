/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */


#import "MenuProtocolManager.h"
#import "AppMenuWidget.h"
#import "DBusConnection.h"
#import "MenuProfiler.h"
#import <dispatch/dispatch.h>

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

        NSDebugLLog(@"gwcomp", @"MenuProtocolManager: Initialized protocol manager");
    }
    return self;
}

#pragma mark - Protocol Management

- (void)registerProtocolHandler:(id<MenuProtocolHandler>)handler forType:(MenuProtocolType)type
{
    NSDebugLLog(@"gwcomp", @"MenuProtocolManager: registerProtocolHandler STARTING for type %d", (int)type);
    
    if (!handler) {
        NSDebugLLog(@"gwcomp", @"MenuProtocolManager: ERROR: Cannot register nil handler");
        return;
    }
    
    NSDebugLLog(@"gwcomp", @"MenuProtocolManager: Handler is not nil, proceeding...");
    
    // Ensure we have enough space in the array
    while ([self.protocolHandlers count] <= (NSUInteger)type) {
        [self.protocolHandlers addObject:[NSNull null]];
    }
    
    NSDebugLLog(@"gwcomp", @"MenuProtocolManager: About to replace object at index %d", (int)type);
    [self.protocolHandlers replaceObjectAtIndex:type withObject:handler];
    
    NSDebugLLog(@"gwcomp", @"MenuProtocolManager: About to check for appMenuWidget");
    // Defer AppMenuWidget setup until after it's created - check will be done later
    NSDebugLLog(@"gwcomp", @"MenuProtocolManager: Deferring appMenuWidget setup until after widget creation");
    
    NSDebugLLog(@"gwcomp", @"MenuProtocolManager: registerProtocolHandler COMPLETED for type %d", (int)type);
    
    NSDebugLLog(@"gwcomp", @"MenuProtocolManager: Registered handler for protocol type %ld", (long)type);
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
    NSDebugLLog(@"gwcomp", @"MenuProtocolManager: Initializing all registered protocols...");
    
    BOOL anySucceeded = NO;
    for (NSUInteger i = 0; i < [self.protocolHandlers count]; i++) {
        id handler = [self.protocolHandlers objectAtIndex:i];
        if (![handler isKindOfClass:[NSNull class]]) {
            NSDebugLLog(@"gwcomp", @"MenuProtocolManager: Initializing protocol %lu...", (unsigned long)i);
            NSDebugLLog(@"gwcomp", @"MenuProtocolManager: About to call connectToDBus on protocol %lu", (unsigned long)i);
            if ([handler connectToDBus]) {
                NSDebugLLog(@"gwcomp", @"MenuProtocolManager: Protocol %lu initialized successfully", (unsigned long)i);
                anySucceeded = YES;
            } else {
                NSDebugLLog(@"gwcomp", @"MenuProtocolManager: Protocol %lu failed to initialize", (unsigned long)i);
            }
            NSDebugLLog(@"gwcomp", @"MenuProtocolManager: Finished with protocol %lu", (unsigned long)i);
        }
    }
    
    if (anySucceeded) {
        NSDebugLLog(@"gwcomp", @"MenuProtocolManager: About to scan for existing menu services...");
        // Scan for existing menus after all protocols are initialized
        [self scanForExistingMenuServices];
        NSDebugLLog(@"gwcomp", @"MenuProtocolManager: Finished scanning for existing menu services");
    }
    
    return anySucceeded;
}

#pragma mark - Unified Menu Interface

- (BOOL)hasMenuForWindow:(unsigned long)windowId
{
    MENU_PROFILE_BEGIN(protocolManagerHasMenuForWindow);
    NSNumber *windowKey = [NSNumber numberWithUnsignedLong:windowId];
    NSNumber *protocolTypeNum = [self.windowToProtocolMap objectForKey:windowKey];
    
    if (protocolTypeNum) {
        // We know which protocol handles this window
        MenuProtocolType protocolType = [protocolTypeNum integerValue];
        id<MenuProtocolHandler> handler = [self handlerForType:protocolType];
        if (handler) {
            BOOL has = [handler hasMenuForWindow:windowId];
            if (!has) {
                // Cached protocol no longer claims this window — clear stale mapping
                [self.windowToProtocolMap removeObjectForKey:windowKey];
            }
            MENU_PROFILE_END(protocolManagerHasMenuForWindow);
            return has;
        }
    }
    
    // Check all protocols to see if any can handle this window
    for (NSUInteger i = 0; i < [self.protocolHandlers count]; i++) {
        id handler = [self.protocolHandlers objectAtIndex:i];
        if (![handler isKindOfClass:[NSNull class]]) {
            if ([handler hasMenuForWindow:windowId]) {
                // Cache which protocol handles this window
                [self.windowToProtocolMap setObject:[NSNumber numberWithUnsignedLong:i] forKey:windowKey];
                MENU_PROFILE_END(protocolManagerHasMenuForWindow);
                return YES;
            }
        }
    }
    
    MENU_PROFILE_END(protocolManagerHasMenuForWindow);
    return NO;
}

/* If a non-GNUstep menu was found, check whether the GNUstep handler also
 * has a stub menu for this window (registered by a stub-menu helper).  If so,
 * prepend the stub items to give bundled apps a standard app-name menu
 * alongside their native DBus menus.
 *
 * The stub may register slightly after the DBus menu due to startup timing.
 * When no stub is found yet, we return the DBus menu as-is — the stub's
 * deferred menu check will trigger a re-display once it registers. */
- (NSMenu *)prependGNUstepStubIfNeeded:(NSMenu *)dbusMenu
                             forWindow:(unsigned long)windowId
                        primaryHandler:(id<MenuProtocolHandler>)primaryHandler
{
    id<MenuProtocolHandler> gnustepHandler = [self handlerForType:MenuProtocolTypeGNUstep];
    if (!gnustepHandler || gnustepHandler == primaryHandler)
        return dbusMenu;

    NSMenu *stubMenu = [gnustepHandler getMenuForWindow:windowId];
    if (!stubMenu || [stubMenu numberOfItems] == 0)
        return dbusMenu;

    /* Build a merged menu: stub items first, then DBus items */
    NSMenu *merged = [[NSMenu alloc] initWithTitle:[dbusMenu title]];

    for (NSInteger i = 0; i < [stubMenu numberOfItems]; i++)
        [merged addItem:[[stubMenu itemAtIndex:i] copy]];

    for (NSInteger i = 0; i < [dbusMenu numberOfItems]; i++)
        [merged addItem:[[dbusMenu itemAtIndex:i] copy]];

    return merged;
}

- (NSMenu *)getMenuForWindow:(unsigned long)windowId
{
    MENU_PROFILE_BEGIN(protocolManagerGetMenuForWindow);
    @try {
        NSNumber *windowKey = [NSNumber numberWithUnsignedLong:windowId];
        NSNumber *protocolTypeNum = [self.windowToProtocolMap objectForKey:windowKey];

        if (protocolTypeNum) {
            // We know which protocol handles this window
            MenuProtocolType protocolType = [protocolTypeNum integerValue];
            id<MenuProtocolHandler> handler = [self handlerForType:protocolType];
            if (handler) {
                NSString *protoName = @"Unknown";
                if (protocolType == 0) protoName = @"Canonical/DBus";
                else if (protocolType == 1) protoName = @"GTK";
                else if (protocolType == 2) protoName = @"GNUstep";

                NSDebugLLog(@"gwcomp", @"MenuProtocolManager: Window %lu handled by protocol: %@ (Type %lu) [Cached]", windowId, protoName, (unsigned long)protocolType);

                NSMenu *menu = [handler getMenuForWindow:windowId];
                if (menu) {
                    if (protocolType != MenuProtocolTypeGNUstep)
                        menu = [self prependGNUstepStubIfNeeded:menu
                                                     forWindow:windowId
                                                primaryHandler:handler];
                    MENU_PROFILE_END(protocolManagerGetMenuForWindow);
                    return menu;
                }
                // Cached protocol returned nil — remove stale mapping so other protocols
                // can be tried on the next call and we don't keep hitting a broken handler.
                NSDebugLLog(@"gwcomp", @"MenuProtocolManager: Cached protocol %@ returned nil for window %lu — clearing stale mapping", protoName, windowId);
                [self.windowToProtocolMap removeObjectForKey:windowKey];
                MENU_PROFILE_END(protocolManagerGetMenuForWindow);
                return nil;
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

                    NSString *protoName = @"Unknown";
                    if (i == 0) protoName = @"Canonical/DBus";
                    else if (i == 1) protoName = @"GTK";
                    else if (i == 2) protoName = @"GNUstep";

                    NSDebugLLog(@"gwcomp", @"MenuProtocolManager: Window %lu handled by protocol: %@ (Type %lu)", windowId, protoName, (unsigned long)i);

                    if ((MenuProtocolType)i != MenuProtocolTypeGNUstep)
                        menu = [self prependGNUstepStubIfNeeded:menu
                                                     forWindow:windowId
                                                primaryHandler:handler];
                    MENU_PROFILE_END(protocolManagerGetMenuForWindow);
                    return menu;
                }
            }
        }
        
        static unsigned long lastFailedWindowId = 0;
        if (lastFailedWindowId != windowId) {
            NSDebugLLog(@"gwcomp", @"MenuProtocolManager: No protocol could provide menu for window %lu", windowId);
            lastFailedWindowId = windowId;
        }
        MENU_PROFILE_END(protocolManagerGetMenuForWindow);
        return nil;
    }
    @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"MenuProtocolManager: Exception getting menu for window %lu: %@", windowId, exception);
        MENU_PROFILE_END(protocolManagerGetMenuForWindow);
        return nil;
    }
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
    
    NSDebugLLog(@"gwcomp", @"MenuProtocolManager: No protocol handler found for window %lu menu activation", windowId);
}

- (void)scanForExistingMenuServices
{
    static int scanCount = 0;
    scanCount++;
    
    // Reduce log spam: log first 10 scans in detail, then only every 50th scan
    BOOL shouldLogVerbose = (scanCount <= 10) || (scanCount % 50 == 0);
    
    if (shouldLogVerbose) {
        NSDebugLLog(@"gwcomp", @"MenuProtocolManager: SCAN #%d - scanForExistingMenuServices called", scanCount);
    }
    
    for (NSUInteger i = 0; i < [self.protocolHandlers count]; i++) {
        id handler = [self.protocolHandlers objectAtIndex:i];
        if (![handler isKindOfClass:[NSNull class]]) {
            // Only log protocol scanning on first few scans
            if (scanCount <= 3) {
                NSDebugLLog(@"gwcomp", @"MenuProtocolManager: Scanning protocol %lu for existing services...", (unsigned long)i);
            }
            [handler scanForExistingMenuServices];
        }
    }
    
    if (shouldLogVerbose) {
        NSDebugLLog(@"gwcomp", @"MenuProtocolManager: SCAN #%d - scanForExistingMenuServices completed", scanCount);
    }
}

#pragma mark - Window Registration

- (void)registerWindow:(unsigned long)windowId 
           serviceName:(NSString *)serviceName 
            objectPath:(NSString *)objectPath
{
    if (!serviceName || !objectPath) {
        NSDebugLLog(@"gwcomp", @"MenuProtocolManager: ERROR: Invalid service name or object path");
        return;
    }
    
    // Detect which protocol this service uses
    MenuProtocolType protocolType = [self detectProtocolTypeForService:serviceName objectPath:objectPath];
    
    id<MenuProtocolHandler> handler = [self handlerForType:protocolType];
    if (!handler) {
        NSDebugLLog(@"gwcomp", @"MenuProtocolManager: ERROR: No handler available for protocol type %ld", (long)protocolType);
        return;
    }
    
    // Register with the appropriate protocol handler
    [handler registerWindow:windowId serviceName:serviceName objectPath:objectPath];
    
    // Cache which protocol handles this window
    NSNumber *windowKey = [NSNumber numberWithUnsignedLong:windowId];
    [self.windowToProtocolMap setObject:[NSNumber numberWithInteger:protocolType] forKey:windowKey];
    
    NSDebugLLog(@"gwcomp", @"MenuProtocolManager: Registered window %lu with protocol %ld (service: %@, path: %@)", 
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
    
    NSDebugLLog(@"gwcomp", @"MenuProtocolManager: Unregistered window %lu", windowId);

    // If the unregistered window is currently displayed, force a menu refresh
    if (_appMenuWidget && _appMenuWidget.currentWindowId == windowId) {
        NSDebugLLog(@"gwcomp", @"MenuProtocolManager: Current menu window %lu unregistered - refreshing menu", windowId);
        dispatch_async(dispatch_get_main_queue(), ^{
            [_appMenuWidget updateForActiveWindow];
        });
    }
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
        NSDebugLLog(@"gwcomp", @"MenuProtocolManager: Detected GTK protocol for service %@ path %@", serviceName, objectPath);
        return MenuProtocolTypeGTK;
    }
    
    // Default to Canonical for compatibility with existing applications
    NSDebugLLog(@"gwcomp", @"MenuProtocolManager: Defaulting to Canonical protocol for service %@ path %@", serviceName, objectPath);
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
    return self.appMenuWidget;
}

#pragma mark - DBus Integration

- (int)getDBusFileDescriptor
{
    // Get the DBus file descriptor from the canonical handler (DBusMenuImporter)
    // since that's the one that manages the AppMenu.Registrar service
    id<MenuProtocolHandler> canonicalHandler = [self handlerForType:MenuProtocolTypeCanonical];
    
    if (!canonicalHandler) {
        NSDebugLLog(@"gwcomp", @"MenuProtocolManager: No canonical handler available for DBus file descriptor");
        return -1;
    }
    
    // Use defensive programming to avoid potential crashes
    @try {
        if ([canonicalHandler respondsToSelector:@selector(getDBusFileDescriptor)]) {
            NSDebugLLog(@"gwcomp", @"MenuProtocolManager: Calling getDBusFileDescriptor on canonical handler");
            int fd = [(id)canonicalHandler getDBusFileDescriptor];
            NSDebugLLog(@"gwcomp", @"MenuProtocolManager: Got file descriptor %d from canonical handler", fd);
            return fd;
        } else {
            NSDebugLLog(@"gwcomp", @"MenuProtocolManager: Canonical handler doesn't respond to getDBusFileDescriptor");
            return -1;
        }
    } @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"MenuProtocolManager: Exception getting DBus file descriptor: %@", exception);
        return -1;
    }
}

- (void)updateAllHandlersWithAppMenuWidget:(AppMenuWidget *)appMenuWidget
{
    NSDebugLLog(@"gwcomp", @"MenuProtocolManager: Updating all handlers with AppMenuWidget");
    
    for (NSUInteger i = 0; i < [self.protocolHandlers count]; i++) {
        id<MenuProtocolHandler> handler = [self.protocolHandlers objectAtIndex:i];
        if (handler && [handler respondsToSelector:@selector(setAppMenuWidget:)]) {
            NSDebugLLog(@"gwcomp", @"MenuProtocolManager: Setting AppMenuWidget on handler %lu", (unsigned long)i);
            @try {
                [handler setAppMenuWidget:appMenuWidget];
            } @catch (NSException *exception) {
                NSDebugLLog(@"gwcomp", @"MenuProtocolManager: Exception setting AppMenuWidget on handler %lu: %@", (unsigned long)i, exception);
            }
        } else {
            NSDebugLLog(@"gwcomp", @"MenuProtocolManager: Handler %lu doesn't support setAppMenuWidget", (unsigned long)i);
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

- (BOOL)refreshMenuStateForWindow:(unsigned long)windowId
{
    // Find the handler responsible for this window.
    NSNumber *windowKey = [NSNumber numberWithUnsignedLong:windowId];
    NSNumber *protocolTypeNum = [self.windowToProtocolMap objectForKey:windowKey];
    id<MenuProtocolHandler> handler = nil;

    if (protocolTypeNum) {
        handler = [self handlerForType:(MenuProtocolType)[protocolTypeNum integerValue]];
    }

    if (!handler) {
        // Scan to find any handler that knows about this window.
        for (id h in self.protocolHandlers) {
            if (![h isKindOfClass:[NSNull class]] &&
                [h respondsToSelector:@selector(hasMenuForWindow:)] &&
                [h hasMenuForWindow:windowId]) {
                handler = h;
                break;
            }
        }
    }

    if (handler && [handler respondsToSelector:@selector(refreshMenuStateForWindow:)]) {
        return [handler refreshMenuStateForWindow:windowId];
    }
    return NO;
}

#pragma mark - Cleanup

- (void)cleanup
{
    NSDebugLLog(@"gwcomp", @"MenuProtocolManager: Cleaning up all protocol handlers...");
    
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
