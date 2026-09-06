/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Network Backend Protocol
 * 
 * This protocol defines the interface for network management backends.
 * Implementations can use NetworkManager, systemd-networkd, BSD ifconfig,
 * or any other network management system while keeping the UI consistent.
 */

#import <Foundation/Foundation.h>

// Network interface types
typedef NS_ENUM(NSInteger, NetworkInterfaceType) {
    NetworkInterfaceTypeUnknown = 0,
    NetworkInterfaceTypeEthernet,
    NetworkInterfaceTypeWLAN,
    NetworkInterfaceTypeBluetooth,
    NetworkInterfaceTypeBridge,
    NetworkInterfaceTypeVPN,
    NetworkInterfaceTypeLoopback
};

// Network connection states
typedef NS_ENUM(NSInteger, NetworkConnectionState) {
    NetworkConnectionStateUnknown = 0,
    NetworkConnectionStateDisconnected,
    NetworkConnectionStateConnecting,
    NetworkConnectionStateConnected,
    NetworkConnectionStateDisconnecting,
    NetworkConnectionStateNeedsAuth,
    NetworkConnectionStateFailed,
    NetworkConnectionStateUnavailable
};

// IP configuration methods
typedef NS_ENUM(NSInteger, IPConfigMethod) {
    IPConfigMethodDHCP = 0,
    IPConfigMethodManual,
    IPConfigMethodDisabled,
    IPConfigMethodLinkLocal
};

// WLAN security types
typedef NS_ENUM(NSInteger, WLANSecurityType) {
    WLANSecurityNone = 0,
    WLANSecurityWEP,
    WLANSecurityWPA,
    WLANSecurityWPA2,
    WLANSecurityWPA3,
    WLANSecurityEnterprise
};

// Forward declarations
@class NetworkInterface;
@class NetworkConnection;
@class WLAN;
@class IPConfiguration;

#pragma mark - IPConfiguration

@interface IPConfiguration : NSObject <NSCopying>
{
    IPConfigMethod method;
    NSString *address;
    NSString *subnetMask;
    NSString *router;
    NSArray *dnsServers;
    NSArray *searchDomains;
}

@property IPConfigMethod method;
@property (copy) NSString *address;
@property (copy) NSString *subnetMask;
@property (copy) NSString *router;
@property (copy) NSArray *dnsServers;
@property (copy) NSArray *searchDomains;

- (BOOL)isValid;

@end

#pragma mark - NetworkInterface

@interface NetworkInterface : NSObject <NSCopying>
{
    NSString *identifier;
    NSString *name;
    NSString *displayName;
    NSString *hardwareAddress;
    NetworkInterfaceType type;
    NetworkConnectionState state;
    BOOL isEnabled;
    BOOL isActive;
    NSString *activeConnectionUUID;
    IPConfiguration *ipv4Config;
    IPConfiguration *ipv6Config;
}

@property (copy) NSString *identifier;
@property (copy) NSString *name;
@property (copy) NSString *displayName;
@property (copy) NSString *hardwareAddress;
@property NetworkInterfaceType type;
@property NetworkConnectionState state;
@property BOOL isEnabled;
@property BOOL isActive;
@property (copy) NSString *activeConnectionUUID;
@property (retain) IPConfiguration *ipv4Config;
@property (retain) IPConfiguration *ipv6Config;

- (NSString *)stateString;
- (NSString *)typeString;
- (NSImage *)statusIcon;

@end

#pragma mark - WLAN

@interface WLAN : NSObject <NSCopying>
{
    NSString *ssid;
    NSString *bssid;
    int signalStrength;
    WLANSecurityType security;
    BOOL isConnected;
    BOOL isSaved;
    int frequency;
    int channel;
}

@property (copy) NSString *ssid;
@property (copy) NSString *bssid;
@property int signalStrength;
@property WLANSecurityType security;
@property BOOL isConnected;
@property BOOL isSaved;
@property int frequency;
@property int channel;

- (NSString *)securityString;
- (NSImage *)signalIcon;
- (int)signalBars; // 0-4 bars

@end

#pragma mark - NetworkConnection (Saved Connection Profile)

@interface NetworkConnection : NSObject <NSCopying>
{
    NSString *uuid;
    NSString *identifier;
    NSString *name;
    NetworkInterfaceType type;
    BOOL autoConnect;
    NSString *interfaceName;
    
    // WLAN specific
    NSString *ssid;
    WLANSecurityType WLANSecurity;
    NSString *clonedMacAddress;
    
    // IP settings
    IPConfiguration *ipv4Config;
    IPConfiguration *ipv6Config;
    
    // 802.1x / Enterprise settings
    NSString *eapMethod;
    NSString *identity;
    NSString *anonymousIdentity;
    NSString *caCertPath;
    NSString *clientCertPath;
    NSString *privateKeyPath;
}

@property (copy) NSString *uuid;
@property (copy) NSString *identifier;
@property (copy) NSString *name;
@property NetworkInterfaceType type;
@property BOOL autoConnect;
@property (copy) NSString *interfaceName;
@property (copy) NSString *ssid;
@property WLANSecurityType WLANSecurity;
@property (copy) NSString *clonedMacAddress;
@property (retain) IPConfiguration *ipv4Config;
@property (retain) IPConfiguration *ipv6Config;
@property (copy) NSString *eapMethod;
@property (copy) NSString *identity;
@property (copy) NSString *anonymousIdentity;
@property (copy) NSString *caCertPath;
@property (copy) NSString *clientCertPath;
@property (copy) NSString *privateKeyPath;

@end

#pragma mark - NetworkBackend Protocol

@protocol NetworkBackendDelegate;

@protocol NetworkBackend <NSObject>

@required

// Backend identification
- (NSString *)backendName;
- (NSString *)backendVersion;
- (BOOL)isAvailable;

// Delegate
@property (assign) id<NetworkBackendDelegate> delegate;

// Interface management
- (NSArray *)availableInterfaces;
- (NetworkInterface *)interfaceWithIdentifier:(NSString *)identifier;
- (BOOL)enableInterface:(NetworkInterface *)interface;
- (BOOL)disableInterface:(NetworkInterface *)interface;

// Connection management
- (NSArray *)savedConnections;
- (NetworkConnection *)connectionWithUUID:(NSString *)uuid;
- (BOOL)activateConnection:(NetworkConnection *)connection onInterface:(NetworkInterface *)interface;
- (BOOL)deactivateConnection:(NetworkConnection *)connection;
- (BOOL)deleteConnection:(NetworkConnection *)connection;
- (BOOL)saveConnection:(NetworkConnection *)connection;
- (NetworkConnection *)createConnectionForInterface:(NetworkInterface *)interface;

// WLAN specific
- (BOOL)isWLANEnabled;
- (BOOL)setWLANEnabled:(BOOL)enabled;
- (NSArray *)scanForWLANs;
- (BOOL)startWLANScan;
- (BOOL)connectToWLAN:(WLAN *)network withPassword:(NSString *)password;
- (BOOL)disconnectFromWLAN;
- (WLAN *)connectedWLAN;
- (NSString *)connectedWLANSSID;
- (NSString *)clonedMacAddressForSSID:(NSString *)ssid;
- (BOOL)setClonedMacAddress:(NSString *)value forSSID:(NSString *)ssid;

// Status
- (NetworkConnectionState)globalConnectionState;
- (NSString *)primaryConnectionName;
- (NetworkInterface *)primaryInterface;

// Refresh
- (void)refresh;

@optional

// VPN support (for future expansion)
- (NSArray *)vpnConnections;
- (BOOL)connectVPN:(NetworkConnection *)connection;
- (BOOL)disconnectVPN:(NetworkConnection *)connection;

// Proxy configuration
- (NSDictionary *)proxyConfiguration;
- (BOOL)setProxyConfiguration:(NSDictionary *)config;

// Locations (network configurations, like on classic systems)
- (NSArray *)locations;
- (NSString *)currentLocation;
- (BOOL)setLocation:(NSString *)locationName;
- (BOOL)createLocation:(NSString *)locationName;
- (BOOL)deleteLocation:(NSString *)locationName;

@end

#pragma mark - NetworkBackendDelegate

@protocol NetworkBackendDelegate <NSObject>

@optional

// Called when network state changes
- (void)networkBackend:(id<NetworkBackend>)backend didChangeState:(NetworkConnectionState)state;

// Called when interfaces change (added/removed/modified)
- (void)networkBackend:(id<NetworkBackend>)backend didUpdateInterfaces:(NSArray *)interfaces;

// Called when connections change
- (void)networkBackend:(id<NetworkBackend>)backend didUpdateConnections:(NSArray *)connections;

// Called when WLAN scan completes
- (void)networkBackend:(id<NetworkBackend>)backend didFinishWLANScan:(NSArray *)networks;

// Called when WLAN state changes
- (void)networkBackend:(id<NetworkBackend>)backend WLANEnabledDidChange:(BOOL)enabled;

// Called when an error occurs
- (void)networkBackend:(id<NetworkBackend>)backend didEncounterError:(NSError *)error;

// Called when a connection attempt completes
- (void)networkBackend:(id<NetworkBackend>)backend 
    connectionDidChange:(NetworkConnection *)connection 
               toState:(NetworkConnectionState)state;

// Called when password is needed for a connection
- (void)networkBackend:(id<NetworkBackend>)backend 
    needsPasswordForNetwork:(WLAN *)network 
            completion:(void (^)(NSString *password, BOOL cancelled))completion;

@end
