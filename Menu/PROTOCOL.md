# GNUStep Menu IPC Architecture Documentation

> [!NOTE]
> This is a **discussion draft** reflecting the current implementation. Discussion is encouraged. Possibly this could evolve into a standard within GNUstep if there is sufficient interest in this. The name `org.gnustep.Gershwin.MenuServer` is a placeholder and is subject to change. Suggestions are welcome.

## Overview

The GNUStep Menu IPC (Inter-Process Communication) system implements a distributed objects architecture that allows a centralized menu bar application (Menu.app) to display and manage menus for GNUStep applications while delegating menu action execution back to the originating application.

## Architecture Components

### 1. Distributed Objects Framework (NSConnection)

The system uses GNUStep's NSConnection class, which implements Distributed Objects (DO) - a remote procedure call (RPC) mechanism built on top of NSPort for inter-process message passing.

**Key Concepts:**
- **NSConnection**: Manages bi-directional communication between processes over ports
- **NSPort**: Low-level abstraction for IPC endpoints (typically Mach ports on macOS, UNIX domain sockets on Linux)
- **NSProxy/NSDistantObject**: Proxy objects that forward method invocations across connection boundaries
- **Protocol-based dispatch**: Methods are discovered via Objective-C protocols declared with `@protocol`
- **Run loop integration**: NSConnection requires active run loop processing to receive incoming messages

### 2. Protocol Definitions

#### GSGNUstepMenuServer Protocol

Implemented by: **Menu.app**  
Purpose: Allows applications to register their menus and receive updates

```objectivec
@protocol GSGNUstepMenuServer <NSObject>
- (oneway void)updateMenuForWindow:(NSNumber *)windowId
                          menuData:(NSDictionary *)menuData
                        clientName:(NSString *)clientName;
- (oneway void)unregisterWindow:(NSNumber *)windowId
                       clientName:(NSString *)clientName;
@end
```

**Registration Name:** `org.gnustep.Gershwin.MenuServer`

**Methods:**
- `updateMenuForWindow:menuData:clientName:` - Application sends serialized menu structure to Menu.app
- `unregisterWindow:clientName:` - Application notifies Menu.app when a window closes

**oneway void Semantics:**
- Caller does not wait for response (fire-and-forget)
- Reduces latency and prevents deadlocks
- Message delivery is asynchronous

#### GSGNUstepMenuClient Protocol

Implemented by: **Applications (via Eau theme)**  
Purpose: Allows Menu.app to trigger menu actions in the application

```objectivec
@protocol GSGNUstepMenuClient <NSObject>
- (oneway void)activateMenuItemAtPath:(NSArray *)indexPath 
                            forWindow:(NSNumber *)windowId;
@end
```

**Registration Name:** `org.gnustep.Gershwin.MenuClient.<PID>` (e.g., `org.gnustep.Gershwin.MenuClient.23857`)

**Methods:**
- `activateMenuItemAtPath:forWindow:` - Menu.app invokes this when user clicks a menu item
  - `indexPath`: Array of NSNumbers representing menu hierarchy (e.g., [1, 0] = "File" menu, first item)
  - `windowId`: X11 window ID (device ID from GSDisplayServer) identifying the target window

**Critical Implementation Detail:**
Protocol must be declared in the **header file** (.h), not just implementation (.m), for NSDistantObject to recognize methods on proxy objects.

### 3. Connection Lifecycle

#### Application Startup (Client Registration)

1. **Theme Initialization** (`Eau.m` in `-_ensureMenuClientRegistered`)
   ```objectivec
   menuClientConnection = [[NSConnection alloc] init];
   [menuClientConnection setRootObject:self];  // Eau theme instance
   ```

2. **Run Loop Integration**
   ```objectivec
   [[NSRunLoop currentRunLoop] addPort:[menuClientConnection receivePort]
                               forMode:NSDefaultRunLoopMode];
   [[NSRunLoop currentRunLoop] addPort:[menuClientConnection receivePort]
                               forMode:NSModalPanelRunLoopMode];
   [[NSRunLoop currentRunLoop] addPort:[menuClientConnection receivePort]
                               forMode:NSEventTrackingRunLoopMode];
   [[NSRunLoop currentRunLoop] addPort:[menuClientConnection receivePort]
                               forMode:NSRunLoopCommonModes];
   ```
   
   **Why This Is Essential:**
   - NSConnection creates receive and send ports for bidirectional communication
   - The receive port MUST be added to the run loop to process incoming messages
   - Without run loop integration, incoming DO messages are never delivered
   - Multiple modes ensure messages arrive during modal dialogs and event tracking
   - NSRunLoopCommonModes ensures messages are processed in all common run loop modes

3. **Name Registration**
   ```objectivec
   NSString *clientName = [NSString stringWithFormat:
       @"org.gnustep.Gershwin.MenuClient.%d", getpid()];
   BOOL registered = [menuClientConnection registerName:clientName];
   ```
   
   **Name Server:**
   - GNUStep maintains a process-wide name server (NSPortNameServer)
   - Registered names allow other processes to discover and connect
   - PID suffix ensures uniqueness per application instance

4. **Server Connection** (`-_ensureMenuServerConnection`)
   ```objectivec
   NSConnection *connection = [NSConnection connectionWithRegisteredName:
       @"org.gnustep.Gershwin.MenuServer" host:nil];
   id proxy = [connection rootProxy];
   [proxy setProtocolForProxy:@protocol(GSGNUstepMenuServer)];
   menuServerProxy = proxy;
   ```
   
   **Proxy Configuration:**
   - `connectionWithRegisteredName:host:` looks up registered name in name server
   - `rootProxy` returns NSDistantObject pointing to remote object
   - `setProtocolForProxy:` tells proxy which methods are available
   - Proxy caches method signatures from protocol for efficient dispatch

#### Menu Registration Flow

1. **Application calls** `[GSTheme setMenu:forWindow:]` (overridden by Eau)

2. **Window Identification**
   ```objectivec
   GSDisplayServer *server = GSServerForWindow(window);
   int internalNumber = [window windowNumber];  // GNUStep internal ID
   uint32_t deviceId = [server windowDevice:internalNumber];  // X11 window ID
   NSNumber *windowId = [NSNumber numberWithUnsignedInt:deviceId];
   ```
   
   **Device ID vs Window Number:**
   - GNUStep uses internal window numbers for tracking
   - Device ID is the actual X11 Window ID visible to other processes
   - Menu.app uses X11 properties on device IDs for discovery

3. **Menu Serialization** (recursive tree walk)
   ```objectivec
   - (NSDictionary *)_serializeMenu:(NSMenu *)menu
   {
       NSMutableArray *items = [NSMutableArray array];
       for (NSMenuItem *item in [menu itemArray])
       {
           NSDictionary *serialized = [self _serializeMenuItem:item];
           [items addObject:serialized];
       }
       return @{@"title": [menu title], @"items": items};
   }
   ```
   
   **Serialization Details:**
   - Converts NSMenu tree to NSDictionary/NSArray hierarchy
   - Includes: title, enabled state, keyboard shortcuts, separators
   - Submenu hierarchy preserved recursively
   - Target/action information NOT serialized (kept server-side for security)

4. **IPC Call to Menu.app**
   ```objectivec
   [(id<GSGNUstepMenuServer>)menuServerProxy 
       updateMenuForWindow:windowId
                  menuData:menuData
                clientName:[self _menuClientName]];
   ```
   
   **Client Name Purpose:**
   - Menu.app stores clientName with each window's menu
   - When user clicks, Menu.app looks up clientName
   - Connects back to client using stored name

5. **Local Cache** (application side)
   ```objectivec
   [menuByWindowId setObject:menu forKey:windowId];
   ```
   
   **Why Cache Locally:**
   - Menu.app only stores serialized structure
   - Original NSMenu objects with targets/actions remain in app
   - Enables action dispatch when IPC callback arrives

### 4. Menu Action Execution Flow

#### User Interaction → Action Dispatch

**Step 1: User Clicks Menu Item in Menu.app**

```objectivec
// GNUStepMenuActionHandler.m
- (void)performMenuAction:(id)sender
{
    NSMenuItem *menuItem = (NSMenuItem *)sender;
    NSDictionary *metadata = [menuItem representedObject];
    
    NSString *clientName = [metadata objectForKey:@"clientName"];
    NSNumber *windowId = [metadata objectForKey:@"windowId"];
    NSArray *indexPath = [metadata objectForKey:@"indexPath"];
    
    // Dispatch to background thread to avoid blocking UI
    [self performSelectorInBackground:@selector(_performMenuActionInBackground:)
                           withObject:metadata];
}
```

**Represented Object Pattern:**
- Each NSMenuItem in Menu.app stores metadata in representedObject
- Contains routing information: clientName, windowId, indexPath
- Index path built during menu construction by walking hierarchy

**Step 2: Connection to Client (Main Thread)**

```objectivec
+ (void)_performMenuActionInBackground:(NSDictionary *)info
{
    NSString *clientName = info[@"clientName"];
    NSNumber *windowId = info[@"windowId"];
    NSArray *indexPath = info[@"indexPath"];
    
    NSConnection *connection = [self _getCachedConnectionForClient:clientName];
    if (!connection) {
        NSLog(@"GNUStepMenuActionHandler: Unable to connect to GNUstep menu client %@", clientName);
        return;
    }
    
    id proxy = [connection rootProxy];
    [proxy setProtocolForProxy:@protocol(GSGNUstepMenuClient)];
    
    [(id<GSGNUstepMenuClient>)proxy activateMenuItemAtPath:indexPath forWindow:windowId];
}
```

**Connection Caching:**
- Connections are cached by client name to avoid repeated lookups
- Cached connections are validated (checked with `isValid`) before reuse
- Invalid connections are removed from cache and new connections created
- Thread-safe access via NSLock for connection cache

**Threading Model:**
- Menu click handled on main thread (UI responsiveness)
- IPC call made directly on main thread (not dispatched to background)
- oneway void semantics mean no response waited for, so blocking is minimal
- Client's run loop will process the incoming message when active

**Step 3: Message Delivery to Client**

The NSConnection runtime:
1. Serializes method invocation (selector, arguments)
2. Sends bytes over NSPort to client's receive port
3. Client's run loop detects port activity
4. NSConnection deserializes and dispatches to root object

**Critical: Run Loop Must Be Active**
- If receive port not in run loop: message buffered but never processed
- If run loop blocked: message queued until next run loop iteration
- Modal dialogs: requires NSModalPanelRunLoopMode
- Menu tracking: requires NSEventTrackingRunLoopMode

**Step 4: Client Receives Callback**

```objectivec
// Eau.m - Called by run loop (message dispatch happens on thread that added port)
- (oneway void)activateMenuItemAtPath:(NSArray *)indexPath 
                            forWindow:(NSNumber *)windowId
{
    NSLog(@"Eau: activateMenuItemAtPath called - indexPath: %@, windowId: %@", 
          indexPath, windowId);
    
    NSDictionary *payload = @{
        @"indexPath": indexPath ?: [NSArray array],
        @"windowId": windowId ?: [NSNumber numberWithUnsignedInt:0]
    };
    
    if (![NSThread isMainThread]) {
        [self performSelectorOnMainThread:@selector(_performMenuActionFromIPC:)
                               withObject:payload
                            waitUntilDone:NO];
        return;
    }
    
    [self _performMenuActionFromIPC:payload];
}
```

**Thread Safety:**
- NSConnection delivers messages on the thread that added the receive port to run loop
- Typically main thread (where Eau theme is initialized)
- Code explicitly checks `[NSThread isMainThread]` and dispatches to main thread if needed
- This ensures menu actions are always executed on main thread

**Step 5: Menu Item Resolution**

```objectivec
- (void)_performMenuActionFromIPC:(NSDictionary *)info
{
    NSNumber *windowId = [info objectForKey:@"windowId"];
    NSArray *indexPath = [info objectForKey:@"indexPath"];
    
    // 1. Retrieve cached menu for this window
    NSMenu *menu = [menuByWindowId objectForKey:windowId];
    if (menu == nil) {
        // Fallback: If we only have one cached menu, use it
        // This handles window ID mismatches (different X11 window ID than expected)
        if ([menuByWindowId count] == 1) {
            menu = [[menuByWindowId allValues] firstObject];
        } else if ([menuByWindowId count] > 0) {
            // Multiple windows cached - use the first one (usually the main window)
            menu = [[menuByWindowId allValues] firstObject];
        }
        
        if (menu == nil) {
            NSLog(@"Eau: No menu cached for window %@", windowId);
            return;
        }
    }
    
    // 2. Walk index path to find menu item using helper method
    NSMenuItem *menuItem = [self _menuItemForIndexPath:indexPath inMenu:menu];
    if (menuItem == nil) {
        return;
    }
    
    // 3. Check if menu item is enabled before executing
    if (![menuItem isEnabled]) {
        NSLog(@"Eau: Menu item '%@' disabled, ignoring", [menuItem title]);
        return;
    }
    
    SEL action = [menuItem action];
    id target = [menuItem target];
    
    if (action == NULL) {
        NSLog(@"Eau: Menu item '%@' has no action", [menuItem title]);
        return;
    }
    
    // 4. Dispatch action (responder chain resolution handled by NSApp)
    BOOL handled = [NSApp sendAction:action to:target from:menuItem];
    NSLog(@"Eau: sendAction returned %@ for menu item '%@'", handled ? @"YES" : @"NO", [menuItem title]);
}
```

**Index Path Resolution:**
- Index path is array of integers: [topLevelIndex, submenuIndex, ...]
- Example: File > Open is [1, 0] (assuming File is second top-level item)
- Walk tree by indexing into itemArray at each level
- Last component identifies the clicked item
- Intermediate components identify parent menus
- Helper method `_menuItemForIndexPath:inMenu:` encapsulates this logic

**Target/Action Pattern:**
- NSMenuItem stores target (object) and action (selector)
- If target is nil, NSApp walks responder chain to find responder implementing action
- Responder chain: key window → window's delegate → NSApp → NSApp delegate
- Common pattern: nil target for automatic first responder dispatch
- Code checks enabled state before dispatching action to prevent execution of disabled items

**Step 6: Action Execution**

```objectivec
[NSApp sendAction:action to:target from:menuItem];
```

NSApplication's sendAction:to:from: implementation:
1. Validates target responds to action selector
2. Invokes `[target performSelector:action withObject:menuItem]`
3. Returns YES if action was sent, NO if target doesn't respond
4. May trigger side effects: save document, show dialog, etc.

## Implementation Requirements

### Client-Side Checklist (Application/Theme)

1. ✅ **Declare protocol in header file** (.h not just .m)
   ```objectivec
   @protocol GSGNUstepMenuClient <NSObject>
   - (oneway void)activateMenuItemAtPath:(NSArray *)indexPath 
                               forWindow:(NSNumber *)windowId;
   @end
   ```

2. ✅ **Declare protocol conformance in interface**
   ```objectivec
   @interface Eau : GSTheme <GSGNUstepMenuClient>
   ```

3. ✅ **Create and configure NSConnection**
   ```objectivec
   menuClientConnection = [[NSConnection alloc] init];
   [menuClientConnection setRootObject:self];
   ```

4. ✅ **Add receive port to run loop (ALL MODES)**
   ```objectivec
   NSPort *receivePort = [menuClientConnection receivePort];
   [[NSRunLoop currentRunLoop] addPort:receivePort forMode:NSDefaultRunLoopMode];
   [[NSRunLoop currentRunLoop] addPort:receivePort forMode:NSModalPanelRunLoopMode];
   [[NSRunLoop currentRunLoop] addPort:receivePort forMode:NSEventTrackingRunLoopMode];
   ```

5. ✅ **Register unique name**
   ```objectivec
   NSString *name = [NSString stringWithFormat:
       @"org.gnustep.Gershwin.MenuClient.%d", getpid()];
   [menuClientConnection registerName:name];
   ```

6. ✅ **Cache menus by window ID**
   ```objectivec
   menuByWindowId = [[NSMutableDictionary alloc] init];
   [menuByWindowId setObject:menu forKey:windowId];
   ```

7. ✅ **Implement callback method on main thread**
   ```objectivec
   - (oneway void)activateMenuItemAtPath:(NSArray *)indexPath 
                               forWindow:(NSNumber *)windowId
   {
       // Resolve menu item from cache
       // Send action via NSApp sendAction:to:from:
   }
   ```

### Server-Side Checklist (Menu.app)

1. ✅ **Register as menu server early in startup**
   ```objectivec
   serverConnection = [[NSConnection alloc] init];
   [serverConnection setRootObject:menuManager];
   [serverConnection registerName:@"org.gnustep.Gershwin.MenuServer"];
   ```

2. ✅ **Store client metadata with menus**
   ```objectivec
   menuCache[@(windowId)] = @{
       @"clientName": clientName,
       @"menuData": menuData,
       @"lastUpdate": [NSDate date]
   };
   ```

3. ✅ **Attach routing info to menu items**
   ```objectivec
   [menuItem setRepresentedObject:@{
       @"clientName": clientName,
       @"windowId": windowId,
       @"indexPath": @[@1, @0]  // Built during menu construction
   }];
   ```

4. ✅ **Connect back to client on main thread with connection caching**
   ```objectivec
   // Cache connections by client name to avoid repeated lookups
   + (NSConnection *)_getCachedConnectionForClient:(NSString *)clientName
   {
       [connectionCacheLock lock];
       NSConnection *connection = [connectionCache objectForKey:clientName];
       
       // Test if connection is still valid
       if (connection && ![connection isValid]) {
           [connectionCache removeObjectForKey:clientName];
           connection = nil;
       }
       
       if (!connection) {
           connection = [NSConnection connectionWithRegisteredName:clientName host:nil];
           if (connection) {
               [connectionCache setObject:connection forKey:clientName];
           }
       }
       
       [connectionCacheLock unlock];
       return connection;
   }
   ```

5. ✅ **Set protocol before calling proxy**
   ```objectivec
   id proxy = [connection rootProxy];
   [proxy setProtocolForProxy:@protocol(GSGNUstepMenuClient)];
   ```

## Application-Level Menus (Windowless Apps)

A GNUstep application with no windows (e.g. a menu-only app) can still show its
main menu in Menu.app.  The menu is keyed by the application rather than by a
window, using the client name (`org.gnustep.Gershwin.MenuClient.<pid>`).

### Server protocol additions

```objectivec
- (oneway void)updateMenuForApplication:(NSDictionary *)menuData
                             clientName:(NSString *)clientName;
- (oneway void)unregisterApplication:(NSString *)clientName;
- (oneway void)updateApplicationMenuEnabledStates:(NSDictionary *)menuData
                                        clientName:(NSString *)clientName;
```

- `updateMenuForApplication:clientName:` - serialize and push `[NSApp mainMenu]`
  exactly like the window path (`windowId` 0 on every item).  Menu.app stores it
  keyed by client name and routes clicks back through the same clientName path.
- `unregisterApplication:clientName:` - sent on `NSApplicationWillTerminate`.
- `updateApplicationMenuEnabledStates:clientName:` - enabled/checkmark push,
  same shape as the window-level state push.

### Client protocol additions

```objectivec
- (oneway void)requestApplicationMenuUpdate;
```

Menu.app calls this (on cached connections only, never blocking on name lookup)
when it started after the windowless app, so the app re-pushes its menu.

### Root-window coordination with the window manager

Two Gershwin root properties connect Menu.app and the WM:

- `_GERSHWIN_ACTIVE_APP` (Cardinal, PID; **WM-owned**).  The WM writes the PID
  of the frontmost application on every focus change, including when the
  frontmost app has no window.  Desktop windows are skipped on purpose: when
  the WM falls back to focusing the desktop after the frontmost app's last
  window closed, this property still names the windowless app.  An explicit
  desktop click writes the desktop app's own PID so a deliberate click always
  wins over the fallback.
- `_GERSHWIN_MENU_APPS` (Cardinal array of PIDs; **Menu.app-owned**).  Menu.app
  republishes this whenever an app menu is stored or removed.  The WM's Alt-Tab
  switcher reads it to add windowless apps as switch targets (skipping PIDs
  already represented by a window), and selecting such an app clears
  `_NET_ACTIVE_WINDOW` and sets `_GERSHWIN_ACTIVE_APP`.

Menu.app display rule for the menu bar:

1. The active window with a registered window menu wins.
2. Otherwise, show the application-level menu of `_GERSHWIN_ACTIVE_APP` when
   the active window is 0, or when the active window is the desktop and its PID
   differs from the active app (windowless fallback).
3. Otherwise keep the current menu if one is shown, else the system-only menu.

## Common Issues and Solutions

### Issue: "Broken pipe" errors in logs

**Cause:** oneway methods don't wait for response; connection closed prematurely

**Solution:** Normal behavior for oneway void - connection closes immediately after sending message. Not an error.

### Issue: Menu items displayed but clicks do nothing

**Root Causes:**
1. ❌ Protocol not declared in header file
2. ❌ Protocol conformance not declared in @interface
3. ❌ Receive port not added to run loop
4. ❌ Missing NSRunLoopCommonModes in run loop setup
5. ❌ Menu not cached locally in application (Eau.m menuByWindowId dictionary)
6. ❌ Window ID mismatch between registration and cache lookup

**Diagnosis:**
```objectivec
// Test with manual connection
NSConnection *conn = [NSConnection connectionWithRegisteredName:clientName host:nil];
if (!conn) {
    NSLog(@"ERROR: Could not find registered client %@", clientName);
    return;
}
id proxy = [conn rootProxy];
if (!proxy) {
    NSLog(@"ERROR: Could not get root proxy from connection");
    return;
}
[proxy setProtocolForProxy:@protocol(GSGNUstepMenuClient)];
NSLog(@"Responds: %d", [proxy respondsToSelector:@selector(activateMenuItemAtPath:forWindow:)]);
```

**Fix:** 
1. Ensure all client-side checklist items completed
2. Check NSLog output: "Eau: Registered GNUstep menu client as org.gnustep.Gershwin.MenuClient.PID"
3. Verify menuByWindowId is being populated in setMenu:forWindow:
4. Check Menu.app is actually running and registering as MenuServer

### Issue: Actions execute on wrong window

**Cause:** Window ID mismatch between registration and cache lookup

**Solution:**
- Use device ID (X11 window ID) consistently
- Don't use GNUStep internal window numbers for IPC
- Log window IDs at registration and callback
- Eau implements fallback mechanism: if exact windowId not found, uses first cached menu
- This handles cases where X11 window ID doesn't exactly match registration
- Check NSLog output: "Eau: Using fallback menu (only one cached menu)"

### Issue: Responder chain not finding target

**Cause:** Menu action selector not implemented anywhere in responder chain

**Solution:**
```objectivec
// In application delegate or document controller
- (void)openDocument:(id)sender {
    // Implementation
}

// Or declare in First Responder
- (IBAction)openDocument:(id)sender;
```

## Performance Considerations

1. **Serialization Overhead:** Menu updates serialize entire menu tree
   - Cache serialized menus when possible
   - Only update on menu structure changes, not state changes

2. **IPC Latency:** Distributed objects add ~1-5ms per call
   - Use oneway void to avoid blocking
   - Batch operations when possible

3. **Run Loop Integration:** Adds port to run loop sources
   - Minimal overhead (~10 file descriptors per connection)
   - Clean up connections when windows close

4. **Threading:** Background threads for IPC prevent UI blocking
   - Always dispatch back to main thread for UI updates
   - Use @autoreleasepool in background threads

## Security Considerations

1. **Name Server Scope:** Process-local by default
   - Remote connections require explicit host parameter
   - PID suffix prevents name collisions

2. **Method Exposure:** Only protocol methods are remotely invocable
   - Don't expose sensitive methods in protocols
   - Validate all parameters in IPC methods

3. **Trust Model:** No authentication between processes
   - Assume local processes are trusted
   - Don't send credentials over DO

## Testing Strategies

### Unit Test: Connection Registration

```objectivec
- (void)testClientRegistration {
    NSString *name = @"org.gnustep.Gershwin.MenuClient.99999";
    NSConnection *conn = [[NSConnection alloc] init];
    [conn setRootObject:self];
    XCTAssertTrue([conn registerName:name]);
    
    NSConnection *remote = [NSConnection connectionWithRegisteredName:name host:nil];
    XCTAssertNotNil(remote);
}
```

### Integration Test: Round-Trip IPC

```objectivec
- (void)testMenuActionCallback {
    // Register client
    [theme _ensureMenuClientRegistered];
    
    // Simulate Menu.app connecting back
    NSConnection *conn = [NSConnection connectionWithRegisteredName:clientName host:nil];
    id<GSGNUstepMenuClient> proxy = [conn rootProxy];
    [proxy setProtocolForProxy:@protocol(GSGNUstepMenuClient)];
    
    // Invoke callback
    [proxy activateMenuItemAtPath:@[@1, @0] forWindow:@(windowId)];
    
    // Wait for async processing
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
    
    // Verify action was called
    XCTAssertTrue(actionWasCalled);
}
```

### Manual Test: Watch Logs

```bash
# Terminal 1: Menu.app with logging
cd /path/to/Menu && ./Menu.app/Menu 2>&1 | grep -E "GNUStep|performMenuAction"

# Terminal 2: Application with logging  
cd /path/to/App && ./App 2>&1 | grep -E "Eau:|activateMenuItemAtPath"

# Terminal 3: Test tool
./test_menu_click <pid>
```

## Testing and Debugging

### Enabling Debug Logging

Set the debug macro in Eau.h:
```objectivec
// In Eau.h
#if 1  // Change to 0 to disable debug logging
#define EAULOG(args...) NSDebugLog(args)
#else
#define EAULOG(args...)
#endif
```

Watch logs with:
```bash
./app 2>&1 | grep -E "Eau:|GNUStepMenuActionHandler"
```

### Common Log Messages

**Client registration success:**
```
Eau: Registered GNUstep menu client as org.gnustep.Gershwin.MenuClient.12345 with receive port
```

**Menu update sent:**
```
Eau: Calling updateMenuForWindow on Menu.app server proxy
Eau: Successfully sent menu update to Menu.app
```

**Callback received:**
```
Eau: activateMenuItemAtPath called - indexPath: (1, 0), windowId: 1234567
```

**Action dispatched:**
```
Eau: sendAction returned YES for menu item 'Open'
```

## References

- GNUstep Base Documentation: NSConnection, NSPort, NSDistantObject
- GNUstep GUI Documentation: GSTheme, NSMenu architecture
- POSIX IPC: domain sockets, named pipes, message queues
- Actual Implementations:
  - [GNUStepMenuIPC.h](gershwin-components/Menu/GNUStepMenuIPC.h) - Protocol definitions
  - [Eau.h](gershwin-eau-theme/Eau.h) - Client interface and protocol conformance
  - [Eau.m](gershwin-eau-theme/Eau.m) - Client implementation
  - [GNUStepMenuActionHandler.m](gershwin-components/Menu/GNUStepMenuActionHandler.m) - Server implementation