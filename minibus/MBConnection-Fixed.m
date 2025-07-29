#import "MBConnection.h"
#import "MBTransport.h"
#import "MBMessage.h"
#import <sys/socket.h>
#import <sys/ucred.h>

typedef enum {
    AUTH_STATE_WAITING_FOR_AUTH = 0,
    AUTH_STATE_WAITING_FOR_DATA,
    AUTH_STATE_WAITING_FOR_BEGIN,
    AUTH_STATE_AUTHENTICATED,
    AUTH_STATE_NEED_DISCONNECT
} AuthState;

@interface MBConnection () {
    int _socket;
    NSMutableData *_readBuffer;
    NSString *_uniqueName;
    ConnectionState _state;
    
    // Authentication state machine from reference implementation
    AuthState _authState;
    NSMutableData *_authIncoming;
    NSMutableData *_authOutgoing;
    NSString *_authIdentity;
    NSString *_serverGuid;
    int _authFailures;
    int _maxAuthFailures;
}

@end

@implementation MBConnection

- (id)initWithSocket:(int)socket
{
    self = [super init];
    if (self) {
        _socket = socket;
        _readBuffer = [[NSMutableData alloc] init];
        _state = CONNECTION_STATE_AUTHENTICATING;
        
        // Initialize auth state machine
        _authState = AUTH_STATE_WAITING_FOR_AUTH;
        _authIncoming = [[NSMutableData alloc] init];
        _authOutgoing = [[NSMutableData alloc] init];
        _authIdentity = @"";
        _serverGuid = @"12345678901234567890123456789012"; // Fixed GUID for simplicity
        _authFailures = 0;
        _maxAuthFailures = 6;
        
        NSLog(@"Created connection for socket %d", socket);
    }
    return self;
}

- (void)dealloc
{
    [self close];
    [_readBuffer release];
    [_authIncoming release];
    [_authOutgoing release];
    [_authIdentity release];
    [_serverGuid release];
    [_uniqueName release];
    [super dealloc];
}

- (BOOL)verifySocketCredentials:(int)socket withClaimedUID:(uid_t)claimedUID {
#ifdef SO_PEERCRED
    struct ucred cred;
    socklen_t len = sizeof(cred);
    
    if (getsockopt(socket, SOL_SOCKET, SO_PEERCRED, &cred, &len) == 0) {
        NSLog(@"Socket credentials: pid=%d uid=%d gid=%d, claimed uid=%d", 
              cred.pid, cred.uid, cred.gid, claimedUID);
        return (cred.uid == claimedUID);
    } else {
        NSLog(@"Failed to get socket credentials: %s", strerror(errno));
        // Fallback - allow if we can't verify
        return YES;
    }
#else
    // No socket credential support, allow authentication
    NSLog(@"No socket credential support, allowing authentication");
    return YES;
#endif
}

- (void)handleData:(NSData *)data
{
    [_readBuffer appendData:data];
    NSLog(@"Received %lu bytes on socket %d", (unsigned long)[data length], _socket);
    
    if (_state == CONNECTION_STATE_AUTHENTICATING) {
        [self processAuthentication];
    } else {
        // Process D-Bus messages
        NSArray *messages = [self parseMessages];
        for (MBMessage *message in messages) {
            NSLog(@"Parsed message: %@", [message description]);
        }
    }
}

- (void)processAuthentication {
    [_authIncoming appendData:_readBuffer];
    [_readBuffer setData:[NSData data]];
    
    // Process one command at a time, like reference implementation
    while ([self processOneAuthCommand]) {
        // Continue processing commands
    }
    
    // Send any pending auth responses
    if ([_authOutgoing length] > 0) {
        BOOL sent = [MBTransport sendData:_authOutgoing onSocket:_socket];
        NSLog(@"Sent auth response: %@ (%lu bytes)", sent ? @"SUCCESS" : @"FAILED", (unsigned long)[_authOutgoing length]);
        [_authOutgoing setData:[NSData data]];
    }
}

- (BOOL)processOneAuthCommand {
    // Find a complete command (ending in \r\n)
    const uint8_t *bytes = [_authIncoming bytes];
    NSUInteger length = [_authIncoming length];
    
    NSUInteger cmdEnd = NSNotFound;
    for (NSUInteger i = 0; i < length - 1; i++) {
        if (bytes[i] == '\r' && bytes[i + 1] == '\n') {
            cmdEnd = i;
            break;
        }
    }
    
    if (cmdEnd == NSNotFound) {
        return NO; // No complete command yet
    }
    
    // Extract the command (skip initial null byte if present)
    NSUInteger cmdStart = 0;
    if (length > 0 && bytes[0] == 0) {
        cmdStart = 1;
    }
    
    if (cmdStart >= cmdEnd) {
        // Empty command, skip it
        [_authIncoming replaceBytesInRange:NSMakeRange(0, cmdEnd + 2) withBytes:NULL length:0];
        return YES;
    }
    
    NSData *cmdData = [NSData dataWithBytes:bytes + cmdStart length:cmdEnd - cmdStart];
    NSString *command = [[NSString alloc] initWithData:cmdData encoding:NSUTF8StringEncoding];
    
    // Remove this command from buffer
    [_authIncoming replaceBytesInRange:NSMakeRange(0, cmdEnd + 2) withBytes:NULL length:0];
    
    NSLog(@"Processing auth command: '%@' (state=%d)", command, _authState);
    
    BOOL result = [self handleAuthCommand:command];
    [command release];
    
    return result;
}

- (BOOL)handleAuthCommand:(NSString *)command {
    NSArray *parts = [command componentsSeparatedByString:@" "];
    if ([parts count] == 0) return YES;
    
    NSString *cmd = parts[0];
    
    if ([cmd isEqualToString:@"AUTH"]) {
        return [self handleAuthCommand:parts];
    } else if ([cmd isEqualToString:@"NEGOTIATE_UNIX_FD"]) {
        return [self handleNegotiateUnixFD];
    } else if ([cmd isEqualToString:@"BEGIN"]) {
        return [self handleBegin];
    } else if ([cmd isEqualToString:@"CANCEL"] || [cmd isEqualToString:@"ERROR"]) {
        return [self handleCancelOrError:command];
    } else {
        return [self sendError:@"Unknown command"];
    }
}

- (BOOL)handleAuthCommand:(NSArray *)parts {
    if (_authState != AUTH_STATE_WAITING_FOR_AUTH) {
        return [self sendError:@"Sent AUTH while not expecting it"];
    }
    
    if ([parts count] < 2) {
        return [self sendRejected];
    }
    
    NSString *mechanism = parts[1];
    if (![mechanism isEqualToString:@"EXTERNAL"]) {
        return [self sendRejected];
    }
    
    // Handle EXTERNAL mechanism like reference implementation
    uid_t claimedUID = getuid(); // Default to current user
    
    if ([parts count] >= 3) {
        NSString *hexUID = parts[2];
        // Decode hex UID
        NSMutableString *decodedUID = [NSMutableString string];
        for (NSUInteger i = 0; i < [hexUID length]; i += 2) {
            if (i + 1 < [hexUID length]) {
                NSString *hexChar = [hexUID substringWithRange:NSMakeRange(i, 2)];
                unsigned int charValue;
                [[NSScanner scannerWithString:hexChar] scanHexInt:&charValue];
                [decodedUID appendFormat:@"%c", (char)charValue];
            }
        }
        claimedUID = [decodedUID intValue];
        NSLog(@"Client claims UID: %d", claimedUID);
    }
    
    // Verify socket credentials
    if ([self verifySocketCredentials:_socket withClaimedUID:claimedUID]) {
        return [self sendOK];
    } else {
        return [self sendRejected];
    }
}

- (BOOL)handleNegotiateUnixFD {
    if (_authState != AUTH_STATE_WAITING_FOR_BEGIN) {
        return [self sendError:@"Need to authenticate first"];
    }
    
    // We don't support Unix FD passing, so send ERROR
    return [self sendError:@"Unix FD passing not supported"];
}

- (BOOL)handleBegin {
    if (_authState != AUTH_STATE_WAITING_FOR_BEGIN) {
        return [self sendError:@"Not expecting BEGIN"];
    }
    
    _authState = AUTH_STATE_AUTHENTICATED;
    _state = CONNECTION_STATE_ACTIVE;
    NSLog(@"Authentication completed for connection %d", _socket);
    
    // Move any remaining data from auth buffer to message buffer
    if ([_authIncoming length] > 0) {
        [_readBuffer appendData:_authIncoming];
        [_authIncoming setData:[NSData data]];
    }
    
    return YES;
}

- (BOOL)handleCancelOrError:(NSString *)command {
    NSLog(@"Authentication cancelled or error for connection %d: '%@'", _socket, command);
    [self close];
    return NO;
}

- (BOOL)sendOK {
    NSString *response = [NSString stringWithFormat:@"OK %@\r\n", _serverGuid];
    NSData *responseData = [response dataUsingEncoding:NSUTF8StringEncoding];
    [_authOutgoing appendData:responseData];
    
    _authState = AUTH_STATE_WAITING_FOR_BEGIN;
    NSLog(@"Prepared OK response, moving to WAITING_FOR_BEGIN state");
    return YES;
}

- (BOOL)sendRejected {
    NSString *response = @"REJECTED EXTERNAL\r\n";
    NSData *responseData = [response dataUsingEncoding:NSUTF8StringEncoding];
    [_authOutgoing appendData:responseData];
    
    _authFailures++;
    if (_authFailures >= _maxAuthFailures) {
        _authState = AUTH_STATE_NEED_DISCONNECT;
        [self close];
        return NO;
    }
    
    _authState = AUTH_STATE_WAITING_FOR_AUTH;
    return YES;
}

- (BOOL)sendError:(NSString *)message {
    NSString *response = [NSString stringWithFormat:@"ERROR \"%@\"\r\n", message];
    NSData *responseData = [response dataUsingEncoding:NSUTF8StringEncoding];
    [_authOutgoing appendData:responseData];
    return YES;
}

- (NSArray *)parseMessages
{
    // Your existing message parsing logic
    if ([_readBuffer length] == 0) {
        return [NSArray array];
    }
    
    NSArray *messages = [MBMessage messagesFromData:_readBuffer];
    if ([messages count] > 0) {
        [_readBuffer setData:[NSData data]];
    }
    
    return messages;
}

- (void)close
{
    if (_socket >= 0) {
        [MBTransport closeSocket:_socket];
        _socket = -1;
    }
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<MBConnection socket=%d state=%d auth_state=%d unique=%@>", 
            _socket, (int)_state, _authState, _uniqueName];
}

@synthesize socket = _socket;
@synthesize uniqueName = _uniqueName;

@end
