#ifndef MB_DAEMON_H
#define MB_DAEMON_H

#import <Foundation/Foundation.h>

@class MBConnection;
@class MBMessage;

/**
 * MBDaemon - A minimal D-Bus message bus daemon
 * 
 * This daemon implements the core D-Bus message bus functionality:
 * - Connection management
 * - Name service (registering and resolving bus names)
 * - Message routing between clients
 * - Basic introspection
 */
@interface MBDaemon : NSObject
{
    NSMutableArray *_connections;
    NSMutableArray *_monitorConnections;  // Separate list for monitor connections
    NSMutableDictionary *_nameOwners;  // Maps bus names to connection objects
    NSMutableDictionary *_connectionNames; // Maps connections to their unique names
    NSString *_socketPath;
    int _serverSocket;
    BOOL _running;
    NSUInteger _nextUniqueId;
}

@property (nonatomic, readonly) NSString *socketPath;
@property (nonatomic, readonly) BOOL running;

/**
 * Initialize daemon with socket path
 */
- (instancetype)initWithSocketPath:(NSString *)socketPath;

/**
 * Start the daemon (creates socket, starts accepting connections)
 */
- (BOOL)start;

/**
 * Stop the daemon
 */
- (void)stop;

/**
 * Main run loop - call this after start
 */
- (void)run;

/**
 * Handle new connection
 */
- (void)handleNewConnection:(int)clientSocket;

/**
 * Process message from a connection
 */
- (void)processMessage:(MBMessage *)message fromConnection:(MBConnection *)connection;

/**
 * Route message to appropriate destination
 */
- (void)routeMessage:(MBMessage *)message fromConnection:(MBConnection *)connection;

/**
 * Register a name for a connection
 */
- (BOOL)registerName:(NSString *)name forConnection:(MBConnection *)connection;

/**
 * Release a name from a connection
 */
- (BOOL)releaseName:(NSString *)name fromConnection:(MBConnection *)connection;

/**
 * Get owner of a name
 */
- (MBConnection *)ownerOfName:(NSString *)name;

/**
 * Generate unique connection name
 */
- (NSString *)generateUniqueNameForConnection:(MBConnection *)connection;

/**
 * Convert connection to monitor (for dbus-monitor support)
 */
- (void)handleBecomeMonitor:(MBMessage *)message fromConnection:(MBConnection *)connection;

@end

#endif // MB_DAEMON_H
