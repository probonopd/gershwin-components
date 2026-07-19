/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * NetworkManager Backend Implementation
 *
 * This implementation uses nmcli as the primary interface to NetworkManager,
 * which is more reliable than the libnm C API for our purposes and doesn't
 * require linking against libnm at compile time.
 */

#import "NMBackend.h"
#import <dlfcn.h>

// NetworkManager device types (from nm-device.h)
enum {
    NM_DEVICE_TYPE_UNKNOWN = 0,
    NM_DEVICE_TYPE_ETHERNET = 1,
    NM_DEVICE_TYPE_WIFI = 2,
    NM_DEVICE_TYPE_UNUSED1 = 3,
    NM_DEVICE_TYPE_UNUSED2 = 4,
    NM_DEVICE_TYPE_BT = 5,
    NM_DEVICE_TYPE_OLPC_MESH = 6,
    NM_DEVICE_TYPE_WIMAX = 7,
    NM_DEVICE_TYPE_MODEM = 8,
    NM_DEVICE_TYPE_INFINIBAND = 9,
    NM_DEVICE_TYPE_BOND = 10,
    NM_DEVICE_TYPE_VLAN = 11,
    NM_DEVICE_TYPE_ADSL = 12,
    NM_DEVICE_TYPE_BRIDGE = 13,
    NM_DEVICE_TYPE_GENERIC = 14,
    NM_DEVICE_TYPE_TEAM = 15,
    NM_DEVICE_TYPE_TUN = 16,
    NM_DEVICE_TYPE_IP_TUNNEL = 17,
    NM_DEVICE_TYPE_MACVLAN = 18,
    NM_DEVICE_TYPE_VXLAN = 19,
    NM_DEVICE_TYPE_VETH = 20
};

// NetworkManager device states (from nm-device.h)
enum {
    NM_DEVICE_STATE_UNKNOWN = 0,
    NM_DEVICE_STATE_UNMANAGED = 10,
    NM_DEVICE_STATE_UNAVAILABLE = 20,
    NM_DEVICE_STATE_DISCONNECTED = 30,
    NM_DEVICE_STATE_PREPARE = 40,
    NM_DEVICE_STATE_CONFIG = 50,
    NM_DEVICE_STATE_NEED_AUTH = 60,
    NM_DEVICE_STATE_IP_CONFIG = 70,
    NM_DEVICE_STATE_IP_CHECK = 80,
    NM_DEVICE_STATE_SECONDARIES = 90,
    NM_DEVICE_STATE_ACTIVATED = 100,
    NM_DEVICE_STATE_DEACTIVATING = 110,
    NM_DEVICE_STATE_FAILED = 120
};

// NetworkManager states
enum {
    NM_STATE_UNKNOWN = 0,
    NM_STATE_ASLEEP = 10,
    NM_STATE_DISCONNECTED = 20,
    NM_STATE_DISCONNECTING = 30,
    NM_STATE_CONNECTING = 40,
    NM_STATE_CONNECTED_LOCAL = 50,
    NM_STATE_CONNECTED_SITE = 60,
    NM_STATE_CONNECTED_GLOBAL = 70
};

@implementation NMBackend

@synthesize delegate;

- (id)init
{
    self = [super init];
    if (self) {
        nmLibHandle = NULL;
        nmAvailable = NO;
        nmClient = NULL;
        
        cachedInterfaces = [[NSMutableArray alloc] init];
        cachedConnections = [[NSMutableArray alloc] init];
        cachedWLANs = [[NSMutableArray alloc] init];
        wifiEnabled = NO;
        
        nmcliPath = [[self findNmcliPath] retain];
        helperPath = [[self findHelperPath] retain];
        sudoPath = [[self findSudoPath] retain];
        
        if (nmcliPath) {
            nmAvailable = YES;
            NSDebugLLog(@"gwcomp", @"[Network] NMBackend initialized with nmcli at: %@", nmcliPath);
        } else {
            NSDebugLLog(@"gwcomp", @"[Network] NMBackend: nmcli not found, backend unavailable");
        }
        
        if (helperPath) {
            NSDebugLLog(@"gwcomp", @"[Network] Network helper found at: %@", helperPath);
        }
        if (sudoPath) {
            NSDebugLLog(@"gwcomp", @"[Network] sudo found at: %@", sudoPath);
        }
    }
    return self;
}

- (void)dealloc
{
    [self unloadNetworkManagerLibrary];
    [cachedInterfaces release];
    [cachedConnections release];
    [cachedWLANs release];
    [nmcliPath release];
    [helperPath release];
    [sudoPath release];
    [super dealloc];
}

#pragma mark - Path Finding

- (NSString *)findNmcliPath
{
    NSArray *paths = @[
        @"/usr/bin/nmcli",
        @"/bin/nmcli",
        @"/usr/local/bin/nmcli",
        @"/sbin/nmcli",
        @"/usr/sbin/nmcli"
    ];
    
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *path in paths) {
        if ([fm isExecutableFileAtPath:path]) {
            return path;
        }
    }
    
    // Try PATH
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"/usr/bin/which"];
    [task setArguments:@[@"nmcli"]];
    
    NSPipe *pipe = [NSPipe pipe];
    [task setStandardOutput:pipe];
    [task setStandardError:[NSPipe pipe]];
    
    @try {
        [task launch];
        [task waitUntilExit];
        
        if ([task terminationStatus] == 0) {
            NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
            NSString *path = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            path = [path stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            [task release];
            
            if ([fm isExecutableFileAtPath:path]) {
                return path;
            }
        }
    } @catch (NSException *e) {
        NSDebugLLog(@"gwcomp", @"[Network] Exception finding nmcli: %@", e);
    }
    
    [task release];
    return nil;
}

- (NSString *)findHelperPath
{
    NSArray *paths = @[
        @"/System/Library/Tools/network-helper",
        @"/System/Tools/network-helper",
        @"/usr/GNUstep/System/Tools/network-helper",
        @"/usr/local/bin/network-helper",
        @"/usr/bin/network-helper"
    ];
    
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *path in paths) {
        if ([fm isExecutableFileAtPath:path]) {
            return path;
        }
    }
    
    return nil;
}

- (NSString *)findSudoPath
{
    NSArray *paths = @[
        @"/usr/bin/sudo",
        @"/bin/sudo",
        @"/usr/local/bin/sudo",
        @"/sbin/sudo",
        @"/usr/sbin/sudo"
    ];
    
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *path in paths) {
        if ([fm isExecutableFileAtPath:path]) {
            return path;
        }
    }
    
    // Try PATH
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"/usr/bin/which"];
    [task setArguments:@[@"sudo"]];
    
    NSPipe *pipe = [NSPipe pipe];
    [task setStandardOutput:pipe];
    [task setStandardError:[NSPipe pipe]];
    
    @try {
        [task launch];
        [task waitUntilExit];
        
        if ([task terminationStatus] == 0) {
            NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
            NSString *path = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            path = [path stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            [task release];
            
            if ([fm isExecutableFileAtPath:path]) {
                return path;
            }
        }
    } @catch (NSException *e) {
        NSDebugLLog(@"gwcomp", @"[Network] Exception finding sudo: %@", e);
    }
    
    [task release];
    return nil;
}

- (BOOL)runPrivilegedHelper:(NSArray *)arguments error:(NSError **)error
{
    NSDebugLLog(@"gwcomp", @"[Network] runPrivilegedHelper: called");
    
    if (!arguments || [arguments count] == 0) {
        NSDebugLLog(@"gwcomp", @"[Network] runPrivilegedHelper: no arguments provided");
        if (error) {
            *error = [NSError errorWithDomain:@"NetworkBackendError"
                                        code:1
                                    userInfo:@{NSLocalizedDescriptionKey: @"No arguments provided to helper"}];
        }
        return NO;
    }
    
    // Log command without sensitive data
    NSMutableArray *logArgs = [NSMutableArray array];
    for (NSUInteger i = 0; i < [arguments count]; i++) {
        NSString *arg = [arguments objectAtIndex:i];
        // Mask password argument (it follows wlan-connect <ssid>)
        if (i >= 2 && [[arguments objectAtIndex:0] isEqualToString:@"wlan-connect"]) {
            [logArgs addObject:@"<password>"];
        } else {
            [logArgs addObject:arg];
        }
    }
    NSDebugLLog(@"gwcomp", @"[Network] runPrivilegedHelper: helper args = %@", logArgs);
    
    if (!helperPath) {
        NSDebugLLog(@"gwcomp", @"[Network] runPrivilegedHelper: helperPath is nil");
        if (error) {
            *error = [NSError errorWithDomain:@"NetworkBackendError"
                                        code:1
                                    userInfo:@{NSLocalizedDescriptionKey: @"Network helper tool not found"}];
        }
        return NO;
    }

    if (!sudoPath) {
        NSDebugLLog(@"gwcomp", @"[Network] runPrivilegedHelper: sudoPath is nil");
        if (error) {
            *error = [NSError errorWithDomain:@"NetworkBackendError"
                                        code:1
                                    userInfo:@{NSLocalizedDescriptionKey: @"sudo not found"}];
        }
        return NO;
    }
    
    NSDebugLLog(@"gwcomp", @"[Network] runPrivilegedHelper: using helper at '%@'", helperPath);
    
    // Build command: sudo -A -E network-helper <arguments>
    NSMutableArray *sudoArgs = [NSMutableArray arrayWithObjects:@"-A", @"-E", helperPath, nil];
    if (!sudoArgs) {
        NSDebugLLog(@"gwcomp", @"[Network] runPrivilegedHelper: failed to create sudoArgs array");
        if (error) {
            *error = [NSError errorWithDomain:@"NetworkBackendError"
                                        code:1
                                    userInfo:@{NSLocalizedDescriptionKey: @"Failed to create command arguments"}];
        }
        return NO;
    }
    [sudoArgs addObjectsFromArray:arguments];
    
    NSDebugLLog(@"gwcomp", @"[Network] runPrivilegedHelper: sudo command = %@ -A -E %@ %@", sudoPath, helperPath, [logArgs componentsJoinedByString:@" "]);
    
    NSTask *task = [[NSTask alloc] init];
    if (!task) {
        NSDebugLLog(@"gwcomp", @"[Network] runPrivilegedHelper: failed to create NSTask");
        if (error) {
            *error = [NSError errorWithDomain:@"NetworkBackendError"
                                        code:1
                                    userInfo:@{NSLocalizedDescriptionKey: @"Failed to create task"}];
        }
        return NO;
    }
    
    [task setLaunchPath:sudoPath];
    [task setArguments:sudoArgs];
    
    NSPipe *errPipe = [NSPipe pipe];
    NSPipe *outPipe = [NSPipe pipe];
    if (!errPipe || !outPipe) {
        NSDebugLLog(@"gwcomp", @"[Network] runPrivilegedHelper: failed to create pipes");
        [task release];
        if (error) {
            *error = [NSError errorWithDomain:@"NetworkBackendError"
                                        code:1
                                    userInfo:@{NSLocalizedDescriptionKey: @"Failed to create pipes"}];
        }
        return NO;
    }
    
    [task setStandardError:errPipe];
    [task setStandardOutput:outPipe];
    
    NSDebugLLog(@"gwcomp", @"[Network] runPrivilegedHelper: launching sudo...");
    
    @try {
        [task launch];
        NSDebugLLog(@"gwcomp", @"[Network] runPrivilegedHelper: sudo launched, will wait in background thread...");
        
        // Create a dictionary to pass task and pipes to background thread
        NSDictionary *taskInfo = [NSDictionary dictionaryWithObjectsAndKeys:
                                  task, @"task",
                                  errPipe, @"errPipe",
                                  outPipe, @"outPipe",
                                  nil];
        
        // Start background thread to wait for task completion
        [NSThread detachNewThreadSelector:@selector(waitForTaskCompletion:)
                                 toTarget:self
                               withObject:taskInfo];
        
        // Return immediately - don't block UI
        // The background thread will log the result when task completes
        NSDebugLLog(@"gwcomp", @"[Network] runPrivilegedHelper: returning (async operation in progress)");
        return YES;
    }
    @catch (NSException *e) {
        NSDebugLLog(@"gwcomp", @"[Network] runPrivilegedHelper: EXCEPTION: %@ - %@", [e name], [e reason]);
        if (task) {
            [task release];
        }
        if (error) {
            *error = [NSError errorWithDomain:@"NetworkBackendError"
                                        code:2
                                    userInfo:@{NSLocalizedDescriptionKey: [e reason] ?: @"Unknown exception"}];
        }
        return NO;
    }
}

// Run a command through sudo -A -E for all WLAN/NetworkManager operations
- (int)runPrivilegedCommand:(NSString *)path arguments:(NSArray *)args output:(NSString **)output error:(NSString **)error
{
    NSTask *task = [[NSTask alloc] init];
    if (sudoPath) {
        // Ensure SSH_ASKPASS is set for sudo -A
        NSString *askpass = [[[NSProcessInfo processInfo] environment] objectForKey:@"SSH_ASKPASS"];
        if (!askpass || [askpass length] == 0) {
            NSFileManager *fm = [NSFileManager defaultManager];
            NSArray *paths = @[@"/System/Library/Tools/SudoAskPass",
                               @"/Library/Tools/SudoAskPass",
                               @"/Local/Library/Tools/SudoAskPass",
                               @"/usr/bin/SudoAskPass",
                               @"/usr/local/bin/SudoAskPass"];
            for (NSString *p in paths) {
                if ([fm isExecutableFileAtPath:p]) {
                    setenv("SSH_ASKPASS", [p UTF8String], 1);
                    NSLog(@"NMBackend: set SSH_ASKPASS=%s", getenv("SSH_ASKPASS"));
                    break;
                }
            }
        }
        NSLog(@"NMBackend: running sudo -A -E %@ %@", path, args);
        [task setLaunchPath:sudoPath];
        NSMutableArray *sudoArgs = [NSMutableArray arrayWithObjects:@"-A", @"-E", path, nil];
        if (args) {
            [sudoArgs addObjectsFromArray:args];
        }
        [task setArguments:sudoArgs];
    } else {
        [task setLaunchPath:path];
        [task setArguments:args];
    }

    NSPipe *outPipe = [NSPipe pipe];
    NSPipe *errPipe = [NSPipe pipe];
    [task setStandardOutput:outPipe];
    [task setStandardError:errPipe];

    int status = -1;
    @try {
        [task launch];
        [task waitUntilExit];
        status = [task terminationStatus];

        if (output) {
            NSData *data = [[outPipe fileHandleForReading] readDataToEndOfFile];
            *output = data ? [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease] : nil;
        }
        if (error) {
            NSData *data = [[errPipe fileHandleForReading] readDataToEndOfFile];
            *error = data ? [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease] : nil;
        }
    } @catch (NSException *e) {
        NSLog(@"NMBackend: Exception running privileged command %@ %@: %@", path, args, e);
    }
    NSLog(@"NMBackend: command exit status=%d", status);
    [task release];
    return status;
}

- (void)waitForTaskCompletion:(NSDictionary *)taskInfo
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    @try {
        NSTask *task = [taskInfo objectForKey:@"task"];
        NSPipe *errPipe = [taskInfo objectForKey:@"errPipe"];
        NSPipe *outPipe = [taskInfo objectForKey:@"outPipe"];
        
        if (!task) {
            NSDebugLLog(@"gwcomp", @"[Network] waitForTaskCompletion: task is nil");
            [pool release];
            return;
        }
        
        // Wait for task to complete
        [task waitUntilExit];
        
        int status = [task terminationStatus];
        NSDebugLLog(@"gwcomp", @"[Network] waitForTaskCompletion: sudo exited with status %d", status);
        
        // Read stderr
        NSData *errData = [[errPipe fileHandleForReading] readDataToEndOfFile];
        NSString *errStr = nil;
        if (errData && [errData length] > 0) {
            errStr = [[[NSString alloc] initWithData:errData encoding:NSUTF8StringEncoding] autorelease];
            errStr = [errStr stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            NSDebugLLog(@"gwcomp", @"[Network] waitForTaskCompletion: stderr = '%@'", errStr);
        }
        
        // Read stdout
        NSData *outData = [[outPipe fileHandleForReading] readDataToEndOfFile];
        if (outData && [outData length] > 0) {
            NSString *outStr = [[[NSString alloc] initWithData:outData encoding:NSUTF8StringEncoding] autorelease];
            NSDebugLLog(@"gwcomp", @"[Network] waitForTaskCompletion: stdout = '%@'", outStr);
        }
        
        if (status == 0) {
            NSDebugLLog(@"gwcomp", @"[Network] waitForTaskCompletion: success");
        } else {
            NSString *errorMsg = (errStr && [errStr length] > 0) ? errStr : @"Operation failed";
            NSDebugLLog(@"gwcomp", @"[Network] waitForTaskCompletion: command failed: %@", errorMsg);
            
            // Parse error message to provide user-friendly feedback
            NSString *userMsg = [self parseErrorMessage:errorMsg];
            
            // Report error on main thread
            [self performSelectorOnMainThread:@selector(reportErrorWithMessage:)
                                   withObject:userMsg
                                waitUntilDone:NO];
        }
    }
    @catch (NSException *e) {
        NSDebugLLog(@"gwcomp", @"[Network] waitForTaskCompletion: EXCEPTION: %@ - %@", [e name], [e reason]);
        [self performSelectorOnMainThread:@selector(reportErrorWithMessage:)
                               withObject:@"An unexpected error occurred"
                            waitUntilDone:NO];
    }
    
    [pool release];
}

#pragma mark - Error Reporting Helper

- (NSString *)parseErrorMessage:(NSString *)errorMsg
{
    if (!errorMsg || [errorMsg length] == 0) {
        return @"Connection failed";
    }
    
    NSString *lower = [errorMsg lowercaseString];
    
    // Check for common error patterns
    if ([lower rangeOfString:@"psk: property is invalid"].location != NSNotFound ||
        [lower rangeOfString:@"invalid password"].location != NSNotFound ||
        [lower rangeOfString:@"authentication failed"].location != NSNotFound ||
        [lower rangeOfString:@"secrets were required"].location != NSNotFound) {
        return @"Incorrect password. Please check your password and try again.";
    }
    
    if ([lower rangeOfString:@"timeout"].location != NSNotFound ||
        [lower rangeOfString:@"timed out"].location != NSNotFound) {
        return @"Connection timeout. The network may be out of range or unavailable.";
    }
    
    if ([lower rangeOfString:@"no network"].location != NSNotFound ||
        [lower rangeOfString:@"network not found"].location != NSNotFound) {
        return @"Network not found. The network may be unavailable or out of range.";
    }
    
    if ([lower rangeOfString:@"insufficient privileges"].location != NSNotFound ||
        [lower rangeOfString:@"permission denied"].location != NSNotFound) {
        return @"Insufficient privileges. Please check your system configuration.";
    }
    
    if ([lower rangeOfString:@"activation failed"].location != NSNotFound ||
        [lower rangeOfString:@"error activating"].location != NSNotFound) {
        return @"Failed to activate connection. Please try again.";
    }
    
    // Default: return a cleaned up version of the error
    return @"Connection failed. Please check your network settings and try again.";
}

- (void)reportErrorWithMessage:(NSString *)message
{
    if (message && [message length] > 0) {
        NSDebugLLog(@"gwcomp", @"[Network] Error: %@", message);
        if (delegate && [delegate respondsToSelector:@selector(networkBackend:didEncounterError:)]) {
            NSError *error = [NSError errorWithDomain:@"NetworkBackendError"
                                                 code:1
                                             userInfo:@{NSLocalizedDescriptionKey: message}];
            [delegate networkBackend:self didEncounterError:error];
        }
    }
}

#pragma mark - Library Loading (for future direct libnm use)

- (BOOL)loadNetworkManagerLibrary
{
    if (nmLibHandle) {
        return YES;
    }
    
    // Try loading libnm
    NSArray *libPaths = @[
        @"libnm.so.0",
        @"libnm.so",
        @"/usr/lib/libnm.so.0",
        @"/usr/lib/x86_64-linux-gnu/libnm.so.0",
        @"/usr/lib/aarch64-linux-gnu/libnm.so.0",
        @"/usr/lib64/libnm.so.0"
    ];
    
    for (NSString *path in libPaths) {
        nmLibHandle = dlopen([path UTF8String], RTLD_LAZY | RTLD_GLOBAL);
        if (nmLibHandle) {
            NSDebugLLog(@"gwcomp", @"[Network] Loaded libnm from: %@", path);
            break;
        }
    }
    
    if (!nmLibHandle) {
        NSDebugLLog(@"gwcomp", @"[Network] Could not load libnm: %s", dlerror());
        return NO;
    }
    
    return YES;
}

- (void)unloadNetworkManagerLibrary
{
    if (nmLibHandle) {
        dlclose(nmLibHandle);
        nmLibHandle = NULL;
    }
    nmClient = NULL;
}

- (BOOL)initializeNMClient
{
    // For now we use nmcli, so this is a no-op
    return nmAvailable;
}

#pragma mark - NetworkBackend Protocol - Identification

- (NSString *)backendName
{
    return @"NetworkManager";
}

- (NSString *)backendVersion
{
    if (!nmAvailable) {
        return @"Not Available";
    }
    
    NSString *output = nil;
    [self runPrivilegedCommand:nmcliPath arguments:@[@"--version"] output:&output error:NULL];
    
    if (!output) {
        return @"Unknown";
    }
    
    // Parse "nmcli tool, version 1.x.y"
    NSRange versionRange = [output rangeOfString:@"version "];
    if (versionRange.location != NSNotFound) {
        NSString *version = [output substringFromIndex:NSMaxRange(versionRange)];
        version = [version stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        return version;
    }
    
    return output;
}

- (BOOL)isAvailable
{
    return nmAvailable;
}

#pragma mark - Interface Management

- (NSArray *)availableInterfaces
{
    [self getInterfacesViaNmcli];
    return [[cachedInterfaces copy] autorelease];
}

- (NSArray *)getInterfacesViaNmcli
{
    [cachedInterfaces removeAllObjects];
    
    if (!nmAvailable) {
        return cachedInterfaces;
    }
    
    // Get device list with details
    NSString *output = nil;
    [self runPrivilegedCommand:nmcliPath arguments:@[@"-t", @"-f", @"DEVICE,TYPE,STATE,CONNECTION", @"device"] output:&output error:NULL];
    
    if (output) {
        NSArray *lines = [output componentsSeparatedByString:@"\n"];
        
        for (NSString *line in lines) {
            if ([line length] == 0) continue;
            
            NSArray *fields = [line componentsSeparatedByString:@":"];
            if ([fields count] < 3) continue;
            
            NSString *deviceName = [fields objectAtIndex:0];
            NSString *deviceType = [fields objectAtIndex:1];
            NSString *deviceState = [fields objectAtIndex:2];
            // connectionName is available in fields[3] if needed
            
            // Skip loopback
            if ([deviceName isEqualToString:@"lo"]) continue;
            
            // Skip virtual/auxiliary interfaces
            if ([deviceName hasPrefix:@"p2p-dev-"]) continue;
            if ([deviceName hasPrefix:@"veth"]) continue;
            if ([deviceName hasPrefix:@"docker"]) continue;
            if ([deviceName hasPrefix:@"virbr"]) continue;
            if ([deviceType isEqualToString:@"wifi-p2p"]) continue;
            
            NetworkInterface *iface = [[NetworkInterface alloc] init];
            [iface setIdentifier:deviceName];
            [iface setName:deviceName];
            
            // Set display name based on type
            if ([deviceType isEqualToString:@"ethernet"]) {
                [iface setType:NetworkInterfaceTypeEthernet];
                [iface setDisplayName:[NSString stringWithFormat:@"Ethernet (%@)", deviceName]];
            } else if ([deviceType isEqualToString:@"wifi"]) {
                [iface setType:NetworkInterfaceTypeWLAN];
                [iface setDisplayName:[NSString stringWithFormat:@"WLAN (%@)", deviceName]];
            } else if ([deviceType isEqualToString:@"bridge"]) {
                [iface setType:NetworkInterfaceTypeBridge];
                [iface setDisplayName:[NSString stringWithFormat:@"Bridge (%@)", deviceName]];
            } else {
                [iface setType:NetworkInterfaceTypeUnknown];
                [iface setDisplayName:deviceName];
            }
            
            // Map state
            if ([deviceState isEqualToString:@"connected"]) {
                [iface setState:NetworkConnectionStateConnected];
                [iface setIsActive:YES];
            } else if ([deviceState isEqualToString:@"connecting"]) {
                [iface setState:NetworkConnectionStateConnecting];
            } else if ([deviceState isEqualToString:@"disconnected"]) {
                [iface setState:NetworkConnectionStateDisconnected];
            } else if ([deviceState isEqualToString:@"unavailable"]) {
                [iface setState:NetworkConnectionStateUnavailable];
            } else {
                [iface setState:NetworkConnectionStateUnknown];
            }
            
            [iface setIsEnabled:![deviceState isEqualToString:@"unavailable"] && 
                                ![deviceState isEqualToString:@"unmanaged"]];
            
            // Get additional info for this device
            [self getDeviceDetails:iface];
            
            [cachedInterfaces addObject:iface];
            [iface release];
        }
    }
    
    return cachedInterfaces;
}

- (void)getDeviceDetails:(NetworkInterface *)iface
{
    if (!nmAvailable || !iface) return;
    
    NSString *output = nil;
    [self runPrivilegedCommand:nmcliPath arguments:@[@"-t", @"-f", @"GENERAL.HWADDR,IP4.ADDRESS,IP4.GATEWAY,IP4.DNS", 
                         @"device", @"show", [iface name]] output:&output error:NULL];
    
    if (output) {
        NSArray *lines = [output componentsSeparatedByString:@"\n"];
        
        IPConfiguration *ipv4 = [[IPConfiguration alloc] init];
        NSMutableArray *dnsServers = [NSMutableArray array];
        
        for (NSString *line in lines) {
            if ([line length] == 0) continue;
            
            NSRange colonRange = [line rangeOfString:@":"];
            if (colonRange.location == NSNotFound) continue;
            
            NSString *key = [line substringToIndex:colonRange.location];
            NSString *value = [line substringFromIndex:colonRange.location + 1];
            
            if ([key isEqualToString:@"GENERAL.HWADDR"]) {
                [iface setHardwareAddress:value];
            } else if ([key hasPrefix:@"IP4.ADDRESS"]) {
                // Format: 192.168.1.100/24
                NSArray *parts = [value componentsSeparatedByString:@"/"];
                if ([parts count] >= 1) {
                    [ipv4 setAddress:[parts objectAtIndex:0]];
                    [ipv4 setMethod:IPConfigMethodDHCP]; // Assume DHCP for now
                    
                    if ([parts count] >= 2) {
                        int prefix = [[parts objectAtIndex:1] intValue];
                        // Convert prefix to subnet mask
                        unsigned int mask = (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF;
                        [ipv4 setSubnetMask:[NSString stringWithFormat:@"%d.%d.%d.%d",
                                            (mask >> 24) & 0xFF,
                                            (mask >> 16) & 0xFF,
                                            (mask >> 8) & 0xFF,
                                            mask & 0xFF]];
                    }
                }
            } else if ([key hasPrefix:@"IP4.GATEWAY"]) {
                [ipv4 setRouter:value];
            } else if ([key hasPrefix:@"IP4.DNS"]) {
                if ([value length] > 0) {
                    [dnsServers addObject:value];
                }
            }
        }
        
        if ([dnsServers count] > 0) {
            [ipv4 setDnsServers:dnsServers];
        }
        
        [iface setIpv4Config:ipv4];
        [ipv4 release];
    }
}

- (NetworkInterface *)interfaceWithIdentifier:(NSString *)identifier
{
    for (NetworkInterface *iface in cachedInterfaces) {
        if ([[iface identifier] isEqualToString:identifier]) {
            return iface;
        }
    }
    return nil;
}

- (BOOL)enableInterface:(NetworkInterface *)interface
{
    if (!nmAvailable || !interface) {
        [self reportErrorWithMessage:@"Cannot enable interface: backend unavailable or no interface specified"];
        return NO;
    }
    
    NSString *ifaceName = [interface name];
    if (!ifaceName) {
        [self reportErrorWithMessage:@"Cannot enable interface: interface name is nil"];
        return NO;
    }
    
    NSString *errStr = nil;
    int exitStatus = [self runPrivilegedCommand:nmcliPath arguments:@[@"device", @"connect", ifaceName] output:NULL error:&errStr];
    BOOL success = (exitStatus == 0);
    
    if (!success) {
        NSDebugLLog(@"gwcomp", @"[Network] enableInterface: nmcli failed with: %@", errStr);
        
        // Check if authorization issue - try privileged helper
        if (errStr && ([errStr rangeOfString:@"not authorized" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                      [errStr rangeOfString:@"permission denied" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                      [errStr rangeOfString:@"Not authorized" options:NSCaseInsensitiveSearch].location != NSNotFound)) {
            
            NSDebugLLog(@"gwcomp", @"[Network] enableInterface: trying privileged helper...");
            NSError *helperError = nil;
            success = [self runPrivilegedHelper:@[@"interface-enable", ifaceName] error:&helperError];
            
            if (!success) {
                NSString *helperErrMsg = helperError ? [helperError localizedDescription] : errStr;
                [self reportErrorWithMessage:[NSString stringWithFormat:@"Failed to enable interface '%@': %@",
                                             [interface displayName], helperErrMsg]];
                return NO;
            }
            
            NSDebugLLog(@"gwcomp", @"[Network] enableInterface: privileged helper succeeded");
            // Do NOT call refresh here - let caller handle it
            return YES;
        }
        
        [self reportErrorWithMessage:[NSString stringWithFormat:@"Failed to enable interface '%@': %@",
                                     [interface displayName], errStr ? errStr : @"unknown error"]];
        return NO;
    }
    
    NSDebugLLog(@"gwcomp", @"[Network] enableInterface: success");
    
    // If interface has DHCP configured, ensure DHCP is requested
    // This is especially important for WiFi interfaces not managed by NetworkManager
    if ([interface type] == NetworkInterfaceTypeWLAN || [interface type] == NetworkInterfaceTypeEthernet) {
        IPConfiguration *ipv4 = [interface ipv4Config];
        if (ipv4 && [ipv4 method] == IPConfigMethodDHCP) {
            NSDebugLLog(@"gwcomp", @"[Network] enableInterface: interface configured for DHCP, requesting lease...");
            
            // Try to request DHCP via helper in background
            // We use NSThread instead of GCD to avoid dispatch dependencies
            [NSThread detachNewThreadSelector:@selector(requestDHCPForInterface:)
                                     toTarget:self
                                   withObject:ifaceName];
        }
    }
    
    // Do NOT call refresh here - let caller handle it
    return YES;
}

- (void)requestDHCPForInterface:(NSString *)ifaceName
{
    @autoreleasepool {
        NSError *dhcpError = nil;
        [self runPrivilegedHelper:@[@"dhcp-renew", ifaceName] error:&dhcpError];
        if (dhcpError) {
            NSDebugLLog(@"gwcomp", @"[Network] DHCP renewal for %@ failed: %@", ifaceName, dhcpError);
        } else {
            NSDebugLLog(@"gwcomp", @"[Network] DHCP renewal for %@ initiated", ifaceName);
        }
    }
}

- (BOOL)disableInterface:(NetworkInterface *)interface
{
    if (!nmAvailable || !interface) {
        NSLog(@"NMBackend: disableInterface — backend unavailable or nil interface");
        [self reportErrorWithMessage:@"Cannot disable interface: backend unavailable or no interface specified"];
        return NO;
    }
    
    NSString *ifaceName = [interface name];
    if (!ifaceName) {
        NSLog(@"NMBackend: disableInterface — interface name is nil");
        [self reportErrorWithMessage:@"Cannot disable interface: interface name is nil"];
        return NO;
    }
    
    NSLog(@"NMBackend: disableInterface — running nmcli device disconnect %@", ifaceName);
    NSString *errStr = nil;
    int exitStatus = [self runPrivilegedCommand:nmcliPath arguments:@[@"device", @"disconnect", ifaceName] output:NULL error:&errStr];
    BOOL success = (exitStatus == 0);
    NSLog(@"NMBackend: disableInterface — exitStatus=%d success=%d errStr=%@", exitStatus, success, errStr);
    
    if (!success) {
        NSDebugLLog(@"gwcomp", @"[Network] disableInterface: nmcli failed with: %@", errStr);
        
        // Check if authorization issue - try privileged helper
        if (errStr && ([errStr rangeOfString:@"not authorized" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                      [errStr rangeOfString:@"permission denied" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                      [errStr rangeOfString:@"Not authorized" options:NSCaseInsensitiveSearch].location != NSNotFound)) {
            
            NSDebugLLog(@"gwcomp", @"[Network] disableInterface: trying privileged helper...");
            NSError *helperError = nil;
            success = [self runPrivilegedHelper:@[@"interface-disable", ifaceName] error:&helperError];
            
            if (!success) {
                NSString *helperErrMsg = helperError ? [helperError localizedDescription] : errStr;
                [self reportErrorWithMessage:[NSString stringWithFormat:@"Failed to disable interface '%@': %@",
                                             [interface displayName], helperErrMsg]];
                return NO;
            }
            
            NSDebugLLog(@"gwcomp", @"[Network] disableInterface: privileged helper succeeded");
            // Do NOT call refresh here - let caller handle it
            return YES;
        }
        
        [self reportErrorWithMessage:[NSString stringWithFormat:@"Failed to disable interface '%@': %@",
                                     [interface displayName], errStr ? errStr : @"unknown error"]];
        return NO;
    }
    
    NSDebugLLog(@"gwcomp", @"[Network] disableInterface: success");
    // Do NOT call refresh here - let caller handle it
    return YES;
}

#pragma mark - Connection Management

- (NSArray *)savedConnections
{
    [self getConnectionsViaNmcli];
    return [[cachedConnections copy] autorelease];
}

- (NSArray *)getConnectionsViaNmcli
{
    [cachedConnections removeAllObjects];
    
    if (!nmAvailable) {
        return cachedConnections;
    }
    
    NSString *output = nil;
    [self runPrivilegedCommand:nmcliPath arguments:@[@"-t", @"-f", @"NAME,UUID,TYPE,DEVICE", @"connection", @"show"] output:&output error:NULL];
    
    if (output) {
        NSArray *lines = [output componentsSeparatedByString:@"\n"];
        
        for (NSString *line in lines) {
            if ([line length] == 0) continue;
            
            NSArray *fields = [line componentsSeparatedByString:@":"];
            if ([fields count] < 3) continue;
            
            NSString *name = [fields objectAtIndex:0];
            NSString *uuid = [fields objectAtIndex:1];
            NSString *type = [fields objectAtIndex:2];
            NSString *device = [fields count] > 3 ? [fields objectAtIndex:3] : @"";
            
            NetworkConnection *conn = [[NetworkConnection alloc] init];
            [conn setName:name];
            [conn setUuid:uuid];
            [conn setIdentifier:uuid];
            [conn setInterfaceName:device];
            
            if ([type isEqualToString:@"802-11-wireless"]) {
                [conn setType:NetworkInterfaceTypeWLAN];
                [conn setSsid:name]; // Often the connection name is the SSID
            } else if ([type isEqualToString:@"802-3-ethernet"]) {
                [conn setType:NetworkInterfaceTypeEthernet];
            } else if ([type isEqualToString:@"bridge"]) {
                [conn setType:NetworkInterfaceTypeBridge];
            } else {
                [conn setType:NetworkInterfaceTypeUnknown];
            }
            
            [cachedConnections addObject:conn];
            [conn release];
        }
    }
    
    return cachedConnections;
}

- (NetworkConnection *)connectionWithUUID:(NSString *)uuid
{
    for (NetworkConnection *conn in cachedConnections) {
        if ([[conn uuid] isEqualToString:uuid]) {
            return conn;
        }
    }
    return nil;
}

- (BOOL)activateConnection:(NetworkConnection *)connection onInterface:(NetworkInterface *)interface
{
    return [self activateConnectionViaNmcli:[connection uuid]];
}

- (BOOL)activateConnectionViaNmcli:(NSString *)uuid
{
    if (!nmAvailable || !uuid) {
        [self reportErrorWithMessage:@"Cannot activate connection: backend unavailable or no connection specified"];
        return NO;
    }
    
    NSString *errStr = nil;
    int status = [self runPrivilegedCommand:nmcliPath arguments:@[@"connection", @"up", uuid] output:NULL error:&errStr];
    BOOL success = (status == 0);
    
    if (!success) {
        errStr = [errStr stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        [self reportErrorWithMessage:[NSString stringWithFormat:@"Failed to activate connection: %@", errStr]];
    } else {
        [self refresh];
    }
    
    return success;
}

- (BOOL)deactivateConnection:(NetworkConnection *)connection
{
    return [self deactivateConnectionViaNmcli:[connection uuid]];
}

- (BOOL)deactivateConnectionViaNmcli:(NSString *)uuid
{
    if (!nmAvailable || !uuid) {
        [self reportErrorWithMessage:@"Cannot deactivate connection: backend unavailable or no connection specified"];
        return NO;
    }
    
    NSString *errStr = nil;
    int status = [self runPrivilegedCommand:nmcliPath arguments:@[@"connection", @"down", uuid] output:NULL error:&errStr];
    BOOL success = (status == 0);
    
    if (!success) {
        errStr = [errStr stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        [self reportErrorWithMessage:[NSString stringWithFormat:@"Failed to deactivate connection: %@", errStr]];
    } else {
        [self refresh];
    }
    
    return success;
}

- (BOOL)deleteConnection:(NetworkConnection *)connection
{
    if (!nmAvailable || !connection) {
        [self reportErrorWithMessage:@"Cannot delete connection: backend unavailable or no connection specified"];
        return NO;
    }
    
    NSString *errStr = nil;
    int status = [self runPrivilegedCommand:nmcliPath arguments:@[@"connection", @"delete", [connection uuid]] output:NULL error:&errStr];
    BOOL success = (status == 0);
    
    if (!success) {
        errStr = [errStr stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        [self reportErrorWithMessage:[NSString stringWithFormat:@"Failed to delete connection '%@': %@",
                                     [connection name], errStr]];
    } else {
        [self refresh];
    }
    
    return success;
}

- (BOOL)saveConnection:(NetworkConnection *)connection
{
    // For now, modifications are done via specific nmcli commands
    // This would need to be expanded for full connection editing
    return YES;
}

- (NetworkConnection *)createConnectionForInterface:(NetworkInterface *)interface
{
    NetworkConnection *conn = [[[NetworkConnection alloc] init] autorelease];
    [conn setType:[interface type]];
    [conn setInterfaceName:[interface name]];
    [conn setName:[NSString stringWithFormat:@"Connection %@", [interface name]]];
    [conn setAutoConnect:YES];
    return conn;
}

#pragma mark - WiFi Management

- (BOOL)isWLANEnabled
{
    if (!nmAvailable) return NO;
    
    NSString *output = nil;
    NSString *errStr = nil;
    int status = [self runCommand:nmcliPath arguments:@[@"radio", @"wifi"] output:&output error:&errStr];
    NSLog(@"NMBackend: isWLANEnabled — status=%d output=%@ err=%@", status, output, errStr);
    
    if (output) {
        output = [output stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        wifiEnabled = [output isEqualToString:@"enabled"];
    } else {
        wifiEnabled = NO;
    }
    return wifiEnabled;
}

- (BOOL)setWLANEnabled:(BOOL)enabled
{
    if (!nmAvailable) {
        NSLog(@"NMBackend: setWLANEnabled:%d — backend unavailable", enabled);
        [self reportErrorWithMessage:@"Cannot change WLAN state: backend unavailable"];
        return NO;
    }
    
    NSLog(@"NMBackend: setWLANEnabled:%d — running nmcli radio wifi %@", enabled, enabled ? @"on" : @"off");
    NSString *errStr = nil;
    int status = [self runPrivilegedCommand:nmcliPath arguments:@[@"radio", @"wifi", enabled ? @"on" : @"off"] output:NULL error:&errStr];
    BOOL success = (status == 0);
    NSLog(@"NMBackend: setWLANEnabled:%d — status=%d success=%d errStr=%@", enabled, status, success, errStr);
    
    if (!success) {
        errStr = [errStr stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        
        // Check if authorization issue - try privileged helper
        if ([errStr rangeOfString:@"Not authorized"].location != NSNotFound ||
            [errStr rangeOfString:@"not authorized"].location != NSNotFound ||
            [errStr rangeOfString:@"permission denied"].location != NSNotFound) {
            
            NSError *helperError = nil;
            NSString *helperCmd = enabled ? @"wlan-enable" : @"wlan-disable";
            success = [self runPrivilegedHelper:@[helperCmd] error:&helperError];
            
            if (!success) {
                [self reportErrorWithMessage:[NSString stringWithFormat:@"Failed to %@ WLAN: %@",
                                             enabled ? @"enable" : @"disable",
                                             helperError ? [helperError localizedDescription] : errStr]];
            }
        } else {
            [self reportErrorWithMessage:[NSString stringWithFormat:@"Failed to %@ WLAN: %@",
                                         enabled ? @"enable" : @"disable", errStr]];
        }
    }
    
    if (success) {
        wifiEnabled = enabled;
        if (delegate && [delegate respondsToSelector:@selector(networkBackend:WLANEnabledDidChange:)]) {
            [delegate networkBackend:self WLANEnabledDidChange:enabled];
        }
    }
    
    return success;
}
- (NSArray *)scanForWLANs
{
    NSLog(@"NMBackend: scanForWLANs called");
    // Build networks list into a local array, then update cache safely
    NSMutableArray *networks = [self buildWLANsList];
    NSLog(@"NMBackend: scanForWLANs — got %lu networks", (unsigned long)[networks count]);
    
    // Update cache on main thread
    if ([NSThread isMainThread]) {
        [cachedWLANs removeAllObjects];
        [cachedWLANs addObjectsFromArray:networks];
    } else {
        // If called from background, the controller will get the result via delegate
        [self performSelectorOnMainThread:@selector(updateCachedWLANs:) 
                               withObject:networks 
                            waitUntilDone:NO];
    }
    
    return [[networks copy] autorelease];
}

- (void)updateCachedWLANs:(NSArray *)networks
{
    [cachedWLANs removeAllObjects];
    if (networks) {
        [cachedWLANs addObjectsFromArray:networks];
    }
    // Do NOT call delegate here - the caller handles the result directly
    // This avoids duplicate calls to wifiScanCompleted
}

- (int)runCommand:(NSString *)path arguments:(NSArray *)args output:(NSString **)output error:(NSString **)error
{
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:path];
    if (args) [task setArguments:args];
    NSPipe *outPipe = [NSPipe pipe];
    NSPipe *errPipe = [NSPipe pipe];
    [task setStandardOutput:outPipe];
    [task setStandardError:errPipe];

    // Force C locale for consistent tool output
    NSMutableDictionary *env = [[[NSProcessInfo processInfo] environment] mutableCopy];
    [env setObject:@"C" forKey:@"LC_ALL"];
    [task setEnvironment:env];
    [env release];

    int status = -1;
    @try {
        [task launch];
        [task waitUntilExit];
        status = [task terminationStatus];
        if (output) {
            NSData *data = [[outPipe fileHandleForReading] readDataToEndOfFile];
            *output = data ? [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease] : nil;
        }
        if (error) {
            NSData *data = [[errPipe fileHandleForReading] readDataToEndOfFile];
            *error = data ? [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease] : nil;
        }
    } @catch (NSException *e) {
        NSDebugLLog(@"gwcomp", @"[Network] Exception running command %@: %@", path, e);
    }
    [task release];
    return status;
}

- (NSMutableArray *)buildWLANsList
{
    NSMutableArray *networks = [NSMutableArray array];
    
    if (!nmAvailable) {
        return networks;
    }
    
    // Get WiFi list (non-privileged)
    NSString *output = nil;
    [self runCommand:nmcliPath arguments:@[@"-t", @"-f", @"SSID,BSSID,SIGNAL,SECURITY,IN-USE,FREQ,CHAN", @"device", @"wifi", @"list"] output:&output error:NULL];
    
    if (output) {
        NSArray *lines = [output componentsSeparatedByString:@"\n"];
        NSMutableDictionary *seenNetworks = [NSMutableDictionary dictionary];
        
        for (NSString *line in lines) {
            if ([line length] == 0) continue;
            
            // Handle escaped colons in SSID (nmcli uses \: for colons in SSIDs)
            NSString *processedLine = [line stringByReplacingOccurrencesOfString:@"\\:" withString:@"\x00"];
            NSArray *fields = [processedLine componentsSeparatedByString:@":"];
            if ([fields count] < 5) continue;
            
            NSString *ssid = [[fields objectAtIndex:0] stringByReplacingOccurrencesOfString:@"\x00" withString:@":"];
            NSString *bssid = [fields objectAtIndex:1];
            int signal = [[fields objectAtIndex:2] intValue];
            NSString *securityStr = [fields objectAtIndex:3];
            BOOL inUse = [[fields objectAtIndex:4] isEqualToString:@"*"];
            int freq = [fields count] > 5 ? [[fields objectAtIndex:5] intValue] : 0;
            int chan = [fields count] > 6 ? [[fields objectAtIndex:6] intValue] : 0;
            
            // Skip hidden networks (empty SSID)
            if ([ssid length] == 0) continue;
            
            // Check if we've already seen this network (keep the one with better signal)
            WLAN *existing = [seenNetworks objectForKey:ssid];
            if (existing && [existing signalStrength] >= signal) {
                // Preserve connected status when the existing entry is the connected one
                if ([existing isConnected] && !inUse) {
                    [existing setFrequency:freq];
                    [existing setChannel:chan];
                }
                continue;
            }
            
            WLAN *network = [[WLAN alloc] init];
            [network setSsid:ssid];
            [network setBssid:bssid];
            [network setSignalStrength:signal];
            [network setIsConnected:inUse];
            [network setFrequency:freq];
            [network setChannel:chan];
            
            // Parse security
            if ([securityStr length] == 0 || [securityStr isEqualToString:@"--"]) {
                [network setSecurity:WLANSecurityNone];
            } else if ([securityStr rangeOfString:@"WPA3"].location != NSNotFound) {
                [network setSecurity:WLANSecurityWPA3];
            } else if ([securityStr rangeOfString:@"WPA2"].location != NSNotFound) {
                [network setSecurity:WLANSecurityWPA2];
            } else if ([securityStr rangeOfString:@"WPA"].location != NSNotFound) {
                [network setSecurity:WLANSecurityWPA];
            } else if ([securityStr rangeOfString:@"WEP"].location != NSNotFound) {
                [network setSecurity:WLANSecurityWEP];
            } else if ([securityStr rangeOfString:@"802.1X"].location != NSNotFound) {
                [network setSecurity:WLANSecurityEnterprise];
            } else {
                [network setSecurity:WLANSecurityNone];
            }
            
            // Check if this is a saved network (use a local copy of connections for thread safety)
            NSArray *connectionsCopy = [[cachedConnections copy] autorelease];
            for (NetworkConnection *conn in connectionsCopy) {
                if ([conn type] == NetworkInterfaceTypeWLAN && 
                    [[conn ssid] isEqualToString:ssid]) {
                    [network setIsSaved:YES];
                    break;
                }
            }
            
            if (existing) {
                [networks removeObject:existing];
            }
            // Carry over connected status when a non-connected entry wins by signal
            if (existing && [existing isConnected] && !inUse) {
                [network setIsConnected:YES];
            }
            [seenNetworks setObject:network forKey:ssid];
            [networks addObject:network];
            [network release];
        }
        
        // Sort by signal strength (descending)
        [networks sortUsingComparator:^NSComparisonResult(WLAN *a, WLAN *b) {
            if ([a signalStrength] > [b signalStrength]) return NSOrderedAscending;
            if ([a signalStrength] < [b signalStrength]) return NSOrderedDescending;
            return NSOrderedSame;
        }];
    }
    
    return networks;
}

- (BOOL)startWLANScan
{
    // Perform scan in background
    [self performSelectorInBackground:@selector(scanForWLANs) withObject:nil];
    return YES;
}

- (BOOL)connectToWLAN:(WLAN *)network withPassword:(NSString *)password
{
    NSDebugLLog(@"gwcomp", @"[Network] connectToWLAN: called");
    
    if (!network) {
        NSDebugLLog(@"gwcomp", @"[Network] connectToWLAN: network is nil");
        [self reportErrorWithMessage:@"Cannot connect: no network specified"];
        return NO;
    }
    
    NSString *ssid = [network ssid];
    if (!ssid || [ssid length] == 0) {
        NSDebugLLog(@"gwcomp", @"[Network] connectToWLAN: SSID is nil or empty");
        [self reportErrorWithMessage:@"Cannot connect: network has no SSID"];
        return NO;
    }
    
    WLANSecurityType security = [network security];
    NSDebugLLog(@"gwcomp", @"[Network] connectToWLAN: connecting to SSID '%@', security=%d (password: %@)",
          ssid, (int)security, (password && [password length] > 0) ? @"<provided>" : @"<none>");
    
    return [self connectToWiFiViaNmcli:ssid password:password security:security];
}

- (BOOL)connectToWiFiViaNmcli:(NSString *)ssid password:(NSString *)password security:(WLANSecurityType)security
{
    NSDebugLLog(@"gwcomp", @"[Network] connectToWiFiViaNmcli: starting connection to '%@' (security=%d)", ssid, (int)security);
    
    if (!nmAvailable) {
        NSDebugLLog(@"gwcomp", @"[Network] connectToWiFiViaNmcli: nmcli not available");
        [self reportErrorWithMessage:@"Cannot connect: NetworkManager not available"];
        return NO;
    }
    
    if (!ssid || [ssid length] == 0) {
        NSDebugLLog(@"gwcomp", @"[Network] connectToWiFiViaNmcli: SSID is nil or empty");
        [self reportErrorWithMessage:@"Cannot connect: no SSID specified"];
        return NO;
    }
    
    if (!nmcliPath) {
        NSDebugLLog(@"gwcomp", @"[Network] connectToWiFiViaNmcli: nmcliPath is nil");
        [self reportErrorWithMessage:@"Cannot connect: nmcli path not set"];
        return NO;
    }
    
    // For secured networks, use 'nmcli connection add' with explicit security settings
    // This is more reliable than 'nmcli device wifi connect'
    if (security != WLANSecurityNone && password && [password length] > 0) {
        NSDebugLLog(@"gwcomp", @"[Network] connectToWiFiViaNmcli: using connection add method for secured network");
        return [self connectToSecuredWLAN:ssid password:password security:security];
    }
    
    // For open networks or when no password provided, use simple connect
    NSDebugLLog(@"gwcomp", @"[Network] connectToWiFiViaNmcli: using device wifi connect for open network");
    
    NSString *errStr = nil;
    NSMutableArray *args = [NSMutableArray arrayWithObjects:@"device", @"wifi", @"connect", ssid, nil];
    NSDebugLLog(@"gwcomp", @"[Network] connectToWiFiViaNmcli: command = nmcli device wifi connect '%@'", ssid);
    int exitStatus = [self runPrivilegedCommand:nmcliPath arguments:args output:NULL error:&errStr];
    BOOL success = (exitStatus == 0);
    
    if (success) {
        NSDebugLLog(@"gwcomp", @"[Network] connectToWiFiViaNmcli: connection successful");
        // Do NOT call refresh here - let the caller schedule a safe refresh on main thread
        return YES;
    }
    
    // Report the error
    NSString *errorMsg = (errStr && [errStr length] > 0) ? errStr : @"Connection failed (unknown error)";
    NSDebugLLog(@"gwcomp", @"[Network] connectToWiFiViaNmcli: reporting error: %@", errorMsg);
    [self reportErrorWithMessage:[NSString stringWithFormat:@"Failed to connect to '%@': %@", ssid, errorMsg]];
    
    return NO;
}

// Connect to a secured WiFi network by creating a connection profile
- (BOOL)connectToSecuredWLAN:(NSString *)ssid password:(NSString *)password security:(WLANSecurityType)security
{
    NSDebugLLog(@"gwcomp", @"[Network] connectToSecuredWLAN: ssid='%@' security=%d", ssid, (int)security);
    
    if (!ssid || !password) {
        NSDebugLLog(@"gwcomp", @"[Network] connectToSecuredWLAN: ssid or password is nil");
        [self reportErrorWithMessage:@"Cannot connect: SSID or password missing"];
        return NO;
    }
    
    // Determine key management type
    NSString *keyMgmt = nil;
    switch (security) {
        case WLANSecurityWPA:
        case WLANSecurityWPA2:
        case WLANSecurityWPA3:
            keyMgmt = @"wpa-psk";
            break;
        case WLANSecurityWEP:
            keyMgmt = @"none";  // WEP uses 'none' for key-mgmt but has wep-key
            break;
        case WLANSecurityEnterprise:
            keyMgmt = @"wpa-eap";
            break;
        default:
            NSDebugLLog(@"gwcomp", @"[Network] connectToSecuredWLAN: unsupported security type");
            [self reportErrorWithMessage:@"Unsupported security type"];
            return NO;
    }
    
    NSDebugLLog(@"gwcomp", @"[Network] connectToSecuredWLAN: key-mgmt = %@", keyMgmt);
    
    // First, delete any existing connection with this SSID to avoid duplicates
    NSDebugLLog(@"gwcomp", @"[Network] connectToSecuredWLAN: checking for existing connection...");
    [self deleteConnectionBySSID:ssid];
    
    // Create new connection using nmcli connection add
    // nmcli connection add type wifi con-name "SSID" ssid "SSID" wifi-sec.key-mgmt wpa-psk wifi-sec.psk "password"
    NSMutableArray *args = [NSMutableArray array];
    [args addObject:@"connection"];
    [args addObject:@"add"];
    [args addObject:@"type"];
    [args addObject:@"wifi"];
    [args addObject:@"con-name"];
    [args addObject:ssid];
    [args addObject:@"ssid"];
    [args addObject:ssid];
    [args addObject:@"wifi-sec.key-mgmt"];
    [args addObject:keyMgmt];
    
    if (security == WLANSecurityWEP) {
        [args addObject:@"wifi-sec.wep-key0"];
        [args addObject:password];
    } else {
        [args addObject:@"wifi-sec.psk"];
        [args addObject:password];
    }
    
    NSDebugLLog(@"gwcomp", @"[Network] connectToSecuredWLAN: command = nmcli connection add type wifi con-name '%@' ssid '%@' wifi-sec.key-mgmt %@ wifi-sec.psk <hidden>",
          ssid, ssid, keyMgmt);
    
    NSString *errStr = nil;
    int exitStatus = [self runPrivilegedCommand:nmcliPath arguments:args output:NULL error:&errStr];
    NSDebugLLog(@"gwcomp", @"[Network] connectToSecuredWLAN: connection add exited with status %d", exitStatus);
    
    if (exitStatus != 0) {
        NSString *errorMsg = (errStr && [errStr length] > 0) ? errStr : @"Failed to create connection profile";
        NSDebugLLog(@"gwcomp", @"[Network] connectToSecuredWLAN: connection add failed: %@", errorMsg);
        
        // Try with privileged helper
        NSDebugLLog(@"gwcomp", @"[Network] connectToSecuredWLAN: trying privileged helper...");
        NSError *helperError = nil;
        NSMutableArray *helperArgs = [NSMutableArray arrayWithObjects:@"wlan-connect", ssid, password, nil];
        
        BOOL success = [self runPrivilegedHelper:helperArgs error:&helperError];
        if (!success) {
            NSString *helperErrMsg = helperError ? [helperError localizedDescription] : errorMsg;
            [self reportErrorWithMessage:[NSString stringWithFormat:@"Failed to connect to '%@': %@", ssid, helperErrMsg]];
            return NO;
        }
        
        NSDebugLLog(@"gwcomp", @"[Network] connectToSecuredWLAN: privileged helper succeeded");
        // Do NOT call refresh here - let the caller schedule a safe refresh on main thread
        return YES;
    }
        
    // Now activate the connection
    NSDebugLLog(@"gwcomp", @"[Network] connectToSecuredWLAN: activating connection '%@'...", ssid);
    
    NSString *upErrStr = nil;
    int upExitStatus = [self runPrivilegedCommand:nmcliPath arguments:@[@"connection", @"up", ssid] output:NULL error:&upErrStr];
    NSDebugLLog(@"gwcomp", @"[Network] connectToSecuredWLAN: connection up exited with status %d", upExitStatus);
    
    if (upExitStatus != 0) {
        NSString *upErrorMsg = (upErrStr && [upErrStr length] > 0) ? upErrStr : @"Failed to activate connection";
        NSDebugLLog(@"gwcomp", @"[Network] connectToSecuredWLAN: connection up failed: %@", upErrorMsg);
        
        // Check if it's an auth error (wrong password)
        if (upErrStr && ([upErrStr rangeOfString:@"Secrets were required" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                        [upErrStr rangeOfString:@"No secrets" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                        [upErrStr rangeOfString:@"password" options:NSCaseInsensitiveSearch].location != NSNotFound)) {
            [self reportErrorWithMessage:[NSString stringWithFormat:@"Failed to connect to '%@': incorrect password", ssid]];
        } else {
            [self reportErrorWithMessage:[NSString stringWithFormat:@"Failed to connect to '%@': %@", ssid, upErrorMsg]];
        }
        
        // Clean up the failed connection profile
        [self deleteConnectionBySSID:ssid];
        return NO;
    }
    
    NSDebugLLog(@"gwcomp", @"[Network] connectToSecuredWLAN: connection successful");
    // Do NOT call refresh here - let the caller schedule a safe refresh on main thread
    return YES;
}

// Helper to delete a connection by SSID (used to clean up before reconnecting)
- (void)deleteConnectionBySSID:(NSString *)ssid
{
    if (!ssid || !nmcliPath) return;
    
    NSDebugLLog(@"gwcomp", @"[Network] deleteConnectionBySSID: deleting any existing connection for '%@'", ssid);
    
    int status = [self runPrivilegedCommand:nmcliPath arguments:@[@"connection", @"delete", ssid] output:NULL error:NULL];
    NSDebugLLog(@"gwcomp", @"[Network] deleteConnectionBySSID: delete exited with status %d", status);
}

- (BOOL)disconnectFromWLAN
{
    NSLog(@"NMBackend: disconnectFromWLAN called, nmAvailable=%d cachedInterfaces=%lu", nmAvailable, (unsigned long)[cachedInterfaces count]);
    
    if (!nmAvailable) {
        NSLog(@"NMBackend: disconnectFromWLAN — backend not available");
        return NO;
    }
    
    // Refresh interface list
    [self getInterfacesViaNmcli];
    NSLog(@"NMBackend: disconnectFromWLAN — after refresh, %lu interfaces", (unsigned long)[cachedInterfaces count]);
    
    // Find WiFi device and disconnect it
    for (NetworkInterface *iface in cachedInterfaces) {
        NSLog(@"NMBackend: disconnectFromWLAN — checking iface %@ type=%ld active=%d", [iface name], (long)[iface type], [iface isActive]);
        if ([iface type] == NetworkInterfaceTypeWLAN && [iface isActive]) {
            NSLog(@"NMBackend: disconnectFromWLAN — disconnecting '%@'", [iface name]);
            return [self disableInterface:iface];
        }
    }
    
    NSLog(@"NMBackend: disconnectFromWLAN — no active WiFi interface found");
    return NO;
}

- (WLAN *)connectedWLAN
{
    for (WLAN *network in cachedWLANs) {
        if ([network isConnected]) {
            NSLog(@"NMBackend: connectedWLAN = %@ (signal=%d)", [network ssid], [network signalStrength]);
            return network;
        }
    }
    return nil;
}

#pragma mark - Status

- (NetworkConnectionState)globalConnectionState
{
    if (!nmAvailable) {
        return NetworkConnectionStateUnavailable;
    }
    
    NSString *output = nil;
    [self runPrivilegedCommand:nmcliPath arguments:@[@"-t", @"-f", @"STATE", @"general"] output:&output error:NULL];
    
    if (output) {
        output = [output stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        
        if ([output isEqualToString:@"connected"]) {
            return NetworkConnectionStateConnected;
        } else if ([output isEqualToString:@"connecting"]) {
            return NetworkConnectionStateConnecting;
        } else if ([output isEqualToString:@"disconnected"]) {
            return NetworkConnectionStateDisconnected;
        } else if ([output isEqualToString:@"disconnecting"]) {
            return NetworkConnectionStateDisconnecting;
        }
    }
    
    return NetworkConnectionStateUnknown;
}

- (NSString *)primaryConnectionName
{
    for (NetworkInterface *iface in cachedInterfaces) {
        if ([iface isActive]) {
            return [iface displayName];
        }
    }
    return nil;
}

- (NetworkInterface *)primaryInterface
{
    for (NetworkInterface *iface in cachedInterfaces) {
        if ([iface isActive]) {
            return iface;
        }
    }
    return nil;
}

#pragma mark - Refresh

- (void)refresh
{
    // Ensure all delegate callbacks happen on main thread
    if (![NSThread isMainThread]) {
        NSDebugLLog(@"gwcomp", @"[Network] refresh: redirecting to main thread");
        [self performSelectorOnMainThread:@selector(refresh) withObject:nil waitUntilDone:NO];
        return;
    }
    
    NSDebugLLog(@"gwcomp", @"[Network] refresh: refreshing interfaces and connections...");
    
    [self getInterfacesViaNmcli];
    [self getConnectionsViaNmcli];
    [self isWLANEnabled]; // Update cached wifi state
    
    // Create copies for delegate callbacks to avoid threading issues
    NSArray *interfacesCopy = [[cachedInterfaces copy] autorelease];
    NSArray *connectionsCopy = [[cachedConnections copy] autorelease];
    
    if (delegate && [delegate respondsToSelector:@selector(networkBackend:didUpdateInterfaces:)]) {
        [delegate networkBackend:self didUpdateInterfaces:interfacesCopy];
    }
    
    if (delegate && [delegate respondsToSelector:@selector(networkBackend:didUpdateConnections:)]) {
        [delegate networkBackend:self didUpdateConnections:connectionsCopy];
    }
    
    NSDebugLLog(@"gwcomp", @"[Network] refresh: complete");
}

#pragma mark - Type Conversion Helpers

- (NetworkInterfaceType)interfaceTypeFromNMDeviceType:(int)nmType
{
    switch (nmType) {
        case NM_DEVICE_TYPE_ETHERNET:
            return NetworkInterfaceTypeEthernet;
        case NM_DEVICE_TYPE_WIFI:
            return NetworkInterfaceTypeWLAN;
        case NM_DEVICE_TYPE_BT:
            return NetworkInterfaceTypeBluetooth;
        case NM_DEVICE_TYPE_BRIDGE:
            return NetworkInterfaceTypeBridge;
        default:
            return NetworkInterfaceTypeUnknown;
    }
}

- (NetworkConnectionState)stateFromNMDeviceState:(int)nmState
{
    switch (nmState) {
        case NM_DEVICE_STATE_ACTIVATED:
            return NetworkConnectionStateConnected;
        case NM_DEVICE_STATE_PREPARE:
        case NM_DEVICE_STATE_CONFIG:
        case NM_DEVICE_STATE_IP_CONFIG:
        case NM_DEVICE_STATE_IP_CHECK:
        case NM_DEVICE_STATE_SECONDARIES:
            return NetworkConnectionStateConnecting;
        case NM_DEVICE_STATE_DISCONNECTED:
            return NetworkConnectionStateDisconnected;
        case NM_DEVICE_STATE_DEACTIVATING:
            return NetworkConnectionStateDisconnecting;
        case NM_DEVICE_STATE_NEED_AUTH:
            return NetworkConnectionStateNeedsAuth;
        case NM_DEVICE_STATE_FAILED:
            return NetworkConnectionStateFailed;
        case NM_DEVICE_STATE_UNAVAILABLE:
        case NM_DEVICE_STATE_UNMANAGED:
            return NetworkConnectionStateUnavailable;
        default:
            return NetworkConnectionStateUnknown;
    }
}

- (WLANSecurityType)securityFromAccessPointFlags:(int)flags wpaFlags:(int)wpa rsnFlags:(int)rsn
{
    if (rsn != 0) {
        return WLANSecurityWPA2;
    } else if (wpa != 0) {
        return WLANSecurityWPA;
    } else if (flags != 0) {
        return WLANSecurityWEP;
    }
    return WLANSecurityNone;
}

@end
