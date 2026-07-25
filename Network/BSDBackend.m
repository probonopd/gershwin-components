/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * BSD Network Backend Implementation
 *
 * Uses native FreeBSD tools (ifconfig, wpa_cli, sysrc, dhclient)
 * to manage network interfaces and connections.
 */

#import "BSDBackend.h"
#import <AppKit/AppKit.h>

/* Known Ethernet driver prefixes on FreeBSD */
static NSArray *ethernetPrefixes(void)
{
    return @[
        @"em", @"igb", @"ixl", @"ixgbe", @"re", @"bge", @"bce",
        @"fxp", @"dc", @"rl", @"sis", @"sk", @"xl", @"vr",
        @"ale", @"alc", @"age", @"jme", @"msk", @"nfe", @"ste",
        @"tl", @"tx", @"vge", @"vte", @"vtnet", @"vmx", @"axe",
        @"ue", @"ure", @"cue", @"kue", @"rue", @"udav",
        @"bxe", @"cxgb", @"mxge", @"oce", @"qlxge"
    ];
}

@implementation BSDBackend

@synthesize delegate;

#pragma mark - Initialization

- (id)init
{
    self = [super init];
    if (self) {
        cachedInterfaces = [[NSMutableArray alloc] init];
        cachedConnections = [[NSMutableArray alloc] init];
        cachedWLANs = [[NSMutableArray alloc] init];
        wlanDeviceMap = [[NSMutableDictionary alloc] init];
        wifiEnabled = NO;
        primaryWLANDevice = nil;
        helperPath = nil;
        ifconfigPath = nil;
        sysrcPath = nil;
        wpaCliPath = nil;
        dhclientPath = nil;
        sysctlPath = nil;
        sudoPath = nil;

        backendAvailable = [self discoverTools];

        helperPath = [[self findHelperPath] retain];

        if (backendAvailable) {
            NSDebugLLog(@"gwcomp", @"[Network] BSDBackend initialized");
            [self discoverWLANDevice];
        } else {
            NSDebugLLog(@"gwcomp", @"[Network] BSDBackend: required tools not found, backend unavailable");
        }
    }
    return self;
}

- (void)dealloc
{
    [cachedInterfaces release];
    [cachedConnections release];
    [cachedWLANs release];
    [wlanDeviceMap release];
    [primaryWLANDevice release];
    [helperPath release];
    [ifconfigPath release];
    [sysrcPath release];
    [wpaCliPath release];
    [dhclientPath release];
    [sysctlPath release];
    [sudoPath release];
    [super dealloc];
}

#pragma mark - Tool Discovery

- (NSString *)findExecutable:(NSString *)name
{
    NSArray *paths = @[
        @"/sbin",
        @"/usr/sbin",
        @"/bin",
        @"/usr/bin",
        @"/usr/local/sbin",
        @"/usr/local/bin"
    ];

    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *dir in paths) {
        NSString *full = [dir stringByAppendingPathComponent:name];
        if ([fm isExecutableFileAtPath:full]) {
            return full;
        }
    }

    /* Try which(1) as fallback */
    NSTask *task = [[NSTask alloc] init];
    @try {
        [task setLaunchPath:@"/usr/bin/which"];
        [task setArguments:@[name]];
        NSPipe *pipe = [NSPipe pipe];
        [task setStandardOutput:pipe];
        [task setStandardError:[NSPipe pipe]];
        [task launch];
        [task waitUntilExit];
        if ([task terminationStatus] == 0) {
            NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
            NSString *result = [[[NSString alloc] initWithData:data
                                                      encoding:NSUTF8StringEncoding] autorelease];
            result = [result stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if ([fm isExecutableFileAtPath:result]) {
                [task release];
                return result;
            }
        }
    } @catch (NSException *e) {
        NSDebugLLog(@"gwcomp", @"[Network] BSDBackend: exception finding %@: %@", name, e);
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

- (BOOL)discoverTools
{
    ifconfigPath = [[self findExecutable:@"ifconfig"] retain];
    sysrcPath = [[self findExecutable:@"sysrc"] retain];
    wpaCliPath = [[self findExecutable:@"wpa_cli"] retain];
    dhclientPath = [[self findExecutable:@"dhclient"] retain];
    sysctlPath = [[self findExecutable:@"sysctl"] retain];
    sudoPath = [[self findExecutable:@"sudo"] retain];

    if (ifconfigPath) {
        NSDebugLLog(@"gwcomp", @"[Network] BSDBackend: ifconfig at %@", ifconfigPath);
    } else {
        NSDebugLLog(@"gwcomp", @"[Network] BSDBackend: ifconfig NOT found");
    }
    if (sysrcPath) {
        NSDebugLLog(@"gwcomp", @"[Network] BSDBackend: sysrc at %@", sysrcPath);
    }
    if (wpaCliPath) {
        NSDebugLLog(@"gwcomp", @"[Network] BSDBackend: wpa_cli at %@", wpaCliPath);
    }
    if (dhclientPath) {
        NSDebugLLog(@"gwcomp", @"[Network] BSDBackend: dhclient at %@", dhclientPath);
    }
    if (sudoPath) {
        NSDebugLLog(@"gwcomp", @"[Network] BSDBackend: sudo at %@", sudoPath);
    }

    /* ifconfig is the minimum requirement */
    return (ifconfigPath != nil);
}

#pragma mark - Command Execution

- (NSString *)runCommand:(NSString *)path arguments:(NSArray *)args
{
    NSString *output = nil;
    (void)[self runCommandWithStatus:path arguments:args output:&output];
    return output;
}

- (int)runCommandWithStatus:(NSString *)path arguments:(NSArray *)args
                     output:(NSString **)output
{
    if (!path) {
        if (output) *output = nil;
        return -1;
    }

    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:path];
    if (args) {
        [task setArguments:args];
    }

    NSPipe *outPipe = [NSPipe pipe];
    [task setStandardOutput:outPipe];
    [task setStandardError:[NSPipe pipe]];

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

        NSData *data = [[outPipe fileHandleForReading] readDataToEndOfFile];
        if (output && data) {
            *output = [[[NSString alloc] initWithData:data
                                             encoding:NSUTF8StringEncoding] autorelease];
        }
    } @catch (NSException *e) {
        NSDebugLLog(@"gwcomp", @"[Network] BSDBackend: exception running %@: %@", path, e);
        if (output) *output = nil;
    }
    [task release];
    return status;
}

#pragma mark - Privileged Helper

- (BOOL)runPrivilegedHelper:(NSArray *)arguments error:(NSError **)error
{
    if (!arguments || [arguments count] == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"BSDBackendError" code:1
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         NSLocalizedString(@"No arguments provided to helper",
                                                           @"Helper error")}];
        }
        return NO;
    }

    if (!helperPath) {
        if (error) {
            *error = [NSError errorWithDomain:@"BSDBackendError" code:1
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         NSLocalizedString(@"Network helper tool not found",
                                                           @"Helper error")}];
        }
        return NO;
    }

    if (!sudoPath) {
        if (error) {
            *error = [NSError errorWithDomain:@"BSDBackendError" code:1
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         NSLocalizedString(@"sudo not found",
                                                           @"Helper error")}];
        }
        return NO;
    }

    NSMutableArray *sudoArgs = [NSMutableArray arrayWithObjects:@"-A", @"-E",
                                helperPath, nil];
    [sudoArgs addObjectsFromArray:arguments];

    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:sudoPath];
    [task setArguments:sudoArgs];

    NSPipe *errPipe = [NSPipe pipe];
    NSPipe *outPipe = [NSPipe pipe];
    [task setStandardError:errPipe];
    [task setStandardOutput:outPipe];

    @try {
        [task launch];

        NSDictionary *taskInfo = @{
            @"task": task,
            @"errPipe": errPipe,
            @"outPipe": outPipe
        };

        [NSThread detachNewThreadSelector:@selector(waitForTaskCompletion:)
                                 toTarget:self
                               withObject:taskInfo];
        [task release];
        return YES;
    } @catch (NSException *e) {
        NSDebugLLog(@"gwcomp", @"[Network] BSDBackend: privileged helper exception: %@", e);
        [task release];
        if (error) {
            *error = [NSError errorWithDomain:@"BSDBackendError" code:2
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         [e reason] ? [e reason] : @"Unknown exception"}];
        }
        return NO;
    }
}

- (void)waitForTaskCompletion:(NSDictionary *)taskInfo
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    @try {
        NSTask *task = [taskInfo objectForKey:@"task"];
        NSPipe *errPipe = [taskInfo objectForKey:@"errPipe"];
        NSPipe *outPipe = [taskInfo objectForKey:@"outPipe"];

        if (!task) { [pool release]; return; }

        [task waitUntilExit];
        int status = [task terminationStatus];

        NSData *errData = [[errPipe fileHandleForReading] readDataToEndOfFile];
        NSString *errStr = nil;
        if (errData && [errData length] > 0) {
            errStr = [[[NSString alloc] initWithData:errData
                                            encoding:NSUTF8StringEncoding] autorelease];
            errStr = [errStr stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        }

        NSData *outData = [[outPipe fileHandleForReading] readDataToEndOfFile];
        if (outData && [outData length] > 0) {
            NSString *outStr = [[[NSString alloc] initWithData:outData
                                                      encoding:NSUTF8StringEncoding] autorelease];
            NSDebugLLog(@"gwcomp", @"[Network] BSDBackend helper stdout: %@", outStr);
        }

        if (status != 0) {
            NSString *msg = (errStr && [errStr length] > 0) ? errStr :
                NSLocalizedString(@"Operation failed", @"Helper error");
            NSDebugLLog(@"gwcomp", @"[Network] BSDBackend helper failed: %@", msg);
            [self performSelectorOnMainThread:@selector(reportErrorWithMessage:)
                                   withObject:msg
                                waitUntilDone:NO];
        } else {
            NSDebugLLog(@"gwcomp", @"[Network] BSDBackend helper succeeded");
        }
    } @catch (NSException *e) {
        NSDebugLLog(@"gwcomp", @"[Network] BSDBackend waitForTaskCompletion exception: %@", e);
    }
    [pool release];
}

- (void)reportErrorWithMessage:(NSString *)message
{
    if (message && [message length] > 0) {
        NSDebugLLog(@"gwcomp", @"[Network] BSDBackend error: %@", message);
        if (delegate && [delegate respondsToSelector:
                         @selector(networkBackend:didEncounterError:)]) {
            NSError *err = [NSError errorWithDomain:@"BSDBackendError" code:1
                                           userInfo:@{NSLocalizedDescriptionKey: message}];
            [delegate networkBackend:self didEncounterError:err];
        }
    }
}

- (int)runPrivilegedCommand:(NSString *)path arguments:(NSArray *)args output:(NSString **)output
{
    NSTask *task = [[NSTask alloc] init];
    if (sudoPath) {
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
    [task setStandardOutput:outPipe];
    [task setStandardError:[NSPipe pipe]];

    int status = -1;
    @try {
        [task launch];
        [task waitUntilExit];
        status = [task terminationStatus];
        if (output) {
            NSData *data = [[outPipe fileHandleForReading] readDataToEndOfFile];
            *output = data ? [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease] : nil;
        }
    } @catch (NSException *e) {
        NSDebugLLog(@"gwcomp", @"[Network] BSDBackend: exception running privileged command %@: %@", path, e);
        if (output) *output = nil;
    }
    [task release];
    return status;
}

#pragma mark - NetworkBackend Protocol - Identification

- (NSString *)backendName
{
    return @"BSD ifconfig";
}

- (NSString *)backendVersion
{
    NSString *output = nil;
    [self runPrivilegedCommand:ifconfigPath arguments:@[@"--version"] output:&output];
    /* ifconfig on FreeBSD doesn't have --version; return OS version instead */
    if (!output || [output length] == 0) {
        NSString *unameOutput = nil;
        (void)[self runCommandWithStatus:@"/usr/bin/uname"
                               arguments:@[@"-r"]
                                  output:&unameOutput];
        if (unameOutput) {
            return [unameOutput stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        }
        return @"Unknown";
    }
    return [output stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

- (BOOL)isAvailable
{
    return backendAvailable;
}

#pragma mark - Interface Detection

- (NSArray *)listInterfaceNames
{
    /*
     * On FreeBSD: ifconfig -l returns a space-separated list of interfaces.
     * On Linux this may not be available, but BSDBackend is only used on FreeBSD.
     */
    NSString *output = nil;
    [self runPrivilegedCommand:ifconfigPath arguments:@[@"-l"] output:&output];
    if (!output || [output length] == 0) {
        return @[];
    }
    output = [output stringByTrimmingCharactersInSet:
              [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return [output componentsSeparatedByString:@" "];
}

- (NetworkInterfaceType)classifyInterface:(NSString *)ifaceName
{
    if (!ifaceName) return NetworkInterfaceTypeUnknown;

    if ([ifaceName hasPrefix:@"lo"]) {
        return NetworkInterfaceTypeLoopback;
    }
    if ([ifaceName hasPrefix:@"wlan"]) {
        return NetworkInterfaceTypeWLAN;
    }
    if ([ifaceName hasPrefix:@"bridge"]) {
        return NetworkInterfaceTypeBridge;
    }

    /* Check known Ethernet driver prefixes */
    for (NSString *prefix in ethernetPrefixes()) {
        if ([ifaceName hasPrefix:prefix]) {
            return NetworkInterfaceTypeEthernet;
        }
    }

    /* Check for USB Ethernet-like adapters (axe0, ue0, etc. are Ethernet) */
    if ([ifaceName hasPrefix:@"usbus"]) {
        return NetworkInterfaceTypeUnknown;  /* USB bus, skip */
    }

    /* Default: Unknown */
    return NetworkInterfaceTypeUnknown;
}

- (NetworkConnectionState)parseInterfaceState:(NSString *)output
{
    if (!output) return NetworkConnectionStateUnknown;

    /*
     * Look for flags like UP, RUNNING and "status: active" / "status: associated"
     * in ifconfig output.
     */
    BOOL hasUp = ([output rangeOfString:@"<UP,"
                               options:NSCaseInsensitiveSearch].location != NSNotFound ||
                  [output rangeOfString:@"<UP>"
                               options:NSCaseInsensitiveSearch].location != NSNotFound);
    BOOL hasRunning = ([output rangeOfString:@"RUNNING"
                                    options:NSCaseInsensitiveSearch].location != NSNotFound);
    BOOL statusActive = ([output rangeOfString:@"status: active"
                                       options:NSCaseInsensitiveSearch].location != NSNotFound);
    BOOL statusAssociated = ([output rangeOfString:@"status: associated"
                                           options:NSCaseInsensitiveSearch].location != NSNotFound);
    BOOL statusNoCarrier = ([output rangeOfString:@"status: no carrier"
                                          options:NSCaseInsensitiveSearch].location != NSNotFound);

    if (hasUp && hasRunning && (statusActive || statusAssociated)) {
        return NetworkConnectionStateConnected;
    }
    if (hasUp && hasRunning && statusNoCarrier) {
        return NetworkConnectionStateDisconnected;
    }
    if (hasUp && hasRunning) {
        /* UP and RUNNING but no explicit status — assume connected */
        return NetworkConnectionStateConnected;
    }
    if (hasUp) {
        return NetworkConnectionStateDisconnected;
    }

    return NetworkConnectionStateUnavailable;
}

- (NSString *)parseHardwareAddress:(NSString *)output
{
    if (!output) return nil;

    /* Look for "ether xx:xx:xx:xx:xx:xx" */
    NSArray *lines = [output componentsSeparatedByString:@"\n"];
    for (NSString *line in lines) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:
                             [NSCharacterSet whitespaceCharacterSet]];
        if ([trimmed hasPrefix:@"ether "]) {
            NSString *mac = [trimmed substringFromIndex:6];
            mac = [mac stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            /* MAC may have trailing info, take first token */
            NSArray *tokens = [mac componentsSeparatedByString:@" "];
            if ([tokens count] > 0) {
                return [tokens objectAtIndex:0];
            }
        }
    }
    return nil;
}

- (IPConfiguration *)parseIPv4Config:(NSString *)output
{
    if (!output) return nil;

    IPConfiguration *ipv4 = [[[IPConfiguration alloc] init] autorelease];
    NSArray *lines = [output componentsSeparatedByString:@"\n"];

    for (NSString *line in lines) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:
                             [NSCharacterSet whitespaceCharacterSet]];

        /* Look for "inet 192.168.1.100 netmask 0xffffff00 broadcast 192.168.1.255" */
        if ([trimmed hasPrefix:@"inet "]) {
            NSArray *tokens = [trimmed componentsSeparatedByString:@" "];
            NSUInteger count = [tokens count];

            for (NSUInteger i = 0; i < count; i++) {
                NSString *tok = [tokens objectAtIndex:i];
                if ([tok isEqualToString:@"inet"] && i + 1 < count) {
                    [ipv4 setAddress:[tokens objectAtIndex:i + 1]];
                }
                if ([tok isEqualToString:@"netmask"] && i + 1 < count) {
                    NSString *mask = [tokens objectAtIndex:i + 1];
                    /* Convert hex mask (0xffffff00) to dotted decimal */
                    if ([mask hasPrefix:@"0x"]) {
                        unsigned int maskVal = 0;
                        NSScanner *scanner = [NSScanner scannerWithString:mask];
                        [scanner scanHexInt:&maskVal];
                        mask = [NSString stringWithFormat:@"%d.%d.%d.%d",
                                (maskVal >> 24) & 0xFF,
                                (maskVal >> 16) & 0xFF,
                                (maskVal >> 8) & 0xFF,
                                maskVal & 0xFF];
                    }
                    [ipv4 setSubnetMask:mask];
                }
            }

            if ([ipv4 address]) {
                [ipv4 setMethod:IPConfigMethodDHCP]; /* Assume DHCP for now */
            }
        }
    }

    /* Try to get default gateway from routing table */
    NSString *routeOutput = nil;
    (void)[self runPrivilegedCommand:@"/usr/bin/netstat"
                           arguments:@[@"-rn", @"-f", @"inet"]
                              output:&routeOutput];
    if (routeOutput) {
        NSArray *routeLines = [routeOutput componentsSeparatedByString:@"\n"];
        for (NSString *rline in routeLines) {
            NSString *rtrimmed = [rline stringByTrimmingCharactersInSet:
                                  [NSCharacterSet whitespaceCharacterSet]];
            if ([rtrimmed hasPrefix:@"default"] || [rtrimmed hasPrefix:@"0.0.0.0"]) {
                /* Split by whitespace */
                NSArray *parts = [rtrimmed componentsSeparatedByCharactersInSet:
                                  [NSCharacterSet whitespaceCharacterSet]];
                /* Filter empty strings */
                NSMutableArray *tokens = [NSMutableArray array];
                for (NSString *p in parts) {
                    if ([p length] > 0) [tokens addObject:p];
                }
                if ([tokens count] >= 2) {
                    [ipv4 setRouter:[tokens objectAtIndex:1]];
                }
                break;
            }
        }
    }

    /* Read DNS from /etc/resolv.conf */
    NSString *resolvConf = [NSString stringWithContentsOfFile:@"/etc/resolv.conf"
                                                     encoding:NSUTF8StringEncoding
                                                        error:nil];
    if (resolvConf) {
        NSMutableArray *dns = [NSMutableArray array];
        NSArray *rcLines = [resolvConf componentsSeparatedByString:@"\n"];
        for (NSString *rcLine in rcLines) {
            NSString *rtrim = [rcLine stringByTrimmingCharactersInSet:
                               [NSCharacterSet whitespaceCharacterSet]];
            if ([rtrim hasPrefix:@"nameserver "]) {
                NSString *server = [rtrim substringFromIndex:11];
                server = [server stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if ([server length] > 0) {
                    [dns addObject:server];
                }
            }
        }
        if ([dns count] > 0) {
            [ipv4 setDnsServers:dns];
        }
    }

    return ipv4;
}

- (NetworkInterface *)parseInterfaceDetails:(NSString *)ifaceName
{
    NSString *output = nil;
    [self runPrivilegedCommand:ifconfigPath arguments:@[ifaceName] output:&output];
    if (!output || [output length] == 0) return nil;

    NetworkInterface *iface = [[[NetworkInterface alloc] init] autorelease];
    [iface setIdentifier:ifaceName];
    [iface setName:ifaceName];

    NetworkInterfaceType ifType = [self classifyInterface:ifaceName];
    [iface setType:ifType];

    switch (ifType) {
        case NetworkInterfaceTypeEthernet:
            [iface setDisplayName:[NSString stringWithFormat:
                NSLocalizedString(@"Ethernet (%@)", @"Interface display name"), ifaceName]];
            break;
        case NetworkInterfaceTypeWLAN:
            [iface setDisplayName:[NSString stringWithFormat:
                NSLocalizedString(@"WLAN (%@)", @"Interface display name"), ifaceName]];
            break;
        case NetworkInterfaceTypeBridge:
            [iface setDisplayName:[NSString stringWithFormat:
                NSLocalizedString(@"Bridge (%@)", @"Interface display name"), ifaceName]];
            break;
        default:
            [iface setDisplayName:ifaceName];
            break;
    }

    NetworkConnectionState state = [self parseInterfaceState:output];
    [iface setState:state];
    [iface setIsActive:(state == NetworkConnectionStateConnected)];
    [iface setIsEnabled:(state != NetworkConnectionStateUnavailable)];

    [iface setHardwareAddress:[self parseHardwareAddress:output]];
    [iface setIpv4Config:[self parseIPv4Config:output]];

    return iface;
}

#pragma mark - Interface Management

- (NSArray *)availableInterfaces
{
    [cachedInterfaces removeAllObjects];

    if (!backendAvailable) {
        return cachedInterfaces;
    }

    NSArray *names = [self listInterfaceNames];
    for (NSString *name in names) {
        /* Skip loopback and pseudo-interfaces */
        if ([name hasPrefix:@"lo"] || [name hasPrefix:@"pflog"] ||
            [name hasPrefix:@"pfsync"] || [name hasPrefix:@"enc"] ||
            [name hasPrefix:@"usbus"] || [name hasPrefix:@"gif"] ||
            [name hasPrefix:@"stf"]) {
            continue;
        }

        NetworkInterfaceType ifType = [self classifyInterface:name];
        if (ifType == NetworkInterfaceTypeUnknown) {
            continue; /* Skip unknown interfaces */
        }

        /* Setup NIC in rc.conf if needed (Ethernet NICs) */
        if (ifType == NetworkInterfaceTypeEthernet) {
            [self setupNIC:name];
        }

        NetworkInterface *iface = [self parseInterfaceDetails:name];
        if (iface) {
            [cachedInterfaces addObject:iface];
        }
    }

    return [[cachedInterfaces copy] autorelease];
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
    if (!interface) return NO;

    NSString *name = [interface name];
    NSDebugLLog(@"gwcomp", @"[Network] BSDBackend: enabling interface %@", name);

    NSError *err = nil;
    BOOL ok = [self runPrivilegedHelper:@[@"interface-enable", name] error:&err];
    if (!ok) {
        [self reportErrorWithMessage:[NSString stringWithFormat:
            NSLocalizedString(@"Failed to enable interface '%@': %@",
                              @"Enable error"),
            [interface displayName],
            err ? [err localizedDescription] : @"unknown error"]];
    }
    return ok;
}

- (BOOL)disableInterface:(NetworkInterface *)interface
{
    if (!interface) return NO;

    NSString *name = [interface name];
    NSDebugLLog(@"gwcomp", @"[Network] BSDBackend: disabling interface %@", name);

    NSError *err = nil;
    BOOL ok = [self runPrivilegedHelper:@[@"interface-disable", name] error:&err];
    if (!ok) {
        [self reportErrorWithMessage:[NSString stringWithFormat:
            NSLocalizedString(@"Failed to disable interface '%@': %@",
                              @"Disable error"),
            [interface displayName],
            err ? [err localizedDescription] : @"unknown error"]];
    }
    return ok;
}

#pragma mark - Connection Management

- (NSArray *)savedConnections
{
    /*
     * On FreeBSD, "saved connections" aren't managed the same way as NM.
     * We parse /etc/wpa_supplicant.conf for known WLAN networks and
     * /etc/rc.conf for configured interfaces.
     */
    [cachedConnections removeAllObjects];

    /* Parse wpa_supplicant.conf for saved wireless networks */
    NSString *wpaConf = [NSString stringWithContentsOfFile:@"/etc/wpa_supplicant.conf"
                                                  encoding:NSUTF8StringEncoding
                                                     error:nil];
    if (wpaConf) {
        NSArray *lines = [wpaConf componentsSeparatedByString:@"\n"];
        BOOL inNetwork = NO;
        NSString *currentSSID = nil;

        for (NSString *line in lines) {
            NSString *trimmed = [line stringByTrimmingCharactersInSet:
                                 [NSCharacterSet whitespaceCharacterSet]];

            if ([trimmed isEqualToString:@"network={"]) {
                inNetwork = YES;
                currentSSID = nil;
                continue;
            }
            if ([trimmed isEqualToString:@"}"] && inNetwork) {
                if (currentSSID) {
                    NetworkConnection *conn = [[NetworkConnection alloc] init];
                    [conn setName:currentSSID];
                    [conn setSsid:currentSSID];
                    [conn setType:NetworkInterfaceTypeWLAN];
                    [conn setAutoConnect:YES];
                    [conn setUuid:currentSSID]; /* Use SSID as identifier */
                    [conn setIdentifier:currentSSID];
                    [cachedConnections addObject:conn];
                    [conn release];
                }
                inNetwork = NO;
                currentSSID = nil;
                continue;
            }
            if (inNetwork && [trimmed hasPrefix:@"ssid="]) {
                /* Extract SSID value: ssid="MyNetwork" */
                NSString *val = [trimmed substringFromIndex:5];
                val = [val stringByTrimmingCharactersInSet:
                       [NSCharacterSet characterSetWithCharactersInString:@"\""]];
                currentSSID = val;
            }
        }
    }

    return [[cachedConnections copy] autorelease];
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

- (BOOL)activateConnection:(NetworkConnection *)connection
               onInterface:(NetworkInterface *)interface
{
    /* On FreeBSD, activating a connection means bringing the interface up */
    if (interface) {
        return [self enableInterface:interface];
    }
    return NO;
}

- (BOOL)deactivateConnection:(NetworkConnection *)connection
{
    /* Find interface for this connection */
    NSString *ifaceName = [connection interfaceName];
    if (ifaceName) {
        NetworkInterface *iface = [self interfaceWithIdentifier:ifaceName];
        if (iface) {
            return [self disableInterface:iface];
        }
    }
    return NO;
}

- (BOOL)deleteConnection:(NetworkConnection *)connection
{
    /* On FreeBSD, deleting a saved connection means removing it from
       wpa_supplicant.conf. This requires root privileges. */
    if (!connection) return NO;

    NSString *ssid = [connection ssid];
    if (!ssid) return NO;

    NSDebugLLog(@"gwcomp", @"[Network] BSDBackend: deleting saved network '%@'", ssid);
    NSError *err = nil;
    BOOL ok = [self runPrivilegedHelper:@[@"connection-delete", ssid] error:&err];
    if (!ok) {
        [self reportErrorWithMessage:[NSString stringWithFormat:
            NSLocalizedString(@"Failed to delete saved network '%@'",
                              @"Delete error"), ssid]];
    }
    return ok;
}

- (BOOL)saveConnection:(NetworkConnection *)connection
{
    return YES;
}

- (NSString *)connectedWLANSSID
{
    return [[self connectedWLAN] ssid];
}

- (NSString *)clonedMacAddressForSSID:(NSString *)ssid
{
    return @"permanent";
}

- (BOOL)setClonedMacAddress:(NSString *)value forSSID:(NSString *)ssid
{
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

#pragma mark - NIC Setup (rc.conf configuration)

- (BOOL)setupNIC:(NSString *)deviceName
{
    /*
     * Call network-helper setup-nic to configure a NIC in rc.conf:
     *  - For WiFi drivers: creates /etc/wpa_supplicant.conf, writes
     *    wlans_<nic>="wlan<N>" and ifconfig_wlan<N>="WPA DHCP" to rc.conf,
     *    runs /etc/pccard_ether <nic> startchildren
     *  - For Ethernet: writes ifconfig_<nic>=DHCP,
     *    runs /etc/pccard_ether <nic> start
     */
    if (!deviceName || [deviceName length] == 0) return NO;

    NSDebugLLog(@"gwcomp", @"[Network] BSDBackend: setting up NIC %@", deviceName);

    NSError *err = nil;
    BOOL ok = [self runPrivilegedHelper:@[@"setup-nic", deviceName] error:&err];
    if (!ok) {
        NSDebugLLog(@"gwcomp", @"[Network] BSDBackend: setup-nic failed for %@: %@",
              deviceName, err ? [err localizedDescription] : @"unknown error");
    }
    return ok;
}

#pragma mark - Wireless Device Discovery

- (NSString *)discoverWLANDevice
{
    [wlanDeviceMap removeAllObjects];

    /* First check if wlan0 already exists */
    NSArray *names = [self listInterfaceNames];
    for (NSString *name in names) {
        if ([name hasPrefix:@"wlan"]) {
            [primaryWLANDevice release];
            primaryWLANDevice = [name retain];
            NSDebugLLog(@"gwcomp", @"[Network] BSDBackend: found existing WLAN device %@", name);
            wifiEnabled = YES;
            return primaryWLANDevice;
        }
    }

    /* Check sysctl net.wlan.devices for physical wireless devices */
    if (sysctlPath) {
        NSString *output = nil;
        [self runPrivilegedCommand:sysctlPath
                        arguments:@[@"net.wlan.devices"]
                           output:&output];
        if (output) {
            output = [output stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            /* Output format: "net.wlan.devices: iwm0" */
            NSRange colonRange = [output rangeOfString:@":"];
            if (colonRange.location != NSNotFound) {
                NSString *devices = [[output substringFromIndex:
                                      colonRange.location + 1]
                    stringByTrimmingCharactersInSet:
                        [NSCharacterSet whitespaceCharacterSet]];
                if ([devices length] > 0) {
                    NSArray *devList = [devices componentsSeparatedByString:@" "];
                    for (NSString *dev in devList) {
                        if ([dev length] > 0) {
                            NSDebugLLog(@"gwcomp", @"[Network] BSDBackend: physical wireless device: %@",
                                  dev);
                            /* Setup NIC in rc.conf if not already configured */
                            [self setupNIC:dev];
                            /* Map physical device to wlan0 (or next available) */
                            [wlanDeviceMap setObject:@"wlan0" forKey:dev];
                        }
                    }
                    wifiEnabled = YES;
                }
            }
        }
    }

    return primaryWLANDevice;
}

- (void)ensureWLANDevice
{
    /*
     * Make sure a wlan0 device exists. If not, try to create one.
     * This requires root privileges, so we use the helper.
     */
    if (primaryWLANDevice) return;

    /* Re-check */
    [self discoverWLANDevice];
    if (primaryWLANDevice) return;

    /* Try to create wlan0 from the first physical device */
    if ([wlanDeviceMap count] > 0) {
        NSString *physDev = [[wlanDeviceMap allKeys] objectAtIndex:0];
        NSDebugLLog(@"gwcomp", @"[Network] BSDBackend: creating wlan0 from %@", physDev);

        NSError *err = nil;
        [self runPrivilegedHelper:@[@"wlan-create", physDev] error:&err];

        /* Re-discover after creation */
        [self discoverWLANDevice];
    }
}

#pragma mark - WLAN Management

- (BOOL)isWLANEnabled
{
    /* On FreeBSD, WLAN is "enabled" if a wlan device exists and is UP */
    [self discoverWLANDevice];

    if (!primaryWLANDevice) {
        wifiEnabled = ([wlanDeviceMap count] > 0);
        return wifiEnabled;
    }

    NSString *output = nil;
    [self runPrivilegedCommand:ifconfigPath
                    arguments:@[primaryWLANDevice]
                       output:&output];
    if (output) {
        wifiEnabled = ([output rangeOfString:@"<UP,"
                                     options:NSCaseInsensitiveSearch].location != NSNotFound ||
                       [output rangeOfString:@"<UP>"
                                     options:NSCaseInsensitiveSearch].location != NSNotFound);
    }
    return wifiEnabled;
}

- (BOOL)setWLANEnabled:(BOOL)enabled
{
    [self ensureWLANDevice];

    if (!primaryWLANDevice) {
        [self reportErrorWithMessage:
            NSLocalizedString(@"No wireless device found", @"WLAN error")];
        return NO;
    }

    NSString *cmd = enabled ? @"wlan-enable" : @"wlan-disable";
    NSError *err = nil;
    BOOL ok = [self runPrivilegedHelper:@[cmd] error:&err];

    if (ok) {
        wifiEnabled = enabled;
        if (delegate && [delegate respondsToSelector:
                         @selector(networkBackend:WLANEnabledDidChange:)]) {
            [delegate networkBackend:self WLANEnabledDidChange:enabled];
        }
    } else {
        [self reportErrorWithMessage:[NSString stringWithFormat:
            NSLocalizedString(@"Failed to %@ WLAN: %@", @"WLAN error"),
            enabled ? @"enable" : @"disable",
            err ? [err localizedDescription] : @"unknown error"]];
    }

    return ok;
}

- (NSArray *)scanForWLANs
{
    NSMutableArray *networks = [NSMutableArray array];

    [self ensureWLANDevice];

    if (!primaryWLANDevice) {
        NSDebugLLog(@"gwcomp", @"[Network] BSDBackend: no WLAN device for scanning");
        return networks;
    }

    /* Try ifconfig scan first */
    NSString *scanOutput = nil;
    int status = [self runPrivilegedCommand:ifconfigPath
                                 arguments:@[primaryWLANDevice, @"list", @"scan"]
                                    output:&scanOutput];

    if (status == 0 && scanOutput && [scanOutput length] > 0) {
        networks = (NSMutableArray *)[self parseIfconfigScan:scanOutput];
    }

    /* If ifconfig scan didn't work, try wpa_cli */
    if ([networks count] == 0 && wpaCliPath) {
        /* Trigger scan */
        [self runPrivilegedCommand:wpaCliPath arguments:@[@"-i", primaryWLANDevice, @"scan"] output:NULL];
        [NSThread sleepForTimeInterval:2.0];

        NSString *wpaOutput = nil;
        [self runPrivilegedCommand:wpaCliPath
                        arguments:@[@"-i", primaryWLANDevice, @"scan_results"]
                           output:&wpaOutput];
        if (wpaOutput && [wpaOutput length] > 0) {
            networks = (NSMutableArray *)[self parseWpaCliScanResults:wpaOutput];
        }
    }

    /* Sort by signal strength descending */
    [networks sortUsingComparator:^NSComparisonResult(WLAN *a, WLAN *b) {
        if ([a signalStrength] > [b signalStrength]) return NSOrderedAscending;
        if ([a signalStrength] < [b signalStrength]) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    /* Mark saved networks */
    NSArray *saved = [self savedConnections];
    for (WLAN *net in networks) {
        for (NetworkConnection *conn in saved) {
            if ([[conn ssid] isEqualToString:[net ssid]]) {
                [net setIsSaved:YES];
                break;
            }
        }
    }

    /* Update cache */
    if ([NSThread isMainThread]) {
        [cachedWLANs removeAllObjects];
        [cachedWLANs addObjectsFromArray:networks];
    } else {
        NSArray *copy = [[networks copy] autorelease];
        dispatch_async(dispatch_get_main_queue(), ^{
            [cachedWLANs removeAllObjects];
            [cachedWLANs addObjectsFromArray:copy];
        });
    }

    return [[networks copy] autorelease];
}

- (NSArray *)parseIfconfigScan:(NSString *)output
{
    /*
     * FreeBSD ifconfig scan output format (fixed-width):
     * SSID/MESH ID    BSSID              CHAN RATE  S:N     INT CAPS
     * MyNetwork       e8:d1:1b:1b:58:ae    1  54M  -47:-96 100 EP RSN
     *
     * We skip the header line and parse each subsequent line.
     */
    NSMutableArray *networks = [NSMutableArray array];
    NSMutableDictionary *seen = [NSMutableDictionary dictionary];

    NSArray *lines = [output componentsSeparatedByString:@"\n"];
    BOOL headerSkipped = NO;

    for (NSString *line in lines) {
        if ([line length] == 0) continue;

        /* Skip the header line */
        if (!headerSkipped) {
            if ([line rangeOfString:@"SSID"].location != NSNotFound &&
                [line rangeOfString:@"BSSID"].location != NSNotFound) {
                headerSkipped = YES;
                continue;
            }
            /* If no header found, try parsing anyway */
            headerSkipped = YES;
        }

        /*
         * The SSID occupies the first ~34 characters, BSSID starts around col 34.
         * We need to find the BSSID (xx:xx:xx:xx:xx:xx pattern) to split correctly.
         */
        NSRange bssidRange = NSMakeRange(NSNotFound, 0);
        /* Find a MAC address pattern in the line */
        NSUInteger len = [line length];
        for (NSUInteger i = 0; i + 16 < len; i++) {
            unichar c1 = [line characterAtIndex:i];
            unichar c2 = (i + 2 < len) ? [line characterAtIndex:i + 2] : 0;
            if (((c1 >= '0' && c1 <= '9') || (c1 >= 'a' && c1 <= 'f') ||
                 (c1 >= 'A' && c1 <= 'F')) && c2 == ':') {
                /* Possible MAC start, verify pattern xx:xx:xx:xx:xx:xx */
                NSString *candidate = nil;
                if (i + 17 <= len) {
                    candidate = [line substringWithRange:NSMakeRange(i, 17)];
                }
                if (candidate && [candidate length] == 17) {
                    /* Verify it looks like a MAC */
                    BOOL isMac = YES;
                    for (int j = 0; j < 17; j++) {
                        unichar ch = [candidate characterAtIndex:j];
                        if (j % 3 == 2) {
                            if (ch != ':') { isMac = NO; break; }
                        } else {
                            if (!((ch >= '0' && ch <= '9') ||
                                  (ch >= 'a' && ch <= 'f') ||
                                  (ch >= 'A' && ch <= 'F'))) {
                                isMac = NO;
                                break;
                            }
                        }
                    }
                    if (isMac) {
                        bssidRange = NSMakeRange(i, 17);
                        break;
                    }
                }
            }
        }

        if (bssidRange.location == NSNotFound) continue;

        /* Extract SSID (everything before BSSID, trimmed) */
        NSString *ssid = [[line substringToIndex:bssidRange.location]
            stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceCharacterSet]];
        NSString *bssid = [line substringWithRange:bssidRange];

        if ([ssid length] == 0) continue; /* Skip hidden networks */

        /* Parse the rest after BSSID */
        NSString *rest = @"";
        if (bssidRange.location + bssidRange.length < len) {
            rest = [[line substringFromIndex:bssidRange.location + bssidRange.length]
                stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceCharacterSet]];
        }

        NSArray *tokens = [rest componentsSeparatedByCharactersInSet:
                           [NSCharacterSet whitespaceCharacterSet]];
        NSMutableArray *parts = [NSMutableArray array];
        for (NSString *t in tokens) {
            if ([t length] > 0) [parts addObject:t];
        }

        int channel = 0;
        int signalStrength = 0;
        NSString *capsStr = @"";

        if ([parts count] >= 1) {
            channel = [[parts objectAtIndex:0] intValue];
        }
        /* S:N is like "-47:-96" */
        if ([parts count] >= 3) {
            NSString *sn = [parts objectAtIndex:2];
            NSArray *snParts = [sn componentsSeparatedByString:@":"];
            if ([snParts count] >= 1) {
                signalStrength = [[snParts objectAtIndex:0] intValue];
            }
        }
        /* Capabilities come after INT field */
        if ([parts count] >= 5) {
            NSMutableArray *capParts = [NSMutableArray array];
            for (NSUInteger ci = 4; ci < [parts count]; ci++) {
                [capParts addObject:[parts objectAtIndex:ci]];
            }
            capsStr = [capParts componentsJoinedByString:@" "];
        }

        /* De-duplicate by SSID (keep strongest) */
        WLAN *existing = [seen objectForKey:ssid];
        if (existing && [existing signalStrength] >= signalStrength) {
            continue;
        }

        WLAN *network = [[WLAN alloc] init];
        [network setSsid:ssid];
        [network setBssid:bssid];
        [network setChannel:channel];
        [network setSignalStrength:signalStrength];
        [network setSecurity:[self parseSecurityCaps:capsStr]];
        [network setIsConnected:NO]; /* Will be updated below */

        if (existing) {
            [networks removeObject:existing];
        }
        [seen setObject:network forKey:ssid];
        [networks addObject:network];
        [network release];
    }

    /* Check which network is currently connected */
    if (primaryWLANDevice) {
        NSString *ifOutput = nil;
        [self runPrivilegedCommand:ifconfigPath
                        arguments:@[primaryWLANDevice]
                           output:&ifOutput];
        if (ifOutput) {
            /* Look for "ssid MyNetwork" in ifconfig output */
            NSArray *ifLines = [ifOutput componentsSeparatedByString:@"\n"];
            for (NSString *ifLine in ifLines) {
                NSString *trimmed = [ifLine stringByTrimmingCharactersInSet:
                                     [NSCharacterSet whitespaceCharacterSet]];
                NSRange ssidRange = [trimmed rangeOfString:@"ssid "];
                if (ssidRange.location != NSNotFound) {
                    NSString *connectedSSID = [trimmed substringFromIndex:
                        ssidRange.location + ssidRange.length];
                    /* SSID may be followed by more fields */
                    NSRange spaceRange = [connectedSSID rangeOfString:@" channel"];
                    if (spaceRange.location != NSNotFound) {
                        connectedSSID = [connectedSSID substringToIndex:
                                         spaceRange.location];
                    }
                    connectedSSID = [connectedSSID stringByTrimmingCharactersInSet:
                        [NSCharacterSet whitespaceAndNewlineCharacterSet]];

                    for (WLAN *net in networks) {
                        if ([[net ssid] isEqualToString:connectedSSID]) {
                            [net setIsConnected:YES];
                            break;
                        }
                    }
                    break;
                }
            }
        }
    }

    return networks;
}

- (NSArray *)parseWpaCliScanResults:(NSString *)output
{
    /*
     * wpa_cli scan_results format:
     * bssid / frequency / signal level / flags / ssid
     * e8:d1:1b:1b:58:ae  2412  -47  [WPA2-PSK-CCMP][ESS]  MyNetwork
     */
    NSMutableArray *networks = [NSMutableArray array];
    NSMutableDictionary *seen = [NSMutableDictionary dictionary];

    NSArray *lines = [output componentsSeparatedByString:@"\n"];
    BOOL headerSkipped = NO;

    for (NSString *line in lines) {
        if ([line length] == 0) continue;

        /* Skip header */
        if (!headerSkipped) {
            if ([line rangeOfString:@"bssid"].location != NSNotFound ||
                [line rangeOfString:@"BSSID"].location != NSNotFound) {
                headerSkipped = YES;
                continue;
            }
        }

        /* Split by tabs (wpa_cli uses tab-separated fields) */
        NSArray *fields = [line componentsSeparatedByString:@"\t"];
        if ([fields count] < 5) continue;

        NSString *bssid = [fields objectAtIndex:0];
        int freq = [[fields objectAtIndex:1] intValue];
        int signal = [[fields objectAtIndex:2] intValue];
        NSString *flags = [fields objectAtIndex:3];
        NSString *ssid = [fields objectAtIndex:4];

        if ([ssid length] == 0) continue;

        /* De-duplicate */
        WLAN *existing = [seen objectForKey:ssid];
        if (existing && [existing signalStrength] >= signal) continue;

        WLAN *network = [[WLAN alloc] init];
        [network setSsid:ssid];
        [network setBssid:bssid];
        [network setFrequency:freq];
        [network setSignalStrength:signal];

        /* Parse security from flags like [WPA2-PSK-CCMP][ESS] */
        if ([flags rangeOfString:@"WPA3"].location != NSNotFound) {
            [network setSecurity:WLANSecurityWPA3];
        } else if ([flags rangeOfString:@"WPA2"].location != NSNotFound) {
            [network setSecurity:WLANSecurityWPA2];
        } else if ([flags rangeOfString:@"WPA"].location != NSNotFound) {
            [network setSecurity:WLANSecurityWPA];
        } else if ([flags rangeOfString:@"WEP"].location != NSNotFound) {
            [network setSecurity:WLANSecurityWEP];
        } else {
            [network setSecurity:WLANSecurityNone];
        }

        if (existing) [networks removeObject:existing];
        [seen setObject:network forKey:ssid];
        [networks addObject:network];
        [network release];
    }

    return networks;
}

- (WLANSecurityType)parseSecurityCaps:(NSString *)caps
{
    if (!caps || [caps length] == 0) return WLANSecurityNone;

    NSString *upper = [caps uppercaseString];

    if ([upper rangeOfString:@"WPA3"].location != NSNotFound) {
        return WLANSecurityWPA3;
    }
    if ([upper rangeOfString:@"RSN"].location != NSNotFound) {
        return WLANSecurityWPA2;  /* RSN = WPA2 */
    }
    if ([upper rangeOfString:@"WPA2"].location != NSNotFound) {
        return WLANSecurityWPA2;
    }
    if ([upper rangeOfString:@"WPA"].location != NSNotFound) {
        return WLANSecurityWPA;
    }
    if ([upper rangeOfString:@"WEP"].location != NSNotFound) {
        return WLANSecurityWEP;
    }
    if ([upper rangeOfString:@"PRIVACY"].location != NSNotFound) {
        return WLANSecurityWEP; /* PRIVACY flag usually means WEP */
    }

    return WLANSecurityNone;
}

- (BOOL)startWLANScan
{
    [self performSelectorInBackground:@selector(scanForWLANs) withObject:nil];
    return YES;
}

- (BOOL)connectToWLAN:(WLAN *)network withPassword:(NSString *)password
{
    if (!network) {
        [self reportErrorWithMessage:
            NSLocalizedString(@"Cannot connect: no network specified",
                              @"WLAN error")];
        return NO;
    }

    NSString *ssid = [network ssid];
    if (!ssid || [ssid length] == 0) {
        [self reportErrorWithMessage:
            NSLocalizedString(@"Cannot connect: network has no SSID",
                              @"WLAN error")];
        return NO;
    }

    NSDebugLLog(@"gwcomp", @"[Network] BSDBackend: connecting to WLAN '%@'", ssid);

    NSMutableArray *args = [NSMutableArray arrayWithObjects:@"wlan-connect",
                            ssid, nil];
    if (password && [password length] > 0) {
        [args addObject:password];
    }

    NSError *err = nil;
    BOOL ok = [self runPrivilegedHelper:args error:&err];
    if (!ok) {
        [self reportErrorWithMessage:[NSString stringWithFormat:
            NSLocalizedString(@"Failed to connect to '%@': %@", @"WLAN error"),
            ssid, err ? [err localizedDescription] : @"unknown error"]];
    }
    return ok;
}

- (BOOL)disconnectFromWLAN
{
    NSDebugLLog(@"gwcomp", @"[Network] BSDBackend: disconnecting from WLAN");

    NSError *err = nil;
    BOOL ok = [self runPrivilegedHelper:@[@"wlan-disconnect"] error:&err];
    if (!ok) {
        [self reportErrorWithMessage:
            NSLocalizedString(@"Failed to disconnect from wireless network",
                              @"WLAN error")];
    }
    return ok;
}

- (WLAN *)connectedWLAN
{
    for (WLAN *net in cachedWLANs) {
        if ([net isConnected]) {
            return net;
        }
    }
    return nil;
}

#pragma mark - Status

- (NetworkConnectionState)globalConnectionState
{
    if (!backendAvailable) return NetworkConnectionStateUnavailable;

    for (NetworkInterface *iface in cachedInterfaces) {
        if ([iface state] == NetworkConnectionStateConnected &&
            [iface type] != NetworkInterfaceTypeLoopback) {
            return NetworkConnectionStateConnected;
        }
    }
    return NetworkConnectionStateDisconnected;
}

- (NSString *)primaryConnectionName
{
    for (NetworkInterface *iface in cachedInterfaces) {
        if ([iface isActive] && [iface type] != NetworkInterfaceTypeLoopback) {
            return [iface displayName];
        }
    }
    return nil;
}

- (NetworkInterface *)primaryInterface
{
    for (NetworkInterface *iface in cachedInterfaces) {
        if ([iface isActive] && [iface type] != NetworkInterfaceTypeLoopback) {
            return iface;
        }
    }
    return nil;
}

#pragma mark - Refresh

- (void)refresh
{
    if (![NSThread isMainThread]) {
        [self performSelectorOnMainThread:@selector(refresh)
                               withObject:nil
                            waitUntilDone:NO];
        return;
    }

    NSDebugLLog(@"gwcomp", @"[Network] BSDBackend: refreshing...");

    [self availableInterfaces];
    [self savedConnections];
    [self isWLANEnabled];

    NSArray *ifCopy = [[cachedInterfaces copy] autorelease];
    NSArray *connCopy = [[cachedConnections copy] autorelease];

    if (delegate && [delegate respondsToSelector:
                     @selector(networkBackend:didUpdateInterfaces:)]) {
        [delegate networkBackend:self didUpdateInterfaces:ifCopy];
    }
    if (delegate && [delegate respondsToSelector:
                     @selector(networkBackend:didUpdateConnections:)]) {
        [delegate networkBackend:self didUpdateConnections:connCopy];
    }

    NSDebugLLog(@"gwcomp", @"[Network] BSDBackend: refresh complete");
}

@end
