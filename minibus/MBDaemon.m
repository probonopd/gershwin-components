#import "MBDaemon.h"
#import "MBConnection.h"
#import "MBMessage.h"
#import "MBTransport.h"
#import "MBServiceManager.h"
#import <sys/select.h>
#import <unistd.h>

// D-Bus RequestName reply constants
#define DBUS_REQUEST_NAME_REPLY_PRIMARY_OWNER    1
#define DBUS_REQUEST_NAME_REPLY_IN_QUEUE         2
#define DBUS_REQUEST_NAME_REPLY_EXISTS           3
#define DBUS_REQUEST_NAME_REPLY_ALREADY_OWNER    4

// D-Bus RequestName flag constants
#define DBUS_NAME_FLAG_ALLOW_REPLACEMENT   0x1
#define DBUS_NAME_FLAG_REPLACE_EXISTING    0x2
#define DBUS_NAME_FLAG_DO_NOT_QUEUE        0x4

@interface MBDaemon ()
// Add properties for match rule tracking
@property (nonatomic, strong) NSMutableDictionary *matchRules; // connection -> array of match rules
@property (nonatomic, strong) NSMutableDictionary *nameOwnerships; // name -> MBNameOwnership (NSDictionary)
@property (nonatomic, strong) NSMutableDictionary *nameQueues; // name -> array of connections waiting
@end

@implementation MBDaemon

- (instancetype)initWithSocketPath:(NSString *)socketPath
{
    self = [super init];
    if (self) {
        _socketPath = [socketPath copy];
        _connections = [[NSMutableArray alloc] init];
        _monitorConnections = [[NSMutableArray alloc] init];
        _nameOwnerships = [[NSMutableDictionary alloc] init]; // name -> NSDictionary
        _connectionNames = [[NSMutableDictionary alloc] init];
        _serverSocket = -1;
        _running = NO;
        _nextUniqueId = 1;
        _matchRules = [[NSMutableDictionary alloc] init];
        _nameQueues = [[NSMutableDictionary alloc] init];
        
        // Set up service activation
        [self setupServiceManager];
    }
    return self;
}

- (void)dealloc
{
    [self stop];
    [_serviceManager release];
    [super dealloc];
}

- (void)setupServiceManager
{
    // Determine service directories based on common D-Bus conventions
    NSMutableArray *servicePaths = [NSMutableArray array];
    
    // Add test directory first for testing
    [servicePaths addObject:@"/tmp/dbus-test-services"];
    
    // Session bus service directories (in order of precedence)
    NSString *homeDir = NSHomeDirectory();
    if (homeDir) {
        [servicePaths addObject:[homeDir stringByAppendingPathComponent:@".local/share/dbus-1/services"]];
    }
    [servicePaths addObject:@"/usr/local/share/dbus-1/services"];
    [servicePaths addObject:@"/usr/share/dbus-1/services"];
    
    // System bus service directories (commented out since minibus is primarily for session bus)
    // [servicePaths addObject:@"/etc/dbus-1/system-services"];
    // [servicePaths addObject:@"/usr/local/share/dbus-1/system-services"];
    // [servicePaths addObject:@"/usr/share/dbus-1/system-services"];
    
    _serviceManager = [[MBServiceManager alloc] initWithServicePaths:servicePaths];
    [_serviceManager loadServices];
    
    NSLog(@"Service activation initialized with %lu available services", 
          (unsigned long)[[_serviceManager availableServiceNames] count]);
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
    
    [_connectionNames removeAllObjects];
    [_nameOwnerships removeAllObjects];
    
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
    // Remove from name ownership - use the new nameOwnerships structure
    NSMutableArray *namesToRelease = [NSMutableArray array];
    for (NSString *name in _nameOwnerships) {
        NSMutableDictionary *ownership = _nameOwnerships[name];
        if (ownership[@"primary_owner"] == connection) {
            [namesToRelease addObject:name];
        }
    }
    for (NSString *name in namesToRelease) {
        [self releaseName:name fromConnection:connection];
    }
    
    // Clean up match rules for this connection
    [self cleanupMatchRulesForConnection:connection];
    
    [_connectionNames removeObjectForKey:@(connection.socket)];
    [_connections removeObject:connection];
    
    NSLog(@"Connection removed: %@", connection);
}

- (void)processMessage:(MBMessage *)message fromConnection:(MBConnection *)connection
{
    // Set sender if not already set
    if (!message.sender && connection.uniqueName) {
        message.sender = connection.uniqueName;
    }
    
    // Add debugging for problematic messages
    if (!message.destination || !message.interface || !message.member) {
        NSLog(@"DEBUG: Problematic message - type=%u serial=%lu", message.type, (unsigned long)message.serial);
        NSLog(@"       destination='%@' interface='%@' member='%@' path='%@'", 
              message.destination, message.interface, message.member, message.path);
        if (message.arguments && [message.arguments count] > 0) {
            NSLog(@"       arguments: %@", message.arguments);
        }
        if (message.signature) {
            NSLog(@"       signature: '%@'", message.signature);
        }
    }

    if (!message.destination) {
        // No destination means this is likely a malformed message
        NSLog(@"Message has no destination - interface: '%@', member: '%@', path: '%@'", 
              message.interface, message.member, message.path);
        
        // Send error back if this was a method call
        if (message.type == MBMessageTypeMethodCall) {
            MBMessage *error = [MBMessage errorWithName:@"org.freedesktop.DBus.Error.Failed"
                                            replySerial:message.serial
                                                message:@"Message has no destination"];
            error.sender = @"org.freedesktop.DBus";
            
            // Broadcast error to monitors too
            [self broadcastToMonitors:error];
            
            [connection sendMessage:error];
        }
        return;
    }
    
    // Handle Hello message
    if ([message.interface isEqualToString:@"org.freedesktop.DBus"] &&
        [message.member isEqualToString:@"Hello"]) {
        NSLog(@"Recognized Hello message!");
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
        NSLog(@"Received D-Bus method call: member='%@', args=%@", message.member, message.arguments);
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
        } else if ([message.member isEqualToString:@"StartServiceByName"]) {
            [self handleStartServiceByName:message fromConnection:connection];
            return;
        } else if ([message.member isEqualToString:@"AddMatch"]) {
            [self handleAddMatch:message fromConnection:connection];
            return;
        } else if ([message.member isEqualToString:@"RemoveMatch"]) {
            [self handleRemoveMatch:message fromConnection:connection];
            return;
        } else if ([message.member isEqualToString:@"NameHasOwner"]) {
            [self handleNameHasOwner:message fromConnection:connection];
            return;
        } else if ([message.member isEqualToString:@"ListActivatableNames"]) {
            [self handleListActivatableNames:message fromConnection:connection];
            return;
        } else if ([message.member isEqualToString:@"ListQueuedOwners"]) {
            [self handleListQueuedOwners:message fromConnection:connection];
            return;
        } else if ([message.member isEqualToString:@"GetConnectionUnixUser"]) {
            [self handleGetConnectionUnixUser:message fromConnection:connection];
            return;
        } else if ([message.member isEqualToString:@"GetConnectionUnixProcessID"]) {
            [self handleGetConnectionUnixProcessID:message fromConnection:connection];
            return;
        } else if ([message.member isEqualToString:@"GetAdtAuditSessionData"]) {
            [self handleGetAdtAuditSessionData:message fromConnection:connection];
            return;
        } else if ([message.member isEqualToString:@"GetConnectionSELinuxSecurityContext"]) {
            [self handleGetConnectionSELinuxSecurityContext:message fromConnection:connection];
            return;
        } else if ([message.member isEqualToString:@"ReloadConfig"]) {
            [self handleReloadConfig:message fromConnection:connection];
            return;
        } else if ([message.member isEqualToString:@"GetId"]) {
            [self handleGetId:message fromConnection:connection];
            return;
        } else if ([message.member isEqualToString:@"GetConnectionCredentials"]) {
            [self handleGetConnectionCredentials:message fromConnection:connection];
            return;
        } else if ([message.member isEqualToString:@"UpdateActivationEnvironment"]) {
            [self handleUpdateActivationEnvironment:message fromConnection:connection];
            return;
        }
    }
    
    // Handle Properties interface
    if ([message.interface isEqualToString:@"org.freedesktop.DBus.Properties"]) {
        if ([message.member isEqualToString:@"Get"]) {
            [self handlePropertiesGet:message fromConnection:connection];
            return;
        } else if ([message.member isEqualToString:@"GetAll"]) {
            [self handlePropertiesGetAll:message fromConnection:connection];
            return;
        } else if ([message.member isEqualToString:@"Set"]) {
            [self handlePropertiesSet:message fromConnection:connection];
            return;
        }
    }
    
    // Handle standard D-Bus interfaces (org.freedesktop.DBus.Peer)
    if ([message.interface isEqualToString:@"org.freedesktop.DBus.Peer"]) {
        if ([message.member isEqualToString:@"Ping"]) {
            [self handlePing:message fromConnection:connection];
            return;
        } else if ([message.member isEqualToString:@"GetMachineId"]) {
            [self handleGetMachineId:message fromConnection:connection];
            return;
        }
    }
    
    // Handle standard D-Bus interfaces (org.freedesktop.DBus.Introspectable)
    if ([message.interface isEqualToString:@"org.freedesktop.DBus.Introspectable"]) {
        if ([message.member isEqualToString:@"Introspect"]) {
            [self handleIntrospect:message fromConnection:connection];
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
    if ([message.arguments count] < 2) {
        MBMessage *error = [MBMessage errorWithName:@"org.freedesktop.DBus.Error.InvalidArgs"
                                        replySerial:message.serial
                                            message:@"Missing name or flags argument"];
        error.sender = @"org.freedesktop.DBus";
        [connection sendMessage:error];
        return;
    }
    
    NSString *name = message.arguments[0];
    NSUInteger flags = [message.arguments[1] unsignedIntegerValue];
    
    // Validate name
    if ([name isEqualToString:@"org.freedesktop.DBus"]) {
        MBMessage *error = [MBMessage errorWithName:@"org.freedesktop.DBus.Error.InvalidArgs"
                                        replySerial:message.serial
                                            message:@"Cannot acquire reserved name org.freedesktop.DBus"];
        error.sender = @"org.freedesktop.DBus";
        [connection sendMessage:error];
        return;
    }
    
    NSUInteger result = [self acquireName:name forConnection:connection withFlags:flags];
    
    // Send reply with proper D-Bus return code
    MBMessage *reply = [MBMessage methodReturnWithReplySerial:message.serial
                                                    arguments:@[@(result)]];
    reply.sender = @"org.freedesktop.DBus";
    reply.destination = connection.uniqueName;
    [connection sendMessage:reply];
    
    // If name was successfully acquired (primary owner), send NameAcquired signal
    if (result == DBUS_REQUEST_NAME_REPLY_PRIMARY_OWNER) {
        MBMessage *signal = [[MBMessage alloc] init];
        signal.type = MBMessageTypeSignal;
        signal.interface = @"org.freedesktop.DBus";
        signal.member = @"NameAcquired";
        signal.path = @"/org/freedesktop/DBus";
        signal.destination = connection.uniqueName;
        signal.sender = @"org.freedesktop.DBus";
        signal.arguments = @[name];
        signal.signature = @"s";
        
        [connection sendMessage:signal];
        [self broadcastToMonitors:signal];
        [signal release];
        
        NSLog(@"Sent NameAcquired signal for %@ to %@", name, connection.uniqueName);
        
        // Notify service manager that this service has connected (activation completed)
        if ([_serviceManager isActivatingService:name]) {
            [_serviceManager serviceActivationCompleted:name];
        }
    }
    
    NSLog(@"RequestName %@ for connection %@ with flags 0x%lx: result %lu", 
          name, connection.uniqueName, (unsigned long)flags, (unsigned long)result);
}

- (void)handleStartServiceByName:(MBMessage *)message fromConnection:(MBConnection *)connection
{
    if ([message.arguments count] < 2) {
        MBMessage *error = [MBMessage errorWithName:@"org.freedesktop.DBus.Error.InvalidArgs"
                                        replySerial:message.serial
                                            message:@"Missing name or flags argument"];
        error.sender = @"org.freedesktop.DBus";
        error.destination = connection.uniqueName;
        [connection sendMessage:error];
        return;
    }
    
    NSString *serviceName = message.arguments[0];
    NSUInteger flags = [message.arguments[1] unsignedIntegerValue];
    
    NSLog(@"StartServiceByName request for service '%@' with flags %lu from %@", 
          serviceName, (unsigned long)flags, connection.uniqueName);
    
    // Special case: org.freedesktop.DBus is always "already running" since WE are the bus daemon
    if ([serviceName isEqualToString:@"org.freedesktop.DBus"]) {
        NSLog(@"StartServiceByName: org.freedesktop.DBus is always running (we are the bus daemon)");
        
        MBMessage *reply = [MBMessage methodReturnWithReplySerial:message.serial
                                                        arguments:@[@1]]; // DBUS_START_REPLY_ALREADY_RUNNING = 1
        reply.sender = @"org.freedesktop.DBus";
        reply.destination = connection.uniqueName;
        [connection sendMessage:reply];
        return;
    }
    
    // Check if service is already running
    MBConnection *owner = [self ownerOfName:serviceName];
    if (owner && owner.uniqueName) {
        // Service already running
        NSLog(@"StartServiceByName: service '%@' already running as %@", serviceName, owner.uniqueName);
        
        MBMessage *reply = [MBMessage methodReturnWithReplySerial:message.serial
                                                        arguments:@[@1]]; // DBUS_START_REPLY_ALREADY_RUNNING = 1
        reply.sender = @"org.freedesktop.DBus";
        reply.destination = connection.uniqueName;
        [connection sendMessage:reply];
        return;
    }
    
    // Check if service is currently being activated
    if ([_serviceManager isActivatingService:serviceName]) {
        NSLog(@"StartServiceByName: service '%@' is already being activated", serviceName);
        
        MBMessage *reply = [MBMessage methodReturnWithReplySerial:message.serial
                                                        arguments:@[@2]]; // DBUS_START_REPLY_SUCCESS = 2 (activation started)
        reply.sender = @"org.freedesktop.DBus";
        reply.destination = connection.uniqueName;
        [connection sendMessage:reply];
        return;
    }
    
    // Try to activate the service
    if ([_serviceManager hasService:serviceName]) {
        NSError *error = nil;
        NSString *busAddress = [NSString stringWithFormat:@"unix:path=%@", _socketPath];
        
        if ([_serviceManager activateService:serviceName 
                                  busAddress:busAddress 
                                     busType:@"session" 
                                       error:&error]) {
            NSLog(@"StartServiceByName: successfully started activation for service '%@'", serviceName);
            
            MBMessage *reply = [MBMessage methodReturnWithReplySerial:message.serial
                                                            arguments:@[@2]]; // DBUS_START_REPLY_SUCCESS = 2
            reply.sender = @"org.freedesktop.DBus";
            reply.destination = connection.uniqueName;
            [connection sendMessage:reply];
        } else {
            NSLog(@"StartServiceByName: failed to activate service '%@': %@", serviceName, error.localizedDescription);
            
            MBMessage *errorMsg = [MBMessage errorWithName:@"org.freedesktop.DBus.Error.Spawn.Failed"
                                               replySerial:message.serial
                                                   message:[NSString stringWithFormat:@"Failed to activate service %@: %@", 
                                                           serviceName, error.localizedDescription]];
            errorMsg.sender = @"org.freedesktop.DBus";
            errorMsg.destination = connection.uniqueName;
            [connection sendMessage:errorMsg];
        }
    } else {
        // Service not found
        NSLog(@"StartServiceByName: service '%@' not found in service files", serviceName);
        
        MBMessage *errorMsg = [MBMessage errorWithName:@"org.freedesktop.DBus.Error.ServiceUnknown"
                                           replySerial:message.serial
                                               message:[NSString stringWithFormat:@"The name %@ was not provided by any .service files", serviceName]];
        errorMsg.sender = @"org.freedesktop.DBus";
        errorMsg.destination = connection.uniqueName;
        [connection sendMessage:errorMsg];
    }
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
    
    // Check if this connection owns the name
    NSMutableDictionary *ownership = self.nameOwnerships[name];
    BOOL wasOwner = (ownership && ownership[@"primary_owner"] == connection);
    
    BOOL success = [self releaseName:name fromConnection:connection];
    
    // Send reply
    NSUInteger result = success ? 1 : 2; // 1 = RELEASED, 2 = NON_EXISTENT
    MBMessage *reply = [MBMessage methodReturnWithReplySerial:message.serial
                                                    arguments:@[@(result)]];
    reply.sender = @"org.freedesktop.DBus";
    reply.destination = connection.uniqueName;
    [connection sendMessage:reply];
    
    // If the connection was the owner and successfully released, send NameLost signal
    if (success && wasOwner) {
        MBMessage *signal = [[MBMessage alloc] init];
        signal.type = MBMessageTypeSignal;
        signal.interface = @"org.freedesktop.DBus";
        signal.member = @"NameLost";
        signal.path = @"/org/freedesktop/DBus";
        signal.destination = connection.uniqueName;
        signal.sender = @"org.freedesktop.DBus";
        signal.arguments = @[name];
        signal.signature = @"s";
        
        [connection sendMessage:signal];
        [self broadcastToMonitors:signal];
        [signal release];
        
        NSLog(@"Sent NameLost signal for %@ to %@", name, connection.uniqueName);
    }
}

- (void)handleListNames:(MBMessage *)message fromConnection:(MBConnection *)connection
{
    NSMutableArray *names = [NSMutableArray array];
    
    // Add bus name FIRST (like reference implementation)
    [names addObject:@"org.freedesktop.DBus"];
    
    // Add well-known names from nameOwnerships
    for (NSString *name in _nameOwnerships) {
        NSMutableDictionary *ownership = _nameOwnerships[name];
        if (ownership[@"primary_owner"] != nil) {
            [names addObject:name];
        }
    }
    
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
    if ([message.arguments count] < 1) {
        NSLog(@"AddMatch: Missing arguments");
        MBMessage *error = [MBMessage errorWithName:@"org.freedesktop.DBus.Error.InvalidArgs"
                                        replySerial:message.serial
                                            message:@"Missing match rule argument"];
        error.sender = @"org.freedesktop.DBus";
        error.destination = connection.uniqueName;
        [connection sendMessage:error];
        return;
    }
    
    NSString *matchRule = message.arguments[0];
    NSLog(@"AddMatch request from %@: '%@'", connection.uniqueName, matchRule);
    
    // Parse and validate the match rule (basic validation)
    if (![self isValidMatchRule:matchRule]) {
        NSLog(@"AddMatch: Invalid match rule: '%@'", matchRule);
        MBMessage *error = [MBMessage errorWithName:@"org.freedesktop.DBus.Error.MatchRuleInvalid"
                                        replySerial:message.serial
                                            message:@"Invalid match rule"];
        error.sender = @"org.freedesktop.DBus";
        error.destination = connection.uniqueName;
        [connection sendMessage:error];
        return;
    }
    
    // Store the match rule for this connection
    NSMutableArray *connectionRules = self.matchRules[connection.uniqueName];
    if (!connectionRules) {
        connectionRules = [[NSMutableArray alloc] init];
        self.matchRules[connection.uniqueName] = connectionRules;
    }
    
    // Check for duplicates (D-Bus allows this but it's good to track)
    if (![connectionRules containsObject:matchRule]) {
        [connectionRules addObject:matchRule];
    }
    
    NSLog(@"AddMatch: Successfully added rule '%@' for %@", matchRule, connection.uniqueName);
    
    // Send success response
    MBMessage *reply = [MBMessage methodReturnWithReplySerial:message.serial
                                                    arguments:@[]];
    reply.sender = @"org.freedesktop.DBus";
    reply.destination = connection.uniqueName;
    [connection sendMessage:reply];
}

- (void)handleRemoveMatch:(MBMessage *)message fromConnection:(MBConnection *)connection
{
    if ([message.arguments count] < 1) {
        MBMessage *error = [MBMessage errorWithName:@"org.freedesktop.DBus.Error.InvalidArgs"
                                        replySerial:message.serial
                                            message:@"Missing match rule argument"];
        error.sender = @"org.freedesktop.DBus";
        error.destination = connection.uniqueName;
        [connection sendMessage:error];
        return;
    }
    
    NSString *matchRule = message.arguments[0];
    NSLog(@"RemoveMatch request from %@: %@", connection.uniqueName, matchRule);
    
    // Find and remove the match rule for this connection
    NSMutableArray *connectionRules = self.matchRules[connection.uniqueName];
    if (!connectionRules || ![connectionRules containsObject:matchRule]) {
        MBMessage *error = [MBMessage errorWithName:@"org.freedesktop.DBus.Error.MatchRuleNotFound"
                                        replySerial:message.serial
                                            message:@"Match rule not found"];
        error.sender = @"org.freedesktop.DBus";
        error.destination = connection.uniqueName;
        [connection sendMessage:error];
        return;
    }
    
    // Remove the first occurrence of the match rule
    [connectionRules removeObject:matchRule];
    
    // Clean up empty rule arrays
    if (connectionRules.count == 0) {
        [self.matchRules removeObjectForKey:connection.uniqueName];
    }
    
    // Send success response
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
    
    // Add debugging for problematic messages
    if (!message.destination || !message.interface || !message.member) {
        NSLog(@"DEBUG: Problematic message - type=%u serial=%lu", message.type, (unsigned long)message.serial);
        NSLog(@"       destination='%@' interface='%@' member='%@' path='%@'", 
              message.destination, message.interface, message.member, message.path);
        if (message.arguments && [message.arguments count] > 0) {
            NSLog(@"       arguments: %@", message.arguments);
        }
        if (message.signature) {
            NSLog(@"       signature: '%@'", message.signature);
        }
    }

    if (!message.destination) {
        // No destination means this is likely a malformed message
        NSLog(@"Message has no destination - interface: '%@', member: '%@', path: '%@'", 
              message.interface, message.member, message.path);
        
        // Send error back if this was a method call
        if (message.type == MBMessageTypeMethodCall) {
            MBMessage *error = [MBMessage errorWithName:@"org.freedesktop.DBus.Error.Failed"
                                            replySerial:message.serial
                                                message:@"Message has no destination"];
            error.sender = @"org.freedesktop.DBus";
            
            // Broadcast error to monitors too
            [self broadcastToMonitors:error];
            
            [connection sendMessage:error];
        }
        return;
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
        
        // Try auto-activation for method calls to well-known names
        if (message.type == MBMessageTypeMethodCall && 
            message.destination && ![message.destination hasPrefix:@":"]) {
            
            if ([self autoActivateServiceForMessage:message fromConnection:connection]) {
                NSLog(@"Auto-activation started for %@, message will be queued", message.destination);
                
                // TODO: Queue the message to be delivered when the service connects
                // For now, we'll just log that activation was started
                // The client will need to retry the call after the service starts
                
                MBMessage *error = [MBMessage errorWithName:@"org.freedesktop.DBus.Error.ServiceUnknown"
                                                replySerial:message.serial
                                                    message:[NSString stringWithFormat:@"Service %@ is being activated, please retry", message.destination]];
                error.sender = @"org.freedesktop.DBus";
                
                // Broadcast error to monitors too
                [self broadcastToMonitors:error];
                
                [connection sendMessage:error];
                return;
            }
        }
        
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
    NSMutableDictionary *ownership = self.nameOwnerships[name];
    if (!ownership) {
        ownership = [@{ @"primary_owner": connection,
                        @"queue": [NSMutableArray array],
                        @"allow_replacement": @(NO) } mutableCopy];
        self.nameOwnerships[name] = ownership;
        return YES;
    }
    if (ownership[@"primary_owner"] != nil) {
        return NO;
    }
    ownership[@"primary_owner"] = connection;
    return YES;
}

// Helper method to release a name from a connection
- (BOOL)releaseName:(NSString *)name fromConnection:(MBConnection *)connection
{
    NSMutableDictionary *ownership = self.nameOwnerships[name];
    if (!ownership || ownership[@"primary_owner"] != connection) {
        return NO;
    }
    
    NSString *oldOwner = connection.uniqueName;
    NSMutableArray *queue = ownership[@"queue"];
    NSString *newOwner = @""; // Empty string means no owner
    
    if ([queue count] > 0) {
        // There's someone in the queue to take over
        MBConnection *nextOwner = queue[0];
        [queue removeObjectAtIndex:0];
        ownership[@"primary_owner"] = nextOwner;
        newOwner = nextOwner.uniqueName;
        
        // Send NameAcquired signal to the new owner
        MBMessage *signal = [[MBMessage alloc] init];
        signal.type = MBMessageTypeSignal;
        signal.interface = @"org.freedesktop.DBus";
        signal.member = @"NameAcquired";
        signal.path = @"/org/freedesktop/DBus";
        signal.destination = nextOwner.uniqueName;
        signal.sender = @"org.freedesktop.DBus";
        signal.arguments = @[name];
        signal.signature = @"s";
        
        [nextOwner sendMessage:signal];
        [self broadcastToMonitors:signal];
        [signal release];
        
        NSLog(@"Sent NameAcquired signal for %@ to new owner %@", name, nextOwner.uniqueName);
    } else {
        // No one in queue, remove the ownership entirely
        [self.nameOwnerships removeObjectForKey:name];
    }
    
    // Send NameOwnerChanged signal to everyone
    MBMessage *ownerChangedSignal = [[MBMessage alloc] init];
    ownerChangedSignal.type = MBMessageTypeSignal;
    ownerChangedSignal.interface = @"org.freedesktop.DBus";
    ownerChangedSignal.member = @"NameOwnerChanged";
    ownerChangedSignal.path = @"/org/freedesktop/DBus";
    ownerChangedSignal.sender = @"org.freedesktop.DBus";
    ownerChangedSignal.arguments = @[name, oldOwner, newOwner];
    ownerChangedSignal.signature = @"sss";
    
    // Broadcast to all connections
    for (MBConnection *conn in _connections) {
        if (conn.state == MBConnectionStateActive) {
            [conn sendMessage:ownerChangedSignal];
        }
    }
    [self broadcastToMonitors:ownerChangedSignal];
    [ownerChangedSignal release];
    
    NSLog(@"Released name %@ from %@, new owner: %@", name, oldOwner, newOwner.length > 0 ? newOwner : @"(none)");
    return YES;
}

// Helper method to get owner of a name
- (MBConnection *)ownerOfName:(NSString *)name
{
    NSMutableDictionary *ownership = self.nameOwnerships[name];
    return ownership ? ownership[@"primary_owner"] : nil;
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
    
    // Remove all names owned by this connection from nameOwnerships
    NSMutableArray *namesToRelease = [NSMutableArray array];
    for (NSString *name in _nameOwnerships) {
        NSMutableDictionary *ownership = _nameOwnerships[name];
        if (ownership[@"primary_owner"] == connection) {
            [namesToRelease addObject:name];
        }
    }
    for (NSString *name in namesToRelease) {
        [self releaseName:name fromConnection:connection];
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

#pragma mark - Standard D-Bus Interface Implementations

- (void)handlePing:(MBMessage *)message fromConnection:(MBConnection *)connection
{
    // org.freedesktop.DBus.Peer.Ping() - just return success
    MBMessage *reply = [MBMessage methodReturnWithReplySerial:message.serial
                                                    arguments:@[]];
    reply.destination = connection.uniqueName;
    reply.sender = @"org.freedesktop.DBus";
    [connection sendMessage:reply];
    
    NSLog(@"Ping handled for connection %@", connection);
}

- (void)handleGetMachineId:(MBMessage *)message fromConnection:(MBConnection *)connection
{
    // org.freedesktop.DBus.Peer.GetMachineId() - return a machine ID
    // For simplicity, generate a fixed UUID-like string based on system info
    NSString *machineId = @"deadbeefdeadbeefdeadbeefdeadbeef"; // Simple fixed ID for testing
    
    MBMessage *reply = [MBMessage methodReturnWithReplySerial:message.serial
                                                    arguments:@[machineId]];
    reply.destination = connection.uniqueName;
    reply.sender = @"org.freedesktop.DBus";
    [connection sendMessage:reply];
    
    NSLog(@"GetMachineId handled for connection %@ - returned %@", connection, machineId);
}

- (void)handleIntrospect:(MBMessage *)message fromConnection:(MBConnection *)connection
{
    // org.freedesktop.DBus.Introspectable.Introspect() - return XML description
    NSString *introspectionXML = @"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
                                 @"<node>\n"
                                 @"  <interface name=\"org.freedesktop.DBus\">\n"
                                 @"    <method name=\"Hello\">\n"
                                 @"      <arg direction=\"out\" type=\"s\"/>\n"
                                 @"    </method>\n"
                                 @"    <method name=\"RequestName\">\n"
                                 @"      <arg direction=\"in\" type=\"s\"/>\n"
                                 @"      <arg direction=\"in\" type=\"u\"/>\n"
                                 @"      <arg direction=\"out\" type=\"u\"/>\n"
                                 @"    </method>\n"
                                 @"    <method name=\"ReleaseName\">\n"
                                 @"      <arg direction=\"in\" type=\"s\"/>\n"
                                 @"      <arg direction=\"out\" type=\"u\"/>\n"
                                 @"    </method>\n"
                                 @"    <method name=\"ListNames\">\n"
                                 @"      <arg direction=\"out\" type=\"as\"/>\n"
                                 @"    </method>\n"
                                 @"    <method name=\"GetNameOwner\">\n"
                                 @"      <arg direction=\"in\" type=\"s\"/>\n"
                                 @"      <arg direction=\"out\" type=\"s\"/>\n"
                                 @"    </method>\n"
                                 @"    <method name=\"StartServiceByName\">\n"
                                 @"      <arg direction=\"in\" type=\"s\"/>\n"
                                 @"      <arg direction=\"in\" type=\"u\"/>\n"
                                 @"      <arg direction=\"out\" type=\"u\"/>\n"
                                 @"    </method>\n"
                                 @"    <method name=\"AddMatch\">\n"
                                 @"      <arg direction=\"in\" type=\"s\"/>\n"
                                 @"    </method>\n"
                                 @"    <method name=\"RemoveMatch\">\n"
                                 @"      <arg direction=\"in\" type=\"s\"/>\n"
                                 @"    </method>\n"
                                 @"    <method name=\"NameHasOwner\">\n"
                                 @"      <arg direction=\"in\" type=\"s\"/>\n"
                                 @"      <arg direction=\"out\" type=\"b\"/>\n"
                                 @"    </method>\n"
                                 @"    <method name=\"ListActivatableNames\">\n"
                                 @"      <arg direction=\"out\" type=\"as\"/>\n"
                                 @"    </method>\n"
                                 @"    <method name=\"ListQueuedOwners\">\n"
                                 @"      <arg direction=\"in\" type=\"s\"/>\n"
                                 @"      <arg direction=\"out\" type=\"as\"/>\n"
                                 @"    </method>\n"
                                 @"    <method name=\"GetConnectionUnixUser\">\n"
                                 @"      <arg direction=\"in\" type=\"s\"/>\n"
                                 @"      <arg direction=\"out\" type=\"u\"/>\n"
                                 @"    </method>\n"
                                 @"    <method name=\"GetConnectionUnixProcessID\">\n"
                                 @"      <arg direction=\"in\" type=\"s\"/>\n"
                                 @"      <arg direction=\"out\" type=\"u\"/>\n"
                                 @"    </method>\n"
                                 @"    <method name=\"GetAdtAuditSessionData\">\n"
                                 @"      <arg direction=\"in\" type=\"s\"/>\n"
                                 @"      <arg direction=\"out\" type=\"ay\"/>\n"
                                 @"    </method>\n"
                                 @"    <method name=\"GetConnectionSELinuxSecurityContext\">\n"
                                 @"      <arg direction=\"in\" type=\"s\"/>\n"
                                 @"      <arg direction=\"out\" type=\"ay\"/>\n"
                                 @"    </method>\n"
                                 @"    <method name=\"ReloadConfig\">\n"
                                 @"    </method>\n"
                                 @"    <method name=\"GetId\">\n"
                                 @"      <arg direction=\"out\" type=\"s\"/>\n"
                                 @"    </method>\n"
                                 @"    <signal name=\"NameOwnerChanged\">\n"
                                 @"      <arg type=\"s\"/>\n"
                                 @"      <arg type=\"s\"/>\n"
                                 @"      <arg type=\"s\"/>\n"
                                 @"    </signal>\n"
                                 @"    <signal name=\"NameLost\">\n"
                                 @"      <arg type=\"s\"/>\n"
                                 @"    </signal>\n"
                                 @"    <signal name=\"NameAcquired\">\n"
                                 @"      <arg type=\"s\"/>\n"
                                 @"    </signal>\n"
                                 @"  </interface>\n"
                                 @"  <interface name=\"org.freedesktop.DBus.Peer\">\n"
                                 @"    <method name=\"Ping\"/>\n"
                                 @"    <method name=\"GetMachineId\">\n"
                                 @"      <arg direction=\"out\" type=\"s\"/>\n"
                                 @"    </method>\n"
                                 @"  </interface>\n"
                                 @"  <interface name=\"org.freedesktop.DBus.Introspectable\">\n"
                                 @"    <method name=\"Introspect\">\n"
                                 @"      <arg direction=\"out\" type=\"s\"/>\n"
                                 @"    </method>\n"
                                 @"  </interface>\n"
                                 @"  <interface name=\"org.freedesktop.DBus.Properties\">\n"
                                 @"    <method name=\"Get\">\n"
                                 @"      <arg direction=\"in\" type=\"s\"/>\n"
                                 @"      <arg direction=\"in\" type=\"s\"/>\n"
                                 @"      <arg direction=\"out\" type=\"v\"/>\n"
                                 @"    </method>\n"
                                 @"    <method name=\"Set\">\n"
                                 @"      <arg direction=\"in\" type=\"s\"/>\n"
                                 @"      <arg direction=\"in\" type=\"s\"/>\n"
                                 @"      <arg direction=\"in\" type=\"v\"/>\n"
                                 @"    </method>\n"
                                 @"    <method name=\"GetAll\">\n"
                                 @"      <arg direction=\"in\" type=\"s\"/>\n"
                                 @"      <arg direction=\"out\" type=\"a{sv}\"/>\n"
                                 @"    </method>\n"
                                 @"    <signal name=\"PropertiesChanged\">\n"
                                 @"      <arg type=\"s\"/>\n"
                                 @"      <arg type=\"a{sv}\"/>\n"
                                 @"      <arg type=\"as\"/>\n"
                                 @"    </signal>\n"
                                 @"  </interface>\n"
                                 @"  <interface name=\"org.freedesktop.DBus.Monitoring\">\n"
                                 @"    <method name=\"BecomeMonitor\">\n"
                                 @"      <arg direction=\"in\" type=\"as\"/>\n"
                                 @"      <arg direction=\"in\" type=\"u\"/>\n"
                                 @"    </method>\n"
                                 @"  </interface>\n"
                                 @"</node>\n";
    
    MBMessage *reply = [MBMessage methodReturnWithReplySerial:message.serial
                                                    arguments:@[introspectionXML]];
    reply.destination = connection.uniqueName;
    reply.sender = @"org.freedesktop.DBus";
    [connection sendMessage:reply];
    
    NSLog(@"Introspect handled for connection %@", connection);
}

#pragma mark - Additional org.freedesktop.DBus Method Implementations

- (void)handleNameHasOwner:(MBMessage *)message fromConnection:(MBConnection *)connection
{
    if ([message.arguments count] < 1) {
        MBMessage *error = [MBMessage errorWithName:@"org.freedesktop.DBus.Error.InvalidArgs"
                                        replySerial:message.serial
                                            message:@"Missing name argument"];
        error.sender = @"org.freedesktop.DBus";
        error.destination = connection.uniqueName;
        [connection sendMessage:error];
        return;
    }
    
    NSString *name = message.arguments[0];
    MBConnection *owner = [self ownerOfName:name];
    
    BOOL hasOwner = (owner != nil) || [name isEqualToString:@"org.freedesktop.DBus"];
    
    MBMessage *reply = [MBMessage methodReturnWithReplySerial:message.serial
                                                    arguments:@[@(hasOwner)]];
    reply.sender = @"org.freedesktop.DBus";
    reply.destination = connection.uniqueName;
    [connection sendMessage:reply];
    
    NSLog(@"NameHasOwner %@ for connection %@: %@", name, connection.uniqueName, hasOwner ? @"true" : @"false");
}

- (void)handleListActivatableNames:(MBMessage *)message fromConnection:(MBConnection *)connection
{
    // For a minimal implementation, we don't support service activation
    // Just return the bus name itself as activatable
    NSArray *activatableNames = @[@"org.freedesktop.DBus"];
    
    MBMessage *reply = [MBMessage methodReturnWithReplySerial:message.serial
                                                    arguments:@[activatableNames]];
    reply.sender = @"org.freedesktop.DBus";
    reply.destination = connection.uniqueName;
    [connection sendMessage:reply];
    
    NSLog(@"ListActivatableNames for connection %@: returning %lu names", 
          connection.uniqueName, (unsigned long)[activatableNames count]);
}

- (void)handleListQueuedOwners:(MBMessage *)message fromConnection:(MBConnection *)connection
{
    if ([message.arguments count] < 1) {
        MBMessage *error = [MBMessage errorWithName:@"org.freedesktop.DBus.Error.InvalidArgs"
                                        replySerial:message.serial
                                            message:@"Missing name argument"];
        error.sender = @"org.freedesktop.DBus";
        error.destination = connection.uniqueName;
        [connection sendMessage:error];
        return;
    }
    
    NSString *name = message.arguments[0];
    
    // For now, we don't implement name queueing, so just return the current owner if any
    NSMutableArray *queuedOwners = [NSMutableArray array];
    MBConnection *owner = [self ownerOfName:name];
    if (owner && owner.uniqueName) {
        [queuedOwners addObject:owner.uniqueName];
    } else if ([name isEqualToString:@"org.freedesktop.DBus"]) {
        [queuedOwners addObject:@"org.freedesktop.DBus"];
    }
    
    MBMessage *reply = [MBMessage methodReturnWithReplySerial:message.serial
                                                    arguments:@[queuedOwners]];
    reply.sender = @"org.freedesktop.DBus";
    reply.destination = connection.uniqueName;
    [connection sendMessage:reply];
    
    NSLog(@"ListQueuedOwners %@ for connection %@: %lu owners", 
          name, connection.uniqueName, (unsigned long)[queuedOwners count]);
}

- (void)handleGetId:(MBMessage *)message fromConnection:(MBConnection *)connection
{
    // Return a fixed bus ID for simplicity
    NSString *busId = @"deadbeefdeadbeefdeadbeefdeadbeef12345678";
    
    MBMessage *reply = [MBMessage methodReturnWithReplySerial:message.serial
                                                    arguments:@[busId]];
    reply.sender = @"org.freedesktop.DBus";
    reply.destination = connection.uniqueName;
    [connection sendMessage:reply];
    
    NSLog(@"GetId handled for connection %@ - returned %@", connection.uniqueName, busId);
}

- (void)handleReloadConfig:(MBMessage *)message fromConnection:(MBConnection *)connection
{
    // For a minimal implementation, we don't have a config file to reload
    // Just return success
    MBMessage *reply = [MBMessage methodReturnWithReplySerial:message.serial
                                                    arguments:@[]];
    reply.sender = @"org.freedesktop.DBus";
    reply.destination = connection.uniqueName;
    [connection sendMessage:reply];
    
    NSLog(@"ReloadConfig handled for connection %@ - no-op success", connection.uniqueName);
}

#pragma mark - Complex org.freedesktop.DBus Method Stubs

- (void)handleUpdateActivationEnvironment:(MBMessage *)message fromConnection:(MBConnection *)connection
{
    NSLog(@"Unimplemented: UpdateActivationEnvironment - requires activation service support and environment management");
    
    MBMessage *error = [MBMessage errorWithName:@"org.freedesktop.DBus.Error.NotSupported"
                                    replySerial:message.serial
                                        message:@"UpdateActivationEnvironment not implemented in MiniBus"];
    error.sender = @"org.freedesktop.DBus";
    error.destination = connection.uniqueName;
    [connection sendMessage:error];
}

- (void)handleGetConnectionUnixUser:(MBMessage *)message fromConnection:(MBConnection *)connection
{
    NSLog(@"Unimplemented: GetConnectionUnixUser - requires credential tracking and socket credential extraction");
    
    MBMessage *error = [MBMessage errorWithName:@"org.freedesktop.DBus.Error.NotSupported"
                                    replySerial:message.serial
                                        message:@"GetConnectionUnixUser not implemented in MiniBus"];
    error.sender = @"org.freedesktop.DBus";
    error.destination = connection.uniqueName;
    [connection sendMessage:error];
}

- (void)handleGetConnectionUnixProcessID:(MBMessage *)message fromConnection:(MBConnection *)connection
{
    NSLog(@"Unimplemented: GetConnectionUnixProcessID - requires process ID tracking and socket credential extraction");
    
    MBMessage *error = [MBMessage errorWithName:@"org.freedesktop.DBus.Error.NotSupported"
                                    replySerial:message.serial
                                        message:@"GetConnectionUnixProcessID not implemented in MiniBus"];
    error.sender = @"org.freedesktop.DBus";
    error.destination = connection.uniqueName;
    [connection sendMessage:error];
}

- (void)handleGetAdtAuditSessionData:(MBMessage *)message fromConnection:(MBConnection *)connection
{
    NSLog(@"Unimplemented: GetAdtAuditSessionData - requires ADT audit support (Solaris-specific)");
    
    MBMessage *error = [MBMessage errorWithName:@"org.freedesktop.DBus.Error.NotSupported"
                                    replySerial:message.serial
                                        message:@"GetAdtAuditSessionData not implemented in MiniBus (platform-specific)"];
    error.sender = @"org.freedesktop.DBus";
    error.destination = connection.uniqueName;
    [connection sendMessage:error];
}

- (void)handleGetConnectionSELinuxSecurityContext:(MBMessage *)message fromConnection:(MBConnection *)connection
{
    NSLog(@"Unimplemented: GetConnectionSELinuxSecurityContext - requires SELinux integration and credential tracking");
    
    MBMessage *error = [MBMessage errorWithName:@"org.freedesktop.DBus.Error.NotSupported"
                                    replySerial:message.serial
                                        message:@"GetConnectionSELinuxSecurityContext not implemented in MiniBus"];
    error.sender = @"org.freedesktop.DBus";
    error.destination = connection.uniqueName;
    [connection sendMessage:error];
}

- (void)handleGetConnectionCredentials:(MBMessage *)message fromConnection:(MBConnection *)connection
{
    NSLog(@"Unimplemented: GetConnectionCredentials - requires comprehensive credential tracking (UID, PID, SELinux, etc.)");
    
    MBMessage *error = [MBMessage errorWithName:@"org.freedesktop.DBus.Error.NotSupported"
                                    replySerial:message.serial
                                        message:@"GetConnectionCredentials not implemented in MiniBus"];
    error.sender = @"org.freedesktop.DBus";
    error.destination = connection.uniqueName;
    [connection sendMessage:error];
}

#pragma mark - org.freedesktop.DBus.Properties Method Implementations

- (void)handlePropertiesGet:(MBMessage *)message fromConnection:(MBConnection *)connection
{
    if ([message.arguments count] < 2) {
        MBMessage *error = [MBMessage errorWithName:@"org.freedesktop.DBus.Error.InvalidArgs"
                                        replySerial:message.serial
                                            message:@"Missing interface or property argument"];
        error.sender = @"org.freedesktop.DBus";
        error.destination = connection.uniqueName;
        [connection sendMessage:error];
        return;
    }
    
    NSString *interfaceName = message.arguments[0];
    NSString *propertyName = message.arguments[1];
    
    if ([interfaceName isEqualToString:@"org.freedesktop.DBus"]) {
        id propertyValue = nil;
        
        if ([propertyName isEqualToString:@"Features"]) {
            propertyValue = @[]; // MiniBus doesn't support advanced features yet
        } else if ([propertyName isEqualToString:@"Interfaces"]) {
            propertyValue = @[
                @"org.freedesktop.DBus.Introspectable",
                @"org.freedesktop.DBus.Peer", 
                @"org.freedesktop.DBus.Properties"
            ];
        } else {
            NSLog(@"Unknown property: %@.%@", interfaceName, propertyName);
            MBMessage *error = [MBMessage errorWithName:@"org.freedesktop.DBus.Error.UnknownProperty"
                                        replySerial:message.serial
                                            message:[NSString stringWithFormat:@"Property %@ not found", propertyName]];
            error.sender = @"org.freedesktop.DBus";
            error.destination = connection.uniqueName;
            [connection sendMessage:error];
            return;
        }
        
        MBMessage *reply = [MBMessage methodReturnWithReplySerial:message.serial
                                                        arguments:@[propertyValue]];
        reply.sender = @"org.freedesktop.DBus";
        reply.destination = connection.uniqueName;
        [connection sendMessage:reply];
        
        NSLog(@"Properties.Get for interface '%@' property '%@' - returned value", interfaceName, propertyName);
    } else {
        NSLog(@"Unimplemented: Properties.Get for interface '%@' property '%@' - requires property introspection", 
              interfaceName, propertyName);
        
        MBMessage *error = [MBMessage errorWithName:@"org.freedesktop.DBus.Error.UnknownInterface"
                                        replySerial:message.serial
                                            message:[NSString stringWithFormat:@"Interface %@ not found", interfaceName]];
        error.sender = @"org.freedesktop.DBus";
        error.destination = connection.uniqueName;
        [connection sendMessage:error];
    }
}

- (void)handlePropertiesGetAll:(MBMessage *)message fromConnection:(MBConnection *)connection
{
    if ([message.arguments count] < 1) {
        MBMessage *error = [MBMessage errorWithName:@"org.freedesktop.DBus.Error.InvalidArgs"
                                        replySerial:message.serial
                                            message:@"Missing interface argument"];
        error.sender = @"org.freedesktop.DBus";
        error.destination = connection.uniqueName;
        [connection sendMessage:error];
        return;
    }
    
    NSString *interfaceName = message.arguments[0];
    
    // For org.freedesktop.DBus interface, return the standard properties
    if ([interfaceName isEqualToString:@"org.freedesktop.DBus"]) {
        // For now, return an empty dictionary since our serializer doesn't support a{sv} properly
        // TODO: Implement proper D-Bus dictionary serialization
        
        MBMessage *reply = [MBMessage methodReturnWithReplySerial:message.serial
                                                        arguments:@[]];
        reply.signature = @"a{sv}";  // Set correct signature manually
        reply.sender = @"org.freedesktop.DBus";
        reply.destination = connection.uniqueName;
        [connection sendMessage:reply];
        
        NSLog(@"Properties.GetAll for interface '%@' - returned empty dictionary (serialization limitation)", interfaceName);
    } else {
        NSLog(@"Unimplemented: Properties.GetAll for interface '%@' - interface not supported", interfaceName);
        
        MBMessage *error = [MBMessage errorWithName:@"org.freedesktop.DBus.Error.UnknownInterface"
                                    replySerial:message.serial
                                        message:[NSString stringWithFormat:@"Interface %@ not found", interfaceName]];
        error.sender = @"org.freedesktop.DBus";
        error.destination = connection.uniqueName;
        [connection sendMessage:error];
    }
}

- (void)handlePropertiesSet:(MBMessage *)message fromConnection:(MBConnection *)connection
{
    if ([message.arguments count] < 3) {
        MBMessage *error = [MBMessage errorWithName:@"org.freedesktop.DBus.Error.InvalidArgs"
                                        replySerial:message.serial
                                            message:@"Missing interface, property, or value argument"];
        error.sender = @"org.freedesktop.DBus";
        error.destination = connection.uniqueName;
        [connection sendMessage:error];
        return;
    }
    
    NSString *interfaceName = message.arguments[0];
    NSString *propertyName = message.arguments[1];
    // NSString *value = message.arguments[2]; // Value to set
    
    NSLog(@"Unimplemented: Properties.Set for interface '%@' property '%@' - properties are read-only in MiniBus", 
          interfaceName, propertyName);
    
    MBMessage *error = [MBMessage errorWithName:@"org.freedesktop.DBus.Error.PropertyReadOnly"
                                    replySerial:message.serial
                                        message:[NSString stringWithFormat:@"Property %@.%@ cannot be set", interfaceName, propertyName]];
    error.sender = @"org.freedesktop.DBus";
    error.destination = connection.uniqueName;
    [connection sendMessage:error];
}

#pragma mark - Helper Methods

// Helper method to validate match rules (basic validation)
- (BOOL)isValidMatchRule:(NSString *)matchRule
{
    if (!matchRule) {
        return NO;
    }
    
    // Allow empty match rules (matches everything)
    if (matchRule.length == 0) {
        return YES;
    }
    
    // Basic validation - check for common match rule patterns
    // A proper implementation would parse the full match rule syntax
    // For now, just check that it doesn't contain obviously invalid characters
    NSCharacterSet *invalidChars = [NSCharacterSet characterSetWithCharactersInString:@"\r\n\0"];
    if ([matchRule rangeOfCharacterFromSet:invalidChars].location != NSNotFound) {
        return NO;
    }
    
    // Very permissive - accept most reasonable strings
    // Real D-Bus match rules have formats like: type='signal',interface='org.example.Foo'
    return YES;
}

// Helper method to acquire names with proper flag handling
- (NSUInteger)acquireName:(NSString *)name forConnection:(MBConnection *)connection withFlags:(NSUInteger)flags
{
    // Reserved name check
    if ([name isEqualToString:@"org.freedesktop.DBus"]) {
        return DBUS_REQUEST_NAME_REPLY_EXISTS;
    }
    
    NSMutableDictionary *ownership = self.nameOwnerships[name];
    if (!ownership) {
        // Create new ownership record
        ownership = [@{ @"primary_owner": connection,
                        @"queue": [NSMutableArray array],
                        @"allow_replacement": @(flags & DBUS_NAME_FLAG_ALLOW_REPLACEMENT ? YES : NO) } mutableCopy];
        self.nameOwnerships[name] = ownership;
        
        // Send NameOwnerChanged signal (from no owner to new owner)
        [self sendNameOwnerChangedSignal:name oldOwner:@"" newOwner:connection.uniqueName];
        
        return DBUS_REQUEST_NAME_REPLY_PRIMARY_OWNER;
    }
    
    MBConnection *currentOwner = ownership[@"primary_owner"];
    NSMutableArray *queue = ownership[@"queue"];
    BOOL allowReplacement = [ownership[@"allow_replacement"] boolValue];
    
    if (currentOwner == connection) {
        // Update flags for existing owner
        ownership[@"allow_replacement"] = @(flags & DBUS_NAME_FLAG_ALLOW_REPLACEMENT ? YES : NO);
        return DBUS_REQUEST_NAME_REPLY_ALREADY_OWNER;
    }
    
    // Handle replacement
    if (flags & DBUS_NAME_FLAG_REPLACE_EXISTING) {
        if (allowReplacement) {
            // Replace current owner
            NSString *oldOwnerName = currentOwner.uniqueName;
            
            // Remove connection from queue if it was there
            [queue removeObject:connection];
            
            // Set as new primary owner
            ownership[@"primary_owner"] = connection;
            ownership[@"allow_replacement"] = @(flags & DBUS_NAME_FLAG_ALLOW_REPLACEMENT ? YES : NO);
            
            // Put old owner in queue if it doesn't have DO_NOT_QUEUE flag
            BOOL oldOwnerAllowsQueue = ![ownership[@"do_not_queue"] boolValue]; // Use old owner's flag
            if (oldOwnerAllowsQueue) {
                [queue insertObject:currentOwner atIndex:0];
            }
            
            // Send NameLost signal to old owner
            MBMessage *nameLostSignal = [[MBMessage alloc] init];
            nameLostSignal.type = MBMessageTypeSignal;
            nameLostSignal.interface = @"org.freedesktop.DBus";
            nameLostSignal.member = @"NameLost";
            nameLostSignal.path = @"/org/freedesktop/DBus";
            nameLostSignal.destination = currentOwner.uniqueName;
            nameLostSignal.sender = @"org.freedesktop.DBus";
            nameLostSignal.arguments = @[name];
            nameLostSignal.signature = @"s";
            
            [currentOwner sendMessage:nameLostSignal];
            [self broadcastToMonitors:nameLostSignal];
            [nameLostSignal release];
            
            // Send NameOwnerChanged signal
            [self sendNameOwnerChangedSignal:name oldOwner:oldOwnerName newOwner:connection.uniqueName];
            
            return DBUS_REQUEST_NAME_REPLY_PRIMARY_OWNER;
        } else {
            // Not allowed to replace
            if (flags & DBUS_NAME_FLAG_DO_NOT_QUEUE) {
                return DBUS_REQUEST_NAME_REPLY_EXISTS;
            } else {
                if (![queue containsObject:connection]) {
                    [queue addObject:connection];
                }
                return DBUS_REQUEST_NAME_REPLY_IN_QUEUE;
            }
        }
    }
    
    // Name exists, not requesting replacement
    if (flags & DBUS_NAME_FLAG_DO_NOT_QUEUE) {
        return DBUS_REQUEST_NAME_REPLY_EXISTS;
    } else {
        if (![queue containsObject:connection]) {
            [queue addObject:connection];
        }
        return DBUS_REQUEST_NAME_REPLY_IN_QUEUE;
    }
}

// Helper method to send NameOwnerChanged signal
- (void)sendNameOwnerChangedSignal:(NSString *)name oldOwner:(NSString *)oldOwner newOwner:(NSString *)newOwner
{
    MBMessage *signal = [[MBMessage alloc] init];
    signal.type = MBMessageTypeSignal;
    signal.interface = @"org.freedesktop.DBus";
    signal.member = @"NameOwnerChanged";
    signal.path = @"/org/freedesktop/DBus";
    signal.sender = @"org.freedesktop.DBus";
    signal.arguments = @[name, oldOwner, newOwner];
    signal.signature = @"sss";
    
    // Broadcast to all connections
    for (MBConnection *conn in _connections) {
        if (conn.state == MBConnectionStateActive) {
            [conn sendMessage:signal];
        }
    }
    [self broadcastToMonitors:signal];
    [signal release];
    
    NSLog(@"Sent NameOwnerChanged signal: %@ from '%@' to '%@'", name, oldOwner, newOwner);
}

// Helper method to clean up match rules when connection closes
- (void)cleanupMatchRulesForConnection:(MBConnection *)connection
{
    if (connection.uniqueName) {
        [self.matchRules removeObjectForKey:connection.uniqueName];
    }
}

// Helper method to unregister a name from a connection
- (void)unregisterName:(NSString *)name fromConnection:(MBConnection *)connection
{
    if (!name) {
        return;
    }
    
    NSMutableDictionary *ownership = self.nameOwnerships[name];
    if (!ownership || ownership[@"primary_owner"] != connection) {
        return;
    }
    
    // Release the name properly using the existing releaseName logic
    [self releaseName:name fromConnection:connection];
    
    NSLog(@"Unregistered name %@ from connection %@", name, connection);
}

- (NSString *)generateUniqueNameForConnection:(MBConnection *)connection
{
    NSString *uniqueName = [NSString stringWithFormat:@":1.%lu", (unsigned long)_nextUniqueId++];
    _connectionNames[@(connection.socket)] = uniqueName;
    return uniqueName;
}

- (BOOL)autoActivateServiceForMessage:(MBMessage *)message fromConnection:(MBConnection *)connection
{
    // Only try auto-activation for method calls to well-known names
    if (message.type != MBMessageTypeMethodCall) {
        return NO;
    }
    
    if (!message.destination || [message.destination hasPrefix:@":"]) {
        // Don't auto-activate for unique names or missing destinations
        return NO;
    }
    
    // Check if the message has the NO_AUTO_START flag
    // (This would be in the message flags, but our implementation doesn't track flags separately)
    // For now, we'll assume auto-start is allowed unless explicitly disabled
    
    // Check if we have a service file for this destination
    if (![_serviceManager hasService:message.destination]) {
        return NO;
    }
    
    // Check if the service is already being activated
    if ([_serviceManager isActivatingService:message.destination]) {
        NSLog(@"Auto-activation: service '%@' is already being activated", message.destination);
        return YES; // Consider this success - activation in progress
    }
    
    NSLog(@"Auto-activating service '%@' for message to %@.%@", 
          message.destination, message.interface, message.member);
    
    // Try to activate the service
    NSError *error = nil;
    NSString *busAddress = [NSString stringWithFormat:@"unix:path=%@", _socketPath];
    
    if ([_serviceManager activateService:message.destination 
                              busAddress:busAddress 
                                 busType:@"session" 
                                   error:&error]) {
        NSLog(@"Auto-activation: successfully started activation for service '%@'", message.destination);
        return YES;
    } else {
        NSLog(@"Auto-activation: failed to activate service '%@': %@", 
              message.destination, error.localizedDescription);
        return NO;
    }
}

@end
