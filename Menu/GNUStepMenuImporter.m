/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "GNUStepMenuImporter.h"
#import "GNUStepMenuActionHandler.h"
#import "AppMenuWidget.h"
#import "MenuUtils.h"
#import <Foundation/NSConnection.h>
#import <AppKit/NSMenu.h>
#import <AppKit/NSMenuItem.h>
#import <dispatch/dispatch.h>
#import <time.h>

static NSString *const kGershwinMenuServerName = @"org.gnustep.Gershwin.MenuServer";

@interface GNUStepMenuImporter ()
@property (nonatomic, strong) NSMutableDictionary *menusByWindow;
@property (nonatomic, strong) NSMutableDictionary *clientNamesByWindow;
@property (nonatomic, strong) NSMutableDictionary *lastMenuDataByWindow;
@property (nonatomic, strong) NSMutableDictionary *lastMenuUpdateTimeByWindow;
@property (nonatomic, strong) NSConnection *menuServerConnection;
// Workaround: retry attempts when registering DO server fails
@property (nonatomic) NSInteger registerRetryAttempts;
@end

/* Coarse DO-call throttle.  GWorkspace can fire updateMenuForWindow: and
   updateMenuEnabledStatesForWindow: thousands of times per second via DO.
   Each call serialises a property-list on the receiving thread, consuming
   significant CPU even if the main-thread handler detects duplicates.
   This clock_gettime-based gate drops calls sooner than MIN_INTERVAL_NS
   apart from the previous ACCEPTED call, regardless of window. */
#define DO_MENU_UPDATE_MIN_NS  100000000LL   /* 100 ms */
#define DO_STATE_UPDATE_MIN_NS  50000000LL   /*  50 ms */
static struct timespec _lastMenuUpdateAccepted;
static struct timespec _lastStateUpdateAccepted;

/* Per-window materialization cooldown.  Proxy-walking via
   NSPropertyListSerialization takes ~1 s per call.  When GWorkspace sends
   updates for many windows in a burst (e.g. opening/closing a dialog),
   we skip re-materialization if we already have a cached menu for the
   same window.  Menu STRUCTURE rarely changes for a living window;
   enabled states come via updateMenuEnabledStatesForWindow: instead.
   The set is cleared on unregisterWindow so re-opening a window always
   gets fresh data.  Protected by @synchronized for DO-thread safety. */
static NSMutableDictionary *_materializationTimeByWindow;

static inline BOOL _shouldThrottleDO(struct timespec *last, long long minNS) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    long long deltaNS = (now.tv_sec - last->tv_sec) * 1000000000LL
                      + (now.tv_nsec - last->tv_nsec);
    if (deltaNS < minNS) return YES;
    *last = now;
    return NO;
}

@implementation GNUStepMenuImporter

- (instancetype)init
{
    self = [super init];
    if (self) {
        _menusByWindow = [[NSMutableDictionary alloc] init];
        _clientNamesByWindow = [[NSMutableDictionary alloc] init];
        _lastMenuDataByWindow = [[NSMutableDictionary alloc] init];
        _lastMenuUpdateTimeByWindow = [[NSMutableDictionary alloc] init];

        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            _materializationTimeByWindow = [[NSMutableDictionary alloc] init];
        });
        
        // Register the GNUstep menu server immediately so apps can connect
        // This must happen early, before any GNUstep apps try to connect
        [self registerService];
    }
    return self;
}

#pragma mark - MenuProtocolHandler

- (BOOL)connectToDBus
{
    return [self registerService];
}

- (BOOL)registerService
{
    if (self.menuServerConnection && [self.menuServerConnection isValid]) {
        return YES;
    }

    NSConnection *connection = [NSConnection defaultConnection];
    [connection setRootObject:self];

    BOOL registered = NO;
    @try {
        registered = [connection registerName:kGershwinMenuServerName];
    } @catch (NSException *e) {
        registered = NO;
        NSDebugLLog(@"gwcomp", @"GNUStepMenuImporter: Exception while registering server name: %@", e);
    }

    // Keep the connection reference even if registration failed. We'll retry and use
    // a polling fallback so menus can still be imported when we can't register the DO server.
    self.menuServerConnection = connection;

    if (!registered) {
        NSDebugLLog(@"gwcomp", @"GNUStepMenuImporter: Failed to register GNUstep menu server name %@", kGershwinMenuServerName);
        // Schedule retries with exponential backoff and proactively scan clients as a fallback
        [self scheduleRegisterRetryWithAttempt:1];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self scanForExistingMenuServices];
        });
        return NO;
    }

    // Safely add receive port to run loop in common modes only (avoid adding many specific modes)
    NSPort *receivePort = [connection receivePort];
    if (receivePort && [receivePort isKindOfClass:[NSPort class]]) {
        @try {
            [[NSRunLoop currentRunLoop] addPort:receivePort forMode:NSRunLoopCommonModes];
        } @catch (NSException *e) {
            NSDebugLLog(@"gwcomp", @"GNUStepMenuImporter: Exception adding receive port to run loop: %@", e);
        }
    }

    NSDebugLLog(@"gwcomp", @"GNUStepMenuImporter: Registered GNUstep menu server as %@ with receive port added to run loop", kGershwinMenuServerName);

    // Immediately attempt to import menus for already-mapped windows (Desktop, etc.)
    dispatch_async(dispatch_get_main_queue(), ^{
        [self scanForExistingMenuServices];
    });

    return YES;
}

#pragma mark - Register retry fallback

- (void)scheduleRegisterRetryWithAttempt:(NSInteger)attempt
{
    const NSInteger MAX_ATTEMPTS = 6;
    if (attempt > MAX_ATTEMPTS) {
        NSDebugLLog(@"gwcomp", @"GNUStepMenuImporter: Abandoning register retries after %ld attempts", (long)attempt - 1);
        return;
    }

    NSTimeInterval delay = MIN(30.0, pow(2.0, attempt));
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        [self attemptRegisterRetry:attempt];
    });
}

- (void)attemptRegisterRetry:(NSInteger)attempt
{
    @try {
        // If already have a valid connection, avoid re-registering
        if (self.menuServerConnection && [self.menuServerConnection isValid]) {
            // It may still not be registered; try a lightweight register to be safe
            NSConnection *conn = self.menuServerConnection;
            BOOL registered = NO;
            @try {
                registered = [conn registerName:kGershwinMenuServerName];
            } @catch (NSException *e) {
                registered = NO;
            }
            if (registered) {
                // Add receive port on main thread
                NSPort *receivePort = [conn receivePort];
                if (receivePort && [receivePort isKindOfClass:[NSPort class]]) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        @try {
                            [[NSRunLoop currentRunLoop] addPort:receivePort forMode:NSRunLoopCommonModes];
                        } @catch (NSException *ex) {
                            NSDebugLLog(@"gwcomp", @"GNUStepMenuImporter: Exception adding receive port during retry: %@", ex);
                        }
                    });
                }
                NSDebugLLog(@"gwcomp", @"GNUStepMenuImporter: Successfully registered GNUstep menu server after %ld attempts", (long)attempt);
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self scanForExistingMenuServices];
                });
                return;
            }
        }

        NSConnection *connection = self.menuServerConnection ?: [NSConnection defaultConnection];
        [connection setRootObject:self];

        BOOL registered = NO;
        @try {
            registered = [connection registerName:kGershwinMenuServerName];
        } @catch (NSException *e) {
            registered = NO;
            NSDebugLLog(@"gwcomp", @"GNUStepMenuImporter: Exception while retrying register: %@", e);
        }

        if (registered) {
            self.menuServerConnection = connection;
            NSPort *receivePort = [connection receivePort];
            if (receivePort && [receivePort isKindOfClass:[NSPort class]]) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    @try {
                        [[NSRunLoop currentRunLoop] addPort:receivePort forMode:NSRunLoopCommonModes];
                    } @catch (NSException *e) {
                        NSDebugLLog(@"gwcomp", @"GNUStepMenuImporter: Exception adding receive port during retry: %@", e);
                    }
                });
            }
            NSDebugLLog(@"gwcomp", @"GNUStepMenuImporter: Successfully registered GNUstep menu server after %ld attempts", (long)attempt);
            dispatch_async(dispatch_get_main_queue(), ^{
                [self scanForExistingMenuServices];
            });
            return;
        } else {
            [self scheduleRegisterRetryWithAttempt:attempt + 1];
        }
    } @catch (NSException *e) {
        NSDebugLLog(@"gwcomp", @"GNUStepMenuImporter: Exception in attemptRegisterRetry: %@", e);
        [self scheduleRegisterRetryWithAttempt:attempt + 1];
    }
}

- (BOOL)hasMenuForWindow:(unsigned long)windowId
{
    NSNumber *key = [NSNumber numberWithUnsignedLong:windowId];
    if ([self.menusByWindow objectForKey:key]) {
        return YES;
    }

    /* Also check with alternative NSNumber representations —
     * Distributed Objects may store the key with a different
     * underlying numeric type. */
    for (NSNumber *storedKey in self.menusByWindow) {
        if ([storedKey unsignedLongValue] == windowId) {
            NSDebugLLog(@"gwcomp", @"GNUStepMenuImporter: Found menu for window %lu via numeric comparison (key type mismatch: stored=%@ lookup=%@)",
                  windowId, [storedKey className], [key className]);
            /* Re-store under the canonical key so future lookups are fast */
            self.menusByWindow[key] = self.menusByWindow[storedKey];
            self.clientNamesByWindow[key] = self.clientNamesByWindow[storedKey];
            return YES;
        }
    }
    
    // Proactively probe the client for this window if we don't have a menu
    // This handles the case where a new GNUstep app window appears but hasn't pushed its menu yet
    pid_t pid = [MenuUtils getWindowPID:windowId];
    if (pid != 0) {
        NSString *clientName = [NSString stringWithFormat:@"org.gnustep.Gershwin.MenuClient.%d", pid];
        
        // Log the probe attempt to help debug why Processes.app might fail
        // Using static to avoid spamming the log every frame/check
        static unsigned long lastProbedWindow = 0;
        if (lastProbedWindow != windowId) {
             NSDebugLLog(@"gwcomp", @"GNUStepMenuImporter: Probing GNUstep client %@ for window %lu", clientName, windowId);
             lastProbedWindow = windowId;
        }

        // Use background queue to avoid blocking main thread during window switch
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            @try {
                NSConnection *connection = [NSConnection connectionWithRegisteredName:clientName host:nil];
                if (connection && [connection isValid]) {
                    id proxy = [connection rootProxy];
                    if (proxy) {
                        // Log success if we connect
                        static unsigned long lastConnectedWindow = 0;
                        if (lastConnectedWindow != windowId) {
                             NSDebugLLog(@"gwcomp", @"GNUStepMenuImporter: Connected to %@ for window %lu", clientName, windowId);
                             lastConnectedWindow = windowId;
                        }

                        @try {
                            [proxy setProtocolForProxy:@protocol(GSGNUstepMenuClient)];
                        } @catch (NSException *e) {
                            // Protocol might not be known or needed depending on runtime
                        }
                        
                        // Request update
                        [(id)proxy requestMenuUpdateForWindow:@(windowId)];
                    } else {
                        NSDebugLLog(@"gwcomp", @"GNUStepMenuImporter: Failed to get root proxy for client %@", clientName);
                    }
                } else {
                    // Only log connection failure once per window to avoid spam
                    // (Scanning logic might retry, so we want to see it at least once)
                     static unsigned long lastFailedWindow = 0;
                     if (lastFailedWindow != windowId) {
                          NSDebugLLog(@"gwcomp", @"GNUStepMenuImporter: Failed to connect to client name %@", clientName);
                          lastFailedWindow = windowId;
                     }
                }
            } @catch (NSException *e) {
                NSDebugLLog(@"gwcomp", @"GNUStepMenuImporter: Exception probing client %@: %@", clientName, e);
            }
        });
    } else {
        NSDebugLLog(@"gwcomp", @"GNUStepMenuImporter: Could not determine PID for window %lu", windowId);
    }
    
    return NO;
}

- (NSMenu *)getMenuForWindow:(unsigned long)windowId
{
    return [self.menusByWindow objectForKey:@(windowId)];
}

- (void)activateMenuItem:(NSMenuItem *)menuItem forWindow:(unsigned long)windowId
{
    if (!menuItem) {
        return;
    }

    [GNUStepMenuActionHandler performMenuAction:menuItem];
}

- (void)registerWindow:(unsigned long)windowId
           serviceName:(NSString *)serviceName
            objectPath:(NSString *)objectPath
{
    (void)windowId;
    (void)serviceName;
    (void)objectPath;
    // GNUstep menus are pushed via updateMenuForWindow:menuData:clientName:
}

- (void)unregisterWindow:(unsigned long)windowId
{
    NSNumber *windowKey = @(windowId);
    [self.menusByWindow removeObjectForKey:windowKey];
    [self.clientNamesByWindow removeObjectForKey:windowKey];
    [self.lastMenuDataByWindow removeObjectForKey:windowKey];
    [self.lastMenuUpdateTimeByWindow removeObjectForKey:windowKey];

    @synchronized (_materializationTimeByWindow) {
        [_materializationTimeByWindow removeObjectForKey:windowKey];
    }

    if (self.appMenuWidget && self.appMenuWidget.currentWindowId == windowId) {
        NSDebugLLog(@"gwcomp", @"GNUStepMenuImporter: Current menu window %lu unregistered - refreshing menu", windowId);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.appMenuWidget updateForActiveWindow];
        });
    }
}

- (void)scanForExistingMenuServices
{
    NSDebugLog(@"GNUStepMenuImporter: scanForExistingMenuServices STARTED");

    // Get all visible windows; attempt to contact any GNUstep clients that may be
    // associated with those windows by PID. If we can reach a client, ask it to
    // push its current menu for that window via requestMenuUpdateForWindow:
    NSArray *allWindows = [MenuUtils getAllWindows];
    if (!allWindows || [allWindows count] == 0) {
        NSDebugLog(@"GNUStepMenuImporter: No windows to scan");
        return;
    }

    int found = 0;
    for (NSNumber *windowNum in allWindows) {
        unsigned long windowId = [windowNum unsignedLongValue];

        // Skip if we already have a menu for this window
        if ([self.menusByWindow objectForKey:windowNum]) {
            continue;
        }

        // Try to determine PID for the window
        pid_t pid = [MenuUtils getWindowPID:windowId];
        if (pid == 0) {
            // Not all windows provide PID - skip
            continue;
        }

        NSString *clientName = [NSString stringWithFormat:@"org.gnustep.Gershwin.MenuClient.%d", pid];
        NSDebugLog(@"GNUStepMenuImporter: Found window %@ (pid: %d) - probing client %@", windowNum, pid, clientName);

        @try {
            NSConnection *connection = [NSConnection connectionWithRegisteredName:clientName host:nil];
            if (connection && [connection isValid]) {
                id proxy = [connection rootProxy];
                if (proxy) {
                    // Tell the proxy which protocol it implements so selectors are known
                    @try {
                        [proxy setProtocolForProxy:@protocol(GSGNUstepMenuClient)];
                    } @catch (NSException *e) {
                        NSDebugLog(@"GNUStepMenuImporter: Failed to set protocol for proxy of %@: %@", clientName, e);
                    }

                    // Ask client to send its menu for this window
                    @try {
                        NSDebugLog(@"GNUStepMenuImporter: Requesting menu update from client %@ for window %lu", clientName, windowId);
                        [(id)proxy requestMenuUpdateForWindow:@(windowId)];
                        found++;
                    } @catch (NSException *e) {
                        NSDebugLog(@"GNUStepMenuImporter: Exception requesting menu update from %@: %@", clientName, e);
                    }
                }
            }
        }
        @catch (NSException *ex) {
            NSDebugLog(@"GNUStepMenuImporter: Exception probing client %@: %@", clientName, ex);
        }
    }

    if (found == 0) {
        NSDebugLog(@"GNUStepMenuImporter: No GNUstep menu clients discovered during scan.");
        // Do NOT reschedule automatically. Scans are triggered by window-change events
        // and registration retries, so there is no need for an unbounded polling loop.
    } else {
        NSDebugLog(@"GNUStepMenuImporter: Requested menu updates from %d clients", found);
    }

    NSDebugLog(@"GNUStepMenuImporter: scanForExistingMenuServices COMPLETED");
}

- (NSString *)getMenuServiceForWindow:(unsigned long)windowId
{
    return [self.clientNamesByWindow objectForKey:@(windowId)];
}

- (NSString *)getMenuObjectPathForWindow:(unsigned long)windowId
{
    (void)windowId;
    return nil;
}

- (void)setAppMenuWidget:(AppMenuWidget *)appMenuWidget
{
    _appMenuWidget = appMenuWidget;
}

#pragma mark - GNUstep Menu Server

- (oneway void)updateMenuForWindow:(bycopy NSNumber *)windowId
                          menuData:(bycopy NSDictionary *)menuData
                        clientName:(bycopy NSString *)clientName
{
    /* Early throttle: drop the call before any work. */
    if (_shouldThrottleDO(&_lastMenuUpdateAccepted, DO_MENU_UPDATE_MIN_NS)) return;

    @try {
        if (!windowId || !menuData || !clientName) return;

        /* With bycopy in the protocol, parameters should arrive as local
           objects.  If the sender (GWorkspace/Eau) was compiled with an
           older protocol, NSDictionary parameters still arrive as DO proxies.
           For proxies: materialize via plist serialization (walks the proxy
           tree once) then work with the local copy.  NSNumber and NSString
           are always sent by value by GNUstep DO regardless of bycopy. */
        NSNumber     *safeWindowId;
        NSString     *safeClientName;
        NSDictionary *safeMenuData;

        if ([(id)windowId isProxy]) {
            safeWindowId = [NSNumber numberWithUnsignedLong:
                            [windowId unsignedLongValue]];
        } else {
            safeWindowId = windowId;
        }

        if ([(id)clientName isProxy]) {
            safeClientName = [NSString stringWithString:
                              (NSString *)clientName];
        } else {
            safeClientName = clientName;
        }

        if ([(id)menuData isProxy]) {
            /* Skip the expensive proxy walk if we already have a cached
               menu for this window.  The first update for any window always
               goes through.  unregisterWindow: clears the entry so a
               re-created window gets fresh data. */
            @synchronized (_materializationTimeByWindow) {
                if (_materializationTimeByWindow[safeWindowId]) {
                    return;
                }
                _materializationTimeByWindow[safeWindowId] = @YES;
            }

            NSData *data = [NSPropertyListSerialization
                            dataWithPropertyList:menuData
                            format:NSPropertyListBinaryFormat_v1_0
                            options:0
                            error:NULL];
            if (data) {
                safeMenuData = [NSPropertyListSerialization
                                propertyListWithData:data
                                options:NSPropertyListImmutable
                                format:NULL
                                error:NULL];
            } else {
                NSLog(@"GNUStepMenuImporter: Failed to serialize proxy menuData for window %@", windowId);
                return;
            }
        } else {
            safeMenuData = menuData;
        }

        if (!safeWindowId || !safeMenuData || !safeClientName) return;

        NSDebugLLog(@"gwcomp", @"GNUStepMenuImporter: Materialized menu for window %@ "
              @"(%lu top items)", safeWindowId,
              (unsigned long)[[safeMenuData objectForKey:@"items"] count]);

        NSDictionary *payload = @{ @"windowId":   safeWindowId,
                                   @"menuData":   safeMenuData,
                                   @"clientName": safeClientName };
        if ([NSThread isMainThread]) {
            [self processMenuUpdateWithPayload:payload];
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self processMenuUpdateWithPayload:payload];
            });
        }
    }
    @catch (NSException *exception) {
        NSLog(@"GNUStepMenuImporter: Exception in updateMenuForWindow: %@", exception);
    }
}

- (void)processMenuUpdateWithPayload:(NSDictionary *)payload
{
    NSNumber *windowId = payload[@"windowId"];
    NSDictionary *menuData = payload[@"menuData"];
    NSString *clientName = payload[@"clientName"];

    // Safety: ensure this runs on main thread
    if (![NSThread isMainThread]) {
        NSDebugLLog(@"gwcomp", @"GNUStepMenuImporter: WARNING - processMenuUpdateWithPayload executing off main thread!");
    }

    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    static NSTimeInterval startupTime = 0;
    if (startupTime == 0) {
        startupTime = now;
    }
    // NOTE: startup suppression and rate-limiting are disabled because they
    // block legitimate post-action enabled-state updates (e.g., Copy enabled
    // after Select All).  Re-enable only if Menu.app stability requires it.
    // if ((now - startupTime) < 15.0 && [self.lastMenuDataByWindow objectForKey:windowId]) {
    //     NSDebugLLog(@"gwcomp", @"GNUStepMenuImporter: Suppressing repeated menu updates during startup for window %@", windowId);
    //     return;
    // }

    NSNumber *lastTime = [self.lastMenuUpdateTimeByWindow objectForKey:windowId];
    // if (lastTime && (now - [lastTime doubleValue]) < 1.0) {
    //     NSDebugLLog(@"gwcomp", @"GNUStepMenuImporter: Throttling rapid menu update for window %@", windowId);
    //     return;
    // }
    (void)now; (void)startupTime; (void)lastTime;

    NSDictionary *lastMenuData = [self.lastMenuDataByWindow objectForKey:windowId];
    if (lastMenuData && [lastMenuData isEqual:menuData]) {
        NSDebugLLog(@"gwcomp", @"GNUStepMenuImporter: Skipping duplicate menu update for window %@", windowId);
        return;
    }

    unsigned long windowValue = [windowId unsignedLongValue];
    // NSLog(@"GNUStepMenuImporter: Building menu for window %lu", windowValue);
    NSMenu *menu = [self menuFromData:menuData
                             windowId:windowValue
                           clientName:clientName
                                path:@[]];
    if (!menu) {
        NSDebugLLog(@"gwcomp", @"GNUStepMenuImporter: Failed to build menu for window %@", windowId);
        return;
    }

    // NSLog(@"GNUStepMenuImporter: Successfully built menu with %ld top-level items", (long)[menu numberOfItems]);
    self.menusByWindow[windowId] = menu;
    self.clientNamesByWindow[windowId] = clientName;
    self.lastMenuDataByWindow[windowId] = [menuData copy];
    self.lastMenuUpdateTimeByWindow[windowId] = @(now);
    // NSLog(@"GNUStepMenuImporter: Stored menu for window %@ (client: %@)", windowId, clientName);

    if (self.appMenuWidget) {
        NSDictionary *userInfo = @{@"windowId": windowId};
        [NSTimer scheduledTimerWithTimeInterval:0.15
                                         target:self
                                       selector:@selector(deferredMenuCheck:)
                                       userInfo:userInfo
                                        repeats:NO];
    }
}

- (oneway void)unregisterWindow:(bycopy NSNumber *)windowId
                       clientName:(bycopy NSString *)clientName
{
    @try {
        (void)clientName;
        if (!windowId) return;
        NSNumber *safeId = [(id)windowId isProxy] ? [windowId copy] : windowId;
        if (!safeId) return;
        [self unregisterWindow:[safeId unsignedLongValue]];
    }
    @catch (NSException *exception) {
        NSLog(@"GNUStepMenuImporter: Exception in unregisterWindow: %@", exception);
    }
}

#pragma mark - Menu State Refresh

// Walk a serialized menu data tree and apply fresh enabled/state values to the
// corresponding items in an existing NSMenu.  Items are matched by title so that
// Menu.app-only items (e.g. the ⌘ system item inserted by setupMenuViewWithMenu:)
// are simply skipped — they are absent from the fresh serialized data.
// This modifies items in-place and does NOT rebuild the menu, preserving all
// action/target/representedObject wiring.
- (void)applyEnabledStatesFromData:(NSDictionary *)menuData
                            toMenu:(NSMenu *)menu
                             depth:(NSUInteger)depth
{
    if (!menuData || !menu || depth > 64) {
        return;
    }

    NSArray *itemsData = [menuData objectForKey:@"items"];
    if (![itemsData isKindOfClass:[NSArray class]]) {
        return;
    }

    NSArray *existingItems = [menu itemArray];

    for (id rawItemData in itemsData) {
        if (![rawItemData isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        NSDictionary *itemData = (NSDictionary *)rawItemData;

        // Separators carry no enabled/state information.
        NSNumber *isSeparatorData = [itemData objectForKey:@"isSeparator"];
        if ([isSeparatorData boolValue]) {
            continue;
        }

        NSString *dataTitle = [itemData objectForKey:@"title"];
        if (![dataTitle isKindOfClass:[NSString class]] || [dataTitle length] == 0) {
            continue;
        }

        // Find the matching NSMenuItem by title.  Menu.app-only items (⌘, etc.)
        // are not present in the serialized data and will simply not be matched.
        NSMenuItem *matchedItem = nil;
        for (NSMenuItem *candidate in existingItems) {
            if (!candidate || [candidate isSeparatorItem]) {
                continue;
            }
            if ([[candidate title] isEqualToString:dataTitle]) {
                matchedItem = candidate;
                break;
            }
        }

        if (!matchedItem) {
            continue;
        }

        // Apply enabled and state.
        NSNumber *enabled = [itemData objectForKey:@"enabled"];
        if ([enabled isKindOfClass:[NSNumber class]]) {
            [matchedItem setEnabled:[enabled boolValue]];
        }
        NSNumber *state = [itemData objectForKey:@"state"];
        if ([state isKindOfClass:[NSNumber class]]) {
            [matchedItem setState:[state integerValue]];
        }

        // Recurse into submenus.
        NSDictionary *submenuData = [itemData objectForKey:@"submenu"];
        if ([submenuData isKindOfClass:[NSDictionary class]] && [matchedItem hasSubmenu]) {
            [self applyEnabledStatesFromData:submenuData
                                      toMenu:[matchedItem submenu]
                                       depth:depth + 1];
        }
    }
}

- (BOOL)refreshMenuStateForWindow:(unsigned long)windowId
{
    NSNumber *key = @(windowId);
    NSString *clientName = [self.clientNamesByWindow objectForKey:key];
    if (!clientName) {
        NSDebugLLog(@"gwcomp", @"GNUStepMenuImporter: refreshMenuStateForWindow: no client for window %lu", windowId);
        return NO;
    }

    NSMenu *menu = [self.menusByWindow objectForKey:key];
    if (!menu) {
        NSDebugLLog(@"gwcomp", @"GNUStepMenuImporter: refreshMenuStateForWindow: no menu for window %lu", windowId);
        return NO;
    }

    // Reuse the cached connection kept by GNUStepMenuActionHandler.
    NSConnection *connection = [GNUStepMenuActionHandler cachedConnectionForClient:clientName];
    if (!connection || ![connection isValid]) {
        NSDebugLLog(@"gwcomp", @"GNUStepMenuImporter: refreshMenuStateForWindow: no valid connection for %@", clientName);
        return NO;
    }

    // Set a short timeout so a slow/hung client does not stall the menu bar.
    [connection setRequestTimeout:0.3];

    id proxy = [connection rootProxy];
    if (!proxy) {
        NSDebugLLog(@"gwcomp", @"GNUStepMenuImporter: refreshMenuStateForWindow: no proxy for %@", clientName);
        return NO;
    }

    [proxy setProtocolForProxy:@protocol(GSGNUstepMenuClient)];

    NSDictionary *freshData = nil;
    @try {
        freshData = [(id<GSGNUstepMenuClient>)proxy validateMenuStateForWindow:@(windowId)];
    } @catch (NSException *e) {
        NSDebugLLog(@"gwcomp", @"GNUStepMenuImporter: validateMenuStateForWindow: raised %@: %@",
                    [e name], [e reason]);
        return NO;
    }

    if (![freshData isKindOfClass:[NSDictionary class]]) {
        NSDebugLLog(@"gwcomp", @"GNUStepMenuImporter: refreshMenuStateForWindow: invalid response for window %lu", windowId);
        return NO;
    }

    [self applyEnabledStatesFromData:freshData toMenu:menu depth:0];
    NSDebugLLog(@"gwcomp", @"GNUStepMenuImporter: refreshMenuStateForWindow: applied fresh states for window %lu", windowId);
    return YES;
}

// Lightweight oneway push from Eau: applies only enabled/state in-place on the
// existing NSMenu without rebuilding it and without any throttling.
// This is the fast path called immediately after every menu action fires in Eau.
- (oneway void)updateMenuEnabledStatesForWindow:(bycopy NSNumber *)windowId
                                       menuData:(bycopy NSDictionary *)menuData
                                     clientName:(bycopy NSString *)clientName
{
    /* Early throttle: drop high-frequency enabled-state updates. */
    if (_shouldThrottleDO(&_lastStateUpdateAccepted, DO_STATE_UPDATE_MIN_NS)) return;

    @try {
        if (!windowId || !menuData) return;

        NSNumber     *safeId;
        NSDictionary *safeData;

        if ([(id)windowId isProxy]) {
            safeId = [NSNumber numberWithUnsignedLong:
                      [windowId unsignedLongValue]];
        } else {
            safeId = windowId;
        }

        if ([(id)menuData isProxy]) {
            /* Proxy state data requires expensive materialization (~1 s).
               Enabled states are also refreshed via the pull path
               (refreshMenuStateForWindow:) before any submenu opens,
               so just skip the push when it arrives as a proxy. */
            return;
        } else {
            safeData = menuData;
        }

        if (!safeId || !safeData) return;

        dispatch_async(dispatch_get_main_queue(), ^{
            NSMenu *menu = [self.menusByWindow objectForKey:safeId];
            if (!menu) return;
            [self applyEnabledStatesFromData:safeData toMenu:menu depth:0];
        });
    } @catch (NSException *e) {
        NSLog(@"GNUStepMenuImporter: Exception in updateMenuEnabledStatesForWindow: %@", e);
    }
}

#pragma mark - Menu Construction

- (NSMenu *)menuFromData:(NSDictionary *)menuData
                windowId:(unsigned long)windowId
              clientName:(NSString *)clientName
                   path:(NSArray *)path
{
    // Defensive checks: limit recursion depth to avoid stack overflows and avoid bad types
    const NSUInteger MAX_DEPTH = 64;
    if ([path count] > MAX_DEPTH) {
        NSDebugLLog(@"gwcomp", @"GNUStepMenuImporter: menuFromData exceeded max depth (%lu) for window %lu", (unsigned long)MAX_DEPTH, windowId);
        return nil;
    }

    NSString *title = @"";
    id rawTitle = [menuData objectForKey:@"title"];
    if ([rawTitle isKindOfClass:[NSString class]]) {
        title = rawTitle;
    }

    NSArray *itemsData = [menuData objectForKey:@"items"];
    if (![itemsData isKindOfClass:[NSArray class]]) {
        itemsData = @[];
    }

    NSMenu *menu = [[NSMenu alloc] initWithTitle:title];
    [menu setAutoenablesItems:NO];

    for (NSUInteger i = 0; i < [itemsData count]; i++) {
        id itemObj = [itemsData objectAtIndex:i];
        if (![itemObj isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        NSDictionary *itemData = (NSDictionary *)itemObj;

        NSNumber *isSeparator = [itemData objectForKey:@"isSeparator"];
        if ([isSeparator boolValue]) {
            [menu addItem:[NSMenuItem separatorItem]];
            continue;
        }

        NSString *itemTitle = @"";
        id rawItemTitle = [itemData objectForKey:@"title"];
        if ([rawItemTitle isKindOfClass:[NSString class]]) {
            itemTitle = rawItemTitle;
        }
        NSString *keyEquivalent = @"";
        id rawKey = [itemData objectForKey:@"keyEquivalent"];
        if ([rawKey isKindOfClass:[NSString class]]) {
            keyEquivalent = rawKey;
        }

        NSMenuItem *menuItem = [[NSMenuItem alloc] initWithTitle:itemTitle
                                                         action:nil
                                                  keyEquivalent:keyEquivalent];

        NSNumber *enabled = [itemData objectForKey:@"enabled"];
        NSNumber *state = [itemData objectForKey:@"state"];
        NSNumber *modifierMask = [itemData objectForKey:@"keyEquivalentModifierMask"];

        if ([enabled isKindOfClass:[NSNumber class]]) {
            [menuItem setEnabled:[enabled boolValue]];
        }
        if ([state isKindOfClass:[NSNumber class]]) {
            [menuItem setState:[state integerValue]];
        }
        if ([modifierMask isKindOfClass:[NSNumber class]]) {
            [menuItem setKeyEquivalentModifierMask:[modifierMask unsignedIntegerValue]];
        }

        id submenuData = [itemData objectForKey:@"submenu"];
        NSArray *itemPath = [path arrayByAddingObject:@(i)];

        if ([submenuData isKindOfClass:[NSDictionary class]]) {
            NSMenu *submenu = [self menuFromData:submenuData
                                         windowId:windowId
                                       clientName:clientName
                                            path:itemPath];
            if (submenu) {
                [menuItem setSubmenu:submenu];
            }
        } else {
            [menuItem setTarget:[GNUStepMenuActionHandler class]];
            [menuItem setAction:@selector(performMenuAction:)];

            // Build a safe representedObject using simple types
            NSArray *safeIndexPath = [NSArray arrayWithArray:itemPath];
            NSDictionary *repObj = @{ @"windowId": @(windowId),
                                      @"clientName": clientName ?: @"",
                                      @"indexPath": safeIndexPath };
            [menuItem setRepresentedObject:repObj];
        }

        [menu addItem:menuItem];
    }

    return menu;
}

- (void)deferredMenuCheck:(NSTimer *)timer
{
    NSDictionary *userInfo = [timer userInfo];
    NSNumber *windowIdNum = [userInfo objectForKey:@"windowId"];
    if (!windowIdNum) {
        return;
    }

    unsigned long windowId = [windowIdNum unsignedLongValue];

    if ([self hasMenuForWindow:windowId] && self.appMenuWidget) {
        [self.appMenuWidget checkAndDisplayMenuForNewlyRegisteredWindow:windowId];
    }
}

@end
