#import "MBDaemon.h"
#import "MBConnection.h"
#import "MBMessage.h"
#import "MBTransport.h"
#import <sys/select.h>
#import <unistd.h>

@implementation MBDaemon

- (instancetype)initWithSocketPath:(NSString *)socketPath
{
    self = [super init];
    if (self) {
        _socketPath = [socketPath copy];
        _connections = [[NSMutableArray alloc] init];
        _monitorConnections = [[NSMutableArray alloc] init];
        _nameOwners = [[NSMutableDictionary alloc] init];
        _connectionNames = [[NSMutableDictionary alloc] init];
        _serverSocket = -1;
        _running = NO;
        _nextUniqueId = 1;
    }
    return self;
}

- (void)dealloc
{
    [self stop];
    [super dealloc];
}

- (BOOL)start
{
    if (_running) {
        return YES;
    }
    
    _serverSocket = [MBTransport createUnixServerSocket:_socketPath];
    if (_serverSocket < 0) {
        NSLog(@"Failed to create server socket");
        return NO;
    }
    
    _running = YES;
    NSLog(@"MiniBus daemon started on %@", _socketPath);
    return YES;
}

- (void)stop
{
    if (!_running) {
        return;
    }
    
    _running = NO;
    
    // Close all client connections
    for (MBConnection *connection in _connections) {
        [connection close];
    }
    [_connections removeAllObjects];
    
    // Close all monitor connections
    for (MBConnection *connection in _monitorConnections) {
        [connection close];
    }
    [_monitorConnections removeAllObjects];
    
    [_nameOwners removeAllObjects];
    [_connectionNames removeAllObjects];
    
    // Close server socket
    if (_serverSocket >= 0) {
        [MBTransport closeSocket:_serverSocket];
        _serverSocket = -1;
        
        // Remove socket file
        unlink([_socketPath UTF8String]);
    }
    
    NSLog(@"MiniBus daemon stopped");
}

- (void)run
{
    if (!_running) {
        NSLog(@"Daemon not started");
        return;
    }
    
    NSLog(@"MiniBus daemon running, waiting for connections...");
    
    while (_running) {
        fd_set readfds;
        FD_ZERO(&readfds);
        
        int maxfd = _serverSocket;
        FD_SET(_serverSocket, &readfds);
        
        // Add all client sockets to select set
        for (MBConnection *connection in _connections) {
            if (connection.socket >= 0) {
                FD_SET(connection.socket, &readfds);
                if (connection.socket > maxfd) {
                    maxfd = connection.socket;
                }
            }
        }
        
        // Add all monitor sockets to select set
        for (MBConnection *connection in _monitorConnections) {
            if (connection.socket >= 0) {
                FD_SET(connection.socket, &readfds);
                if (connection.socket > maxfd) {
                    maxfd = connection.socket;
                }
            }
        }
        
        // Use select with timeout
        struct timeval timeout;
        timeout.tv_sec = 1;
        timeout.tv_usec = 0;
        
        int result = select(maxfd + 1, &readfds, NULL, NULL, &timeout);
        
        if (result < 0) {
            if (errno == EINTR) {
                continue; // Interrupted by signal
            }
            NSLog(@"select() failed: %s", strerror(errno));
            break;
        }
        
        if (result == 0) {
            continue; // Timeout
        }
        
        // Check for new connections
        if (FD_ISSET(_serverSocket, &readfds)) {
            int clientSocket = [MBTransport acceptConnection:_serverSocket];
            if (clientSocket >= 0) {
                [self handleNewConnection:clientSocket];
            }
        }
        
        // Check existing connections for data
        NSMutableArray *connectionsToRemove = [NSMutableArray array];
        
        // Create a copy of connections array to avoid mutation during enumeration
        NSArray *connectionsCopy = [NSArray arrayWithArray:_connections];
        
        for (MBConnection *connection in connectionsCopy) {
            if (connection.socket >= 0 && FD_ISSET(connection.socket, &readfds)) {
                NSArray *messages = [connection processIncomingData];
                
                if (connection.socket < 0) {
                    // Connection closed
                    [connectionsToRemove addObject:connection];
                    continue;
                }
                
                // Process received messages
                for (MBMessage *message in messages) {
                    [self processMessage:message fromConnection:connection];
                }
            }
        }
        
        // Remove closed connections
        for (MBConnection *connection in connectionsToRemove) {
            [self removeConnection:connection];
        }
        
        // Check monitor connections for data (they don't send messages, just receive)
        NSMutableArray *monitorConnectionsToRemove = [NSMutableArray array];
        NSArray *monitorConnectionsCopy = [NSArray arrayWithArray:_monitorConnections];
        
        for (MBConnection *connection in monitorConnectionsCopy) {
            if (connection.socket >= 0 && FD_ISSET(connection.socket, &readfds)) {
                NSArray *messages = [connection processIncomingData];
                
                if (connection.socket < 0) {
                    // Monitor connection closed
                    [monitorConnectionsToRemove addObject:connection];
                    continue;
                }
                
                // Monitor connections shouldn't send messages, but if they do, ignore them
                if ([messages count] > 0) {
                    NSLog(@"Monitor connection attempted to send message - ignoring");
                }
            }
        }
        
        // Remove closed monitor connections
        for (MBConnection *connection in monitorConnectionsToRemove) {
            [_monitorConnections removeObject:connection];
            NSLog(@"Monitor connection removed: %@", connection);
        }
    }
}

- (void)handleNewConnection:(int)clientSocket
{
    // Set client socket to non-blocking mode
    if (![MBTransport setSocketNonBlocking:clientSocket]) {
        NSLog(@"Failed to set client socket to non-blocking mode");
        close(clientSocket);
        return;
    }
    
    MBConnection *connection = [[MBConnection alloc] initWithSocket:clientSocket daemon:self];
    [_connections addObject:connection];
    
    NSLog(@"New connection added: %@", connection);
}

- (void)removeConnection:(MBConnection *)connection
{
    // Remove from name ownership
    NSMutableArray *namesToRelease = [NSMutableArray array];
    for (NSString *name in _nameOwners) {
        if (_nameOwners[name] == connection) {
            [namesToRelease addObject:name];
        }
    }
    for (NSString *name in namesToRelease) {
        [_nameOwners removeObjectForKey:name];
    }
    
    [_connectionNames removeObjectForKey:@(connection.socket)];
    [_connections removeObject:connection];
    
    NSLog(@"Connection removed: %@", connection);
}

- (void)processMessage:(MBMessage *)message fromConnection:(MBConnection *)connection
{
    NSLog(@"Processing message: %@ from %@", message, connection);
    
    // Handle Hello message
    if ([message.interface isEqualToString:@"org.freedesktop.DBus"] &&
        [message.member isEqualToString:@"Hello"]) {
        [self handleHelloMessage:message fromConnection:connection];
        return;
    }
    
    // All other messages require the client to be registered (have sent Hello)
    if (connection.state != MBConnectionStateActive) {
        NSLog(@"Rejecting message from unregistered client: %@", message);
        MBMessage *error = [MBMessage errorWithName:@"org.freedesktop.DBus.Error.AccessDenied"
                                        replySerial:message.serial
                                            message:@"Client tried to send a message other than Hello without being registered"];
        error.sender = @"org.freedesktop.DBus";
        [connection sendMessage:error];
        return;
    }
    
    // Handle name service methods
    if ([message.interface isEqualToString:@"org.freedesktop.DBus"]) {
        if ([message.member isEqualToString:@"RequestName"]) {
            [self handleRequestName:message fromConnection:connection];
            return;
        } else if ([message.member isEqualToString:@"ReleaseName"]) {
            [self handleReleaseName:message fromConnection:connection];
            return;
        } else if ([message.member isEqualToString:@"ListNames"]) {
            [self handleListNames:message fromConnection:connection];
            return;
        } else if ([message.member isEqualToString:@"GetNameOwner"]) {
            [self handleGetNameOwner:message fromConnection:connection];
            return;
        } else if ([message.member isEqualToString:@"AddMatch"]) {
            [self handleAddMatch:message fromConnection:connection];
            return;
        } else if ([message.member isEqualToString:@"RemoveMatch"]) {
            [self handleRemoveMatch:message fromConnection:connection];
            return;
        }
    }
    
    // Handle monitoring interface methods
    if ([message.interface isEqualToString:@"org.freedesktop.DBus.Monitoring"]) {
        if ([message.member isEqualToString:@"BecomeMonitor"]) {
            [self handleBecomeMonitor:message fromConnection:connection];
            return;
        }
    }
    
    // Route message to destination
    [self routeMessage:message fromConnection:connection];
}

- (void)handleHelloMessage:(MBMessage *)message fromConnection:(MBConnection *)connection
{
    if (connection.state != MBConnectionStateWaitingForHello) {
        // Send error
        MBMessage *error = [MBMessage errorWithName:@"org.freedesktop.DBus.Error.Failed"
                                        replySerial:message.serial
                                            message:@"Hello already sent"];
        error.sender = @"org.freedesktop.DBus";
        [connection sendMessage:error];
        return;
    }
    
    // Generate unique name
    NSString *uniqueName = [self generateUniqueNameForConnection:connection];
    connection.uniqueName = uniqueName;
    connection.state = MBConnectionStateActive;
    
    // Send reply with unique name
    MBMessage *reply = [MBMessage methodReturnWithReplySerial:message.serial
                                                    arguments:@[uniqueName]];
    // Real daemon Hello replies have destination=client, sender=bus
    reply.destination = uniqueName;  // Reply is addressed to the client
    reply.sender = @"org.freedesktop.DBus";  // Reply comes from the bus
    
    // Send ONLY the Hello reply - don't send NameAcquired signal with it
    // Standard tools like dbus-send expect exactly one message in response to Hello
    [connection sendMessage:reply];
    
    // Broadcast Hello reply to monitors
    [self broadcastToMonitors:reply];
    
    NSLog(@"Hello processed for connection %@, assigned name %@", connection, uniqueName);
}

- (void)handleRequestName:(MBMessage *)message fromConnection:(MBConnection *)connection
{
    if ([message.arguments count] < 1) {
        MBMessage *error = [MBMessage errorWithName:@"org.freedesktop.DBus.Error.InvalidArgs"
                                        replySerial:message.serial
                                            message:@"Missing name argument"];
        error.sender = @"org.freedesktop.DBus";
        [connection sendMessage:error];
        return;
    }
    
    NSString *name = message.arguments[0];
    BOOL success = [self registerName:name forConnection:connection];
    
    // Send reply
    NSUInteger result = success ? 1 : 2; // 1 = DBUS_REQUEST_NAME_REPLY_PRIMARY_OWNER, 2 = EXISTS
    MBMessage *reply = [MBMessage methodReturnWithReplySerial:message.serial
                                                    arguments:@[@(result)]];
    reply.sender = @"org.freedesktop.DBus";
    [connection sendMessage:reply];
    
    NSLog(@"RequestName %@ for connection %@: %@", name, connection, success ? @"SUCCESS" : @"FAILED");
}

- (void)handleReleaseName:(MBMessage *)message fromConnection:(MBConnection *)connection
{
    if ([message.arguments count] < 1) {
        MBMessage *error = [MBMessage errorWithName:@"org.freedesktop.DBus.Error.InvalidArgs"
                                        replySerial:message.serial
                                            message:@"Missing name argument"];
        error.sender = @"org.freedesktop.DBus";
        [connection sendMessage:error];
        return;
    }
    
    NSString *name = message.arguments[0];
    BOOL success = [self releaseName:name fromConnection:connection];
    
    // Send reply
    NSUInteger result = success ? 1 : 2; // 1 = RELEASED, 2 = NON_EXISTENT
    MBMessage *reply = [MBMessage methodReturnWithReplySerial:message.serial
                                                    arguments:@[@(result)]];
    reply.sender = @"org.freedesktop.DBus";
    [connection sendMessage:reply];
}

- (void)handleListNames:(MBMessage *)message fromConnection:(MBConnection *)connection
{
    NSMutableArray *names = [NSMutableArray array];
    
    // Add bus name FIRST (like reference implementation)
    [names addObject:@"org.freedesktop.DBus"];
    
    // Add well-known names
    [names addObjectsFromArray:[_nameOwners allKeys]];
    
    // Add unique names
    for (MBConnection *conn in _connections) {
        if (conn.uniqueName) {
            [names addObject:conn.uniqueName];
        }
    }

    NSLog(@"ListNames: returning %lu names: %@", (unsigned long)[names count], names);
    
    MBMessage *reply = [MBMessage methodReturnWithReplySerial:message.serial
                                                    arguments:@[names]];
    reply.sender = @"org.freedesktop.DBus";
    reply.destination = connection.uniqueName;  // Reply is addressed to the client
    
    NSLog(@"ListNames: sending reply to %@", connection.uniqueName);
    BOOL success = [connection sendMessage:reply];
    NSLog(@"ListNames: send result: %@", success ? @"SUCCESS" : @"FAILED");
}

- (void)handleGetNameOwner:(MBMessage *)message fromConnection:(MBConnection *)connection
{
    if ([message.arguments count] < 1) {
        MBMessage *error = [MBMessage errorWithName:@"org.freedesktop.DBus.Error.InvalidArgs"
                                        replySerial:message.serial
                                            message:@"Missing name argument"];
        error.sender = @"org.freedesktop.DBus";
        [connection sendMessage:error];
        return;
    }
    
    NSString *name = message.arguments[0];
    MBConnection *owner = [self ownerOfName:name];
    
    if (owner && owner.uniqueName) {
        MBMessage *reply = [MBMessage methodReturnWithReplySerial:message.serial
                                                        arguments:@[owner.uniqueName]];
        reply.sender = @"org.freedesktop.DBus";
        [connection sendMessage:reply];
    } else {
        MBMessage *error = [MBMessage errorWithName:@"org.freedesktop.DBus.Error.NameHasNoOwner"
                                        replySerial:message.serial
                                            message:@"Name has no owner"];
        error.sender = @"org.freedesktop.DBus";
        [connection sendMessage:error];
    }
}

- (void)handleAddMatch:(MBMessage *)message fromConnection:(MBConnection *)connection
{
    // AddMatch is used to subscribe to D-Bus signals
    // For now, just acknowledge success - signal routing is not fully implemented
    NSLog(@"AddMatch request from %@: %@", connection.uniqueName, message.arguments);
    
    MBMessage *reply = [MBMessage methodReturnWithReplySerial:message.serial
                                                    arguments:@[]];
    reply.sender = @"org.freedesktop.DBus";
    reply.destination = connection.uniqueName;
    [connection sendMessage:reply];
}

- (void)handleRemoveMatch:(MBMessage *)message fromConnection:(MBConnection *)connection
{
    // RemoveMatch is used to unsubscribe from D-Bus signals  
    // For now, just acknowledge success - signal routing is not fully implemented
    NSLog(@"RemoveMatch request from %@: %@", connection.uniqueName, message.arguments);
    
    MBMessage *reply = [MBMessage methodReturnWithReplySerial:message.serial
                                                    arguments:@[]];
    reply.sender = @"org.freedesktop.DBus";
    reply.destination = connection.uniqueName;
    [connection sendMessage:reply];
}

- (void)routeMessage:(MBMessage *)message fromConnection:(MBConnection *)connection
{
    // Broadcast to monitors first (before any modification)
    [self broadcastToMonitors:message];
    
    // Set sender if not already set
    if (!message.sender && connection.uniqueName) {
        message.sender = connection.uniqueName;
    }
    
    if (!message.destination) {
        NSLog(@"Message has no destination, treating as org.freedesktop.DBus call");
        // For testing, assume any message without destination is for the bus
        message.destination = @"org.freedesktop.DBus";
        message.interface = @"org.freedesktop.DBus";
        message.member = @"GetNameOwner";
    }
    
    // Find destination connection
    MBConnection *destConnection = nil;
    
    // Check if it's a well-known name
    destConnection = [self ownerOfName:message.destination];
    
    // Check if it's a unique name
    if (!destConnection) {
        for (MBConnection *conn in _connections) {
            if ([conn.uniqueName isEqualToString:message.destination]) {
                destConnection = conn;
                break;
            }
        }
    }
    
    if (destConnection) {
        [destConnection sendMessage:message];
        NSLog(@"Routed message to %@", destConnection);
        
        // If this generates a reply, monitors should see that too
        // (this will be handled when the reply is processed)
        
    } else {
        NSLog(@"No destination found for %@", message.destination);
        
        // Send error back if this was a method call
        if (message.type == MBMessageTypeMethodCall) {
            MBMessage *error = [MBMessage errorWithName:@"org.freedesktop.DBus.Error.ServiceUnknown"
                                            replySerial:message.serial
                                                message:@"Service not found"];
            error.sender = @"org.freedesktop.DBus";
            
            // Broadcast error to monitors too
            [self broadcastToMonitors:error];
            
            [connection sendMessage:error];
        }
    }
}

- (BOOL)registerName:(NSString *)name forConnection:(MBConnection *)connection
{
    if (!name || [name length] == 0) {
        return NO;
    }
    
    // Check if name already owned
    if (_nameOwners[name]) {
        return NO; // Name already taken
    }
    
    _nameOwners[name] = connection;
    NSLog(@"Registered name %@ for connection %@", name, connection);
    return YES;
}

- (BOOL)releaseName:(NSString *)name fromConnection:(MBConnection *)connection
{
    if (!name || _nameOwners[name] != connection) {
        return NO;
    }
    
    [_nameOwners removeObjectForKey:name];
    NSLog(@"Released name %@ from connection %@", name, connection);
    return YES;
}

- (MBConnection *)ownerOfName:(NSString *)name
{
    return _nameOwners[name];
}

- (NSString *)generateUniqueNameForConnection:(MBConnection *)connection
{
    NSString *uniqueName = [NSString stringWithFormat:@":1.%lu", (unsigned long)_nextUniqueId++];
    _connectionNames[@(connection.socket)] = uniqueName;
    return uniqueName;
}

- (void)handleBecomeMonitor:(MBMessage *)message fromConnection:(MBConnection *)connection
{
    NSLog(@"BecomeMonitor request from connection %@", connection);
    
    // TODO: In a real implementation, we should check if the connection is privileged
    // For now, we'll allow any connection to become a monitor
    
    // Convert the connection to a monitor
    connection.state = MBConnectionStateMonitor;
    
    // Remove from regular connections and add to monitor connections
    [_connections removeObject:connection];
    [_monitorConnections addObject:connection];
    
    // Remove all names owned by this connection (monitors can't own names)
    NSMutableArray *namesToRelease = [NSMutableArray array];
    for (NSString *name in _nameOwners) {
        if (_nameOwners[name] == connection) {
            [namesToRelease addObject:name];
        }
    }
    for (NSString *name in namesToRelease) {
        [_nameOwners removeObjectForKey:name];
    }
    
    // Remove unique name tracking
    [_connectionNames removeObjectForKey:@(connection.socket)];
    
    // Send empty reply (success)
    MBMessage *reply = [MBMessage methodReturnWithReplySerial:message.serial
                                                    arguments:@[]];  // Empty arguments array
    reply.destination = connection.uniqueName;  // Use old unique name for reply
    reply.sender = @"org.freedesktop.DBus";
    
    [connection sendMessage:reply];
    
    NSLog(@"Connection %@ converted to monitor", connection);
}

- (void)broadcastToMonitors:(MBMessage *)message
{
    // Send message to all monitor connections
    for (MBConnection *monitor in _monitorConnections) {
        // Create a copy of the message for monitoring
        MBMessage *monitorMessage = [[MBMessage alloc] init];
        monitorMessage.type = message.type;
        monitorMessage.destination = message.destination;
        monitorMessage.sender = message.sender;
        monitorMessage.interface = message.interface;
        monitorMessage.member = message.member;
        monitorMessage.path = message.path;
        monitorMessage.signature = message.signature;
        monitorMessage.serial = message.serial;
        monitorMessage.replySerial = message.replySerial;
        monitorMessage.arguments = message.arguments;
        
        [monitor sendMessage:monitorMessage];
        [monitorMessage release];
    }
}

@end
