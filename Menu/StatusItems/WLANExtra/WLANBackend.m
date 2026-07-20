/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "WLANBackend.h"
#import <sys/utsname.h>
#import <string.h>

@interface WLANBackend ()
{
    BOOL _isLinux;
    BOOL _isBSD;
    NSString *_wlanIface;
    NSString *_nmcli;
    NSString *_wpaCli;
    NSString *_ifconfig;
    NSString *_dhclient;
    NSString *_sysctl;
}
@end

static NSString *findTool(NSString *name)
{
    NSArray *dirs = @[@"/sbin", @"/usr/sbin", @"/bin", @"/usr/bin",
                      @"/usr/local/sbin", @"/usr/local/bin"];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *dir in dirs) {
        NSString *path = [dir stringByAppendingPathComponent:name];
        if ([fm isExecutableFileAtPath:path]) return path;
    }
    return nil;
}

static NSString *runCommand(NSString *path, NSArray *args)
{
    if (!path) return nil;
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:path];
    if (args) [task setArguments:args];
    NSPipe *outPipe = [NSPipe pipe];
    [task setStandardOutput:outPipe];
    [task setStandardError:[NSFileHandle fileHandleWithNullDevice]];
    @try {
        [task launch];
        [task waitUntilExit];
    } @catch (NSException *e) {
        return nil;
    }
    NSData *data = [[outPipe fileHandleForReading] readDataToEndOfFile];
    NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static int runPrivilegedCommand(NSString *path, NSArray *args)
{
    if (!path) return -1;
    NSString *sudoPath = findTool(@"sudo");
    if (!sudoPath) return -1;
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:sudoPath];
    NSMutableArray *allArgs = [NSMutableArray arrayWithObjects:@"-n", path, nil];
    if (args) [allArgs addObjectsFromArray:args];
    [task setArguments:allArgs];
    [task setStandardError:[NSFileHandle fileHandleWithNullDevice]];
    @try {
        [task launch];
        [task waitUntilExit];
    } @catch (NSException *e) {
        return -1;
    }
    return [task terminationStatus];
}

@implementation WLANBackend

- (id)init
{
    self = [super init];
    if (self) {
        struct utsname u;
        uname(&u);
        _isLinux = (strcmp(u.sysname, "Linux") == 0);
        _isBSD = (strcmp(u.sysname, "FreeBSD") == 0 ||
                  strcmp(u.sysname, "DragonFly") == 0 ||
                  strcmp(u.sysname, "OpenBSD") == 0 ||
                  strcmp(u.sysname, "NetBSD") == 0);

        if (_isLinux) {
            _nmcli = findTool(@"nmcli");
        }
        if (_isBSD) {
            _wpaCli = findTool(@"wpa_cli");
            _ifconfig = findTool(@"ifconfig");
            _dhclient = findTool(@"dhclient");
            _sysctl = findTool(@"sysctl");
        }
    }
    return self;
}

- (BOOL)isAvailable
{
    if (_isLinux) return (_nmcli != nil);
    if (_isBSD) return (_wpaCli != nil && _ifconfig != nil);
    return NO;
}

#pragma mark - Interface discovery (BSD)

- (nullable NSString *)bsdWLANInterface
{
    if (_wlanIface) return _wlanIface;

    /* Try sysctl net.wlan.devices for physical WLAN devices */
    if (_sysctl) {
        NSString *devs = runCommand(_sysctl, @[@"-n", @"net.wlan.devices"]);
        if (devs && [devs length] > 0) {
            NSArray *phys = [devs componentsSeparatedByString:@" "];
            for (NSString *physDev in phys) {
                if ([physDev length] == 0) continue;
                /* Check if wlan0 already exists for this physical device */
                NSString *ifaces = runCommand(_ifconfig, @[@"-l"]);
                if (ifaces) {
                    NSArray *allIfaces = [ifaces componentsSeparatedByString:@" "];
                    for (NSString *iface in allIfaces) {
                        if ([iface hasPrefix:@"wlan"]) {
                            /* Verify it belongs to this physical device */
                            NSString *info = runCommand(_ifconfig, @[iface]);
                            if (info && [info rangeOfString:physDev].location != NSNotFound) {
                                _wlanIface = iface;
                                return _wlanIface;
                            }
                        }
                    }
                }
                /* Try wlan0 if it exists */
                for (int i = 0; i < 8; i++) {
                    NSString *candidate = [NSString stringWithFormat:@"wlan%d", i];
                    NSString *info = runCommand(_ifconfig, @[candidate, @"list", @"scan"]);
                    if (info && [info length] > 0 && ![info hasPrefix:@"ifconfig:"] &&
                        [info rangeOfString:@"SSID"].location != NSNotFound) {
                        _wlanIface = candidate;
                        return _wlanIface;
                    }
                }
            }
        }
    }

    /* Fallback: look for any wlan interface via ifconfig -l */
    NSString *ifaces = runCommand(_ifconfig, @[@"-l"]);
    if (ifaces) {
        NSArray *allIfaces = [ifaces componentsSeparatedByString:@" "];
        for (NSString *iface in allIfaces) {
            if ([iface hasPrefix:@"wlan"]) {
                _wlanIface = iface;
                return _wlanIface;
            }
        }
    }

    return nil;
}

#pragma mark - Linux (nmcli) methods

- (BOOL)linuxIsEnabled
{
    NSString *radio = runCommand(_nmcli, @[@"radio", @"wifi"]);
    return [radio isEqualToString:@"enabled"];
}

- (void)linuxSetEnabled:(BOOL)enabled
{
    runPrivilegedCommand(_nmcli, @[@"radio", @"wifi", enabled ? @"on" : @"off"]);
}

- (nullable NSString *)linuxConnectedSSID
{
    NSString *conn = runCommand(_nmcli, @[@"-t", @"-f", @"NAME,DEVICE,TYPE",
                                          @"connection", @"show", @"--active"]);
    for (NSString *line in [conn componentsSeparatedByString:@"\n"]) {
        NSArray *parts = [line componentsSeparatedByString:@":"];
        if ([parts count] >= 3 && [[parts objectAtIndex:2] containsString:@"wireless"]) {
            return [parts objectAtIndex:0];
        }
    }
    return nil;
}

- (int)linuxSignalStrength
{
    NSString *sig = runCommand(_nmcli, @[@"-t", @"-f", @"IN-USE,SSID,SIGNAL",
                                          @"device", @"wifi", @"list"]);
    for (NSString *line in [sig componentsSeparatedByString:@"\n"]) {
        if ([line hasPrefix:@"*:"]) {
            NSArray *parts = [line componentsSeparatedByString:@":"];
            if ([parts count] >= 3) {
                return [[parts objectAtIndex:2] intValue];
            }
        }
    }
    return 0;
}

- (NSArray<NSDictionary *> *)linuxScanNetworks
{
    NSString *scan = runCommand(_nmcli, @[@"-t", @"-f", @"SSID,SIGNAL,SECURITY",
                                          @"device", @"wifi", @"list"]);
    NSMutableArray *result = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (NSString *line in [scan componentsSeparatedByString:@"\n"]) {
        if ([line length] == 0) continue;
        NSArray *parts = [line componentsSeparatedByString:@":"];
        if ([parts count] < 1) continue;
        NSString *ssid = [parts objectAtIndex:0];
        if ([ssid length] == 0) continue;
        if ([seen containsObject:ssid]) continue;
        [seen addObject:ssid];
        int signal = ([parts count] >= 2) ? [[parts objectAtIndex:1] intValue] : 0;
        NSString *security = ([parts count] >= 3) ? [parts objectAtIndex:2] : @"";
        [result addObject:@{@"ssid": ssid, @"signal": @(signal),
                            @"security": security, @"bssid": @""}];
    }
    return result;
}

- (BOOL)linuxConnect:(NSString *)ssid password:(nullable NSString *)password
{
    if (password && [password length] > 0) {
        runPrivilegedCommand(_nmcli, @[@"device", @"wifi", @"connect", ssid,
                                        @"password", password]);
    } else {
        runPrivilegedCommand(_nmcli, @[@"device", @"wifi", @"connect", ssid]);
    }
    return ([self linuxConnectedSSID] != nil);
}

- (void)linuxDisconnect
{
    NSString *ssid = [self linuxConnectedSSID];
    if (ssid) {
        runPrivilegedCommand(_nmcli, @[@"connection", @"down", @"id", ssid]);
    }
}

#pragma mark - BSD (wpa_cli/ifconfig) methods

- (BOOL)bsdIsEnabled
{
    NSString *iface = [self bsdWLANInterface];
    if (!iface) return NO;
    NSString *info = runCommand(_ifconfig, @[iface]);
    return (info && [info rangeOfString:@"<UP,"].location != NSNotFound);
}

- (void)bsdSetEnabled:(BOOL)enabled
{
    NSString *iface = [self bsdWLANInterface];
    if (!iface) return;
    runCommand(_ifconfig, @[iface, enabled ? @"up" : @"down"]);
}

- (nullable NSString *)bsdConnectedSSID
{
    NSString *iface = [self bsdWLANInterface];
    if (!iface || !_wpaCli) return nil;
    NSString *status = runCommand(_wpaCli, @[@"-i", iface, @"status"]);
    for (NSString *line in [status componentsSeparatedByString:@"\n"]) {
        if ([line hasPrefix:@"ssid="]) {
            return [[line substringFromIndex:5]
                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        }
    }
    return nil;
}

- (int)bsdSignalStrength
{
    NSString *iface = [self bsdWLANInterface];
    if (!iface || !_wpaCli) return 0;
    NSString *status = runCommand(_wpaCli, @[@"-i", iface, @"signal_poll"]);
    for (NSString *line in [status componentsSeparatedByString:@"\n"]) {
        if ([line hasPrefix:@"RSSI="]) {
            return [[line substringFromIndex:5] intValue];
        }
    }
    /* Fallback: parse from scan results for connected network */
    NSString *ssid = [self bsdConnectedSSID];
    if (!ssid) return 0;
    NSArray *nets = [self bsdScanNetworks];
    for (NSDictionary *net in nets) {
        if ([[net objectForKey:@"ssid"] isEqualToString:ssid]) {
            return [[net objectForKey:@"signal"] intValue];
        }
    }
    return 0;
}

- (NSArray<NSDictionary *> *)bsdScanNetworks
{
    NSString *iface = [self bsdWLANInterface];
    if (!iface) return @[];

    NSMutableArray *result = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];

    /* Try ifconfig list scan first */
    if (_ifconfig) {
        NSString *scan = runCommand(_ifconfig, @[iface, @"list", @"scan"]);
        if (scan && [scan length] > 0 && ![scan hasPrefix:@"ifconfig:"]) {
            NSArray *lines = [scan componentsSeparatedByString:@"\n"];
            BOOL headerPassed = NO;
            for (NSString *line in lines) {
                if ([line length] == 0) continue;
                if (!headerPassed) {
                    if ([line rangeOfString:@"SSID"].location != NSNotFound &&
                        [line rangeOfString:@"BSSID"].location != NSNotFound) {
                        headerPassed = YES;
                    }
                    continue;
                }
                /* Find BSSID (MAC address pattern) */
                NSUInteger len = [line length];
                NSRange bssidRange = NSMakeRange(NSNotFound, 0);
                for (NSUInteger i = 0; i + 16 < len; i++) {
                    unichar c1 = [line characterAtIndex:i];
                    unichar c2 = (i + 2 < len) ? [line characterAtIndex:i+2] : 0;
                    if (((c1 >= '0' && c1 <= '9') || (c1 >= 'a' && c1 <= 'f') ||
                         (c1 >= 'A' && c1 <= 'F')) && c2 == ':') {
                        if (i + 17 <= len) {
                            NSString *cand = [line substringWithRange:NSMakeRange(i, 17)];
                            BOOL isMac = YES;
                            for (int j = 0; j < 17; j++) {
                                unichar ch = [cand characterAtIndex:j];
                                if (j % 3 == 2) { if (ch != ':') { isMac = NO; break; } }
                                else if (!((ch >= '0' && ch <= '9') ||
                                           (ch >= 'a' && ch <= 'f') ||
                                           (ch >= 'A' && ch <= 'F'))) { isMac = NO; break; }
                            }
                            if (isMac) { bssidRange = NSMakeRange(i, 17); break; }
                        }
                    }
                }
                if (bssidRange.location == NSNotFound) continue;
                NSString *ssid = [[line substringToIndex:bssidRange.location]
                    stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                if ([ssid length] == 0) continue;
                NSString *bssid = [line substringWithRange:bssidRange];
                NSString *rest = @"";
                if (bssidRange.location + bssidRange.length < len) {
                    rest = [[line substringFromIndex:bssidRange.location + bssidRange.length]
                        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                }
                NSArray *tokens = [rest componentsSeparatedByCharactersInSet:
                    [NSCharacterSet whitespaceCharacterSet]];
                NSMutableArray *parts = [NSMutableArray array];
                for (NSString *t in tokens) { if ([t length] > 0) [parts addObject:t]; }
                int signal = 0;
                if ([parts count] >= 3) {
                    NSString *sn = [parts objectAtIndex:2];
                    NSArray *snParts = [sn componentsSeparatedByString:@":"];
                    if ([snParts count] >= 1) signal = [[snParts objectAtIndex:0] intValue];
                }
                NSString *capsStr = @"";
                if ([parts count] >= 5) {
                    NSArray *capParts = [parts subarrayWithRange:NSMakeRange(4, [parts count] - 4)];
                    capsStr = [capParts componentsJoinedByString:@" "];
                }
                NSString *security = [self parseBSDSecurityCaps:capsStr];
                if ([seen containsObject:ssid]) continue;
                [seen addObject:ssid];
                [result addObject:@{@"ssid": ssid, @"signal": @(signal),
                                    @"security": security, @"bssid": bssid}];
            }
        }
    }

    /* Fallback: wpa_cli scan_results */
    if ([result count] == 0 && _wpaCli) {
        runCommand(_wpaCli, @[@"-i", iface, @"scan"]);
        [NSThread sleepForTimeInterval:2.0];
        NSString *scan = runCommand(_wpaCli, @[@"-i", iface, @"scan_results"]);
        if (scan && [scan length] > 0) {
            NSArray *lines = [scan componentsSeparatedByString:@"\n"];
            BOOL headerPassed = NO;
            for (NSString *line in lines) {
                if ([line length] == 0) continue;
                if (!headerPassed) {
                    if ([line rangeOfString:@"bssid"].location != NSNotFound ||
                        [line rangeOfString:@"BSSID"].location != NSNotFound) {
                        headerPassed = YES;
                    }
                    continue;
                }
                NSArray *fields = [line componentsSeparatedByString:@"\t"];
                if ([fields count] < 5) continue;
                NSString *bssid = [fields objectAtIndex:0];
                int signal = [[fields objectAtIndex:2] intValue];
                NSString *flags = [fields objectAtIndex:3];
                NSString *ssid = [fields objectAtIndex:4];
                if ([ssid length] == 0) continue;
                NSString *security = @"";
                if ([flags rangeOfString:@"WPA3"].location != NSNotFound)
                    security = @"WPA3";
                else if ([flags rangeOfString:@"WPA2"].location != NSNotFound)
                    security = @"WPA2";
                else if ([flags rangeOfString:@"WPA"].location != NSNotFound)
                    security = @"WPA";
                else if ([flags rangeOfString:@"WEP"].location != NSNotFound)
                    security = @"WEP";
                if ([seen containsObject:ssid]) continue;
                [seen addObject:ssid];
                [result addObject:@{@"ssid": ssid, @"signal": @(signal),
                                    @"security": security, @"bssid": bssid}];
            }
        }
    }

    /* Sort by signal descending */
    [result sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        int sa = [[a objectForKey:@"signal"] intValue];
        int sb = [[b objectForKey:@"signal"] intValue];
        if (sa > sb) return NSOrderedAscending;
        if (sa < sb) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    return result;
}

- (BOOL)bsdConnect:(NSString *)ssid password:(nullable NSString *)password
{
    NSString *iface = [self bsdWLANInterface];
    if (!iface || !_wpaCli) return NO;

    /* Add network */
    NSString *addResult = runCommand(_wpaCli, @[@"-i", iface, @"add_network"]);
    int netId = [addResult intValue];
    if (netId < 0) return NO;

    /* Set SSID */
    NSString *ssidArg = [NSString stringWithFormat:@"\"%@\"", ssid];
    runCommand(_wpaCli, @[@"-i", iface, @"set_network",
                           [NSString stringWithFormat:@"%d", netId],
                           @"ssid", ssidArg]);

    /* Set key management */
    if (password && [password length] > 0) {
        runCommand(_wpaCli, @[@"-i", iface, @"set_network",
                               [NSString stringWithFormat:@"%d", netId],
                               @"psk", [NSString stringWithFormat:@"\"%@\"", password]]);
    } else {
        runCommand(_wpaCli, @[@"-i", iface, @"set_network",
                               [NSString stringWithFormat:@"%d", netId],
                               @"key_mgmt", @"NONE"]);
    }

    /* Enable and select network */
    runCommand(_wpaCli, @[@"-i", iface, @"enable_network",
                           [NSString stringWithFormat:@"%d", netId]]);
    runCommand(_wpaCli, @[@"-i", iface, @"select_network",
                           [NSString stringWithFormat:@"%d", netId]]);
    runCommand(_wpaCli, @[@"-i", iface, @"save_config"]);

    /* Wait for connection */
    for (int i = 0; i < 15; i++) {
        [NSThread sleepForTimeInterval:1.0];
        NSString *status = runCommand(_wpaCli, @[@"-i", iface, @"status"]);
        if ([status rangeOfString:@"wpa_state=COMPLETED"].location != NSNotFound) {
            /* Run DHCP */
            if (_dhclient) {
                runCommand(_dhclient, @[iface]);
            }
            return YES;
        }
    }
    return NO;
}

- (void)bsdDisconnect
{
    NSString *iface = [self bsdWLANInterface];
    if (!iface || !_wpaCli) return;
    runCommand(_wpaCli, @[@"-i", iface, @"disconnect"]);
}

- (NSString *)parseBSDSecurityCaps:(NSString *)caps
{
    if (!caps || [caps length] == 0) return @"";
    NSString *upper = [caps uppercaseString];
    if ([upper rangeOfString:@"WPA3"].location != NSNotFound) return @"WPA3";
    if ([upper rangeOfString:@"RSN"].location != NSNotFound) return @"WPA2";
    if ([upper rangeOfString:@"WPA2"].location != NSNotFound) return @"WPA2";
    if ([upper rangeOfString:@"WPA"].location != NSNotFound) return @"WPA";
    if ([upper rangeOfString:@"WEP"].location != NSNotFound) return @"WEP";
    if ([upper rangeOfString:@"PRIVACY"].location != NSNotFound) return @"WEP";
    return @"";
}

#pragma mark - Unified API

- (BOOL)isWLANEnabled
{
    if (_isLinux) return [self linuxIsEnabled];
    if (_isBSD) return [self bsdIsEnabled];
    return NO;
}

- (void)setWLANEnabled:(BOOL)enabled
{
    if (_isLinux) [self linuxSetEnabled:enabled];
    else if (_isBSD) [self bsdSetEnabled:enabled];
}

- (nullable NSString *)connectedSSID
{
    if (_isLinux) return [self linuxConnectedSSID];
    if (_isBSD) return [self bsdConnectedSSID];
    return nil;
}

- (int)signalStrength
{
    if (_isLinux) return [self linuxSignalStrength];
    if (_isBSD) return [self bsdSignalStrength];
    return 0;
}

- (NSArray<NSDictionary *> *)scanNetworks
{
    if (_isLinux) return [self linuxScanNetworks];
    if (_isBSD) return [self bsdScanNetworks];
    return @[];
}

- (BOOL)connectToNetwork:(NSString *)ssid password:(nullable NSString *)password
{
    if (_isLinux) return [self linuxConnect:ssid password:password];
    if (_isBSD) return [self bsdConnect:ssid password:password];
    return NO;
}

- (void)disconnect
{
    if (_isLinux) [self linuxDisconnect];
    else if (_isBSD) [self bsdDisconnect];
}

@end
