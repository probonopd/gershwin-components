/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "GNUStepMenuActionHandler.h"
#import "GNUStepMenuIPC.h"
#import "GNUStepMenuImporter.h"
#import <Foundation/NSConnection.h>
#import <AppKit/NSMenuItem.h>

// Static cache of connections to GNUstep clients (keyed by clientName)
static NSMutableDictionary *connectionCache = nil;
static NSLock *connectionCacheLock = nil;

@implementation GNUStepMenuActionHandler

+ (void)initialize
{
    if (self == [GNUStepMenuActionHandler class]) {
        connectionCache = [[NSMutableDictionary alloc] init];
        connectionCacheLock = [[NSLock alloc] init];
    }
}

/* Return the cached connection WITHOUT doing a name lookup, or nil if the
 * client is not yet cached.  The main-thread refresh path uses this so a
 * blocking connectionWithRegisteredName: can never run on the main thread. */
+ (NSConnection *)existingConnectionForClient:(NSString *)clientName
{
    [connectionCacheLock lock];
    NSConnection *connection = [connectionCache objectForKey:clientName];
    if (connection && ![connection isValid]) {
        [connectionCache removeObjectForKey:clientName];
        connection = nil;
    }
    [connectionCacheLock unlock];
    return connection;
}

/* Record a connection discovered by a background probe, so the main thread
 * finds it cached and skips the blocking DO name lookup entirely. */
+ (void)cacheConnection:(NSConnection *)connection forClient:(NSString *)clientName
{
    if (!connection || !clientName) return;
    [connectionCacheLock lock];
    NSConnection *existing = [connectionCache objectForKey:clientName];
    if (existing == nil || ![existing isValid]) {
        [connectionCache setObject:connection forKey:clientName];
    }
    [connectionCacheLock unlock];
}

+ (void)performMenuAction:(id)sender
{
    
    if (![sender isKindOfClass:[NSMenuItem class]]) {
        NSDebugLLog(@"gwcomp", @"GNUStepMenuActionHandler: Sender is not an NSMenuItem");
        return;
    }

    NSMenuItem *menuItem = (NSMenuItem *)sender;
    NSDictionary *info = [menuItem representedObject];
    
    NSDebugLLog(@"gwcomp", @"GNUStepMenuActionHandler: Menu item '%@' representedObject: %@", [menuItem title], info);
    
    if (![info isKindOfClass:[NSDictionary class]]) {
        NSDebugLLog(@"gwcomp", @"GNUStepMenuActionHandler: Missing action metadata for item '%@'", [menuItem title]);
        return;
    }

    NSString *clientName = [info objectForKey:@"clientName"];
    NSNumber *windowId = [info objectForKey:@"windowId"];
    NSArray *indexPath = [info objectForKey:@"indexPath"];

    NSDebugLLog(@"gwcomp", @"GNUStepMenuActionHandler: Extracted - clientName: %@, windowId: %@, indexPath: %@", clientName, windowId, indexPath);

    if (!clientName || !windowId || !indexPath) {
        NSDebugLLog(@"gwcomp", @"GNUStepMenuActionHandler: Invalid action metadata for item '%@'", [menuItem title]);
        return;
    }

    // Execute the IPC callback on the main thread to keep the NSConnection stable.
    // GNUstep DO requires connection/proxy traffic to run on the thread that
    // services the connection (the main run loop); sending from a GCD worker
    // thread silently fails and poisons the cached connection, which broke all
    // GNUstep menu actions when this was briefly moved to a background queue.
    // The oneway call is non-blocking, so this should not freeze Menu.app.
    NSDictionary *backgroundInfo = @{ @"clientName": clientName, @"windowId": windowId, @"indexPath": indexPath, @"menuItemTitle": [menuItem title] };
    [self _performMenuActionInBackground:backgroundInfo];
}

+ (void)_performMenuActionInBackground:(NSDictionary *)info
{
    NSString *clientName = info[@"clientName"];
    NSNumber *windowId = info[@"windowId"];
    NSArray *indexPath = info[@"indexPath"];
    NSString *menuItemTitle = info[@"menuItemTitle"];

    /* The displayed menu item may carry the client name of a PREVIOUS app
       instance (X reuses window IDs across relaunches).  Resolve the CURRENT
       client for the window from the importer - the authoritative mapping from
       the last accepted menu push - so actions reach the live process instead
       of silently targeting a dead one.  Fall back to the item's own name. */
    NSString *currentClient = [GNUStepMenuImporter currentClientNameForWindow:
      [windowId unsignedLongValue]];
    if ([currentClient length] > 0)
        clientName = currentClient;

    NSDebugLLog(@"gwcomp", @"GNUStepMenuActionHandler: Main thread - getting connection to client %@", clientName);

    /* Menu item selection runs on the main thread.  Only use a connection that
       is already cached: a blocking connectionWithRegisteredName: here would
       freeze the menu bar if this client (e.g. Workspace) is stalled.  The
       background probes cache connections eagerly, so a healthy client is
       normally found here. */
    NSConnection *connection = [self existingConnectionForClient:clientName];
    if (!connection) {
        /* The background probe may not have cached this client's connection
           yet (a freshly relaunched app registers its MenuClient after Menu
           scanned).  Fall back to a name lookup here - the client pushed its
           menu, so it is alive and registered.  On a slow VM the name lookup
           can transiently fail; retry briefly so a menu action is not silently
           dropped (which made the About box never appear in the uitests).
           The lookup already blocks on the DO name server, so a bounded retry
           adds no new freeze risk. */
        for (int i = 0; i < 5 && !connection; i++) {
            @try {
                connection = [NSConnection connectionWithRegisteredName:clientName
                                                                   host:nil];
                if (connection)
                    [self cacheConnection:connection forClient:clientName];
            } @catch (NSException *e) {
                connection = nil;
            }
            if (!connection && i < 4)
                [NSThread sleepForTimeInterval:0.2];
        }
    }
    if (!connection) {
        NSDebugLLog(@"gwcomp", @"GNUStepMenuActionHandler: No cached connection to GNUstep menu client %@", clientName);
        return;
    }
    
    NSDebugLLog(@"gwcomp", @"GNUStepMenuActionHandler: Have connection to client %@", clientName);

    id proxy = [connection rootProxy];
    if (!proxy) {
        NSDebugLLog(@"gwcomp", @"GNUStepMenuActionHandler: No root proxy for GNUstep menu client %@", clientName);
        return;
    }

    [proxy setProtocolForProxy:@protocol(GSGNUstepMenuClient)];
    
    NSDebugLLog(@"gwcomp", @"GNUStepMenuActionHandler: Proxy protocol set, about to call activateMenuItemAtPath");
    NSDebugLLog(@"gwcomp", @"GNUStepMenuActionHandler: Proxy responds to selector: %d", [proxy respondsToSelector:@selector(activateMenuItemAtPath:forWindow:)]);

    @try {
        // The oneway modifier ensures this doesn't block waiting for a response
        NSDebugLLog(@"gwcomp", @"GNUStepMenuActionHandler: Calling activateMenuItemAtPath:forWindow: on proxy");
        [(id<GSGNUstepMenuClient>)proxy activateMenuItemAtPath:indexPath forWindow:windowId];
        NSDebugLLog(@"gwcomp", @"GNUStepMenuActionHandler: Call completed, dispatched action for menu item '%@'", menuItemTitle);
    }
    @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"GNUStepMenuActionHandler: Exception activating menu item '%@': %@ - %@", menuItemTitle, [exception name], [exception reason]);
    }
}

@end
