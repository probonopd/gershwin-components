#import "DBusConnection.h"
#import <dbus/dbus.h>

// Use typedef to avoid naming conflicts
typedef struct DBusConnection DBusConnectionStruct;

static GNUDBusConnection *sharedSessionBus = nil;

@implementation GNUDBusConnection

+ (GNUDBusConnection *)sessionBus
{
    if (!sharedSessionBus) {
        sharedSessionBus = [[GNUDBusConnection alloc] init];
        [sharedSessionBus connect];
    }
    return sharedSessionBus;
}

- (id)init
{
    self = [super init];
    if (self) {
        _connection = NULL;
        _connected = NO;
        _messageHandlers = [[NSMutableDictionary alloc] init];
    }
    return self;
}

- (BOOL)connect
{
    DBusError error;
    dbus_error_init(&error);
    
    _connection = dbus_bus_get(DBUS_BUS_SESSION, &error);
    if (dbus_error_is_set(&error)) {
        NSLog(@"DBusConnection: Failed to connect to session bus: %s", error.message);
        dbus_error_free(&error);
        return NO;
    }
    
    if (!_connection) {
        NSLog(@"DBusConnection: Failed to get session bus connection");
        return NO;
    }
    
    _connected = YES;
    NSLog(@"DBusConnection: Successfully connected to session bus");
    return YES;
}

- (void)disconnect
{
    if (_connection) {
        dbus_connection_unref((DBusConnectionStruct *)_connection);
        _connection = NULL;
    }
    _connected = NO;
}

- (BOOL)isConnected
{
    return _connected;
}

- (BOOL)registerService:(NSString *)serviceName
{
    if (!_connected || !_connection) {
        return NO;
    }
    
    DBusError error;
    dbus_error_init(&error);
    
    int result = dbus_bus_request_name((DBusConnectionStruct *)_connection, 
                                      [serviceName UTF8String],
                                      DBUS_NAME_FLAG_REPLACE_EXISTING | DBUS_NAME_FLAG_ALLOW_REPLACEMENT,
                                      &error);
    
    if (dbus_error_is_set(&error)) {
        NSLog(@"DBusConnection: Failed to register service %@: %s", serviceName, error.message);
        dbus_error_free(&error);
        return NO;
    }
    
    if (result != DBUS_REQUEST_NAME_REPLY_PRIMARY_OWNER && 
        result != DBUS_REQUEST_NAME_REPLY_ALREADY_OWNER) {
        
        const char *resultStr = "unknown";
        switch (result) {
            case DBUS_REQUEST_NAME_REPLY_IN_QUEUE:
                resultStr = "IN_QUEUE (another service owns the name)";
                break;
            case DBUS_REQUEST_NAME_REPLY_EXISTS:
                resultStr = "EXISTS (name already exists and DBUS_NAME_FLAG_DO_NOT_QUEUE was specified)";
                break;
            default:
                resultStr = "unknown error";
                break;
        }
        
        NSLog(@"DBusConnection: Failed to become owner of service %@ (result: %d - %s)", serviceName, result, resultStr);
        NSLog(@"DBusConnection: Another application may already be providing the AppMenu.Registrar service");
        NSLog(@"DBusConnection: This is normal if multiple menu applications are running");
        return NO;
    }
    
    if (result == DBUS_REQUEST_NAME_REPLY_ALREADY_OWNER) {
        NSLog(@"DBusConnection: Already owner of service: %@", serviceName);
    } else {
        NSLog(@"DBusConnection: Successfully registered service: %@", serviceName);
    }
    return YES;
}

- (BOOL)registerObjectPath:(NSString *)objectPath 
                 interface:(NSString *)interfaceName 
                   handler:(id)handler
{
    if (!_connected || !_connection) {
        return NO;
    }
    
    // Store the handler for this object path
    NSString *key = [NSString stringWithFormat:@"%@:%@", objectPath, interfaceName];
    [_messageHandlers setObject:handler forKey:key];
    
    NSLog(@"DBusConnection: Registered handler for %@ on %@", interfaceName, objectPath);
    return YES;
}

- (id)callMethod:(NSString *)method
      onService:(NSString *)serviceName
    objectPath:(NSString *)objectPath
     interface:(NSString *)interfaceName
     arguments:(NSArray *)arguments
{
    if (!_connected || !_connection) {
        return nil;
    }
    
    DBusMessage *message = dbus_message_new_method_call([serviceName UTF8String],
                                                       [objectPath UTF8String],
                                                       [interfaceName UTF8String],
                                                       [method UTF8String]);
    if (!message) {
        NSLog(@"DBusConnection: Failed to create method call message");
        return nil;
    }
    
    // Add arguments if provided
    if (arguments && [arguments count] > 0) {
        DBusMessageIter iter;
        dbus_message_iter_init_append(message, &iter);
        
        for (id argument in arguments) {
            if ([argument isKindOfClass:[NSString class]]) {
                const char *str = [argument UTF8String];
                dbus_message_iter_append_basic(&iter, DBUS_TYPE_STRING, &str);
            } else if ([argument isKindOfClass:[NSNumber class]]) {
                if (strcmp([argument objCType], @encode(BOOL)) == 0) {
                    dbus_bool_t val = [argument boolValue];
                    dbus_message_iter_append_basic(&iter, DBUS_TYPE_BOOLEAN, &val);
                } else if (strcmp([argument objCType], @encode(int)) == 0 ||
                          strcmp([argument objCType], @encode(long)) == 0) {
                    dbus_int32_t val = [argument intValue];
                    dbus_message_iter_append_basic(&iter, DBUS_TYPE_INT32, &val);
                } else if (strcmp([argument objCType], @encode(unsigned int)) == 0 ||
                          strcmp([argument objCType], @encode(unsigned long)) == 0) {
                    dbus_uint32_t val = [argument unsignedIntValue];
                    dbus_message_iter_append_basic(&iter, DBUS_TYPE_UINT32, &val);
                }
            }
        }
    }
    
    // Send message and get reply
    DBusError error;
    dbus_error_init(&error);
    
    DBusMessage *reply = dbus_connection_send_with_reply_and_block((DBusConnectionStruct *)_connection, 
                                                                  message, 1000, &error);
    dbus_message_unref(message);
    
    if (dbus_error_is_set(&error)) {
        NSLog(@"DBusConnection: Method call failed: %s", error.message);
        dbus_error_free(&error);
        return nil;
    }
    
    if (!reply) {
        NSLog(@"DBusConnection: No reply received");
        return nil;
    }
    
    // Parse reply
    id result = nil;
    if (dbus_message_get_type(reply) == DBUS_MESSAGE_TYPE_METHOD_RETURN) {
        DBusMessageIter iter;
        if (dbus_message_iter_init(reply, &iter)) {
            int argType = dbus_message_iter_get_arg_type(&iter);
            if (argType == DBUS_TYPE_STRING) {
                char *str;
                dbus_message_iter_get_basic(&iter, &str);
                result = [NSString stringWithUTF8String:str];
            } else if (argType == DBUS_TYPE_BOOLEAN) {
                dbus_bool_t val;
                dbus_message_iter_get_basic(&iter, &val);
                result = [NSNumber numberWithBool:val];
            } else if (argType == DBUS_TYPE_INT32) {
                dbus_int32_t val;
                dbus_message_iter_get_basic(&iter, &val);
                result = [NSNumber numberWithInt:val];
            } else if (argType == DBUS_TYPE_UINT32) {
                dbus_uint32_t val;
                dbus_message_iter_get_basic(&iter, &val);
                result = [NSNumber numberWithUnsignedInt:val];
            }
        }
    }
    
    dbus_message_unref(reply);
    
    NSLog(@"DBusConnection: Method call %@.%@ completed", interfaceName, method);
    return result;
}

- (void)processMessages
{
    if (!_connected || !_connection) {
        return;
    }
    
    // Process pending messages with timeout
    dbus_connection_read_write_dispatch((DBusConnectionStruct *)_connection, 0);
    
    // Check for incoming messages
    DBusMessage *message;
    while ((message = dbus_connection_pop_message((DBusConnectionStruct *)_connection)) != NULL) {
        [self handleIncomingMessage:message];
        dbus_message_unref(message);
    }
}

- (DBusConnectionStruct *)rawConnection
{
    return (DBusConnectionStruct *)_connection;
}

- (BOOL)sendReply:(void *)reply
{
    if (!_connected || !_connection || !reply) {
        return NO;
    }
    
    dbus_bool_t result = dbus_connection_send((DBusConnectionStruct *)_connection, (DBusMessage *)reply, NULL);
    return result == TRUE;
}

- (void)handleIncomingMessage:(DBusMessage*)message
{
    if (!message) return;
    
    const char *path = dbus_message_get_path(message);
    const char *interface = dbus_message_get_interface(message);
    const char *method = dbus_message_get_member(message);
    
    if (!path || !interface || !method) {
        return;
    }
    
    NSString *pathStr = [NSString stringWithUTF8String:path];
    NSString *interfaceStr = [NSString stringWithUTF8String:interface];
    NSString *methodStr = [NSString stringWithUTF8String:method];
    
    NSLog(@"DBusConnection: Received method call: %@.%@ on %@", interfaceStr, methodStr, pathStr);
    
    // Handle introspection requests
    if ([interfaceStr isEqualToString:@"org.freedesktop.DBus.Introspectable"] && 
        [methodStr isEqualToString:@"Introspect"]) {
        [self handleIntrospectRequest:message];
        return;
    }
    
    // Find and call the appropriate handler
    NSString *key = [NSString stringWithFormat:@"%@:%@", pathStr, interfaceStr];
    id handler = [_messageHandlers objectForKey:key];
    
    if (handler && [handler respondsToSelector:@selector(handleDBusMethodCall:)]) {
        NSDictionary *callInfo = @{
            @"message": [NSValue valueWithPointer:message],
            @"path": pathStr,
            @"interface": interfaceStr,
            @"method": methodStr
        };
        [handler performSelector:@selector(handleDBusMethodCall:) withObject:callInfo];
    } else {
        NSLog(@"DBusConnection: No handler found for %@.%@ on %@", interfaceStr, methodStr, pathStr);
    }
}

- (void)handleIntrospectRequest:(DBusMessage*)message
{
    const char *path = dbus_message_get_path(message);
    NSString *introspectionXML = [self getIntrospectionXMLForPath:[NSString stringWithUTF8String:path]];
    
    DBusMessage *reply = dbus_message_new_method_return(message);
    if (reply) {
        const char *xmlStr = [introspectionXML UTF8String];
        dbus_message_append_args(reply, DBUS_TYPE_STRING, &xmlStr, DBUS_TYPE_INVALID);
        
        dbus_connection_send((DBusConnectionStruct *)_connection, reply, NULL);
        dbus_message_unref(reply);
        
        NSLog(@"DBusConnection: Sent introspection XML for path %s", path);
    }
}

- (NSString *)getIntrospectionXMLForPath:(NSString *)path
{
    if ([path isEqualToString:@"/com/canonical/AppMenu/Registrar"]) {
        return @"<!DOCTYPE node PUBLIC \"-//freedesktop//DTD D-BUS Object Introspection 1.0//EN\"\n"
               @"\"http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd\">\n"
               @"<node>\n"
               @"  <interface name=\"org.freedesktop.DBus.Introspectable\">\n"
               @"    <method name=\"Introspect\">\n"
               @"      <arg name=\"xml_data\" type=\"s\" direction=\"out\"/>\n"
               @"    </method>\n"
               @"  </interface>\n"
               @"  <interface name=\"com.canonical.AppMenu.Registrar\">\n"
               @"    <method name=\"RegisterWindow\">\n"
               @"      <arg name=\"windowId\" type=\"u\" direction=\"in\"/>\n"
               @"      <arg name=\"menuObjectPath\" type=\"o\" direction=\"in\"/>\n"
               @"    </method>\n"
               @"    <method name=\"UnregisterWindow\">\n"
               @"      <arg name=\"windowId\" type=\"u\" direction=\"in\"/>\n"
               @"    </method>\n"
               @"    <method name=\"GetMenuForWindow\">\n"
               @"      <arg name=\"windowId\" type=\"u\" direction=\"in\"/>\n"
               @"      <arg name=\"service\" type=\"s\" direction=\"out\"/>\n"
               @"      <arg name=\"menuObjectPath\" type=\"o\" direction=\"out\"/>\n"
               @"    </method>\n"
               @"    <signal name=\"WindowRegistered\">\n"
               @"      <arg name=\"windowId\" type=\"u\" direction=\"out\"/>\n"
               @"      <arg name=\"service\" type=\"s\" direction=\"out\"/>\n"
               @"      <arg name=\"menuObjectPath\" type=\"o\" direction=\"out\"/>\n"
               @"    </signal>\n"
               @"    <signal name=\"WindowUnregistered\">\n"
               @"      <arg name=\"windowId\" type=\"u\" direction=\"out\"/>\n"
               @"    </signal>\n"
               @"  </interface>\n"
               @"</node>";
    }
    
    return @"<!DOCTYPE node PUBLIC \"-//freedesktop//DTD D-BUS Object Introspection 1.0//EN\"\n"
           @"\"http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd\">\n"
           @"<node>\n"
           @"</node>";
}

- (DBusConnectionStruct *)connection
{
    return (DBusConnectionStruct *)_connection;
}

- (void)dealloc
{
    [self disconnect];
    [_messageHandlers release];
    [super dealloc];
}

@end
