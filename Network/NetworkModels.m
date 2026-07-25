/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Network Data Models Implementation
 */

#import "NetworkBackend.h"
#import <AppKit/AppKit.h>

#pragma mark - IPConfiguration

@implementation IPConfiguration

@synthesize method, address, subnetMask, router, dnsServers, searchDomains;

- (id)init
{
    self = [super init];
    if (self) {
        method = IPConfigMethodDHCP;
        address = nil;
        subnetMask = nil;
        router = nil;
        dnsServers = nil;
        searchDomains = nil;
    }
    return self;
}

- (void)dealloc
{
    [address release];
    [subnetMask release];
    [router release];
    [dnsServers release];
    [searchDomains release];
    [super dealloc];
}

- (id)copyWithZone:(NSZone *)zone
{
    IPConfiguration *copy = [[IPConfiguration allocWithZone:zone] init];
    copy.method = self.method;
    copy.address = self.address;
    copy.subnetMask = self.subnetMask;
    copy.router = self.router;
    copy.dnsServers = self.dnsServers;
    copy.searchDomains = self.searchDomains;
    return copy;
}

- (BOOL)isValid
{
    if (method == IPConfigMethodDHCP || method == IPConfigMethodDisabled) {
        return YES;
    }
    
    if (method == IPConfigMethodManual) {
        // Must have at least an IP address
        if (!address || [address length] == 0) {
            return NO;
        }
        
        // Validate IP format (basic check)
        NSArray *octets = [address componentsSeparatedByString:@"."];
        if ([octets count] != 4) {
            return NO;
        }
        
        for (NSString *octet in octets) {
            int val = [octet intValue];
            if (val < 0 || val > 255) {
                return NO;
            }
        }
        
        return YES;
    }
    
    return YES;
}

@end

#pragma mark - NetworkInterface

@implementation NetworkInterface

@synthesize identifier, name, displayName, hardwareAddress, type, state;
@synthesize isEnabled, isActive, activeConnectionUUID, ipv4Config, ipv6Config;

- (id)init
{
    self = [super init];
    if (self) {
        identifier = nil;
        name = nil;
        displayName = nil;
        hardwareAddress = nil;
        type = NetworkInterfaceTypeUnknown;
        state = NetworkConnectionStateUnknown;
        isEnabled = NO;
        isActive = NO;
        activeConnectionUUID = nil;
        ipv4Config = nil;
        ipv6Config = nil;
    }
    return self;
}

- (void)dealloc
{
    [identifier release];
    [name release];
    [displayName release];
    [hardwareAddress release];
    [activeConnectionUUID release];
    [ipv4Config release];
    [ipv6Config release];
    [super dealloc];
}

- (id)copyWithZone:(NSZone *)zone
{
    NetworkInterface *copy = [[NetworkInterface allocWithZone:zone] init];
    copy.identifier = self.identifier;
    copy.name = self.name;
    copy.displayName = self.displayName;
    copy.hardwareAddress = self.hardwareAddress;
    copy.type = self.type;
    copy.state = self.state;
    copy.isEnabled = self.isEnabled;
    copy.isActive = self.isActive;
    copy.activeConnectionUUID = self.activeConnectionUUID;
    copy.ipv4Config = [[self.ipv4Config copy] autorelease];
    copy.ipv6Config = [[self.ipv6Config copy] autorelease];
    return copy;
}

- (NSString *)stateString
{
    switch (state) {
        case NetworkConnectionStateConnected:
            return @"Connected";
        case NetworkConnectionStateConnecting:
            return @"Connecting...";
        case NetworkConnectionStateDisconnected:
            return @"Not Connected";
        case NetworkConnectionStateDisconnecting:
            return @"Disconnecting...";
        case NetworkConnectionStateNeedsAuth:
            return @"Authentication Required";
        case NetworkConnectionStateFailed:
            return @"Connection Failed";
        case NetworkConnectionStateUnavailable:
            return @"Unavailable";
        default:
            return @"Unknown";
    }
}

- (NSString *)typeString
{
    switch (type) {
        case NetworkInterfaceTypeEthernet:
            return @"Ethernet";
        case NetworkInterfaceTypeWLAN:
            return @"WLAN";
        case NetworkInterfaceTypeBluetooth:
            return @"Bluetooth";
        case NetworkInterfaceTypeBridge:
            return @"Bridge";
        case NetworkInterfaceTypeVPN:
            return @"VPN";
        case NetworkInterfaceTypeLoopback:
            return @"Loopback";
        default:
            return @"Unknown";
    }
}

- (NSImage *)statusIcon
{
    NSString *iconName = nil;
    
    if (state == NetworkConnectionStateConnected) {
        switch (type) {
            case NetworkInterfaceTypeEthernet:
                iconName = @"network-wired";
                break;
            case NetworkInterfaceTypeWLAN:
                iconName = @"network-wireless";
                break;
            default:
                iconName = @"network-idle";
                break;
        }
    } else {
        iconName = @"network-offline";
    }
    
    // Try to load from system icons
    NSImage *icon = [NSImage imageNamed:iconName];
    if (!icon) {
        // Fallback to generic icon
        icon = [NSImage imageNamed:@"NSNetwork"];
    }
    
    return icon;
}

@end

#pragma mark - WLAN

@implementation WLAN

@synthesize ssid, bssid, signalStrength, security, isConnected, isSaved;
@synthesize frequency, channel;

- (id)init
{
    self = [super init];
    if (self) {
        ssid = nil;
        bssid = nil;
        signalStrength = 0;
        security = WLANSecurityNone;
        isConnected = NO;
        isSaved = NO;
        frequency = 0;
        channel = 0;
    }
    return self;
}

- (void)dealloc
{
    [ssid release];
    [bssid release];
    [super dealloc];
}

- (id)copyWithZone:(NSZone *)zone
{
    WLAN *copy = [[WLAN allocWithZone:zone] init];
    copy.ssid = self.ssid;
    copy.bssid = self.bssid;
    copy.signalStrength = self.signalStrength;
    copy.security = self.security;
    copy.isConnected = self.isConnected;
    copy.isSaved = self.isSaved;
    copy.frequency = self.frequency;
    copy.channel = self.channel;
    return copy;
}

- (NSString *)securityString
{
    switch (security) {
        case WLANSecurityNone:
            return @"Open";
        case WLANSecurityWEP:
            return @"WEP";
        case WLANSecurityWPA:
            return @"WPA";
        case WLANSecurityWPA2:
            return @"WPA2";
        case WLANSecurityWPA3:
            return @"WPA3";
        case WLANSecurityEnterprise:
            return @"802.1X";
        default:
            return @"";
    }
}

- (int)signalBars
{
    // Convert dBm to bars (0-4)
    // Typical ranges: -30 dBm (excellent) to -90 dBm (unusable)
    if (signalStrength >= -50) return 4;
    if (signalStrength >= -60) return 3;
    if (signalStrength >= -70) return 2;
    if (signalStrength >= -80) return 1;
    return 0;
}

- (NSImage *)signalIcon
{
    int bars = [self signalBars];
    NSString *iconName = [NSString stringWithFormat:@"network-wireless-signal-%d", bars];
    
    NSImage *icon = [NSImage imageNamed:iconName];
    if (!icon) {
        icon = [NSImage imageNamed:@"NSNetwork"];
    }
    
    return icon;
}

@end

#pragma mark - NetworkConnection

@implementation NetworkConnection

@synthesize uuid, identifier, name, type, autoConnect, interfaceName;
@synthesize ssid, WLANSecurity, clonedMacAddress, ipv4Config, ipv6Config;
@synthesize eapMethod, identity, anonymousIdentity;
@synthesize caCertPath, clientCertPath, privateKeyPath;

- (id)init
{
    self = [super init];
    if (self) {
        uuid = nil;
        identifier = nil;
        name = nil;
        type = NetworkInterfaceTypeUnknown;
        autoConnect = YES;
        interfaceName = nil;
        ssid = nil;
        WLANSecurity = WLANSecurityNone;
        ipv4Config = [[IPConfiguration alloc] init];
        ipv6Config = [[IPConfiguration alloc] init];
        eapMethod = nil;
        identity = nil;
        anonymousIdentity = nil;
        caCertPath = nil;
        clientCertPath = nil;
        privateKeyPath = nil;
    }
    return self;
}

- (void)dealloc
{
    [uuid release];
    [identifier release];
    [name release];
    [interfaceName release];
    [ssid release];
    [clonedMacAddress release];
    [ipv4Config release];
    [ipv6Config release];
    [eapMethod release];
    [identity release];
    [anonymousIdentity release];
    [caCertPath release];
    [clientCertPath release];
    [privateKeyPath release];
    [super dealloc];
}

- (id)copyWithZone:(NSZone *)zone
{
    NetworkConnection *copy = [[NetworkConnection allocWithZone:zone] init];
    copy.uuid = self.uuid;
    copy.identifier = self.identifier;
    copy.name = self.name;
    copy.type = self.type;
    copy.autoConnect = self.autoConnect;
    copy.interfaceName = self.interfaceName;
    copy.ssid = self.ssid;
    copy.WLANSecurity = self.WLANSecurity;
    copy.clonedMacAddress = self.clonedMacAddress;
    copy.ipv4Config = [[self.ipv4Config copy] autorelease];
    copy.ipv6Config = [[self.ipv6Config copy] autorelease];
    copy.eapMethod = self.eapMethod;
    copy.identity = self.identity;
    copy.anonymousIdentity = self.anonymousIdentity;
    copy.caCertPath = self.caCertPath;
    copy.clientCertPath = self.clientCertPath;
    copy.privateKeyPath = self.privateKeyPath;
    return copy;
}

@end
