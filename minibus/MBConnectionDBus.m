#import "MBConnectionDBus.h"
#import "MBMessage.h"
#import <dbus/dbus.h>
#import <dbus/dbus-internals.h>

// Forward declarations for private libdbus functions
extern DBusAuth* _dbus_auth_server_new(const DBusString *guid);
extern void _dbus_auth_unref(DBusAuth *auth);
extern void _dbus_string_init(DBusString *str);
extern void _dbus_string_free(DBusString *str);
extern dbus_bool_t _dbus_string_append_len(DBusString *str, const char *buffer, int len);
extern DBusAuthState _dbus_auth_do_work(DBusAuth *auth);
extern dbus_bool_t _dbus_auth_get_bytes_to_send(DBusAuth *auth, const DBusString **str);
extern void _dbus_auth_bytes_sent(DBusAuth *auth, int bytes_sent);
extern void _dbus_auth_get_buffer(DBusAuth *auth, DBusString **buffer);
extern void _dbus_auth_return_buffer(DBusAuth *auth, DBusString *buffer);
extern void _dbus_auth_get_unused_bytes(DBusAuth *auth, const DBusString **str);
extern const char* _dbus_string_get_const_data(const DBusString *str);
extern int _dbus_string_get_length(const DBusString *str);

@implementation MBConnectionDBus

- (id)initWithFileDescriptor:(int)fd {
    self = [super init];
    if (self) {
        _fd = fd;
        _authenticated = NO;
        _authCompleted = NO;
        _pendingData = [[NSMutableData alloc] init];
        
        // Initialize libdbus authentication
        DBusString guid;
        _dbus_string_init(&guid);
        _dbus_string_append_len(&guid, "1234567890abcdef", 16);
        
        _auth = _dbus_auth_server_new(&guid);
        _dbus_string_free(&guid);
        
        if (!_auth) {
            NSLog(@"Failed to create DBusAuth server");
            return nil;
        }
        
        _authIncoming = malloc(sizeof(DBusString));
        _authOutgoing = malloc(sizeof(DBusString));
        _dbus_string_init(_authIncoming);
        _dbus_string_init(_authOutgoing);
        
        NSLog(@"Created MBConnectionDBus with fd=%d", fd);
    }
    return self;
}

- (void)dealloc {
    if (_auth) {
        _dbus_auth_unref(_auth);
    }
    if (_authIncoming) {
        _dbus_string_free(_authIncoming);
        free(_authIncoming);
    }
    if (_authOutgoing) {
        _dbus_string_free(_authOutgoing);
        free(_authOutgoing);
    }
    [_pendingData release];
    [_connectionName release];
    [super dealloc];
}

- (BOOL)processIncomingData:(NSData *)data {
    NSLog(@"Processing %lu bytes of incoming data", (unsigned long)[data length]);
    
    if (!_authCompleted) {
        // Add data to auth buffer
        DBusString *authBuffer;
        _dbus_auth_get_buffer(_auth, &authBuffer);
        _dbus_string_append_len(authBuffer, [data bytes], [data length]);
        _dbus_auth_return_buffer(_auth, authBuffer);
        
        // Process authentication
        DBusAuthState state = _dbus_auth_do_work(_auth);
        NSLog(@"Auth state: %d", state);
        
        if (state == DBUS_AUTH_STATE_AUTHENTICATED) {
            NSLog(@"Authentication completed!");
            _authenticated = YES;
            _authCompleted = YES;
            
            // Get any unused bytes (D-Bus messages after auth)
            const DBusString *unused;
            _dbus_auth_get_unused_bytes(_auth, &unused);
            if (_dbus_string_get_length(unused) > 0) {
                const char *unusedData = _dbus_string_get_const_data(unused);
                int unusedLen = _dbus_string_get_length(unused);
                [_pendingData appendBytes:unusedData length:unusedLen];
                NSLog(@"Found %d unused bytes after auth", unusedLen);
            }
        } else if (state == DBUS_AUTH_STATE_NEED_DISCONNECT) {
            NSLog(@"Authentication failed - disconnecting");
            return NO;
        }
    } else {
        // Authentication complete, this is D-Bus message data
        [_pendingData appendBytes:[data bytes] length:[data length]];
        NSLog(@"Added %lu bytes to pending message data", (unsigned long)[data length]);
    }
    
    return YES;
}

- (NSData *)getOutgoingData {
    if (!_authCompleted) {
        // Get authentication response data
        const DBusString *authResponse;
        if (_dbus_auth_get_bytes_to_send(_auth, &authResponse)) {
            const char *responseData = _dbus_string_get_const_data(authResponse);
            int responseLen = _dbus_string_get_length(authResponse);
            
            if (responseLen > 0) {
                NSData *response = [NSData dataWithBytes:responseData length:responseLen];
                _dbus_auth_bytes_sent(_auth, responseLen);
                NSLog(@"Sending auth response: %lu bytes", (unsigned long)[response length]);
                return response;
            }
        }
    }
    
    return nil;
}

- (void)sendMessage:(MBMessage *)message {
    if (!_authenticated) {
        NSLog(@"Cannot send message - not authenticated");
        return;
    }
    
    NSData *messageData = [message serialize];
    if (messageData) {
        ssize_t written = write(_fd, [messageData bytes], [messageData length]);
        if (written != [messageData length]) {
            NSLog(@"Failed to write complete message: %zd/%lu", written, (unsigned long)[messageData length]);
        } else {
            NSLog(@"Sent message: %lu bytes", (unsigned long)[messageData length]);
        }
    }
}

- (void)close {
    if (_fd >= 0) {
        close(_fd);
        _fd = -1;
    }
}

@synthesize fd = _fd;
@synthesize connectionName = _connectionName;
@synthesize authenticated = _authenticated;

@end
