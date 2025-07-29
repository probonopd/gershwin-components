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
    reply.destination = uniqueName;  // Reply is addressed to the client
    reply.sender = @"org.freedesktop.DBus";  // Bus daemon is the sender
    
    // Send NameAcquired signal to the new connection
    MBMessage *nameAcquired = [MBMessage signalWithPath:@"/org/freedesktop/DBus"
                                              interface:@"org.freedesktop.DBus"
                                                 member:@"NameAcquired"
                                              arguments:@[uniqueName]];
    nameAcquired.sender = @"org.freedesktop.DBus";
    nameAcquired.destination = uniqueName;
    
    // Send Hello reply and NameAcquired signal atomically to prevent client disconnect
    [connection sendMessages:@[reply, nameAcquired]];
    
    // Send NameOwnerChanged signal to all connections (including this one)
    MBMessage *nameOwnerChanged = [MBMessage signalWithPath:@"/org/freedesktop/DBus"
                                                  interface:@"org.freedesktop.DBus"
                                                     member:@"NameOwnerChanged"
                                                  arguments:@[uniqueName, @"", uniqueName]];
    nameOwnerChanged.sender = @"org.freedesktop.DBus";
    // No destination means broadcast to all connections
    
    // Send to all active connections
    for (MBConnection *conn in [_connections copy]) {
        if (conn.state == MBConnectionStateActive) {
            [conn sendMessage:nameOwnerChanged];
        }
    }
    
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
    NSMutableArray *names = [NSMutableArray arrayWithArray:[_nameOwners allKeys]];
    
    // Add unique names
    for (MBConnection *conn in _connections) {
        if (conn.uniqueName) {
            [names addObject:conn.uniqueName];
        }
    }
    
    // Add bus name
    [names addObject:@"org.freedesktop.DBus"];
    
    MBMessage *reply = [MBMessage methodReturnWithReplySerial:message.serial
                                                    arguments:@[names]];
    reply.sender = @"org.freedesktop.DBus";
    [connection sendMessage:reply];
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

- (void)routeMessage:(MBMessage *)message fromConnection:(MBConnection *)connection
{
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
    } else {
        NSLog(@"No destination found for %@", message.destination);
        
        // Send error back if this was a method call
        if (message.type == MBMessageTypeMethodCall) {
            MBMessage *error = [MBMessage errorWithName:@"org.freedesktop.DBus.Error.ServiceUnknown"
                                            replySerial:message.serial
                                                message:@"Service not found"];
            error.sender = @"org.freedesktop.DBus";
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

@end
