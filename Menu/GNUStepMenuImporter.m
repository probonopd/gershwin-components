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
#import <X11/Xlib.h>
#import <signal.h>
#import <errno.h>

/* Coarse DO-call throttle for full menu rebuilds.
   GWorkspace can fire updateMenuForWindow: thousands of times per second via DO.
   Each call serialises a property-list on the receiving thread, consuming
   significant CPU.  This clock_gettime-based gate drops calls sooner than
   DO_MENU_UPDATE_MIN_NS apart from the previous accepted call. */
#define DO_MENU_UPDATE_MIN_NS   100000000LL   /* 100 ms */
#define DO_STATE_UPDATE_MIN_NS   50000000LL   /*  50 ms */
static struct timespec _lastMenuUpdateAccepted;
static struct timespec _lastStateUpdateAccepted;
/* App-level menu pushes use their own throttle gates so a windowless app's
   menu updates never collide with (and get dropped by) the window-level ones. */
static struct timespec _lastApplicationMenuUpdateAccepted;
static struct timespec _lastApplicationStateUpdateAccepted;

/* ============================================================
   PER-WINDOW PROXY MATERIALIZATION CACHE  —  DO NOT REMOVE!
   ============================================================

   Background:
   -----------
   GWorkspace talks to Menu.app via GNUstep Distributed Objects (DO).  A DO
   server always RECEIVES its parameters as proxies unless the sender explicitly
   declares the parameters with 'bycopy' AND was compiled with a protocol header
   that includes that qualifier.  Even when the protocol declares 'bycopy', older
   GWorkspace builds without the updated header still send proxies.

   Walking a proxy NSDictionary that contains an entire app menu tree (the
   "menuData" parameter) triggers a synchronous round-trip IPC call for every
   key access.  For a large app like Workspace or GWorkspace with 100+ items
   across multiple submenus, this takes ~1 second PER CALL.

   The problem:
   ------------
   GWorkspace fires updateMenuForWindow: thousands of times per second during a
   window switch.  Without a guard, EVERY call would walk the proxy tree, locking
   the DO receive thread for seconds and spiking the CPU to 100%.

   The solution:
   -------------
   On the first updateMenuForWindow: call for a window we materialize the proxy
   ONCE by serialising it through NSPropertyListSerialization (which walks the
   proxy tree in one batch, minimising IPC round-trips).  The resulting local
   NSDictionary is stored in lastMenuDataByWindow.

   All subsequent updateMenuForWindow: calls for the SAME window that arrive with
   proxy data are dropped immediately (the guard below).  The menu structure does
   not change while a window is alive; only enabled states change, and those are
   delivered via updateMenuEnabledStatesForWindow: which has its own cheaper path.

   The cache entry is cleared in unregisterWindow: so that when an app closes
   and reopens its window, the next updateMenuForWindow: call materializes fresh
   data instead of skipping it.

   CRITICAL OWNERSHIP RULE:
   ------------------------
   _materializationTimeByWindow is written ONLY by updateMenuForWindow:.
   updateMenuEnabledStatesForWindow: MUST NOT write to it.  If a state-update
   call arrives before the full menu update (common with Chrome/Chromium and
   other fast-starting apps), writing to _materializationTimeByWindow from the
   state-update path would cause updateMenuForWindow: to see the window as
   "already cached" and skip the full proxy walk — leaving the window with no
   menu in menusByWindow forever.

   If you ever feel tempted to remove this cache:
   - CPU will spike to 95–100% every time any GNUstep app gains focus.
   - All GNUstep app menus will be unusably slow to appear.
   - The system will feel completely broken to the user.
   DO NOT REMOVE THIS CACHE. */
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

static NSString *const kGershwinMenuServerName = @"org.gnustep.Gershwin.MenuServer";

@interface GNUStepMenuImporter ()
@property (nonatomic, strong) NSMutableDictionary *menusByWindow;
@property (nonatomic, strong) NSMutableDictionary *clientNamesByWindow;
@property (nonatomic, strong) NSMutableDictionary *lastMenuDataByWindow;
@property (nonatomic, strong) NSMutableDictionary *lastMenuUpdateTimeByWindow;
// Window -> NSTimeInterval of the last successful enabled/state refresh or
// push.  Lets the click path skip the synchronous DO pull when states are
// known to be current, so repeated menu opens are lag-free.
@property (nonatomic, strong) NSMutableDictionary *lastStateRefreshByWindow;
// Application-level menus, keyed by clientName ("org.gnustep.Gershwin.MenuClient.<pid>").
// These back the menu bar for windowless frontmost apps.  clientPidByClientName
// lets us advertise the set of menu-bearing apps to the WM (root property
// _GERSHWIN_MENU_APPS) so Alt-Tab can list windowless apps.
@property (nonatomic, strong) NSMutableDictionary *menusByClient;
@property (nonatomic, strong) NSMutableDictionary *clientPidByClientName;
@property (nonatomic, strong) NSMutableDictionary *lastApplicationMenuDataByClient;
@property (nonatomic, strong) NSMutableDictionary *lastApplicationStateRefreshByClient;
@property (nonatomic, strong) NSConnection *menuServerConnection;
// Workaround: retry attempts when registering DO server fails
@property (nonatomic) NSInteger registerRetryAttempts;
// Serial queue for per-window client probes.  A blocking DO name lookup
// (connectionWithRegisteredName:) must never run on the main thread, or the
// whole menu bar freezes while a window switch is being processed.
@property (nonatomic) dispatch_queue_t menuScanQueue;
@end

@implementation GNUStepMenuImporter

static GNUStepMenuImporter *sSharedImporter = nil;

/* Menu item actions (GNUStepMenuActionHandler) resolve the client by name.
 * The items shown may still carry a client name from a previous app instance
 * (X reuses window IDs), so the handler asks us for the CURRENT client for the
 * window - the authoritative mapping from the last accepted menu push. */
+ (NSString *)currentClientNameForWindow:(unsigned long)windowId
{
    if (sSharedImporter == nil) return nil;
    return [sSharedImporter.clientNamesByWindow objectForKey:
      [NSNumber numberWithUnsignedLong:windowId]];
}

/* Number of windows that currently have a cached menu tree.  Used by the CPU
   profiler to detect unbounded growth from windows that closed without
   unregistering.  Must stay bounded thanks to reconcileMenusWithLiveWindows. */
+ (NSUInteger)cachedMenuCount
{
    if (sSharedImporter == nil) return 0;
    return [sSharedImporter.menusByWindow count];
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        sSharedImporter = self;
        _menusByWindow = [[NSMutableDictionary alloc] init];
        _clientNamesByWindow = [[NSMutableDictionary alloc] init];
        _lastMenuDataByWindow = [[NSMutableDictionary alloc] init];
        _lastMenuUpdateTimeByWindow = [[NSMutableDictionary alloc] init];
        _lastStateRefreshByWindow = [[NSMutableDictionary alloc] init];
        _menusByClient = [[NSMutableDictionary alloc] init];
        _clientPidByClientName = [[NSMutableDictionary alloc] init];
        _lastApplicationMenuDataByClient = [[NSMutableDictionary alloc] init];
        _lastApplicationStateRefreshByClient = [[NSMutableDictionary alloc] init];

        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            _materializationTimeByWindow = [[NSMutableDictionary alloc] init];
        });

        _menuScanQueue = dispatch_queue_create("io.github.gershwin-desktop.menu.gnustep-scan", DISPATCH_QUEUE_SERIAL);
        
        // Register the GNUstep menu server immediately so apps can connect
        // This must happen early, before any GNUstep apps try to connect
        [self registerService];

        /* Reconcile cached menu state against live X windows periodically so
           windows that close without unregistering (crash, no DO unregister)
           do not accumulate in menusByWindow forever.  The sweep is cheap: a
           per-window XGetWindowAttributes existence check. */
        [NSTimer scheduledTimerWithTimeInterval: 30.0
                                         target: self
                                       selector: @selector(reconcileMenusWithLiveWindows)
                                       userInfo: nil
                                        repeats: YES];
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

    /* Use a dedicated NSConnection, NOT [NSConnection defaultConnection].
       The default connection is a process-wide singleton: once a name is
       registered on it, a later registerName: for the same name is a no-op
       even if a name-server restart wiped the registry - so a lost
       MenuServer registration could never be recovered.  A fresh connection
       re-registers cleanly. */
    NSConnection *connection = [[NSConnection alloc] init];
    [connection setRootObject:self];

    BOOL registered = NO;
    @try {
        registered = [connection registerName:kGershwinMenuServerName];
    } @catch (NSException *e) {
        registered = NO;
        NSDebugLLog(@"gwcomp", @"GNUStepMenuImporter: Exception while registering server name: %@", e);
    }

    if (registered) {
        self.menuServerConnection = connection;
    } else {
        connection = nil;
    }

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

    /* Keep the registration alive across name-server restarts.  The first
       verification runs after a delay so startup lookups are not disturbed. */
    [self performSelector: @selector(scheduleMenuServerVerification)
               withObject: nil
               afterDelay: 5.0];

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

/* Verify that our MenuServer registration still exists on the DO name server
   and re-register if it vanished.  A name-server restart (gdnc) wipes the
   whole names registry but the NSConnection object stays valid, so neither
   registerService: nor NSConnectionDidDieNotification notices the loss - the
   result is that Menu.app can no longer be found and NO GNUstep app shows an
   app menu.  Check by re-resolving the name; if the lookup fails, drop the
   stale connection and register fresh.  Runs on a timer so any user's desktop
   recovers automatically. */
- (void)verifyMenuServerRegistration
{
    @try {
        NSConnection *found = [NSConnection connectionWithRegisteredName:
            kGershwinMenuServerName host: @""];
        if (found) {
            [found invalidate];
            /* Registration is alive.  Reschedule so the check keeps running
               (the timer is non-repeating). */
            [self scheduleMenuServerVerification];
            return;
        }
        /* The name is gone - our connection's registration was lost.  Drop the
           stale connection so registerService: creates a fresh one. */
        NSDebugLLog(@"gwcomp", @"GNUStepMenuImporter: MenuServer registration lost - re-registering");
        NSPort *oldPort = [self.menuServerConnection receivePort];
        if (oldPort) {
            [[NSRunLoop currentRunLoop] removePort: oldPort
                                           forMode: NSRunLoopCommonModes];
        }
        [self.menuServerConnection invalidate];
        self.menuServerConnection = nil;
        [self registerService];
        [self scheduleMenuServerVerification];
    } @catch (NSException *e) {
        /* Lookup threw - the name server itself may be restarting.  Try again
           on the next tick. */
        [self scheduleMenuServerVerification];
    }
}

- (void)scheduleMenuServerVerification
{
    /* Low frequency: a name-server restart is a rare event and the lookup is
       cheap, but polling every second would waste CPU for nothing. */
    [NSTimer scheduledTimerWithTimeInterval: 30.0
                                     target: self
                                   selector: @selector(verifyMenuServerRegistration)
                                   userInfo: nil
                                    repeats: NO];
}

#pragma mark - Stale-window reconcile

/* Purge menu state for windows that no longer exist in X.  Menu entries are
   only removed by unregisterWindow:, which relies on the client app calling
   the DO unregister when it closes a window.  Apps that crash, or that close
   a window without unregistering, leave their menu tree cached in
   menusByWindow forever.  Over a long session this grows RSS unboundedly and
   turns every app-switch menu replacement (menusByWindow[windowId] = menu)
   into a deep dealloc storm of the replaced tree on the main thread.  Run
   periodically and drop entries whose X window is gone. */
- (void)reconcileMenusWithLiveWindows
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self reconcileMenusWithLiveWindows];
        });
        return;
    }

    NSArray *keys = [self.menusByWindow allKeys];
    NSMutableArray *staleKeys = [NSMutableArray array];
    for (NSNumber *windowKey in keys) {
        unsigned long windowId = [windowKey unsignedLongValue];
        if (windowId != 0 && ![MenuUtils isWindowValid:windowId]) {
            [staleKeys addObject:windowKey];
        }
    }

    if ([staleKeys count] == 0) {
        return;
    }

    NSDebugLLog(@"gwcomp", @"GNUStepMenuImporter: Reconcile purging %lu stale window(s)",
          (unsigned long)[staleKeys count]);
    for (NSNumber *windowKey in staleKeys) {
        [self.menusByWindow removeObjectForKey:windowKey];
        [self.clientNamesByWindow removeObjectForKey:windowKey];
        [self.lastMenuDataByWindow removeObjectForKey:windowKey];
        [self.lastMenuUpdateTimeByWindow removeObjectForKey:windowKey];
        [self.lastStateRefreshByWindow removeObjectForKey:windowKey];
        @synchronized (_materializationTimeByWindow) {
            NSString *prefix = [NSString stringWithFormat:@"%lu:",
                                          [windowKey unsignedLongValue]];
            NSArray *mkeys = [_materializationTimeByWindow allKeys];
            for (NSString *mk in mkeys) {
                if ([mk hasPrefix:prefix])
                    [_materializationTimeByWindow removeObjectForKey:mk];
            }
        }
    }

    /* Drop application-level menus whose owning process has exited.  A
       windowless app can disappear without sending unregisterApplication:
       (crash, SIGKILL); without this sweep its menu stays in menusByClient
       and the Alt-Tab menu-app list goes stale. */
    [self reconcileApplicationMenusWithLiveProcesses];
}

/* Remove app-level menus for clients whose process is no longer alive. */
- (void)reconcileApplicationMenusWithLiveProcesses
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self reconcileApplicationMenusWithLiveProcesses];
        });
        return;
    }

    NSArray *clientNames = [self.menusByClient allKeys];
    NSMutableArray *deadClients = [NSMutableArray array];
    for (NSString *clientName in clientNames) {
        NSNumber *pidNum = [self.clientPidByClientName objectForKey:clientName];
        if (!pidNum || [pidNum unsignedIntValue] == 0) {
            continue;
        }
        pid_t pid = [pidNum intValue];
        /* kill(pid, 0) reports ESRCH for a dead process (and EPERM for a
           live one owned by someone else, which still means alive). */
        if (kill(pid, 0) == -1 && errno == ESRCH) {
            [deadClients addObject:clientName];
        }
    }

    if ([deadClients count] == 0) {
        return;
    }
    for (NSString *clientName in deadClients) {
        [self removeApplicationMenuForClient:clientName];
    }
    NSDebugLLog(@"gwcomp", @"GNUStepMenuImporter: Reconcile purged %lu stale application menu(s)",
          (unsigned long)[deadClients count]);
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
    
    /* Check whether any of our stored GNUstep windows are children of this
     * X11 window.  GNUstep's X11 backend creates child windows for its NSWindow
     * content areas, so the top-level X11 window (returned by _NET_ACTIVE_WINDOW)
     * is often the PARENT of the window ID that GNUstep's windowDevice: returns.
     * Menu.app looks up menus by the active X11 window ID, but Eau registers
     * menus under the child window ID.  This mismatch causes Menu.app to never
     * find the menu for focused GNUstep windows.
     *
     * We fix this by walking the X11 window tree: for each stored GNUstep window,
     * we climb up to its ancestors.  If any ancestor matches the requested
     * windowId, we have a match and re-key the cache entries under windowId. */
    {
      Display *dpy = [MenuUtils sharedDisplay];
      if (dpy) {
        Window root = 0;
        /* Collect stored IDs in a separate array to avoid mutation during iteration. */
        NSArray *candidates = [self.menusByWindow allKeys];
        for (NSNumber *storedKey in candidates) {
          unsigned long childWin = [storedKey unsignedLongValue];
          Window w = (Window)childWin;
          /* Walk up the window tree: w → parent → grandparent → ... */
          while (w != None) {
            Window currentRoot, parent;
            Window *children;
            unsigned int nchildren;
            if (XQueryTree(dpy, w, &currentRoot, &parent, &children, &nchildren)) {
              if (children) XFree(children);
              root = currentRoot;
              if (parent == (Window)windowId || parent == root) {
                /* Found direct parent match (or hit root → no match this branch). */
                if (parent == (Window)windowId) {
                  NSDebugLLog(@"gwcomp", @"GNUStepMenuImporter: Found GNUstep window 0x%lx as child of requested window 0x%lx", childWin, windowId);
                  self.menusByWindow[key] = self.menusByWindow[storedKey];
                  self.clientNamesByWindow[key] = self.clientNamesByWindow[storedKey];
                  return YES;
                }
                break; /* hit root, no need to continue */
              }
              w = parent;
            } else {
              break;
            }
          }
        }
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
                    /* Cache the connection so the main-thread state refresh can
                       use it without a blocking name lookup (which would wedge
                       the menu bar if this client is stalled). */
                    [GNUStepMenuActionHandler cacheConnection:connection forClient:clientName];
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
    [self.lastStateRefreshByWindow removeObjectForKey:windowKey];

    /* Clear the materialization cache for this window so that if the window
       reopens (same or new app instance), the next updateMenuForWindow: call
       performs a fresh proxy materialization instead of skipping it.  Keys are
       "<windowId>:<clientName>", so remove every entry for this window. */
    @synchronized (_materializationTimeByWindow) {
        NSString *prefix = [NSString stringWithFormat:@"%lu:", windowId];
        NSArray *keys = [_materializationTimeByWindow allKeys];
        for (NSString *k in keys) {
            if ([k hasPrefix:prefix])
                [_materializationTimeByWindow removeObjectForKey:k];
        }
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
    // push its current menu for that window via requestMenuUpdateForWindow:.
    // The per-window probe (PID lookup + blocking DO name lookup + DO call) is
    // dispatched to a background queue so the main thread is never stalled by
    // connectionWithRegisteredName:, which can block for a long time if the DO
    // name server is slow or a stale registration is being resolved.
    NSArray *allWindows = [MenuUtils getAllWindows];
    if (!allWindows || [allWindows count] == 0) {
        NSDebugLog(@"GNUStepMenuImporter: No windows to scan");
        return;
    }

    NSUInteger probesDispatched = 0;
    for (NSNumber *windowNum in allWindows) {
        unsigned long windowId = [windowNum unsignedLongValue];

        // Skip if we already have a menu for this window
        if ([self.menusByWindow objectForKey:windowNum]) {
            continue;
        }

        probesDispatched++;
        dispatch_async(self.menuScanQueue, ^{
            // Try to determine PID for the window
            pid_t pid = [MenuUtils getWindowPID:windowId];
            if (pid == 0) {
                // Not all windows provide PID - skip
                return;
            }

            NSString *clientName = [NSString stringWithFormat:@"org.gnustep.Gershwin.MenuClient.%d", pid];
            NSDebugLog(@"GNUStepMenuImporter: Found window %@ (pid: %d) - probing client %@", windowNum, pid, clientName);

            @try {
                NSConnection *connection = [NSConnection connectionWithRegisteredName:clientName host:nil];
                if (connection && [connection isValid]) {
                    /* Cache for the main-thread refresh path (avoids a blocking
                       DO name lookup if this client stalls later). */
                    [GNUStepMenuActionHandler cacheConnection:connection forClient:clientName];
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
                        } @catch (NSException *e) {
                            NSDebugLog(@"GNUStepMenuImporter: Exception requesting menu update from %@: %@", clientName, e);
                        }
                    }
                }
            }
            @catch (NSException *ex) {
                NSDebugLog(@"GNUStepMenuImporter: Exception probing client %@: %@", clientName, ex);
            }
        });
    }

    if (probesDispatched == 0) {
        NSDebugLog(@"GNUStepMenuImporter: No GNUstep menu clients discovered during scan.");
        // Do NOT reschedule automatically. Scans are triggered by window-change events
        // and registration retries, so there is no need for an unbounded polling loop.
    } else {
        NSDebugLog(@"GNUStepMenuImporter: Requested menu updates from %lu client probes", (unsigned long)probesDispatched);
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
    /* Early throttle: drop rapid-fire full-menu calls before doing any work. */
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
            /* PROXY DEDUPLICATION — see the large comment block near _materializationTimeByWindow
               at the top of this file for the full explanation of why this guard exists.

               Short version: walking a proxy menu tree takes ~1 s per call; GWorkspace fires
               thousands of calls per second.  We materialize ONCE and skip all subsequent calls
               for the same window.  unregisterWindow: clears the entry when the window closes
               so the next updateMenuForWindow: call (after the window reopens) materializes fresh
               data.

               OWNERSHIP: only updateMenuForWindow: writes to _materializationTimeByWindow.
               updateMenuEnabledStatesForWindow: must never write to it (see comments there).

               Keyed by windowId AND clientName: X reuses window IDs across app relaunches, so a
               new app instance pushing for the same windowId must materialize fresh, not be
               skipped because an earlier instance already walked this window. */
            NSString *materializeKey = [NSString stringWithFormat:@"%lu:%@",
              [safeWindowId unsignedLongValue], safeClientName];
            @synchronized (_materializationTimeByWindow) {
                if (_materializationTimeByWindow[materializeKey]) {
                    NSDebugLLog(@"gwcomp", @"GNUStepMenuImporter: Skipping proxy materialization for window %@ (already cached)", safeWindowId);
                    return;
                }
                _materializationTimeByWindow[materializeKey] = @YES;
            }

            /* Materialize proxy menuData by serialization. */
            /* This is the one expensive call we allow per window lifetime. */
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
    /* Only deduplicate when the SAME client re-sends the SAME content for the
       window.  X reuses window IDs across app relaunches, so a fresh app
       instance pushing an identical menu for the same windowId must NOT be
       dropped as a duplicate - that made the global menu work only on the
       first launch of an app. */
    NSString *lastClient = [self.clientNamesByWindow objectForKey:windowId];
    if (lastClient && [lastClient isEqualToString:clientName]
        && lastMenuData && [lastMenuData isEqual:menuData]) {
        NSDebugLLog(@"gwcomp", @"GNUStepMenuImporter: Skipping duplicate menu update for window %@", windowId);
        return;
    }

    unsigned long windowValue = [windowId unsignedLongValue];

    /* If the Info submenu contains an "Info Panel..." or Cmd-? item,
       move it to the parent menu and rename it "About...". */
    menuData = [self promoteAboutItemFromMenuData:menuData];

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
    NSString *oldClient = [self.clientNamesByWindow objectForKey:windowId];
    self.menusByWindow[windowId] = menu;
    self.clientNamesByWindow[windowId] = clientName;
    self.lastMenuDataByWindow[windowId] = [menuData copy];
    self.lastMenuUpdateTimeByWindow[windowId] = @(now);

    /* If the client (app instance) changed for a window that is currently
       displayed, the visible menu still carries menu items bound to the OLD
       client - a relaunched app reuses the X window ID, so those actions would
       target a dead process.  Force a reload of the displayed menu so the new
       instance's items (with the new clientName) are shown.  loadMenu:'s
       same-PID skip does not apply because the PID changed. */
    if (oldClient && ![oldClient isEqualToString:clientName]
        && self.appMenuWidget
        && self.appMenuWidget.currentWindowId == windowValue) {
        [self.appMenuWidget loadMenu:menu forWindow:windowValue];
    }

    // If this window is currently displayed, apply the fresh enabled/state values
    // directly to the visible menu right now.  loadMenu:forWindow: skips rebuilds
    // when the top-level structure is unchanged (which is always true for
    // enabled-state-only changes like Copy/Paste becoming available), so without
    // this in-place update the user would never see the correct state.
    AppMenuWidget *widget = self.appMenuWidget;
    if (widget && widget.currentWindowId == windowValue && widget.currentMenu) {
        [self applyEnabledStatesFromData:menuData toMenu:widget.currentMenu depth:0];
    }

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

#pragma mark - Application-level menus

/* Parse the pid embedded in a GNUstep menu client name
   ("org.gnustep.Gershwin.MenuClient.<pid>").  Returns 0 when unparseable. */
- (pid_t)_pidFromClientName:(NSString *)clientName
{
    if (!clientName || [clientName length] == 0) return 0;
    NSArray *parts = [clientName componentsSeparatedByString:@"."];
    NSString *pidPart = [parts lastObject];
    if (!pidPart || [pidPart length] == 0) return 0;
    return (pid_t)[pidPart integerValue];
}

/* Rewrite the _GERSHWIN_MENU_APPS root property with the PIDs of every app
   that currently has an application-level menu.  The window manager reads
   this so its Alt-Tab switcher can list windowless apps (apps with a menu
   but no windows) alongside regular windows. */
- (void)publishMenuAppsProperty
{
    NSMutableArray *pids = [NSMutableArray array];
    NSArray *clientNames = [self.clientPidByClientName allKeys];
    for (NSString *clientName in clientNames) {
        NSNumber *pidNum = [self.clientPidByClientName objectForKey:clientName];
        if (pidNum && [pidNum unsignedIntValue] != 0) {
            [pids addObject:pidNum];
        }
    }
    /* Sort so the property is stable and diffable. */
    [pids sortUsingSelector:@selector(compare:)];
    [MenuUtils setMenuApps:pids];
}

/* Store an application-level menu for a client (removing any stale entry) and
   refresh the menu bar if that client is the currently displayed app.  The
   app is the "currently displayed app" when the widget shows an app-level
   menu (currentWindowId == 0) for the same PID. */
- (void)storeApplicationMenu:(NSMenu *)menu
                    menuData:(NSDictionary *)menuData
                  clientName:(NSString *)clientName
{
    BOOL isNew = ([self.menusByClient objectForKey:clientName] == nil);
    NSString *oldClient = nil;
    if (isNew) {
        /* If the same PID previously pushed under a differently-formatted name,
           drop it so we do not end up with two entries for one app. */
        pid_t pid = [self _pidFromClientName:clientName];
        for (NSString *candidate in [self.clientPidByClientName allKeys]) {
            if ([[self.clientPidByClientName objectForKey:candidate] intValue] == (int)pid
                && ![candidate isEqualToString:clientName]) {
                [self removeApplicationMenuForClient:candidate];
            }
        }
    } else {
        oldClient = clientName;
    }

    self.menusByClient[clientName] = menu;
    pid_t pid = [self _pidFromClientName:clientName];
    if (pid > 0) {
        self.clientPidByClientName[clientName] = @(pid);
    }
    self.lastApplicationMenuDataByClient[clientName] = [menuData copy];
    self.lastApplicationStateRefreshByClient[clientName] =
      @([NSDate timeIntervalSinceReferenceDate]);
    [self publishMenuAppsProperty];

    /* If this client's app menu is currently displayed (windowless app shown
       in the bar) and its menu changed, reload the visible menu so the user
       sees the update immediately. */
    AppMenuWidget *widget = self.appMenuWidget;
    if (widget && widget.currentWindowId == 0 && widget.currentWindowPID != 0) {
        pid_t widgetPid = widget.currentWindowPID;
        if ((pid > 0 && widgetPid == pid)
            || (oldClient && [oldClient isEqualToString:clientName])) {
            [self.appMenuWidget loadApplicationMenu:menu forPID:widgetPid];
        }
    }
}

/* Remove an application-level menu for a client and update the menu bar if it
   was being displayed. */
- (void)removeApplicationMenuForClient:(NSString *)clientName
{
    if (!clientName) return;
    BOOL hadMenu = ([self.menusByClient objectForKey:clientName] != nil);
    [self.menusByClient removeObjectForKey:clientName];
    [self.clientPidByClientName removeObjectForKey:clientName];
    [self.lastApplicationMenuDataByClient removeObjectForKey:clientName];
    [self.lastApplicationStateRefreshByClient removeObjectForKey:clientName];

    if (!hadMenu) {
        [self publishMenuAppsProperty];
        return;
    }
    [self publishMenuAppsProperty];

    AppMenuWidget *widget = self.appMenuWidget;
    if (widget && widget.currentWindowId == 0 && widget.currentWindowPID != 0) {
        pid_t pid = [self _pidFromClientName:clientName];
        if (pid > 0 && widget.currentWindowPID == pid) {
            /* The frontmost windowless app's menu disappeared (app quit or
               unregistered).  Re-evaluate what to show. */
            dispatch_async(dispatch_get_main_queue(), ^{
                [widget updateForActiveWindow];
            });
        }
    }
}

- (oneway void)updateMenuForApplication:(bycopy NSDictionary *)menuData
                             clientName:(bycopy NSString *)clientName
{
    /* Early throttle: drop rapid-fire duplicate pushes before any work. */
    if (_shouldThrottleDO(&_lastApplicationMenuUpdateAccepted, DO_MENU_UPDATE_MIN_NS)) return;

    @try {
        if (!menuData || !clientName) return;

        NSString *safeClientName = [(id)clientName isProxy] ?
          [NSString stringWithString:(NSString *)clientName] : clientName;
        if (!safeClientName || [safeClientName length] == 0) return;

        NSDictionary *safeMenuData;
        if ([(id)menuData isProxy]) {
            NSData *data = [NSPropertyListSerialization
                            dataWithPropertyList:menuData
                            format:NSPropertyListBinaryFormat_v1_0
                            options:0
                            error:NULL];
            if (!data) {
                NSLog(@"GNUStepMenuImporter: Failed to serialize proxy app menuData for %@", clientName);
                return;
            }
            safeMenuData = [NSPropertyListSerialization
                            propertyListWithData:data
                            options:NSPropertyListImmutable
                            format:NULL
                            error:NULL];
        } else {
            safeMenuData = menuData;
        }
        if (!safeMenuData) return;

        NSDictionary *payload = @{ @"menuData": safeMenuData,
                                   @"clientName": safeClientName };
        if ([NSThread isMainThread]) {
            [self processApplicationMenuUpdateWithPayload:payload];
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self processApplicationMenuUpdateWithPayload:payload];
            });
        }
    }
    @catch (NSException *exception) {
        NSLog(@"GNUStepMenuImporter: Exception in updateMenuForApplication: %@", exception);
    }
}

- (void)processApplicationMenuUpdateWithPayload:(NSDictionary *)payload
{
    NSDictionary *menuData = payload[@"menuData"];
    NSString *clientName = payload[@"clientName"];

    NSDictionary *lastMenuData = [self.lastApplicationMenuDataByClient objectForKey:clientName];
    if (lastMenuData && [lastMenuData isEqual:menuData]) {
        NSDebugLLog(@"gwcomp", @"GNUStepMenuImporter: Skipping duplicate app menu for %@", clientName);
        return;
    }

    NSMenu *menu = [self menuFromData:menuData
                             windowId:0
                           clientName:clientName
                                path:@[]];
    if (!menu) {
        NSDebugLLog(@"gwcomp", @"GNUStepMenuImporter: Failed to build app menu for %@", clientName);
        return;
    }
    [self storeApplicationMenu:menu menuData:menuData clientName:clientName];
}

- (oneway void)unregisterApplication:(bycopy NSString *)clientName
{
    @try {
        if (!clientName) return;
        NSString *safeClientName = [(id)clientName isProxy] ?
          [NSString stringWithString:(NSString *)clientName] : clientName;
        if (!safeClientName) return;
        [self removeApplicationMenuForClient:safeClientName];
    }
    @catch (NSException *exception) {
        NSLog(@"GNUStepMenuImporter: Exception in unregisterApplication: %@", exception);
    }
}

- (oneway void)updateApplicationMenuEnabledStates:(bycopy NSDictionary *)menuData
                                        clientName:(bycopy NSString *)clientName
{
    /* Early throttle: same 50ms gate as the window-level state path. */
    if (_shouldThrottleDO(&_lastApplicationStateUpdateAccepted, DO_STATE_UPDATE_MIN_NS)) return;

    @try {
        if (!menuData || !clientName) return;
        NSString *safeClientName = [(id)clientName isProxy] ?
          [NSString stringWithString:(NSString *)clientName] : clientName;
        if (!safeClientName) return;

        NSDictionary *safeMenuData;
        if ([(id)menuData isProxy]) {
            NSData *data = [NSPropertyListSerialization
                            dataWithPropertyList:menuData
                            format:NSPropertyListBinaryFormat_v1_0
                            options:0
                            error:NULL];
            if (!data) return;
            safeMenuData = [NSPropertyListSerialization
                            propertyListWithData:data
                            options:NSPropertyListImmutable
                            format:NULL
                            error:NULL];
        } else {
            safeMenuData = menuData;
        }
        if (!safeMenuData) return;

        dispatch_async(dispatch_get_main_queue(), ^{
            NSMenu *menu = [self.menusByClient objectForKey:safeClientName];
            if (menu) {
                [self applyEnabledStatesFromData:safeMenuData toMenu:menu depth:0];
                self.lastApplicationStateRefreshByClient[safeClientName] =
                  @([NSDate timeIntervalSinceReferenceDate]);
                /* Mirror to the visible menu if this app is currently shown. */
                AppMenuWidget *widget = self.appMenuWidget;
                if (widget && widget.currentWindowId == 0 && widget.currentMenu
                    && widget.currentWindowPID != 0
                    && widget.currentWindowPID == [self _pidFromClientName:safeClientName]) {
                    [self applyEnabledStatesFromData:safeMenuData
                                              toMenu:widget.currentMenu
                                               depth:0];
                }
            }
        });
    }
    @catch (NSException *exception) {
        NSLog(@"GNUStepMenuImporter: Exception in updateApplicationMenuEnabledStates: %@", exception);
    }
}

/* Ask a client to re-push its application-level menu (startup recovery when
   Menu.app started after a windowless app).  Uses only cached connections so
   the main thread never blocks on a DO name lookup. */
- (void)requestApplicationMenuUpdateForClient:(NSString *)clientName
{
    if (!clientName) return;
    NSConnection *connection = [GNUStepMenuActionHandler existingConnectionForClient:clientName];
    if (connection && [connection isValid]) {
        @try {
            id proxy = [connection rootProxy];
            if (proxy) {
                [proxy setProtocolForProxy:@protocol(GSGNUstepMenuClient)];
                [(id)proxy requestApplicationMenuUpdate];
            }
        } @catch (NSException *e) {
            NSDebugLog(@"GNUStepMenuImporter: Exception requesting app menu update from %@: %@", clientName, e);
        }
    }
}

/* MenuProtocolHandler / unified API for app-level menus. */

- (BOOL)hasApplicationMenuForPID:(pid_t)pid
{
    if (pid <= 0) return NO;
    for (NSString *clientName in [self.clientPidByClientName allKeys]) {
        if ([[self.clientPidByClientName objectForKey:clientName] intValue] == (int)pid
            && [self.menusByClient objectForKey:clientName]) {
            return YES;
        }
    }
    return NO;
}

- (NSMenu *)getApplicationMenuForPID:(pid_t)pid
{
    if (pid <= 0) return nil;
    for (NSString *clientName in [self.clientPidByClientName allKeys]) {
        if ([[self.clientPidByClientName objectForKey:clientName] intValue] == (int)pid) {
            return [self.menusByClient objectForKey:clientName];
        }
    }
    return nil;
}

- (BOOL)refreshApplicationMenuStateForPID:(pid_t)pid
{
    if (pid <= 0) return NO;
    for (NSString *clientName in [self.clientPidByClientName allKeys]) {
        if ([[self.clientPidByClientName objectForKey:clientName] intValue] != (int)pid) {
            continue;
        }
        NSMenu *menu = [self.menusByClient objectForKey:clientName];
        if (!menu) return NO;
        NSNumber *last = [self.lastApplicationStateRefreshByClient objectForKey:clientName];
        if (last && ([NSDate timeIntervalSinceReferenceDate] - [last doubleValue]) < 2.0) {
            return YES; /* states known current within TTL */
        }
        /* No cached connection means nothing fresh to pull; the client's own
           pushes keep states current for windowless apps. */
        NSConnection *connection = [GNUStepMenuActionHandler existingConnectionForClient:clientName];
        if (connection && [connection isValid]) {
            @try {
                id proxy = [connection rootProxy];
                if (proxy) {
                    [proxy setProtocolForProxy:@protocol(GSGNUstepMenuClient)];
                    id flat = [(id)proxy validateMenuStateForWindow:@(0)];
                    if ([flat isKindOfClass:[NSArray class]]) {
                        [self applyEnabledStatesFromFlatArray:flat toMenu:menu];
                        self.lastApplicationStateRefreshByClient[clientName] =
                          @([NSDate timeIntervalSinceReferenceDate]);
                        return YES;
                    }
                }
            } @catch (NSException *e) {
                NSDebugLog(@"GNUStepMenuImporter: Exception refreshing app menu state for %@: %@", clientName, e);
            }
        }
        return NO;
    }
    return NO;
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

// Apply enabled/state from a flat array of @[title, enabled, state] triples.
// Matches by title so the ⌘ system item at Menu.app index 0 is handled correctly.
- (void)applyEnabledStatesFromFlatArray:(NSArray *)flatArray
                                 toMenu:(NSMenu *)menu
{
    if (!flatArray || !menu) return;
    // Build title -> entry map for fast lookup
    NSMutableDictionary *map = [NSMutableDictionary dictionary];
    for (id entry in flatArray) {
        if (![entry isKindOfClass:[NSArray class]] || [entry count] < 3) continue;
        NSString *title = [entry objectAtIndex:0];
        if ([title isKindOfClass:[NSString class]] && [title length] > 0) {
            map[title] = entry;
        }
    }
    // Walk menu tree by title, applying enabled/state
    [self _applyFlatArrayMap:map toMenu:menu];
}

- (void)_applyFlatArrayMap:(NSDictionary *)map toMenu:(NSMenu *)menu
{
    for (NSMenuItem *item in [menu itemArray]) {
        if ([item isSeparatorItem]) continue;
        NSString *title = [item title];
        if (!title || [title length] == 0) continue;
        NSArray *entry = map[title];
        if (entry && [entry count] >= 3) {
            NSNumber *enabled = [entry objectAtIndex:1];
            if ([enabled isKindOfClass:[NSNumber class]]) {
                [item setEnabled:[enabled boolValue]];
            }
            NSNumber *state = [entry objectAtIndex:2];
            if ([state isKindOfClass:[NSNumber class]]) {
                [item setState:[state integerValue]];
            }
        }
        if ([item hasSubmenu]) {
            [self _applyFlatArrayMap:map toMenu:[item submenu]];
        }
    }
}

- (BOOL)refreshMenuStateForWindow:(unsigned long)windowId
{
    NSNumber *key = @(windowId);
    NSString *clientName = [self.clientNamesByWindow objectForKey:key];
    if (!clientName) {
        NSLog(@"GNUStepMenuImporter: refreshMenuStateForWindow[%lu]: no client in cache (keys=%@)", windowId, [self.clientNamesByWindow allKeys]);
        NSDebugLLog(@"gwcomp", @"GNUStepMenuImporter: refreshMenuStateForWindow: no client for window %lu", windowId);
        return NO;
    }

    NSMenu *menu = [self.menusByWindow objectForKey:key];
    if (!menu) {
        NSLog(@"GNUStepMenuImporter: refreshMenuStateForWindow[%lu]: no menu in cache (keys=%@)", windowId, [self.menusByWindow allKeys]);
        NSDebugLLog(@"gwcomp", @"GNUStepMenuImporter: refreshMenuStateForWindow: no menu for window %lu", windowId);
        return NO;
    }

    /* Make a lightweight DO call to get fresh enabled/state values.
       validateMenuStateForWindow: now returns a flat NSArray of
       @[title, enabled, state] triples — no nested dictionaries, so
       it copies over DO in a single batch instantly regardless of
       bycopy support.  We match items by TITLE to handle the ⌘
       system item at index 0. */
    id rawResult = nil;

    /* Only use a connection that is ALREADY cached.  Doing the DO name lookup
       here (connectionWithRegisteredName:) on the main thread would block the
       whole menu bar while a stalled client (e.g. Workspace) resolves.  The
       background probes cache connections when they succeed, so a healthy
       client is found here; an uncached client means we have nothing fresh to
       offer, so fall through to the stale-state path instead of blocking. */
    NSConnection *connection = [GNUStepMenuActionHandler existingConnectionForClient:clientName];
    if (connection && [connection isValid]) {
        [connection setRequestTimeout:0.3];
        id proxy = [connection rootProxy];
        if (proxy) {
            [proxy setProtocolForProxy:@protocol(GSGNUstepMenuClient)];
            @try {
                rawResult = [(id<GSGNUstepMenuClient>)proxy validateMenuStateForWindow:@(windowId)];
                /* Materialize proxy in one batch via plist if needed */
                if (rawResult && [(id)rawResult isProxy]) {
                    @try {
                        NSError *err = nil;
                        NSData *plist = [NSPropertyListSerialization dataWithPropertyList:rawResult format:NSPropertyListBinaryFormat_v1_0 options:0 error:&err];
                        if (plist && !err) {
                            rawResult = [NSPropertyListSerialization propertyListWithData:plist options:NSPropertyListImmutable format:nil error:&err];
                        }
                    } @catch (NSException *e) {}
                    if (!rawResult) rawResult = [rawResult copy];
                }
            } @catch (NSException *e) {}
        }
    }

    NSMenu *safeMenu = [self.menusByWindow objectForKey:@(windowId)];
    if (!safeMenu) safeMenu = menu;

    if ([rawResult isKindOfClass:[NSArray class]]) {
        [self applyEnabledStatesFromFlatArray:rawResult toMenu:safeMenu];
        AppMenuWidget *widget = self.appMenuWidget;
        if (widget && widget.currentWindowId == windowId && widget.currentMenu != nil && widget.currentMenu != safeMenu) {
            [self applyEnabledStatesFromFlatArray:rawResult toMenu:widget.currentMenu];
        }
    } else {
        [safeMenu update];
    }

    /* Mark states as freshly refreshed so repeated menu opens skip the
       synchronous DO pull for STATE_REFRESH_TTL seconds. */
    @synchronized (self) {
        self.lastStateRefreshByWindow[@(windowId)] = @([NSDate timeIntervalSinceReferenceDate]);
    }
    return YES;
}

/* Returns YES when the enabled/checkmark states for the window are known to be
   current, i.e. they were pulled or pushed within the given TTL.  Windows we do
   not track (GTK/DBus menus, which have no state-pull path) are reported as
   fresh so the caller skips the useless pull. */
- (BOOL)menuStatesAreFreshForWindow:(unsigned long)windowId
                          withinTTL:(NSTimeInterval)ttl
{
    NSNumber *key = @(windowId);
    NSMenu *menu = nil;
    @synchronized (self) {
        menu = [self.menusByWindow objectForKey:key];
        if (menu) {
            NSNumber *ts = [self.lastStateRefreshByWindow objectForKey:key];
            if (!ts) return NO;
            NSTimeInterval age = [NSDate timeIntervalSinceReferenceDate] - [ts doubleValue];
            return (age < ttl);
        }
    }
    /* No tracked menu for this window — nothing for us to refresh. */
    return YES;
}

// Lightweight oneway push from Eau: applies only enabled/state in-place on the
// existing NSMenu without rebuilding it.
// This is the fast path called immediately after every menu action fires in Eau.
- (oneway void)updateMenuEnabledStatesForWindow:(bycopy NSNumber *)windowId
                                       menuData:(bycopy NSDictionary *)menuData
                                     clientName:(bycopy NSString *)clientName
{
    /* No logging before the throttle gate: GWorkspace fires this path
       thousands of times per second, and an unconditional NSLog here burned
       CPU on string formatting + log I/O for every dropped call. */
    /* Throttle to 50 ms: GWorkspace fires this path thousands of times per second.
       50 ms is imperceptible to the user but cuts CPU by ~98%.  Enabled-state
       changes (Copy/Paste becoming available after text selection) are visible to
       the user within one 50 ms window, which is indistinguishable from instant.
       The on-demand pull path (menuWillOpen: → refreshMenuStateForWindow:) ensures
       states are always fresh by the time the user actually opens a submenu. */
    if (_shouldThrottleDO(&_lastStateUpdateAccepted, DO_STATE_UPDATE_MIN_NS)) return;

    NSDebugLLog(@"gwcomp", @"GNUStepMenuImporter: updateMenuEnabledStatesForWindow accepted - windowId=%@", windowId);

    (void)clientName;
    // Validate parameters — we're on a background DO thread.
    if (![windowId isKindOfClass:[NSNumber class]] ||
        ![menuData isKindOfClass:[NSDictionary class]]) {
        return;
    }

    NSNumber *safeId = [windowId copy];

    /* PROXY HANDLING FOR STATE UPDATES
       ----------------------------------
       'menuData' may arrive as a DO proxy when the sender was compiled without
       the bycopy protocol qualifier.  We must materialize it to access its
       enabled/state values.

       *** CRITICAL: DO NOT WRITE TO _materializationTimeByWindow HERE. ***

       _materializationTimeByWindow is exclusively owned by updateMenuForWindow:.
       Its purpose is to deduplicate expensive full-menu proxy walks during the
       window-switch flood (thousands of calls/second for the same window).

       If a state-update call arrives BEFORE the full menu update — which happens
       regularly with Chrome, Chromium, and any fast-starting app — writing to
       _materializationTimeByWindow here would cause updateMenuForWindow: to see
       the window as "already cached" and skip its proxy walk entirely.  The
       window would never get an entry in menusByWindow, and the app menu would
       never appear.

       Why materializing here is safe despite cost:
       - The 50 ms throttle gate above limits us to at most 20 calls/second.
       - updateMenuEnabledStatesForWindow: is only sent when menu states actually
         change (user makes a selection, edits text, etc.) — far fewer calls than
         the focus-change flood that hits updateMenuForWindow:.
       - Outside of window-switch floods the DO channel is quiet, so proxy walks
         complete in < 50 ms rather than the ~1 s seen under heavy congestion.

       DO NOT replace this materialization with lastMenuDataByWindow lookup.
       lastMenuDataByWindow holds the state at the time the full menu was first
       built (e.g., Copy=disabled).  Using it for state updates actively overwrites
       fresh states (e.g., Copy=enabled after Select All) and breaks copy/paste. */
    NSDictionary *safeData = nil;
    if ([(id)menuData isProxy]) {
        /* Materialize proxy: one batch IPC walk, result stored locally. */
        @try {
            NSError *err = nil;
            NSData *plist = [NSPropertyListSerialization dataWithPropertyList:menuData
                                                                        format:NSPropertyListBinaryFormat_v1_0
                                                                       options:0
                                                                         error:&err];
            if (plist && !err) {
                safeData = [NSPropertyListSerialization propertyListWithData:plist
                                                                      options:NSPropertyListImmutable
                                                                       format:nil
                                                                        error:&err];
            }
        } @catch (NSException *e) { /* fall through to copy below */ }
        if (!safeData) safeData = [menuData copy];
    } else {
        /* Non-proxy (bycopy arrived as local copy) — use directly, no expensive walk. */
        safeData = menuData;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        NSMenu *menu = [self.menusByWindow objectForKey:safeId];
        if (!menu) {
            NSDebugLLog(@"gwcomp", @"GNUStepMenuImporter: updateMenuEnabledStatesForWindow: no menu for window %@", safeId);
            return;
        }
        [self applyEnabledStatesFromData:safeData toMenu:menu depth:0];
        // Also apply to the currently displayed menu if it is a different object.
        // processMenuUpdateWithPayload: can rebuild the cached menu, making
        // menusByWindow[windowId] diverge from appMenuWidget.currentMenu until the
        // 150 ms deferred-check fires.  Updating both here ensures the visible menu
        // reflects the latest enabled/state values immediately.
        AppMenuWidget *widget = self.appMenuWidget;
        if (widget &&
            widget.currentWindowId == [safeId unsignedLongValue] &&
            widget.currentMenu != nil &&
            widget.currentMenu != menu) {
            [self applyEnabledStatesFromData:safeData toMenu:widget.currentMenu depth:0];
        }
        @synchronized (self) {
            self.lastStateRefreshByWindow[safeId] = @([NSDate timeIntervalSinceReferenceDate]);
        }
        NSDebugLLog(@"gwcomp", @"GNUStepMenuImporter: updateMenuEnabledStatesForWindow: applied states for window %@", safeId);
    });
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

#pragma mark - Info Panel / About... fixup

- (NSDictionary *)promoteAboutItemFromMenuData:(NSDictionary *)menuData
{
    NSArray *itemsData = [menuData objectForKey:@"items"];
    if (![itemsData isKindOfClass:[NSArray class]] || [itemsData count] == 0) {
        return menuData;
    }

    for (NSUInteger i = 0; i < [itemsData count]; i++) {
        NSDictionary *itemData = [itemsData objectAtIndex:i];
        if (![itemData isKindOfClass:[NSDictionary class]]) {
            continue;
        }

        NSString *title = [itemData objectForKey:@"title"];
        if (![title isKindOfClass:[NSString class]] || ![title isEqualToString:@"Info"]) {
            continue;
        }

        NSDictionary *submenuData = [itemData objectForKey:@"submenu"];
        if (![submenuData isKindOfClass:[NSDictionary class]]) {
            continue;
        }

        NSArray *submenuItems = [submenuData objectForKey:@"items"];
        if (![submenuItems isKindOfClass:[NSArray class]]) {
            continue;
        }

        for (NSUInteger j = 0; j < [submenuItems count]; j++) {
            NSDictionary *subItemData = [submenuItems objectAtIndex:j];
            if (![subItemData isKindOfClass:[NSDictionary class]]) {
                continue;
            }

            NSString *subTitle = [subItemData objectForKey:@"title"];
            NSString *subKey = [subItemData objectForKey:@"keyEquivalent"];

            BOOL isInfoPanel = [subTitle isKindOfClass:[NSString class]] && [subTitle isEqualToString:@"Info Panel..."];
            BOOL isHelpKey = [subKey isKindOfClass:[NSString class]] && [subKey isEqualToString:@"?"];

            if (!isInfoPanel && !isHelpKey) {
                continue;
            }

            /* Remove item from submenu. */
            NSMutableArray *newSubmenuItems = [submenuItems mutableCopy];
            [newSubmenuItems removeObjectAtIndex:j];

            NSMutableDictionary *newSubmenuData = [submenuData mutableCopy];
            [newSubmenuData setObject:newSubmenuItems forKey:@"items"];

            /* Update the Info submenu item to use the new submenu. */
            NSMutableArray *newItems = [itemsData mutableCopy];
            NSMutableDictionary *newInfoItem = [itemData mutableCopy];
            [newInfoItem setObject:newSubmenuData forKey:@"submenu"];
            [newItems replaceObjectAtIndex:i withObject:newInfoItem];

            /* Create the promoted "About..." item. */
            NSMutableDictionary *aboutItemData = [subItemData mutableCopy];
            [aboutItemData setObject:@"About..." forKey:@"title"];
            [newItems insertObject:aboutItemData atIndex:i + 1];

            NSMutableDictionary *newMenuData = [menuData mutableCopy];
            [newMenuData setObject:newItems forKey:@"items"];

            NSDebugLLog(@"gwcomp", @"GNUStepMenuImporter: Promoted '%@' from Info submenu to parent menu in menuData", subTitle);
            return newMenuData;
        }
    }

    return menuData;
}

@end
