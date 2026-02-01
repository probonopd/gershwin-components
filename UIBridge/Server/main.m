/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import "../Common/UIBridgeProtocol.h"
#import "X11Support.h"
#import "LLDBController.h"
#import <sys/select.h>
#import <unistd.h>

// Simple JSON helper
static id ParseJSON(NSString *input) {
    if (!input) return nil;
    NSData *data = [input dataUsingEncoding:NSUTF8StringEncoding];
    NSError *error = nil;
    if (!data) return nil;
    return [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
}

static void SendJSON(id obj) {
    if (!obj) return;
    @try {
        NSError *error = nil;
        NSData *data = [NSJSONSerialization dataWithJSONObject:obj options:0 error:&error];
        if (data) {
            NSLog(@"[Server] Serialized JSON successfully, length: %lu", (unsigned long)[data length]);
            // Log raw JSON for debugging (truncated to 16k to avoid noisy logs)
            NSString *jsonStr = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            if (jsonStr) {
                NSString *trunc = ([jsonStr length] > 16384) ? [jsonStr substringToIndex:16384] : jsonStr;
                NSLog(@"[Server] RAW_JSON: %@", trunc);
                [jsonStr release];
            } else {
                NSLog(@"[Server] RAW_JSON: <non-utf8 bytes, length=%lu>", (unsigned long)[data length]);
            }
            NSFileHandle *stdoutHandle = [NSFileHandle fileHandleWithStandardOutput];
            [stdoutHandle writeData:data];
            [stdoutHandle writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
            [stdoutHandle synchronizeFile];
            NSLog(@"[Server] Sent JSON to stdout.");
        } else {
            NSLog(@"[Server] JSON Serialization failed: %@", error);
        }
    } @catch (NSException *e) {
        NSLog(@"[Server] EXCEPTION in SendJSON: %@", e);
    }
}
// --- Static helper functions (must be at file scope) ---

// Connect to app via Distributed Objects (DO) - Theme service via DO by default
static id<UIBridgeProtocol> ConnectToApp(int pid) {
    id proxy = nil;
    
    // Try to connect to per-PID theme UIBridge service using Distributed Objects (DO)
    // This is the preferred method - works directly with Eau theme
    if (pid > 0) {
      NSString *themeServiceName = [NSString stringWithFormat:@"org.gershwin.Gershwin.Theme.UIBridge.%d", pid];
      NSLog(@"[Server] Connecting to per-PID theme UIBridge service via DO: %@", themeServiceName);
      proxy = [NSConnection rootProxyForConnectionWithRegisteredName:themeServiceName host:nil];
      if (proxy) {
        [(NSDistantObject *)proxy setProtocolForProxy:@protocol(UIBridgeProtocol)];
        NSConnection *conn = [proxy connectionForProxy];
        [conn setRequestTimeout:2.0];
        [conn setReplyTimeout:2.0];
        [conn enableMultipleThreads];
        NSLog(@"[Server] Successfully connected to theme service via DO: %@", themeServiceName);
        return proxy;
      } else {
        NSLog(@"[Server] Theme service not available via DO: %@", themeServiceName);
      }
    }

    // Fallback: scan running PIDs for any running theme DO services
    // Note: NSFileManager contentsOfDirectoryAtPath doesn't work reliably on /proc (esp. on FreeBSD)
    // Use ps command to get PID list portably
    NSLog(@"[Server] Scanning PIDs via ps for theme services via DO as fallback");
    
    NSTask *psTask = [[NSTask alloc] init];
    [psTask setLaunchPath:@"/bin/ps"];
    [psTask setArguments:@[@"-axo", @"pid="]];
    NSPipe *pipe = [NSPipe pipe];
    [psTask setStandardOutput:pipe];
    [psTask setStandardError:[NSFileHandle fileHandleWithNullDevice]];
    
    @try {
        [psTask launch];
        [psTask waitUntilExit];
    } @catch (NSException *e) {
        NSLog(@"[Server] Failed to run ps: %@", e);
        [psTask release];
        return nil;
    }
    
    NSData *psData = [[pipe fileHandleForReading] readDataToEndOfFile];
    [psTask release];
    
    NSString *psOutput = [[NSString alloc] initWithData:psData encoding:NSUTF8StringEncoding];
    NSArray *lines = [psOutput componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    [psOutput release];
    
    for (NSString *line in lines) {
      NSString *entry = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
      if ([entry length] == 0) continue;
      
      // Verify it's a numeric PID
      NSCharacterSet *digits = [NSCharacterSet decimalDigitCharacterSet];
      if ([entry rangeOfCharacterFromSet:[digits invertedSet]].location != NSNotFound) continue;
      
      // Try per-PID theme service via DO
      NSString *themeServiceName = [NSString stringWithFormat:@"org.gershwin.Gershwin.Theme.UIBridge.%@", entry];
      proxy = [NSConnection rootProxyForConnectionWithRegisteredName:themeServiceName host:nil];
      if (proxy) {
        NSLog(@"[Server] Found per-PID theme service via fallback: %@", themeServiceName);
        [(NSDistantObject *)proxy setProtocolForProxy:@protocol(UIBridgeProtocol)];
        NSConnection *conn = [proxy connectionForProxy];
        [conn setRequestTimeout:2.0];
        [conn setReplyTimeout:2.0];
        [conn enableMultipleThreads];
        return proxy;
      }
    }

    return nil;
}

// Launch a GNUstep application
// Apps should be built with Eau theme for UIBridge support via DO
static int LaunchApp(NSString *appPath) {
    NSTask *task = [[NSTask alloc] init];
    NSString *appName = [[appPath lastPathComponent] stringByDeletingPathExtension];
    NSString *executable = [appPath stringByAppendingPathComponent:appName];
    [task setLaunchPath:executable];

    // Environment setup
    NSMutableDictionary *env = [[[NSProcessInfo processInfo] environment] mutableCopy];
    
    // Applications with Eau theme register their UIBridge service automatically via DO
    
    // Handle special cases (e.g., CreateLiveMediaAssistant that uses sudo relaunch)
    NSString *appNameLower = [appName lowercaseString];
    if ([appNameLower isEqualToString:@"createlivemediaassistant"]) {
        env[@"CLM_SKIP_SUDO"] = @"1";
        NSLog(@"[Server] Setting CLM_SKIP_SUDO=1 for CreateLiveMediaAssistant");
    }

    [task setEnvironment:env];
    [env release];

    // Redirect child output to a log file to avoid corrupting the MCP pipe on stdout
    NSString *logPath = [NSString stringWithFormat:@"/tmp/%@.log", appName];
    [[NSFileManager defaultManager] removeItemAtPath:logPath error:nil];
    [[NSFileManager defaultManager] createFileAtPath:logPath contents:nil attributes:nil];
    NSFileHandle *logHandle = [NSFileHandle fileHandleForWritingAtPath:logPath];
    if (logHandle) {
        [task setStandardOutput:logHandle];
        [task setStandardError:logHandle];
        NSLog(@"[Server] App output redirected to %@", logPath);
    } else {
        [task setStandardOutput:[NSFileHandle fileHandleWithNullDevice]];
        [task setStandardError:[NSFileHandle fileHandleWithNullDevice]];
    }

    [task launch];

    int pid = [task processIdentifier];
    NSLog(@"[Server] Launched app '%@' with PID %d", appName, pid);
    NSLog(@"[Server] App should register its UIBridge service via Distributed Objects (DO) if it uses Eau theme");

    [task release];
    return pid;
}

static void RedirectLogs(void) {
    const char *logPath = "/tmp/uibridge.log";
    freopen(logPath, "a", stderr);
    NSLog(@"[Server] --- UIBridge Server Session Start ---");
}



@interface BridgeServer : NSObject
@property (assign) int currentPID;
@property (assign) BOOL isWatching;
@property (retain) NSDictionary *lastFullTree;
- (void)checkInput:(NSTimer *)timer;
- (void)watchLoop:(NSTimer *)timer;
- (id)findObjectInTree:(id)node class:(NSString *)cls title:(NSString *)title tag:(NSNumber *)tag;
@end

@implementation BridgeServer
@synthesize currentPID, isWatching, lastFullTree;

- (void)dealloc {
    [lastFullTree release];
    [super dealloc];
}

- (void)watchLoop:(NSTimer *)timer {
    if (!self.isWatching || self.currentPID == 0) return;
    
    NSLog(@"[Server] watchLoop firing for PID %d", self.currentPID);
    id<UIBridgeProtocol> app = ConnectToApp(self.currentPID);
    if (!app) {
        NSLog(@"[Server] watchLoop: failed to connect to app via DO");
        return;
    }
    
    @try {
        NSString *treeJSON = [app fullTreeForObjectJSON:nil];
        if (!treeJSON) {
            NSLog(@"[Server] watchLoop: app returned nil tree");
            return;
        }
        NSDictionary *newTree = ParseJSON(treeJSON);
        if (!newTree) {
            NSLog(@"[Server] watchLoop: failed to parse tree JSON (len: %lu)", (unsigned long)[treeJSON length]);
            return;
        }
        
        if (self.lastFullTree) {
            NSMutableArray *changes = [NSMutableArray array];
            [self diffNode:self.lastFullTree withNode:newTree path:@"" results:changes];
            
            NSLog(@"[Server] watchLoop: found %lu changes", (unsigned long)[changes count]);
            if ([changes count] > 0) {
                 NSDictionary *notification = @{
                     @"jsonrpc": @"2.0",
                     @"method": @"notifications/ui_event",
                     @"params": @{
                         @"events": changes
                     }
                 };
                 SendJSON(notification);
            }
        }
        
        self.lastFullTree = newTree;

    } @catch (NSException *e) {
        NSLog(@"[Server] Exception in watchLoop: %@", e);
    }
}

- (void)diffNode:(NSDictionary *)oldNode withNode:(NSDictionary *)newNode path:(NSString *)path results:(NSMutableArray *)results {
    NSString *objID = newNode[@"object_id"];
    NSString *cls = newNode[@"class"];
    
    // Check basic props
    NSArray *props = @[@"enabled", @"hidden", @"title", @"string", @"frame"];
    for (NSString *p in props) {
        id oldVal = oldNode[p];
        id newVal = newNode[p];
        if (newVal && ![newVal isEqual:oldVal]) {
            [results addObject:@{
                @"type": @"property_change",
                @"object_id": objID,
                @"class": cls,
                @"property": p,
                @"old": oldVal ?: [NSNull null],
                @"new": newVal
            }];
        }
    }
    
    // Check windows (if root)
    if (newNode[@"windows"]) {
        NSArray *oldWins = oldNode[@"windows"] ?: @[];
        NSArray *newWins = newNode[@"windows"] ?: @[];
        [self diffCollection:oldWins new:newWins parentPath:path type:@"window" results:results];
    }
    
    // Check subviews
    if (newNode[@"subviews"]) {
        NSArray *oldViews = oldNode[@"subviews"] ?: @[];
        NSArray *newViews = newNode[@"subviews"] ?: @[];
        [self diffCollection:oldViews new:newViews parentPath:path type:@"view" results:results];
    }
    
    // Recurse subviews by matching object_ids
    if (newNode[@"subviews"] && oldNode[@"subviews"]) {
        for (NSDictionary *newSub in newNode[@"subviews"]) {
            NSString *sid = newSub[@"object_id"];
            for (NSDictionary *oldSub in oldNode[@"subviews"]) {
                if ([oldSub[@"object_id"] isEqualToString:sid]) {
                    [self diffNode:oldSub withNode:newSub path:[path stringByAppendingFormat:@"/%@", sid] results:results];
                    break;
                }
            }
        }
    }
    
    // Recurse windows
    if (newNode[@"windows"] && oldNode[@"windows"]) {
        for (NSDictionary *newWin in newNode[@"windows"]) {
            NSString *wid = newWin[@"object_id"];
            for (NSDictionary *oldWin in oldNode[@"windows"]) {
                if ([oldWin[@"object_id"] isEqualToString:wid]) {
                    [self diffNode:oldWin withNode:newWin path:[path stringByAppendingFormat:@"/%@", wid] results:results];
                    break;
                }
            }
        }
    }

    // Recurse contentView
    if (newNode[@"contentView"] && oldNode[@"contentView"]) {
        [self diffNode:oldNode[@"contentView"] withNode:newNode[@"contentView"] path:[path stringByAppendingString:@"/contentView"] results:results];
    }
}

- (void)diffCollection:(NSArray *)oldArr new:(NSArray *)newArr parentPath:(NSString *)path type:(NSString *)type results:(NSMutableArray *)results {
    NSMutableSet *oldIDs = [NSMutableSet set];
    for (NSDictionary *d in oldArr) [oldIDs addObject:d[@"object_id"]];
    
    NSMutableSet *newIDs = [NSMutableSet set];
    for (NSDictionary *d in newArr) [newIDs addObject:d[@"object_id"]];
    
    // New items
    for (NSDictionary *d in newArr) {
        if (![oldIDs containsObject:d[@"object_id"]]) {
            [results addObject:@{
                @"type": [NSString stringWithFormat:@"%@_added", type],
                @"object": d
            }];
        }
    }
    
    // Removed items
    for (NSDictionary *d in oldArr) {
        if (![newIDs containsObject:d[@"object_id"]]) {
            [results addObject:@{
                @"type": [NSString stringWithFormat:@"%@_removed", type],
                @"object_id": d[@"object_id"],
                @"class": d[@"class"],
                @"title": d[@"title"] ?: @""
            }];
        }
    }
}

- (id)findObjectInTree:(id)node class:(NSString *)cls title:(NSString *)title tag:(NSNumber *)tag {
    if (![node isKindOfClass:[NSDictionary class]]) return nil;
    
    BOOL match = YES;
    if (cls && [node[@"class"] rangeOfString:cls options:NSCaseInsensitiveSearch].location == NSNotFound) match = NO;
    if (tag && (!node[@"tag"] || ![node[@"tag"] isEqual:tag])) match = NO;
    if (title) {
        NSString *nodeTitle = node[@"title"] ?: node[@"string"];
        if (!nodeTitle || [nodeTitle rangeOfString:title options:NSCaseInsensitiveSearch].location == NSNotFound) match = NO;
    }
    
    if (match && (cls || title || tag)) return node;
    
    // Recurse subviews
    for (id sub in node[@"subviews"]) {
        id found = [self findObjectInTree:sub class:cls title:title tag:tag];
        if (found) return found;
    }
    // Recurse windows if node is root
    for (id win in node[@"windows"]) {
        id found = [self findObjectInTree:win class:cls title:title tag:tag];
        if (found) return found;
    }
    // Recurse contentView
    if (node[@"contentView"]) {
        id found = [self findObjectInTree:node[@"contentView"] class:cls title:title tag:tag];
        if (found) return found;
    }
    
    return nil;
}

- (void)findWidgetsInTree:(id)node class:(NSString *)cls text:(NSString *)text tag:(NSNumber *)tag visibleOnly:(BOOL)visibleOnly into:(NSMutableArray *)results {
    if (![node isKindOfClass:[NSDictionary class]]) return;
    
    if (visibleOnly && [node[@"hidden"] boolValue]) return;
    
    BOOL match = YES;
    if (cls && [node[@"class"] rangeOfString:cls options:NSCaseInsensitiveSearch].location == NSNotFound) match = NO;
    if (tag && (!node[@"tag"] || ![node[@"tag"] isEqual:tag])) match = NO;
    if (text) {
        NSString *nodeTitle = node[@"title"] ?: node[@"string"];
        if (!nodeTitle || [nodeTitle rangeOfString:text options:NSCaseInsensitiveSearch].location == NSNotFound) match = NO;
    }
    
    if (match && (cls || text || tag)) {
        [results addObject:node];
    }
    
    // Recurse
    for (id sub in node[@"subviews"]) [self findWidgetsInTree:sub class:cls text:text tag:tag visibleOnly:visibleOnly into:results];
    for (id win in node[@"windows"]) [self findWidgetsInTree:win class:cls text:text tag:tag visibleOnly:visibleOnly into:results];
    if (node[@"contentView"]) [self findWidgetsInTree:node[@"contentView"] class:cls text:text tag:tag visibleOnly:visibleOnly into:results];
}

- (id)widgetAtPoint:(NSPoint)p inTree:(id)node {
    if (![node isKindOfClass:[NSDictionary class]]) return nil;
    if ([node[@"hidden"] boolValue]) return nil;
    
    NSString *frameStr = node[@"screen_frame"];
    if (frameStr) {
        NSRect r = NSRectFromString(frameStr);
        if (NSPointInRect(p, r)) {
            // Check sub-elements first for innermost match
            for (id sub in node[@"subviews"]) {
                id found = [self widgetAtPoint:p inTree:sub];
                if (found) return found;
            }
            if (node[@"contentView"]) {
                id found = [self widgetAtPoint:p inTree:node[@"contentView"]];
                if (found) return found;
            }
            for (id win in node[@"windows"]) {
                id found = [self widgetAtPoint:p inTree:win];
                if (found) return found;
            }
            return node;
        }
    }
    return nil;
}

- (void)checkInput:(NSTimer *)timer {
    NSFileHandle *stdinHandle = [NSFileHandle fileHandleWithStandardInput];
    int fd = [stdinHandle fileDescriptor];
    static BOOL hadData = NO;
    
    // Use select to check if data is available without blocking the runloop
    fd_set set;
    struct timeval tv;
    FD_ZERO(&set);
    FD_SET(fd, &set);
    tv.tv_sec = 0;
    tv.tv_usec = 0;
    
    if (select(fd + 1, &set, NULL, NULL, &tv) > 0) {
        NSData *data = [stdinHandle availableData];
        if ([data length] > 0) {
            hadData = YES;
            NSString *chunk = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            NSLog(@"[Server] Read chunk: %@", chunk);
            NSArray *lines = [chunk componentsSeparatedByString:@"\n"];
            
            for (NSString *line in lines) {
                NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if ([trimmed length] == 0) continue;
                
                NSDictionary *json = ParseJSON(trimmed);
                if (!json) continue;
                
                [self processRequest:json];
            }
            [chunk release];
        } else if (hadData) {
            NSLog(@"[Server] EOF reached on stdin after data; continuing to run.");
            hadData = NO;
        }
    }
}

- (void)processRequest:(NSDictionary *)json {
    id reqID = json[@"id"];
    NSString *method = json[@"method"];
    NSDictionary *params = json[@"params"];

    NSLog(@"[Server] Processing request: method=%@, id=%@", method, reqID);

    id result = nil;
    NSString *errorMsg = nil;
    int errorCode = -32603;
    BOOL hasError = NO;

    @try {
        if (!method || !reqID) {
            hasError = YES;
            errorMsg = @"Invalid Request: missing 'method' or 'id'";
            errorCode = -32600;
        } else if ([method isEqualToString:@"initialize"]) {
        result = @{
            @"protocolVersion": params[@"protocolVersion"] ?: @"2024-11-05",
            @"capabilities": @{
                @"tools": @{},
                @"resources": @{},
                @"prompts": @{}
            },
            @"serverInfo": @{
                @"name": @"uibridge", 
                @"version": @"1.4.0",
                @"description": @"UIBridge is a comprehensive automation and introspection server for GNUstep applications. It features high-performance UI tree recursion with absolute screen coordinate tracking, autonomous real-time UI logging (when enabled), and real-time 'watch' notifications for state changes. It provides intelligent widget discovery (regex matching, tag/coordinate lookup) and robust X11 input simulation. Designed for end-to-end GUI testing, accessibility auditing, layout analysis, and fully autonomous task execution even during modal alert sessions."
            }
        };
    } else if ([method isEqualToString:@"tools/list"] || [method isEqualToString:@"list_tools"]) {
        // Canonical MCP structure for tools: wrap success in content schema
        id contentSchema = @{
            @"type": @"object",
            @"properties": @{
                @"content": @{
                    @"type": @"array",
                    @"items": @{
                        @"type": @"object",
                        @"properties": @{
                            @"type": @{@"type": @"string", @"enum": @[@"json", @"text"]},
                            @"json": @{@"type": @"object"},
                            @"text": @{@"type": @"string"}
                        }
                    }
                }
            }
        };

        result = @{
            @"tools": @[
                @{@"name": @"launch_app", @"description": @"Launches a GNUstep application. The application will automatically register its UIBridge service via Distributed Objects if it uses the Eau theme.", @"inputSchema": @{@"type": @"object", @"properties": @{@"app_path": @{@"type": @"string", @"description": @"The absolute path to the .app bundle or its binary executable."}}}, @"outputSchema": contentSchema},
                @{@"name": @"list_apps", @"description": @"Scans standard GNUstep application directories and returns a list of installed applications. Use this to discover which apps are available to be launched and tested on the current system.", @"inputSchema": @{@"type": @"object", @"properties": @{}}, @"outputSchema": contentSchema},
                @{@"name": @"list_running_apps", @"description": @"Scans running processes for GNUstep applications that have registered an Eau theme UIBridge service via Distributed Objects and returns their PID, service name, and optional metadata (app name, preview). Use this to discover already-launched apps to attach to.", @"inputSchema": @{@"type": @"object", @"properties": @{}}, @"outputSchema": contentSchema},
                @{@"name": @"attach_app", @"description": @"Attach UIBridge to an already-running GNUstep application by PID or service name. Provide either 'pid' (integer) or 'service_name' (string). On success the server's currentPID is set to the attached app's PID.", @"inputSchema": @{@"type": @"object", @"properties": @{@"pid": @{@"type": @"integer"}, @"service_name": @{@"type": @"string"}}}, @"outputSchema": contentSchema},
                @{@"name": @"list_files", @"description": @"Lists files in a given directory path. Useful for exploring application resources, data bundles, or confirming the presence of specifically required files before or during testing.", @"inputSchema": @{@"type": @"object", @"properties": @{@"path": @{@"type": @"string", @"description": @"The directory path to list."}}}, @"outputSchema": contentSchema},
                @{@"name": @"read_file_content", @"description": @"Reads the full text content of a file. Use this to inspect configuration files, logs, or other text-based data within the application's environment.", @"inputSchema": @{@"type": @"object", @"properties": @{@"path": @{@"type": @"string", @"description": @"The path to the file to read."}}}, @"outputSchema": contentSchema},
                @{@"name": @"get_root", @"description": @"Retrieves the entry-level Objective-C objects for the currently running app: the NSApp instance and a list of all top-level windows. This provides the starting point for exploring the UI widget tree and application-wide state.", @"inputSchema": @{@"type": @"object", @"properties": @{}}, @"outputSchema": contentSchema},
                @{@"name": @"get_object_details", @"description": @"Fetches comprehensive details about a specific Objective-C object within the target application. Returns its class name, window context, frame (relative), window_frame (relative to window), and screen_frame (absolute). Also lists direct child components. Essential for verifying widget state and position.", @"inputSchema": @{@"type": @"object", @"properties": @{@"object_id": @{@"type": @"string", @"description": @"The unique object identifier (e.g., 'objc:0x...') returned by other tools."}}}, @"outputSchema": contentSchema},
                @{@"name": @"get_full_tree", @"description": @"Recursively fetches the entire UI hierarchy starting from a specific object, or the whole app if no ID is provided. Each object in the tree includes 'frame' (relative), 'window_frame' (relative to window root), and 'screen_frame' (absolute screen coordinates). Use this sparingly for large apps; prefer using the watch stream (notifications/ui_event) for rapid state checks.", @"inputSchema": @{@"type": @"object", @"properties": @{@"object_id": @{@"type": @"string", @"description": @"Optional object identifier to start from. If omitted, starts from NSApp."}}}, @"outputSchema": contentSchema},
                @{@"name": @"find_widgets", @"description": @"Scans the UI tree for all widgets matching specific criteria. Now supports searching by 'tag'. This tool works even when modal alerts are active. If you can't find a button you expect (like 'Save'), ensure you've checked recent watch notifications (notifications/ui_event) for the alert's window.", @"inputSchema": @{@"type": @"object", @"properties": @{@"class": @{@"type": @"string", @"description": @"Class name to match (partial matches ok)."}, @"text": @{@"type": @"string", @"description": @"Text or title content to match (supports regex)."}, @"tag": @{@"type": @"integer", @"description": @"Tag value to match."}, @"visible_only": @{@"type": @"boolean", @"description": @"If true, only returns widgets that are not hidden."}}}, @"outputSchema": contentSchema},
                @{@"name": @"get_widget_at", @"description": @"Identifies the UI widget located at the specified absolute screen coordinates (x, y). Useful for mapping X11 events back to Objective-C objects.", @"inputSchema": @{@"type": @"object", @"properties": @{@"x": @{@"type": @"integer", @"description": @"X screen coordinate."}, @"y": @{@"type": @"integer", @"description": @"Y screen coordinate."}}}, @"outputSchema": contentSchema},
                @{@"name": @"watch_app", @"description": @"Starts or stops a live stream of UI changes. When enabled, the server will emit JSON-RPC notifications ('notifications/ui_event') whenever windows are opened/closed, widgets are added/removed, or properties change. Note: Optional autonomous file logging (when enabled) runs independently of this setting.", @"inputSchema": @{@"type": @"object", @"properties": @{@"enabled": @{@"type": @"boolean", @"description": @"Set to true to start watching, false to stop."}}}, @"outputSchema": contentSchema},
                @{@"name": @"wait_for_text", @"description": @"A specialized version of wait_for_object that polls the entire application until the specified text appears. This tool is modal-resilient and will continue to work while alerts or save panels are open.", @"inputSchema": @{@"type": @"object", @"properties": @{@"text": @{@"type": @"string", @"description": @"The text string to wait for."}, @"timeout": @{@"type": @"integer", @"description": @"Maximum time to wait in seconds. Defaults to 10."}}}, @"outputSchema": contentSchema},
                @{@"name": @"wait_for_object", @"description": @"Polls the application until an object matching the specified class and/or title appears. Modal-resilient: safely waits for alerts or sub-windows that block the main event loop.", @"inputSchema": @{@"type": @"object", @"properties": @{@"class": @{@"type": @"string", @"description": @"The class name to look for (e.g., 'NSWindow', 'TextView')."}, @"title": @{@"type": @"string", @"description": @"The title or string content to match (supports partial matching)."}, @"timeout": @{@"type": @"integer", @"description": @"Maximum time to wait in seconds. Defaults to 10."}}}, @"outputSchema": contentSchema},
                @{@"name": @"invoke_selector", @"description": @"Dynamically calls an Objective-C selector (method) on a remote object in the target application. This allows directly manipulating application state, triggering internal workflows, or simulating events at the model/controller level. Support passing an array of primitive arguments.", @"inputSchema": @{@"type": @"object", @"properties": @{@"object_id": @{@"type": @"string", @"description": @"The object identifier to call the method on."}, @"selector": @{@"type": @"string", @"description": @"The Objective-C selector name (e.g., 'setTitle:')."}, @"args": @{@"type": @"array", @"description": @"Optional array of arguments to pass to the method.", @"items": @{}}}}, @"outputSchema": contentSchema},
                // Menu Tools
                @{@"name": @"list_menus", @"description": @"Provides a hierarchical view of the application's entire menu system. Use this to identify available actions and find the object_id of menu items for goal-oriented automation.", @"inputSchema": @{@"type": @"object", @"properties": @{}}, @"outputSchema": contentSchema},
                @{@"name": @"invoke_menu_item", @"description": @"Triggers the action associated with a specific menu item via its object_id. This is the preferred way to automate menu-driven interactions (e.g., 'File' -> 'Open') in the application.", @"inputSchema": @{@"type": @"object", @"properties": @{@"object_id": @{@"type": @"string", @"description": @"The object identifier of the NSMenuItem to invoke."}}}, @"outputSchema": contentSchema},
                // X11 Tools
                @{@"name": @"x11_list_windows", @"description": @"Returns a low-level list of all X11 window IDs currently managed by the X server. Useful for cross-referencing GNUstep window objects with OS-level window management or debugging window positioning.", @"inputSchema": @{@"type": @"object", @"properties": @{}}, @"outputSchema": contentSchema},
                @{@"name": @"x11_window_info", @"description": @"Gets detailed geometric and metadata information for a specific X11 window. Use this for precise coordinate-based input automation when internal Object-C inspection is not enough.", @"inputSchema": @{@"type": @"object", @"properties": @{@"xid": @{@"type": @"integer", @"description": @"The X11 window ID."}}}, @"outputSchema": contentSchema},
                @{@"name": @"x11_mouse_move", @"description": @"Moves the system mouse cursor to the specified screen coordinates. Can be combined with x11_click for raw input automation tasks.", @"inputSchema": @{@"type": @"object", @"properties": @{@"x": @{@"type": @"integer", @"description": @"The X screen coordinate."}, @"y": @{@"type": @"integer", @"description": @"The Y screen coordinate."}}}, @"outputSchema": contentSchema},
                @{@"name": @"x11_click", @"description": @"Simulates a hardware mouse button click at the current cursor position. Works for both system-level and application-level widgets.", @"inputSchema": @{@"type": @"object", @"properties": @{@"button": @{@"type": @"integer", @"description": @"The mouse button to click: 1=Left, 2=Middle, 3=Right."}}}, @"outputSchema": contentSchema},
                @{@"name": @"x11_type", @"description": @"Simulates typing a UTF-8 string into the currently focused window. Useful for automating text entry in fields where direct Objective-C manipulation is not desired or to test actual keyboard event handling.", @"inputSchema": @{@"type": @"object", @"properties": @{@"text": @{@"type": @"string", @"description": @"The text string to type."}}}, @"outputSchema": contentSchema},
                // LLDB Tools
                @{@"name": @"lldb_exec", @"description": @"Executes an arbitrary LLDB command against the target application while the debugger is attached. This provides the most powerful inspection and modification capabilities, including memory scanning, breakpoint management, and backtrace inspection. Note: this may briefly pause the application execution.", @"inputSchema": @{@"type": @"object", @"properties": @{@"command": @{@"type": @"string", @"description": @"The LLDB command to execute."}}}, @"outputSchema": contentSchema}
            ]
        };
    } else if ([method isEqualToString:@"resources/list"] || [method isEqualToString:@"list_resources"]) {
        result = @{@"resources": @[]};
    } else if ([method isEqualToString:@"prompts/list"] || [method isEqualToString:@"list_prompts"]) {
        result = @{@"prompts": @[
            @{
                @"name": @"inspect_ui",
                @"description": @"Expert guide for inspecting a GNUstep application's UI hierarchy and discovering details about its buttons, views, and windows.",
                @"arguments": @[
                    @{@"name": @"app_path", @"description": @"Absolute path to the .app bundle to inspect", @"required": @YES}
                ]
            },
            @{
                @"name": @"automate_task",
                @"description": @"Step-by-step assistant for automating a complex task within a GNUstep application using UIBridge tools.",
                @"arguments": @[
                    @{@"name": @"task_description", @"description": @"Detailed description of the task to automate (e.g., 'Open TextEdit and type Hello World')", @"required": @YES}
                ]
            },
            @{
                @"name": @"debug_ui_flow",
                @"description": @"Expert assistant for debugging UI flows, specifically for handling modal alerts or save dialogs that appear during automation. Tracks live UI events (via the watch stream) to see buttons and text in modal windows as they appear.",
                @"arguments": @[
                    @{@"name": @"app_path", @"description": @"Absolute path to the .app bundle to debug", @"required": @YES}
                ]
            },
            @{
                @"name": @"test_layout",
                @"description": @"Expert assistant for analyzing UI layout, detecting overlapping widgets, or verifying alignment and visibility of controls using absolute screen coordinates.",
                @"arguments": @[
                    @{@"name": @"app_path", @"description": @"Absolute path to the .app bundle to test", @"required": @YES}
                ]
            }
        ]};
    } else if ([method isEqualToString:@"prompts/get"] || [method isEqualToString:@"get_prompt"]) {
        NSString *name = params[@"name"];
        if ([name isEqualToString:@"inspect_ui"]) {
            NSString *appPath = params[@"arguments"][@"app_path"];
            result = @{
                @"description": @"UI Inspection Guide",
                @"messages": @[
                    @{
                        @"role": @"user",
                        @"content": @{
                            @"type": @"text",
                            @"text": [NSString stringWithFormat:@"I want to inspect the UI of the application at %@. Please start by launching it, then list its windows and browse the root objects to give me an overview of its widget tree.", appPath]
                        }
                    }
                ]
            };
        } else if ([name isEqualToString:@"automate_task"]) {
            NSString *task = params[@"arguments"][@"task_description"];
            result = @{
                @"description": @"Task Automation Assistant",
                @"messages": @[
                    @{
                        @"role": @"user",
                        @"content": @{
                            @"type": @"text",
                            @"text": [NSString stringWithFormat:@"I need to automate the following task: '%@'. Please analyze the application's menus and UI objects to find the best way to achieve this using UIBridge tools.", task]
                        }
                    }
                ]
            };
        } else if ([name isEqualToString:@"test_layout"]) {
            NSString *appPath = params[@"arguments"][@"app_path"];
            result = @{
                @"description": @"Layout Testing Assistant",
                @"messages": @[
                    @{
                        @"role": @"user",
                        @"content": @{
                            @"type": @"text",
                            @"text": [NSString stringWithFormat:@"I want to test the UI layout of the application at %@. Please launch it and use 'get_full_tree' to retrieve absolute screen coordinates for all widgets. Then, analyze the frames to check for any overlapping elements or controls that are clipped or off-screen.", appPath]
                        }
                    }
                ]
            };
        } else {
            errorMsg = @"Prompt not found";
        }
    } else if ([method isEqualToString:@"notifications/initialized"]) {
        // Notification, no result needed
        return;
    } else {
        // Handle tool calls which might come wrapped in tools/call
        NSDictionary *callParams = params;
        NSString *toolName = method;
        
        if ([method isEqualToString:@"tools/call"]) {
            toolName = params[@"name"];
            callParams = params[@"arguments"];
        }
        
        if ([toolName isEqualToString:@"launch_app"]) {
            NSString *path = callParams[@"app_path"];
            if (path) {
                self.currentPID = LaunchApp(path);
                if (self.currentPID > 0) {
                    // Automatically enable watch when a new app is launched
                    self.isWatching = YES;
                    result = @{
                        @"pid": @(self.currentPID), 
                        @"status": @"launched",
                        @"observation": @"Application launched. You can monitor progress via logs in /tmp or wait for 'notifications/ui_event'."
                    };
                } else {
                     errorMsg = @"Failed to launch";
                }
            } else {
                errorMsg = @"Missing app_path";
            }
        } else if ([toolName isEqualToString:@"list_apps"]) {
            NSFileManager *fm = [NSFileManager defaultManager];
            NSArray *domainPaths = NSSearchPathForDirectoriesInDomains(NSAllApplicationsDirectory, NSAllDomainsMask, YES);
            NSMutableArray *paths = [NSMutableArray arrayWithArray:domainPaths];
            
            // Add some likely Gershwin locations if not already there
            NSArray *extras = @[@"/System/Applications", @"/Local/Applications", @"/Network/Applications", [NSHomeDirectory() stringByAppendingPathComponent:@"Applications"]];
            for (NSString *ext in extras) {
                if (![paths containsObject:ext]) {
                    [paths addObject:ext];
                }
            }

            NSLog(@"[Server] Searching for apps in: %@", paths);
            NSMutableArray *apps = [NSMutableArray array];
            for (NSString *path in paths) {
                NSError *error = nil;
                NSArray *contents = [fm contentsOfDirectoryAtPath:path error:&error];
                if (contents) {
                    for (NSString *item in contents) {
                        if ([item hasSuffix:@".app"]) {
                            NSString *fullPath = [path stringByAppendingPathComponent:item];
                            NSString *executable = [item stringByDeletingPathExtension];
                            NSString *execPath = [[fullPath stringByAppendingPathComponent:executable] stringByStandardizingPath];
                            
                            // Check if executable exists, if not, it might not be a valid app bundle for our terms
                            if ([fm isExecutableFileAtPath:execPath]) {
                                [apps addObject:@{@"name": item, @"path": fullPath, @"executable": execPath}];
                            } else {
                                // Try looking inside (maybe it's a newer layout or something)
                                NSLog(@"[Server] App candidate has no top-level executable: %@", fullPath);
                            }
                        }
                    }
                }
            }
            result = @{@"apps": apps};
        } else if ([toolName isEqualToString:@"list_running_apps"]) {
            NSMutableArray *found = [NSMutableArray array];
            NSTask *psTask = [[NSTask alloc] init];
            [psTask setLaunchPath:@"/bin/ps"];
            [psTask setArguments:@[@"-axo", @"pid="]];
            NSPipe *pipe = [NSPipe pipe];
            [psTask setStandardOutput:pipe];
            [psTask setStandardError:[NSFileHandle fileHandleWithNullDevice]];
            @try {
                [psTask launch];
                [psTask waitUntilExit];
            } @catch (NSException *e) {
                NSLog(@"[Server] Failed to run ps for list_running_apps: %@", e);
                [psTask release];
                result = @{@"apps": found};
            }

            NSData *psData = [[pipe fileHandleForReading] readDataToEndOfFile];
            [psTask release];

            NSString *psOutput = [[NSString alloc] initWithData:psData encoding:NSUTF8StringEncoding];
            NSArray *lines = [psOutput componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
            [psOutput release];

            for (NSString *line in lines) {
                NSString *entry = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                if ([entry length] == 0) continue;
                NSCharacterSet *digits = [NSCharacterSet decimalDigitCharacterSet];
                if ([entry rangeOfCharacterFromSet:[digits invertedSet]].location != NSNotFound) continue;

                NSString *themeServiceName = [NSString stringWithFormat:@"org.gershwin.Gershwin.Theme.UIBridge.%@", entry];
                id proxy = [NSConnection rootProxyForConnectionWithRegisteredName:themeServiceName host:nil];
                if (proxy) {
                    [(NSDistantObject *)proxy setProtocolForProxy:@protocol(UIBridgeProtocol)];
                    NSConnection *conn = [proxy connectionForProxy];
                    [conn setRequestTimeout:1.0];
                    [conn setReplyTimeout:1.0];
                    [conn enableMultipleThreads];

                    NSMutableDictionary *info = [NSMutableDictionary dictionary];
                    info[@"pid"] = @([entry intValue]);
                    info[@"service"] = themeServiceName;

                    NSString *commPath = [NSString stringWithFormat:@"/proc/%@/comm", entry];
                    NSError *err = nil;
                    NSString *comm = [NSString stringWithContentsOfFile:commPath encoding:NSUTF8StringEncoding error:&err];
                    if (comm) info[@"comm"] = [comm stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

                    @try {
                        NSString *rootJSON = [proxy rootObjectsJSON];
                        if ([rootJSON length] > 0) {
                            NSString *preview = [rootJSON substringToIndex:MIN((NSUInteger)256, [rootJSON length])];
                            info[@"preview"] = preview;
                        }
                    } @catch (NSException *e) {
                        // ignore failures to query the app; service presence is enough
                    }

                    [found addObject:info];
                }
            }

            result = @{@"apps": found};
        } else if ([toolName isEqualToString:@"attach_app"]) {
            NSNumber *pidNum = callParams[@"pid"];
            NSString *service = callParams[@"service_name"];
            id proxy = nil;
            int pid = 0;
            if (service) {
                proxy = [NSConnection rootProxyForConnectionWithRegisteredName:service host:nil];
                if (proxy) {
                    [(NSDistantObject *)proxy setProtocolForProxy:@protocol(UIBridgeProtocol)];
                    NSConnection *conn = [proxy connectionForProxy];
                    [conn setRequestTimeout:2.0];
                    [conn setReplyTimeout:2.0];
                    [conn enableMultipleThreads];
                    // try a light probe
                    @try {
                        [proxy rootObjectsJSON];
                    } @catch (NSException *e) {
                        proxy = nil;
                    }
                    // attempt to extract PID from service name if formatted with trailing PID
                    if (proxy && pid == 0) {
                        NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
                        NSString *digits = [[service componentsSeparatedByCharactersInSet:nonDigits] componentsJoinedByString:@""];
                        if ([digits length] > 0) pid = [digits intValue];
                    }
                }
            } else if (pidNum) {
                pid = [pidNum intValue];
                proxy = ConnectToApp(pid);
            } else {
                errorMsg = @"Missing pid or service_name";
            }
            if (proxy) {
                self.currentPID = pid;
                result = @{@"status": @"attached", @"pid": @(self.currentPID), @"service": service ?: [NSString stringWithFormat:@"org.gershwin.Gershwin.Theme.UIBridge.%d", self.currentPID]};
            } else {
                errorMsg = @"Failed to attach to service/pid";
            }
        } else if ([toolName isEqualToString:@"list_files"]) {
            NSString *path = callParams[@"path"];
            if (!path) path = @".";
            NSError *error = nil;
            NSArray *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:&error];
            if (contents) {
                result = @{@"contents": contents};
            } else {
                errorMsg = [NSString stringWithFormat:@"Failed to list directory: %@", error];
            }
        } else if ([toolName isEqualToString:@"read_file_content"]) {
            NSString *path = callParams[@"path"];
            if (path) {
                NSError *error = nil;
                NSString *content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&error];
                if (content) {
                    result = @{@"content": content};
                } else {
                    errorMsg = [NSString stringWithFormat:@"Failed to read file: %@", error];
                }
            } else {
                errorMsg = @"Missing path";
            }
        } else if ([toolName isEqualToString:@"x11_list_windows"]) {
            // Return detailed info for each X11 window: id, pid, title, geometry and app (when resolvable)
            NSArray *winIDs = [X11Support windowList];
            NSMutableArray *detailed = [NSMutableArray array];
            for (NSNumber *n in winIDs) {
                unsigned long xid = [n unsignedLongValue];
                NSDictionary *info = [X11Support windowInfo:xid];
                NSMutableDictionary *entry = [NSMutableDictionary dictionary];
                entry[@"id"] = @(xid);
                if (info) {
                    // Copy known keys and provide defaults
                    entry[@"pid"] = info[@"pid"] ?: @0;
                    entry[@"title"] = info[@"title"] ?: @"";
                    entry[@"x"] = info[@"x"] ?: @0;
                    entry[@"y"] = info[@"y"] ?: @0;
                    entry[@"width"] = info[@"width"] ?: @0;
                    entry[@"height"] = info[@"height"] ?: @0;

                    // Try to resolve application name from PID (Linux /proc)
                    NSNumber *pidNum = info[@"pid"];
                    if (pidNum && [pidNum intValue] > 0) {
                        NSString *commPath = [NSString stringWithFormat:@"/proc/%@/comm", pidNum];
                        NSError *err = nil;
                        NSString *comm = [NSString stringWithContentsOfFile:commPath encoding:NSUTF8StringEncoding error:&err];
                        if (comm) {
                            NSString *trim = [comm stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                            if ([trim length] > 0) entry[@"app"] = trim;
                        }
                    }
                }
                [detailed addObject:entry];
            }
            result = @{@"windows": detailed};
        } else if ([toolName isEqualToString:@"x11_window_info"]) {
            NSNumber *xid = callParams[@"xid"];
            if (xid) {
                NSDictionary *info = [X11Support windowInfo:[xid unsignedLongValue]];
                if (info) result = info;
                else errorMsg = @"Window not found or invalid XID";
            } else {
                errorMsg = @"Missing xid";
            }
        } else if ([toolName isEqualToString:@"x11_mouse_move"]) {
            NSNumber *x = callParams[@"x"];
            NSNumber *y = callParams[@"y"];
            if (x && y) {
                [X11Support simulateMouseMoveTo:NSMakePoint([x doubleValue], [y doubleValue])];
                result = @{@"status": @"ok"};
            } else {
                errorMsg = @"Missing x or y";
            }
        } else if ([toolName isEqualToString:@"x11_click"]) {
            NSNumber *btn = callParams[@"button"] ?: @1;
            [X11Support simulateClick:[btn intValue]];
            result = @{@"status": @"ok"};
        } else if ([toolName isEqualToString:@"x11_type"]) {
            NSString *text = callParams[@"text"];
            if (text) {
                [X11Support simulateKeyStroke:text];
                result = @{@"status": @"ok"};
            } else {
                errorMsg = @"Missing text";
            }
        } else if ([toolName isEqualToString:@"lldb_exec"]) {
            if (self.currentPID == 0) {
                errorMsg = @"No app running. Call launch_app first with the absolute path to the .app bundle.";
            } else {
                NSString *cmd = callParams[@"command"];
                if (cmd) {
                     // Warning: this is slow because it attaches/detaches every time.
                    result = @{@"output": [LLDBController runCommand:cmd forPID:self.currentPID]};
                } else {
                    errorMsg = @"Missing command";
                }
            }
        } else {
            // Try to connect to app via Distributed Objects. If currentPID is 0, ConnectToApp will scan for any available service.
            id<UIBridgeProtocol> app = ConnectToApp(self.currentPID);
            if (!app) {
                if (self.currentPID == 0) {
                    errorMsg = @"No GNUstep app detected. Launch an app using the Eau theme or call launch_app first with the absolute path to the .app bundle.";
                } else {
                    errorMsg = @"Could not connect to app via Distributed Objects - ensure app uses Eau theme";
                }
            } else {
                @try {
                    id jsonResult = nil; // may be NSString, NSData, NSDictionary, or NSArray
                    if ([toolName isEqualToString:@"get_root"]) {
                        NSLog(@"[Server] Requesting app root objects via DO...");
                        jsonResult = [app rootObjectsJSON];
                        if (!jsonResult) jsonResult = [app rootObjects];
                    } else if ([toolName isEqualToString:@"get_object_details"]) {
                        jsonResult = [app detailsForObjectJSON:callParams[@"object_id"]];
                        if (!jsonResult) jsonResult = [app detailsForObject:callParams[@"object_id"]];
                    } else if ([toolName isEqualToString:@"get_full_tree"]) {
                        jsonResult = [app fullTreeForObjectJSON:callParams[@"object_id"]];
                        if (!jsonResult) jsonResult = [app fullTreeForObject:callParams[@"object_id"]];
                    } else if ([toolName isEqualToString:@"watch_app"]) {
                        self.isWatching = [callParams[@"enabled"] boolValue];
                        if (self.isWatching) {
                            // Clear last tree so it starts fresh
                            self.lastFullTree = nil;
                            result = @{@"status": @"watching"};
                        } else {
                            result = @{@"status": @"stopped"};
                        }
                    } else if ([toolName isEqualToString:@"wait_for_object"]) {
                        NSString *cls = callParams[@"class"];
                        NSString *title = callParams[@"title"];
                        NSNumber *tag = callParams[@"tag"];
                        int timeout = [callParams[@"timeout"] ?: @10 intValue];
                        NSDate *expiry = [NSDate dateWithTimeIntervalSinceNow:timeout];
                        while ([[NSDate date] compare:expiry] == NSOrderedAscending) {
                            @try {
                                NSString *treeJSON = [app fullTreeForObjectJSON:nil];
                                id tree = ParseJSON(treeJSON);
                                id found = [self findObjectInTree:tree class:cls title:title tag:tag];
                                if (found) {
                                    result = found;
                                    break;
                                }
                            } @catch (NSException *e) {
                                NSLog(@"[Server] Exception during wait_for_object poll: %@", e);
                            }
                            [NSThread sleepForTimeInterval:0.5];
                        }
                        if (!result) {
                            errorMsg = [NSString stringWithFormat:@"Timed out waiting for object (class=%@, title=%@, tag=%@)", cls, title, tag];
                        }
                    } else if ([toolName isEqualToString:@"wait_for_text"]) {
                        NSString *text = callParams[@"text"];
                        int timeout = [callParams[@"timeout"] ?: @10 intValue];
                        NSDate *expiry = [NSDate dateWithTimeIntervalSinceNow:timeout];
                        while ([[NSDate date] compare:expiry] == NSOrderedAscending) {
                             NSString *treeJSON = [app fullTreeForObjectJSON:nil];
                             id tree = ParseJSON(treeJSON);
                             id found = [self findObjectInTree:tree class:nil title:text tag:nil];
                             if (found) {
                                 result = found;
                                 break;
                             }
                             [NSThread sleepForTimeInterval:0.5];
                        }
                        if (!result) errorMsg = [NSString stringWithFormat:@"Timed out waiting for text: %@", text];
                    } else if ([toolName isEqualToString:@"find_widgets"]) {
                        NSString *cls = callParams[@"class"];
                        NSString *text = callParams[@"text"];
                        NSNumber *tag = callParams[@"tag"];
                        BOOL visibleOnly = [callParams[@"visible_only"] ?: @NO boolValue];
                        NSString *treeJSON = [app fullTreeForObjectJSON:nil];
                        id tree = ParseJSON(treeJSON);
                        NSMutableArray *foundArr = [NSMutableArray array];
                        [self findWidgetsInTree:tree class:cls text:text tag:tag visibleOnly:visibleOnly into:foundArr];
                        result = foundArr;
                    } else if ([toolName isEqualToString:@"get_widget_at"]) {
                        int x = [callParams[@"x"] intValue];
                        int y = [callParams[@"y"] intValue];
                        NSString *treeJSON = [app fullTreeForObjectJSON:nil];
                        id tree = ParseJSON(treeJSON);
                        result = [self widgetAtPoint:NSMakePoint(x, y) inTree:tree] ?: @{};
                    } else if ([toolName isEqualToString:@"invoke_selector"]) {
                        jsonResult = [app invokeSelectorJSON:callParams[@"selector"] onObject:callParams[@"object_id"] withArgs:callParams[@"args"]];
                        if (!jsonResult) jsonResult = [app invokeSelector:callParams[@"selector"] onObject:callParams[@"object_id"] withArgs:callParams[@"args"]];
                    } else if ([toolName isEqualToString:@"list_menus"]) {
                        // Prefer JSON variant for reliability over DO
                        NSString *menusJSON = [app listMenusJSON];
                        if (menusJSON) {
                            result = ParseJSON(menusJSON);
                        } else {
                            // Fallback to typed variant
                            result = [app listMenus];
                        }
                    } else if ([toolName isEqualToString:@"invoke_menu_item"]) {
                        // Call invokeMenuItem via DO proxy (app)
                        BOOL ok = [app invokeMenuItem:callParams[@"object_id"]];
                        result = @{ @"status": ok ? @"invoked" : @"failed" };
                    } else {
                        errorMsg = [NSString stringWithFormat:@"Unknown tool: %@", toolName];
                    }
                    if (jsonResult) {
                        // Defensive: app may return NSString (JSON), NSData (raw bytes),
                        // or even already-parsed NSDictionary/NSArray in some DO implementations.
                        NSLog(@"[Server] App returned object of class: %@", NSStringFromClass([jsonResult class]));
                        if ([jsonResult isKindOfClass:[NSString class]]) {
                            result = ParseJSON(jsonResult);
                        } else if ([jsonResult isKindOfClass:[NSData class]]) {
                            NSLog(@"[Server] App returned NSData — attempting to decode as UTF-8 JSON string");
                            NSString *s = [[NSString alloc] initWithData:jsonResult encoding:NSUTF8StringEncoding];
                            if (s) {
                                result = ParseJSON(s);
                            } else {
                                NSLog(@"[Server] Failed to decode app NSData as UTF-8");
                                result = @{ @"error": @"Service returned non-UTF8 NSData" };
                            }
                            [s release];
                        } else if ([jsonResult isKindOfClass:[NSDictionary class]] || [jsonResult isKindOfClass:[NSArray class]]) {
                            result = jsonResult;
                        } else if (jsonResult == [NSNull null] || jsonResult == nil) {
                            result = nil;
                        } else {
                            // Fallback: try to stringify and parse
                            NSLog(@"[Server] App returned unexpected type — using description() as fallback");
                            NSString *desc = [jsonResult description];
                            result = ParseJSON(desc);
                        }
                    }
                } @catch (NSException *e) {
                    errorMsg = [NSString stringWithFormat:@"Exception: %@", e];
                }
            }
        }
    }
    } @catch (NSException *e) {
        hasError = YES;
        errorMsg = [NSString stringWithFormat:@"Internal error: %@", e];
        errorCode = -32603;
    }

    NSLog(@"[Server] Constructing response...");
    NSMutableDictionary *resp = [NSMutableDictionary dictionary];
    resp[@"jsonrpc"] = @"2.0";
    resp[@"id"] = reqID ?: [NSNull null];

    if (hasError || errorMsg) {
        if ([method isEqualToString:@"tools/call"]) {
             resp[@"result"] = @{
                 @"content": @[@{ @"type": @"text", @"text": [NSString stringWithFormat:@"Error: %@", errorMsg] }],
                 @"isError": @YES
             };
        } else {
             resp[@"error"] = @{@"code": @(errorCode), @"message": errorMsg ?: @"Unknown error"};
        }
    } else {
        // Ensure result is JSON-safe
        if (result && !([result isKindOfClass:[NSDictionary class]] ||
                       [result isKindOfClass:[NSArray class]] ||
                       [result isKindOfClass:[NSString class]] ||
                       [result isKindOfClass:[NSNumber class]] ||
                       result == [NSNull null])) {
            result = [result description];
        }

        if ([method isEqualToString:@"tools/call"]) {
            // VS Code / MCP expectation: wrap in content array
            id contentItem = nil;
            if (result && ([result isKindOfClass:[NSDictionary class]] || [result isKindOfClass:[NSArray class]])) {
                NSLog(@"[Server] result is collection (class: %@), serializing content for MCP", NSStringFromClass([result class]));
                NSError *error = nil;
                NSData *jsonData = [NSJSONSerialization dataWithJSONObject:result 
                                                                   options:NSJSONWritingPrettyPrinted 
                                                                     error:&error];
                if (jsonData) {
                    NSString *jsonStr = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
                    contentItem = @{ @"type": @"text", @"text": jsonStr ?: [result description] };
                    [jsonStr release];
                } else {
                    NSLog(@"[Server] NSJSONSerialization failed for result: %@", error);
                    contentItem = @{ @"type": @"text", @"text": [result description] };
                }
            } else if (result) {
                contentItem = @{ @"type": @"text", @"text": [result description] };
            } else {
                contentItem = @{ @"type": @"text", @"text": @"ok" };
            }
            resp[@"result"] = @{
                @"content": @[contentItem],
                @"isError": @NO
            };
        } else {
            resp[@"result"] = result ?: @{};
        }
    }
    NSLog(@"[Server] Final response dictionary constructed. Calling SendJSON...");
    SendJSON(resp);
    NSLog(@"[Server] processRequest finished.");
}

@end

int main(int argc, const char *argv[]) {
    // Standard Gershwin environment setup
    setenv("GNUSTEP_SYSTEM_ROOT", "/System", 1);
    setenv("GNUSTEP_LOCAL_ROOT", "/Local", 1);
    setenv("GNUSTEP_NETWORK_ROOT", "/Network", 1);
    
    // Ensure we find the correct GNUstep.conf for Gershwin
    NSArray *configCandidates = @[
        @"/System/Library/Preferences/GNUstep.conf",
        @"/Local/Library/Preferences/GNUstep.conf",
        @"/etc/GNUstep/GNUstep.conf"
    ];
    for (NSString *conf in configCandidates) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:conf]) {
            setenv("GNUSTEP_CONFIG_FILE", [conf UTF8String], 1);
            break;
        }
    }
    
    // Set LD_LIBRARY_PATH for GNUstep libraries
    const char *ldpath = getenv("LD_LIBRARY_PATH");
    NSString *ldpathStr = ldpath ? [NSString stringWithUTF8String:ldpath] : @"";
    NSMutableArray *parts = [NSMutableArray arrayWithObjects:@"/System/Library/Libraries", @"/Local/Library/Libraries", nil];
    NSString *extra = [[[NSProcessInfo processInfo] environment] objectForKey:@"UIBRIDGE_EXTRA_LIBS"];
    if (extra && [extra length] > 0) [parts addObject:extra];
    if ([ldpathStr length] > 0) [parts addObject:ldpathStr];
    NSString *newLdPath = [parts componentsJoinedByString:@":"];
    setenv("LD_LIBRARY_PATH", [newLdPath UTF8String], 1);
    
    // Unbuffer stdout
    setbuf(stdout, NULL);
    
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    RedirectLogs();
    
    BridgeServer *server = [[BridgeServer alloc] init];

    // Use timer to poll for input.
    [NSTimer scheduledTimerWithTimeInterval:0.05 target:server selector:@selector(checkInput:) userInfo:nil repeats:YES];
    
    // Watch timer for background observation
    [NSTimer scheduledTimerWithTimeInterval:1.0 target:server selector:@selector(watchLoop:) userInfo:nil repeats:YES];

    NSLog(@"[Server] Starting RunLoop...");
    [[NSRunLoop currentRunLoop] run];
    
    [pool release];
    return 0;
}
