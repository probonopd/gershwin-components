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

- (instancetype)initWithSocket:(int)socket daemon:(MBDaemon *)daemon
{
    self = [super init];
    if (self) {
        _socket = socket;
        _daemon = daemon;
        _readBuffer = [[NSMutableData alloc] init];
        _state = MBConnectionStateWaitingForAuth;
        
        // Initialize auth state machine
        _authState = AUTH_STATE_WAITING_FOR_AUTH;
        _authIncoming = [[NSMutableData alloc] init];
        _authOutgoing = [[NSMutableData alloc] init];
        _authIdentity = @"";
        _serverGuid = @"12345678901234567890123456789012"; // Fixed GUID for simplicity
        _authFailures = 0;
        _maxAuthFailures = 6;
        
        // Initialize debug counters
        _processIncomingDataCallCount = 0;
        _processAuthenticationCallCount = 0;
        
        NSLog(@"Created connection for socket %d", socket);
    }
    return self;
}

- (void)dealloc
{
    [self close];
    [_authIncoming release];
    [_authOutgoing release];
    [_authIdentity release];
    [_serverGuid release];
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

- (NSArray *)processIncomingData
{
    _processIncomingDataCallCount++;
    NSLog(@"processIncomingData called #%d for socket %d", _processIncomingDataCallCount, _socket);
    
    if (_processIncomingDataCallCount > 100) {
        NSLog(@"ERROR: processIncomingData called too many times, stopping to prevent infinite loop");
        [self close];
        return [NSArray array];
    }
    
    // Read incoming data from socket
    NSData *data = [MBTransport receiveDataFromSocket:_socket];
    if (!data) {
        // Connection closed or error
        NSLog(@"processIncomingData: no data received, closing connection");
        [self close];
        return [NSArray array];
    }
    
    // Only proceed if we actually received new data
    if ([data length] == 0) {
        // No new data available, don't process anything
        NSLog(@"processIncomingData: empty data received");
        return [NSArray array];
    }
    
    [_readBuffer appendData:data];
    NSLog(@"Received %lu bytes on socket %d, total buffer: %lu", (unsigned long)[data length], _socket, (unsigned long)[_readBuffer length]);
    
    if (_state == MBConnectionStateWaitingForAuth) {
        NSLog(@"processIncomingData: processing authentication");
        [self processAuthentication];
        // After authentication, check if state changed and we have remaining data
        if (_state != MBConnectionStateWaitingForAuth && [_readBuffer length] > 0) {
            NSLog(@"Authentication completed, processing %lu bytes of message data", (unsigned long)[_readBuffer length]);
            return [self parseMessages];
        }
        return [NSArray array]; // No messages during auth
    } else {
        // Process D-Bus messages (active or waiting for hello)
        NSLog(@"processIncomingData: processing D-Bus messages");
        return [self parseMessages];
    }
}

- (BOOL)handleAuthentication
{
    return [self processAuthentication];
}

- (BOOL)processAuthentication {
    _processAuthenticationCallCount++;
    NSLog(@"processAuthentication called #%d for socket %d", _processAuthenticationCallCount, _socket);
    
    // Move new data from read buffer to auth buffer (BUG FIX: do not append _authIncoming to itself!)
    if ([_readBuffer length] > 0) {
        [_authIncoming appendData:_readBuffer];
        NSLog(@"Moved %lu bytes from read buffer to auth buffer, auth buffer now has %lu bytes", 
              (unsigned long)[_readBuffer length], (unsigned long)[_authIncoming length]);
        [_readBuffer setData:[NSData data]];
    }
    
    // D-Bus authentication protocol state machine (see dbus-specification.html)
    // 1. Wait for AUTH command
    // 2. Accept any EXTERNAL mechanism (no security checks per user request)
    // 3. Send OK with GUID
    // 4. Wait for BEGIN
    // 5. On BEGIN, transition to authenticated state
    // 6. Move any remaining data to message buffer
    // 7. Ready for D-Bus messages
    
    int commandCount = 0;
    int maxCommands = 10;  // Increased but still safe limit
    while (commandCount < maxCommands) {
        BOOL hasCommand = [self processOneAuthCommand];
        if (!hasCommand) {
            NSLog(@"No more auth commands to process, breaking loop");
            break; // No more commands available
        }
        
        commandCount++;
        NSLog(@"Processed auth command %d", commandCount);
        
        // If we're authenticated, break out of the loop
        if (_authState == AUTH_STATE_AUTHENTICATED) {
            NSLog(@"Authentication completed, breaking out of command loop");
            break;
        }
        
        // Safety check: if auth buffer is getting too large, something is wrong
        if ([_authIncoming length] > 10000) {
            NSLog(@"ERROR: Auth buffer too large (%lu bytes), breaking to prevent memory issues", 
                  (unsigned long)[_authIncoming length]);
            break;
        }
    }
    
    if (commandCount >= maxCommands) {
        NSLog(@"WARNING: Hit maximum auth command limit (%d), stopping processing", maxCommands);
    }
    
    NSLog(@"processAuthentication finished, auth state: %d, remaining buffer: %lu bytes", 
          _authState, (unsigned long)[_authIncoming length]);
    return (_authState == AUTH_STATE_AUTHENTICATED);
}

- (BOOL)processOneAuthCommand {
    NSLog(@"processOneAuthCommand called, buffer has %lu bytes", (unsigned long)[_authIncoming length]);
    
    // Find a complete command (ending in \r\n)
    const uint8_t *bytes = [_authIncoming bytes];
    NSUInteger length = [_authIncoming length];
    
    if (length == 0) {
        NSLog(@"Auth buffer is empty, no commands to process");
        return NO;
    }
    
    NSUInteger cmdEnd = NSNotFound;
    for (NSUInteger i = 0; i < length - 1; i++) {
        if (bytes[i] == '\r' && bytes[i + 1] == '\n') {
            cmdEnd = i;
            break;
        }
    }
    
    if (cmdEnd == NSNotFound) {
        NSLog(@"No complete command found (no \\r\\n), waiting for more data");
        return NO; // No complete command yet
    }
    
    NSLog(@"Found complete command ending at position %lu", (unsigned long)cmdEnd);
    
    // Extract the command (skip initial null byte if present)
    NSUInteger cmdStart = 0;
    if (length > 0 && bytes[0] == 0) {
        cmdStart = 1;
        NSLog(@"Skipping initial null byte");
    }
    
    if (cmdStart >= cmdEnd) {
        // Empty command, skip it and stop processing (don't continue loop)
        NSLog(@"Empty command found, removing from buffer");
        [_authIncoming replaceBytesInRange:NSMakeRange(0, cmdEnd + 2) withBytes:NULL length:0];
        return NO;
    }
    
    NSLog(@"Extracting command from position %lu to %lu", (unsigned long)cmdStart, (unsigned long)cmdEnd);
    NSData *cmdData = [NSData dataWithBytes:bytes + cmdStart length:cmdEnd - cmdStart];
    NSString *command = [[NSString alloc] initWithData:cmdData encoding:NSUTF8StringEncoding];
    
    NSLog(@"Extracted command: '%@'", command);
    
    // Remove this command from buffer
    NSLog(@"Removing command from buffer (range 0 to %lu)", (unsigned long)(cmdEnd + 2));
    [_authIncoming replaceBytesInRange:NSMakeRange(0, cmdEnd + 2) withBytes:NULL length:0];
    NSLog(@"Buffer after removal has %lu bytes", (unsigned long)[_authIncoming length]);
    
    NSLog(@"Processing auth command: '%@' (state=%d)", command, _authState);
    
    BOOL result = [self handleAuthCommand:command];
    NSLog(@"Auth command processing result: %@", result ? @"SUCCESS" : @"FAILED");
    
    return result;
}

- (BOOL)handleAuthCommand:(NSString *)command {
    NSArray *parts = [command componentsSeparatedByString:@" "];
    if ([parts count] == 0) return YES;
    
    NSString *cmd = parts[0];
    
    if ([cmd isEqualToString:@"AUTH"]) {
        return [self handleAuthCommandParts:parts];
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

- (BOOL)handleAuthCommandParts:(NSArray *)parts {
    // Accept any EXTERNAL mechanism, skip all credential checks
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
    // Accept any claimed UID, skip all security checks
    return [self sendOK];
}

- (BOOL)handleNegotiateUnixFD {
    if (_authState != AUTH_STATE_WAITING_FOR_BEGIN) {
        return [self sendError:@"Need to authenticate first"];
    }
    
    // Send AGREE_UNIX_FD to match real dbus-daemon behavior
    // (We don't actually implement FD passing but clients expect this response)
    NSString *response = @"AGREE_UNIX_FD\r\n";
    NSData *responseData = [response dataUsingEncoding:NSUTF8StringEncoding];
    BOOL sent = [MBTransport sendData:responseData onSocket:_socket];
    NSLog(@"Sent AGREE_UNIX_FD response: %@", sent ? @"SUCCESS" : @"FAILED");
    return sent;
}

- (BOOL)handleBegin {
    NSLog(@"handleBegin called for socket %d, auth state: %d", _socket, _authState);
    
    if (_authState != AUTH_STATE_WAITING_FOR_BEGIN) {
        NSLog(@"handleBegin: not expecting BEGIN, sending error");
        return [self sendError:@"Not expecting BEGIN"];
    }
    
    NSLog(@"handleBegin: setting auth state to authenticated");
    _authState = AUTH_STATE_AUTHENTICATED;
    _state = MBConnectionStateWaitingForHello;  // Should wait for Hello, not be active yet
    NSLog(@"Authentication completed for connection %d, now waiting for Hello", _socket);
    
    // Move any remaining data from auth buffer to message buffer
    NSLog(@"handleBegin: checking auth buffer, has %lu bytes", (unsigned long)[_authIncoming length]);
    if ([_authIncoming length] > 0) {
        NSLog(@"Moving %lu bytes from auth buffer to read buffer", (unsigned long)[_authIncoming length]);
        
        // Debug: check if remaining data looks like auth data
        const uint8_t *bytes = [_authIncoming bytes];
        if ([_authIncoming length] > 10) {
            NSMutableString *hexString = [NSMutableString string];
            for (NSUInteger i = 0; i < MIN([_authIncoming length], 32); i++) {
                [hexString appendFormat:@"%02x ", bytes[i]];
            }
            NSLog(@"Remaining auth data hex: %@", hexString);
            
            // Check if this looks like a D-Bus message (starts with endian byte)
            if (bytes[0] == 'l' || bytes[0] == 'B') {
                NSLog(@"Remaining data appears to be a D-Bus message");
            } else {
                NSLog(@"WARNING: Remaining data does not look like a D-Bus message");
            }
        }
        
        NSLog(@"handleBegin: appending data to read buffer");
        [_readBuffer appendData:_authIncoming];
        NSLog(@"handleBegin: clearing auth buffer");
        [_authIncoming setData:[NSData data]];
        NSLog(@"handleBegin: data transfer complete");
    } else {
        NSLog(@"handleBegin: no remaining data to transfer");
    }
    
    NSLog(@"handleBegin: returning YES");
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
    
    // Send immediately rather than buffering
    BOOL sent = [MBTransport sendData:responseData onSocket:_socket];
    NSLog(@"Sent OK response immediately: %@ (%lu bytes)", sent ? @"SUCCESS" : @"FAILED", (unsigned long)[responseData length]);
    
    _authState = AUTH_STATE_WAITING_FOR_BEGIN;
    NSLog(@"Prepared OK response, moving to WAITING_FOR_BEGIN state");
    return NO;  // Don't continue processing more commands until BEGIN is received
}

- (BOOL)sendRejected {
    NSString *response = @"REJECTED EXTERNAL\r\n";
    NSData *responseData = [response dataUsingEncoding:NSUTF8StringEncoding];
    
    // Send immediately rather than buffering
    BOOL sent = [MBTransport sendData:responseData onSocket:_socket];
    NSLog(@"Sent REJECTED response immediately: %@ (%lu bytes)", sent ? @"SUCCESS" : @"FAILED", (unsigned long)[responseData length]);
    
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
    
    // Send immediately rather than buffering
    BOOL sent = [MBTransport sendData:responseData onSocket:_socket];
    NSLog(@"Sent ERROR response immediately: %@ (%lu bytes)", sent ? @"SUCCESS" : @"FAILED", (unsigned long)[responseData length]);
    
    return NO;  // Don't continue processing after error
}

- (NSArray *)parseMessages
{
    // Parse D-Bus messages from buffer
    if ([_readBuffer length] == 0) {
        return [NSArray array];
    }
    
    NSLog(@"parseMessages called with %lu bytes in buffer", (unsigned long)[_readBuffer length]);
    
    // Show first few bytes for debugging
    const uint8_t *bytes = [_readBuffer bytes];
    NSMutableString *hexString = [NSMutableString string];
    for (NSUInteger i = 0; i < MIN([_readBuffer length], 16); i++) {
        [hexString appendFormat:@"%02x ", bytes[i]];
    }
    NSLog(@"Buffer hex: %@", hexString);
    
    @try {
        NSArray *messages = [MBMessage messagesFromData:_readBuffer];
        if ([messages count] > 0) {
            NSLog(@"Parsed %lu D-Bus messages", (unsigned long)[messages count]);
            [_readBuffer setData:[NSData data]];
        } else {
            NSLog(@"No messages parsed, keeping buffer for next attempt");
        }
        return messages;
    }
    @catch (NSException *exception) {
        NSLog(@"Exception in message parsing: %@", exception);
        // Clear buffer to prevent infinite loop
        NSLog(@"Clearing buffer to prevent infinite loop");
        [_readBuffer setData:[NSData data]];
        return [NSArray array];
    }
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

- (BOOL)sendMessage:(MBMessage *)message
{
    if (_state != MBConnectionStateActive && 
        _state != MBConnectionStateWaitingForHello && 
        _state != MBConnectionStateMonitor) {
        NSLog(@"Cannot send message - connection not authenticated (state=%d)", (int)_state);
        return NO;
    }
    
    NSLog(@"Sending message: %@", message);
    NSData *messageData = [message serialize];
    if (messageData) {
        NSLog(@"Serialized message to %lu bytes", (unsigned long)[messageData length]);
        BOOL result = [MBTransport sendData:messageData onSocket:_socket];
        NSLog(@"Send result: %@", result ? @"SUCCESS" : @"FAILED");
        return result;
    }
    NSLog(@"Failed to serialize message");
    return NO;
}

- (BOOL)sendMessages:(NSArray *)messages
{
    if (_state != MBConnectionStateActive && 
        _state != MBConnectionStateWaitingForHello && 
        _state != MBConnectionStateMonitor) {
        NSLog(@"Cannot send messages - connection not authenticated (state=%d)", (int)_state);
        return NO;
    }
    
    if ([messages count] == 0) {
        return YES; // Nothing to send
    }
    
    if ([messages count] == 1) {
        return [self sendMessage:[messages objectAtIndex:0]];
    }
    
    // Serialize all messages and combine into one data block
    NSMutableData *combinedData = [NSMutableData data];
    NSLog(@"Sending %lu messages atomically:", (unsigned long)[messages count]);
    
    for (MBMessage *message in messages) {
        NSLog(@"  - %@", message);
        NSData *messageData = [message serialize];
        if (messageData) {
            [combinedData appendData:messageData];
            NSLog(@"    Serialized to %lu bytes", (unsigned long)[messageData length]);
        } else {
            NSLog(@"    Failed to serialize message");
            return NO;
        }
    }
    
    NSLog(@"Combined message data: %lu bytes total", (unsigned long)[combinedData length]);
    BOOL result = [MBTransport sendData:combinedData onSocket:_socket];
    NSLog(@"Atomic send result: %@", result ? @"SUCCESS" : @"FAILED");
    return result;
}

@synthesize socket = _socket;
@synthesize state = _state;
@synthesize uniqueName = _uniqueName;
@synthesize daemon = _daemon;

@end
