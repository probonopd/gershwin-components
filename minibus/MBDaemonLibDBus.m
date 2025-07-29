#import "MBDaemonLibDBus.h"
#import <dbus/dbus.h>

static void new_connection_callback(DBusServer *server, DBusConnection *new_connection, void *data);
static DBusHandlerResult message_handler(DBusConnection *connection, DBusMessage *message, void *data);

@implementation MBDaemonLibDBus

- (id)init {
    self = [super init];
    if (self) {
        _connections = [[NSMutableArray alloc] init];
        _running = NO;
    }
    return self;
}

- (void)dealloc {
    [self stop];
    [_connections release];
    [super dealloc];
}

- (BOOL)startWithSocketPath:(NSString *)socketPath {
    DBusError error;
    dbus_error_init(&error);
    
    // Create server with Unix socket
    NSString *serverAddress = [NSString stringWithFormat:@"unix:path=%@", socketPath];
    
    _server = dbus_server_listen([serverAddress UTF8String], &error);
    if (!_server) {
        NSLog(@"Failed to create D-Bus server: %s", error.message);
        dbus_error_free(&error);
        return NO;
    }
    
    NSLog(@"Created D-Bus server at %@", socketPath);
    
    // Set up new connection callback
    dbus_server_set_new_connection_function(_server, new_connection_callback, self, NULL);
    
    _running = YES;
    NSLog(@"MBDaemonLibDBus started successfully");
    
    return YES;
}

- (void)stop {
    if (_server) {
        dbus_server_disconnect(_server);
        dbus_server_unref(_server);
        _server = NULL;
    }
    
    // Close all connections
    for (NSValue *connValue in _connections) {
        DBusConnection *connection = [connValue pointerValue];
        dbus_connection_close(connection);
        dbus_connection_unref(connection);
    }
    [_connections removeAllObjects];
    
    _running = NO;
    NSLog(@"MBDaemonLibDBus stopped");
}

- (void)runMainLoop {
    NSLog(@"Starting main loop");
    
    while (_running) {
        // Process server events
        if (_server) {
            dbus_server_dispatch(_server);
        }
        
        // Process connection events
        for (NSValue *connValue in [_connections copy]) {
            DBusConnection *connection = [connValue pointerValue];
            
            // Check if connection is still open
            if (dbus_connection_get_is_connected(connection)) {
                dbus_connection_read_write_dispatch(connection, 0);
            } else {
                NSLog(@"Connection closed, removing from list");
                dbus_connection_unref(connection);
                [_connections removeObject:connValue];
            }
        }
        
        // Small sleep to prevent busy loop
        usleep(1000); // 1ms
    }
    
    NSLog(@"Main loop finished");
}

- (void)handleNewConnection:(DBusConnection *)connection {
    NSLog(@"New D-Bus connection established");
    
    // Add message handler
    if (!dbus_connection_add_filter(connection, message_handler, self, NULL)) {
        NSLog(@"Failed to add message filter to connection");
        dbus_connection_close(connection);
        return;
    }
    
    // Store connection
    NSValue *connValue = [NSValue valueWithPointer:connection];
    [_connections addObject:connValue];
    
    // Request Hello to get unique name
    dbus_connection_set_exit_on_disconnect(connection, FALSE);
    
    NSLog(@"Connection setup complete, total connections: %lu", (unsigned long)[_connections count]);
}

- (void)handleMessage:(DBusMessage *)message onConnection:(DBusConnection *)connection {
    const char *interface = dbus_message_get_interface(message);
    const char *member = dbus_message_get_member(message);
    const char *path = dbus_message_get_path(message);
    
    NSLog(@"Received message: interface=%s, member=%s, path=%s", 
          interface ? interface : "(null)",
          member ? member : "(null)", 
          path ? path : "(null)");
    
    // Handle org.freedesktop.DBus interface
    if (interface && strcmp(interface, "org.freedesktop.DBus") == 0) {
        if (member && strcmp(member, "Hello") == 0) {
            [self handleHelloMessage:message onConnection:connection];
        } else if (member && strcmp(member, "ListNames") == 0) {
            [self handleListNamesMessage:message onConnection:connection];
        } else {
            NSLog(@"Unhandled D-Bus method: %s", member);
        }
    } else {
        NSLog(@"Message not for org.freedesktop.DBus interface");
    }
}

- (void)handleHelloMessage:(DBusMessage *)message onConnection:(DBusConnection *)connection {
    NSLog(@"Handling Hello message");
    
    // Generate unique name for this connection
    static int connectionCounter = 1;
    NSString *uniqueName = [NSString stringWithFormat:@":1.%d", connectionCounter++];
    
    // Create reply message
    DBusMessage *reply = dbus_message_new_method_return(message);
    if (!reply) {
        NSLog(@"Failed to create Hello reply");
        return;
    }
    
    const char *uniqueNameStr = [uniqueName UTF8String];
    if (!dbus_message_append_args(reply, DBUS_TYPE_STRING, &uniqueNameStr, DBUS_TYPE_INVALID)) {
        NSLog(@"Failed to append unique name to Hello reply");
        dbus_message_unref(reply);
        return;
    }
    
    // Send reply
    if (!dbus_connection_send(connection, reply, NULL)) {
        NSLog(@"Failed to send Hello reply");
    } else {
        NSLog(@"Sent Hello reply with unique name: %@", uniqueName);
    }
    
    dbus_message_unref(reply);
}

- (void)handleListNamesMessage:(DBusMessage *)message onConnection:(DBusConnection *)connection {
    NSLog(@"Handling ListNames message");
    
    // Create reply with basic bus names
    DBusMessage *reply = dbus_message_new_method_return(message);
    if (!reply) {
        NSLog(@"Failed to create ListNames reply");
        return;
    }
    
    // Create array of names
    const char *names[] = {
        "org.freedesktop.DBus",
        ":1.0",  // The bus itself
        NULL
    };
    
    DBusMessageIter iter, array_iter;
    dbus_message_iter_init_append(reply, &iter);
    
    if (!dbus_message_iter_open_container(&iter, DBUS_TYPE_ARRAY, "s", &array_iter)) {
        NSLog(@"Failed to open array container");
        dbus_message_unref(reply);
        return;
    }
    
    for (int i = 0; names[i]; i++) {
        if (!dbus_message_iter_append_basic(&array_iter, DBUS_TYPE_STRING, &names[i])) {
            NSLog(@"Failed to append name to array");
            dbus_message_unref(reply);
            return;
        }
    }
    
    if (!dbus_message_iter_close_container(&iter, &array_iter)) {
        NSLog(@"Failed to close array container");
        dbus_message_unref(reply);
        return;
    }
    
    // Send reply
    if (!dbus_connection_send(connection, reply, NULL)) {
        NSLog(@"Failed to send ListNames reply");
    } else {
        NSLog(@"Sent ListNames reply");
    }
    
    dbus_message_unref(reply);
}

@synthesize running = _running;

@end

// C callback functions
static void new_connection_callback(DBusServer *server, DBusConnection *new_connection, void *data) {
    MBDaemonLibDBus *daemon = (MBDaemonLibDBus *)data;
    
    // Take a reference to the connection
    dbus_connection_ref(new_connection);
    
    [daemon handleNewConnection:new_connection];
}

static DBusHandlerResult message_handler(DBusConnection *connection, DBusMessage *message, void *data) {
    MBDaemonLibDBus *daemon = (MBDaemonLibDBus *)data;
    
    [daemon handleMessage:message onConnection:connection];
    
    return DBUS_HANDLER_RESULT_HANDLED;
}
