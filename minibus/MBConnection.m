/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#define _GNU_SOURCE 1

#import "MBConnection.h"
#import "MBDaemon.h"
#import "MBTransport.h"
#import "MBMessage.h"
#import <sys/socket.h>
#import <sys/un.h>
#if defined(__FreeBSD__) || defined(__NetBSD__) || defined(__DragonFly__)
#import <sys/ucred.h>
#endif
#if defined(__OpenBSD__)
#import <unistd.h>
#endif
#include <fcntl.h>

// D-Bus protocol constants
#define DBUS_LITTLE_ENDIAN 'l'
#define DBUS_BIG_ENDIAN 'B'

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
        _serverGuid = [self generateHexGuid];
        _authFailures = 0;
        _maxAuthFailures = 6;

        NSDebugLLog(@"gwcomp", @"Created connection for socket %d", socket);
    }
    return self;
}

- (NSString *)generateHexGuid {
    uint8_t bytes[16];
    NSMutableString *hex = [NSMutableString stringWithCapacity:32];

    int fd = open("/dev/urandom", O_RDONLY);
    if (fd >= 0) {
        read(fd, bytes, 16);
        close(fd);
    } else {
        // Fallback - use arc4random
        for (int i = 0; i < 16; i++) {
            bytes[i] = arc4random_uniform(256);
        }
    }

    for (int i = 0; i < 16; i++) {
        [hex appendFormat:@"%02x", bytes[i]];
    }

    return [NSString stringWithString:hex];
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
#if defined(SO_PEERCRED)
    struct ucred cred;
    socklen_t len = sizeof(cred);
    
    if (getsockopt(socket, SOL_SOCKET, SO_PEERCRED, &cred, &len) == 0) {
        NSDebugLLog(@"gwcomp", @"Socket credentials: pid=%d uid=%d gid=%d, claimed uid=%d", 
              cred.pid, cred.uid, cred.gid, claimedUID);
        return (cred.uid == claimedUID);
    } else {
        NSDebugLLog(@"gwcomp", @"Failed to get socket credentials: %s", strerror(errno));
        // Fallback - allow if we can't verify
        return YES;
    }
#elif defined(LOCAL_PEERCRED)
    struct xucred cred;
    socklen_t len = sizeof(cred);
    
    if (getsockopt(socket, 0, LOCAL_PEERCRED, &cred, &len) == 0 && cred.cr_version == XUCRED_VERSION) {
        NSDebugLLog(@"gwcomp", @"Socket credentials: uid=%d, claimed uid=%d", cred.cr_uid, claimedUID);
        return (cred.cr_uid == claimedUID);
    } else {
        NSDebugLLog(@"gwcomp", @"Failed to get socket credentials: %s", strerror(errno));
        return YES;
    }
#elif defined(HAVE_GETPEEREID)
    uid_t uid;
    gid_t gid;
    
    if (getpeereid(socket, &uid, &gid) == 0) {
        NSDebugLLog(@"gwcomp", @"Socket credentials: uid=%d, claimed uid=%d", uid, claimedUID);
        return (uid == claimedUID);
    } else {
        NSDebugLLog(@"gwcomp", @"Failed to get socket credentials: %s", strerror(errno));
        return YES;
    }
#else
    // No socket credential support, allow authentication
    NSDebugLLog(@"gwcomp", @"No socket credential support, allowing authentication");
    return YES;
#endif
}

- (NSArray *)processIncomingData
{
    NSDebugLLog(@"gwcomp", @"processIncomingData for socket %d", _socket);

    // Read incoming data from socket
    NSData *data = [MBTransport receiveDataFromSocket:_socket];
    if (!data) {
        // Connection closed or error
        NSDebugLLog(@"gwcomp", @"processIncomingData: no data received, closing connection");
        [self close];
        return [NSArray array];
    }

    // Only proceed if we actually received new data
    if ([data length] == 0) {
        // No new data available, don't process anything
        return [NSArray array];
    }

    // Guard against a runaway peer: disconnect instead of buffering forever
    if ([_readBuffer length] + [data length] > 16 * 1024 * 1024) {
        NSDebugLLog(@"gwcomp", @"Connection %d buffer exceeds 16 MiB, disconnecting", _socket);
        [self close];
        return [NSArray array];
    }

    [_readBuffer appendData:data];
    NSDebugLLog(@"gwcomp", @"Received %lu bytes on socket %d, total buffer: %lu", (unsigned long)[data length], _socket, (unsigned long)[_readBuffer length]);

    if (_state == MBConnectionStateWaitingForAuth) {
        [self processAuthentication];
        // After authentication, check if state changed and we have remaining data
        if (_state != MBConnectionStateWaitingForAuth && [_readBuffer length] > 0) {
            return [self parseMessages];
        }
        return [NSArray array]; // No messages during auth
    } else {
        return [self parseMessages];
    }
}

- (BOOL)handleAuthentication
{
    return [self processAuthentication];
}

- (BOOL)processAuthentication {
    NSDebugLLog(@"gwcomp", @"processAuthentication for socket %d", _socket);
    
    // Move new data from read buffer to auth buffer (BUG FIX: do not append _authIncoming to itself!)
    if ([_readBuffer length] > 0) {
        [_authIncoming appendData:_readBuffer];
        NSDebugLLog(@"gwcomp", @"Moved %lu bytes from read buffer to auth buffer, auth buffer now has %lu bytes", 
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
    int maxCommands = 10;
    while (commandCount < maxCommands) {
        BOOL hasCommand = [self processOneAuthCommand];
        if (!hasCommand) {
            NSDebugLLog(@"gwcomp", @"No more auth commands to process, breaking loop");
            break; // No more commands available
        }
        
        commandCount++;
        NSDebugLLog(@"gwcomp", @"Processed auth command %d", commandCount);
        
        // If we're authenticated, break out of the loop
        if (_authState == AUTH_STATE_AUTHENTICATED) {
            NSDebugLLog(@"gwcomp", @"Authentication completed, breaking out of command loop");
            break;
        }
        
        // Safety check: if auth buffer is getting too large, something is wrong
        if ([_authIncoming length] > 10000) {
            NSDebugLLog(@"gwcomp", @"ERROR: Auth buffer too large (%lu bytes), breaking to prevent memory issues", 
                  (unsigned long)[_authIncoming length]);
            break;
        }
    }
    
    NSDebugLLog(@"gwcomp", @"processAuthentication finished, auth state: %d, remaining buffer: %lu bytes", 
          _authState, (unsigned long)[_authIncoming length]);
    return (_authState == AUTH_STATE_AUTHENTICATED);
}

- (BOOL)processOneAuthCommand {
    NSDebugLLog(@"gwcomp", @"processOneAuthCommand called, buffer has %lu bytes", (unsigned long)[_authIncoming length]);
    
    // Find a complete command (ending in \r\n)
    const uint8_t *bytes = [_authIncoming bytes];
    NSUInteger length = [_authIncoming length];
    
    if (length == 0) {
        NSDebugLLog(@"gwcomp", @"Auth buffer is empty, no commands to process");
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
        NSDebugLLog(@"gwcomp", @"No complete command found (no \\r\\n), waiting for more data");
        return NO; // No complete command yet
    }
    
    NSDebugLLog(@"gwcomp", @"Found complete command ending at position %lu", (unsigned long)cmdEnd);
    
    // Extract the command (skip initial null byte if present)
    NSUInteger cmdStart = 0;
    if (length > 0 && bytes[0] == 0) {
        cmdStart = 1;
        NSDebugLLog(@"gwcomp", @"Skipping initial null byte");
    }
    
    if (cmdStart >= cmdEnd) {
        // Empty command, skip it and stop processing (don't continue loop)
        NSDebugLLog(@"gwcomp", @"Empty command found, removing from buffer");
        [_authIncoming replaceBytesInRange:NSMakeRange(0, cmdEnd + 2) withBytes:NULL length:0];
        return NO;
    }
    
    NSDebugLLog(@"gwcomp", @"Extracting command from position %lu to %lu", (unsigned long)cmdStart, (unsigned long)cmdEnd);
    NSData *cmdData = [NSData dataWithBytes:bytes + cmdStart length:cmdEnd - cmdStart];
    NSString *command = [[NSString alloc] initWithData:cmdData encoding:NSUTF8StringEncoding];
    
    NSDebugLLog(@"gwcomp", @"Extracted command: '%@'", command);
    
    // Remove this command from buffer
    NSDebugLLog(@"gwcomp", @"Removing command from buffer (range 0 to %lu)", (unsigned long)(cmdEnd + 2));
    [_authIncoming replaceBytesInRange:NSMakeRange(0, cmdEnd + 2) withBytes:NULL length:0];
    NSDebugLLog(@"gwcomp", @"Buffer after removal has %lu bytes", (unsigned long)[_authIncoming length]);
    
    NSDebugLLog(@"gwcomp", @"Processing auth command: '%@' (state=%d)", command, _authState);
    
    BOOL result = [self handleAuthCommand:command];
    NSDebugLLog(@"gwcomp", @"Auth command processing result: %@", result ? @"SUCCESS" : @"FAILED");
    
    return result;
}

- (BOOL)handleAuthCommand:(NSString *)command {
    NSArray *parts = [command componentsSeparatedByString:@" "];
    if ([parts count] == 0) return YES;
    
    NSString *cmd = parts[0];
    
    if ([cmd isEqualToString:@"AUTH"]) {
        return [self handleAuthCommandParts:parts];
    } else if ([cmd isEqualToString:@"DATA"]) {
        return [self handleDataCommand:parts];
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

    // Check if client sent initial response (hex-encoded UID)
    if ([parts count] >= 3) {
        // Client provided initial response - verify if possible
        NSString *hexUid = parts[2];
        NSDebugLLog(@"gwcomp", @"AUTH EXTERNAL with initial response: %@", hexUid);

        // Try to verify against SO_PEERCED if we have a valid claimed UID
        uid_t claimedUid = [self uidFromHexString:hexUid];
        if (claimedUid != (uid_t)-1 && ![self verifySocketCredentials:_socket withClaimedUID:claimedUid]) {
            NSDebugLLog(@"gwcomp", @"Credential verification failed for uid %d", claimedUid);
            return [self sendRejected];
        }

        // Credentials verified (or couldn't verify but client claimed one)
        return [self sendOK];
    } else {
        // No initial response - per SASL EXTERNAL spec, send DATA "" to request identity
        NSDebugLLog(@"gwcomp", @"AUTH EXTERNAL with no initial response, requesting credentials");
        return [self sendDataEmpty];
    }
}

- (uid_t)uidFromHexString:(NSString *)hex {
    if ([hex length] == 0) {
        return (uid_t)-1;
    }

    unsigned long long value = 0;
    NSScanner *scanner = [NSScanner scannerWithString:hex];
    unsigned int result;
    if ([scanner scanHexInt:&result]) {
        return (uid_t)result;
    }
    return (uid_t)-1;
}

- (BOOL)sendDataEmpty {
    NSString *response = @"DATA \r\n";
    NSData *responseData = [response dataUsingEncoding:NSUTF8StringEncoding];
    BOOL sent = [MBTransport sendData:responseData onSocket:_socket];
    NSDebugLLog(@"gwcomp", @"Sent DATA '' response: %@", sent ? @"SUCCESS" : @"FAILED");

    _authState = AUTH_STATE_WAITING_FOR_DATA;
    return sent;
}

- (BOOL)handleDataCommand:(NSArray *)parts {
    if (_authState != AUTH_STATE_WAITING_FOR_DATA) {
        NSDebugLLog(@"gwcomp", @"handleDataCommand: not expecting DATA, auth state: %d", _authState);
        return [self sendError:@"Not expecting DATA"];
    }

    // DATA response contains hex-encoded UID
    if ([parts count] >= 2) {
        NSString *hexUid = [parts[1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSDebugLLog(@"gwcomp", @"DATA response with uid: %@", hexUid);

        uid_t claimedUid = [self uidFromHexString:hexUid];
        if (claimedUid != (uid_t)-1 && ![self verifySocketCredentials:_socket withClaimedUID:claimedUid]) {
            NSDebugLLog(@"gwcomp", @"Credential verification failed for uid from DATA: %d", claimedUid);
            return [self sendRejected];
        }
    }

    // Accept the authentication
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
    NSDebugLLog(@"gwcomp", @"Sent AGREE_UNIX_FD response: %@", sent ? @"SUCCESS" : @"FAILED");
    return sent;
}

- (BOOL)handleBegin {
    NSDebugLLog(@"gwcomp", @"handleBegin called for socket %d, auth state: %d", _socket, _authState);
    
    if (_authState != AUTH_STATE_WAITING_FOR_BEGIN) {
        NSDebugLLog(@"gwcomp", @"handleBegin: not expecting BEGIN, sending error");
        return [self sendError:@"Not expecting BEGIN"];
    }
    
    NSDebugLLog(@"gwcomp", @"handleBegin: setting auth state to authenticated");
    _authState = AUTH_STATE_AUTHENTICATED;
    _state = MBConnectionStateWaitingForHello;  // Should wait for Hello, not be active yet
    NSDebugLLog(@"gwcomp", @"Authentication completed for connection %d, now waiting for Hello", _socket);
    
    // Move any remaining data from auth buffer to message buffer
    NSDebugLLog(@"gwcomp", @"handleBegin: checking auth buffer, has %lu bytes", (unsigned long)[_authIncoming length]);
    if ([_authIncoming length] > 0) {
        NSDebugLLog(@"gwcomp", @"Moving %lu bytes from auth buffer to read buffer", (unsigned long)[_authIncoming length]);
        
        // Debug: check if remaining data looks like auth data
        const uint8_t *bytes = [_authIncoming bytes];
        if ([_authIncoming length] > 4) {
            NSMutableString *hexString = [NSMutableString string];
            for (NSUInteger i = 0; i < MIN([_authIncoming length], 32); i++) {
                [hexString appendFormat:@"%02x ", bytes[i]];
            }
            NSDebugLLog(@"gwcomp", @"Remaining auth data hex: %@", hexString);
            
            // Check if this looks like a D-Bus message (starts with endian byte)
            if (bytes[0] == 'l' || bytes[0] == 'B') {
                // Additional validation: check if it looks like a complete D-Bus header
                if ([_authIncoming length] >= 16) {
                    uint8_t type = bytes[1];
                    uint8_t version = bytes[3];
                    if (type >= 1 && type <= 4 && version == 1) {
                        NSDebugLLog(@"gwcomp", @"Remaining data appears to be a valid D-Bus message");
                        NSDebugLLog(@"gwcomp", @"handleBegin: appending data to read buffer");
                        [_readBuffer appendData:_authIncoming];
                    } else {
                        NSDebugLLog(@"gwcomp", @"Remaining data looks like D-Bus but has invalid header fields (type=%d, version=%d)", type, version);
                        // Still append it but warn
                        [_readBuffer appendData:_authIncoming];
                    }
                } else {
                    NSDebugLLog(@"gwcomp", @"Remaining data starts with endian byte but is too short for D-Bus header");
                    [_readBuffer appendData:_authIncoming];
                }
            } else {
                NSDebugLLog(@"gwcomp", @"WARNING: Remaining data does not look like a D-Bus message (first byte=0x%02x '%c'), searching for valid data", 
                      bytes[0], (bytes[0] >= 32 && bytes[0] < 127) ? bytes[0] : '?');
                
                // Search for valid D-Bus message start
                NSUInteger validOffset = NSNotFound;
                for (NSUInteger i = 0; i < [_authIncoming length]; i++) {
                    if (bytes[i] == 'l' || bytes[i] == 'B') {
                        // Found potential D-Bus message, validate further
                        if (i + 4 < [_authIncoming length]) {
                            uint8_t type = bytes[i + 1];
                            uint8_t version = bytes[i + 3];
                            if (type >= 1 && type <= 4 && version == 1) {
                                validOffset = i;
                                NSDebugLLog(@"gwcomp", @"Found valid D-Bus message at offset %lu", (unsigned long)i);
                                break;
                            }
                        }
                    }
                }
                
                if (validOffset != NSNotFound) {
                    NSData *validData = [NSData dataWithBytes:bytes + validOffset 
                                                       length:[_authIncoming length] - validOffset];
                    NSDebugLLog(@"gwcomp", @"handleBegin: appending %lu bytes of valid data to read buffer", 
                          (unsigned long)[validData length]);
                    [_readBuffer appendData:validData];
                } else {
                    NSDebugLLog(@"gwcomp", @"handleBegin: no valid D-Bus data found in remaining %lu bytes, discarding", 
                          (unsigned long)[_authIncoming length]);
                    // Don't append invalid data - this prevents the parsing issues
                }
            }
        } else {
            NSDebugLLog(@"gwcomp", @"handleBegin: remaining data is very short (%lu bytes), appending as-is", 
                  (unsigned long)[_authIncoming length]);
            [_readBuffer appendData:_authIncoming];
        }
        
        NSDebugLLog(@"gwcomp", @"handleBegin: clearing auth buffer");
        [_authIncoming setData:[NSData data]];
        NSDebugLLog(@"gwcomp", @"handleBegin: data transfer complete, read buffer now has %lu bytes", 
              (unsigned long)[_readBuffer length]);
    } else {
        NSDebugLLog(@"gwcomp", @"handleBegin: no remaining data to transfer");
    }
    
    NSDebugLLog(@"gwcomp", @"handleBegin: returning YES");
    return YES;
}

- (BOOL)handleCancelOrError:(NSString *)command {
    NSDebugLLog(@"gwcomp", @"Authentication cancelled or error for connection %d: '%@'", _socket, command);
    [self close];
    return NO;
}

- (BOOL)sendOK {
    NSString *response = [NSString stringWithFormat:@"OK %@\r\n", _serverGuid];
    NSData *responseData = [response dataUsingEncoding:NSUTF8StringEncoding];
    
    // Send immediately rather than buffering
    BOOL sent = [MBTransport sendData:responseData onSocket:_socket];
    NSDebugLLog(@"gwcomp", @"Sent OK response immediately: %@ (%lu bytes)", sent ? @"SUCCESS" : @"FAILED", (unsigned long)[responseData length]);
    
    _authState = AUTH_STATE_WAITING_FOR_BEGIN;
    NSDebugLLog(@"gwcomp", @"Prepared OK response, moving to WAITING_FOR_BEGIN state");
    return NO;  // Don't continue processing more commands until BEGIN is received
}

- (BOOL)sendRejected {
    NSString *response = @"REJECTED EXTERNAL\r\n";
    NSData *responseData = [response dataUsingEncoding:NSUTF8StringEncoding];
    
    // Send immediately rather than buffering
    BOOL sent = [MBTransport sendData:responseData onSocket:_socket];
    NSDebugLLog(@"gwcomp", @"Sent REJECTED response immediately: %@ (%lu bytes)", sent ? @"SUCCESS" : @"FAILED", (unsigned long)[responseData length]);
    
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
    NSDebugLLog(@"gwcomp", @"Sent ERROR response immediately: %@ (%lu bytes)", sent ? @"SUCCESS" : @"FAILED", (unsigned long)[responseData length]);
    
    return NO;  // Don't continue processing after error
}

- (NSArray *)parseMessages
{
    // Parse complete D-Bus messages from the buffer, keeping any trailing
    // partial message for the next read.
    if ([_readBuffer length] == 0) {
        return [NSArray array];
    }

    NSMutableData *buffer = _readBuffer;
    NSMutableArray *messages = [NSMutableArray array];

    while ([buffer length] > 0) {
        NSUInteger total = [MBMessage messageLengthFromData:buffer];
        if (total == 0) {
            // Need more bytes for the fixed header
            break;
        }
        if (total == NSNotFound) {
            NSDebugLLog(@"gwcomp", @"Protocol error on socket %d: invalid message header, disconnecting", _socket);
            [_readBuffer setData:[NSData data]];
            [self close];
            break;
        }
        if (total > [buffer length]) {
            // Partial message: wait for the rest
            NSDebugLLog(@"gwcomp", @"Buffer holds %lu of %lu bytes of a message on socket %d",
                  (unsigned long)[buffer length], (unsigned long)total, _socket);
            break;
        }

        NSUInteger consumed = 0;
        NSData *slice = [NSData dataWithBytes:[buffer bytes] length:total];
        NSArray *parsed = [MBMessage messagesFromData:slice consumedBytes:&consumed];
        if ([parsed count] == 0 || consumed == 0) {
            NSDebugLLog(@"gwcomp", @"Protocol error on socket %d: failed to parse complete message, disconnecting", _socket);
            [_readBuffer setData:[NSData data]];
            [self close];
            break;
        }

        [messages addObjectsFromArray:parsed];
        [_readBuffer replaceBytesInRange:NSMakeRange(0, consumed) withBytes:NULL length:0];
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

- (BOOL)sendMessage:(MBMessage *)message
{
    return [self sendMessage:message mirrorToMonitors:YES];
}

- (BOOL)sendMessage:(MBMessage *)message mirrorToMonitors:(BOOL)mirror
{
    if (_state != MBConnectionStateActive && 
        _state != MBConnectionStateWaitingForHello && 
        _state != MBConnectionStateMonitor) {
        NSDebugLLog(@"gwcomp", @"Cannot send message - connection not authenticated (state=%d)", (int)_state);
        return NO;
    }
    
    NSDebugLLog(@"gwcomp", @"Sending message: %@", message);
    NSData *messageData = [message serialize];
    if (messageData) {
        NSDebugLLog(@"gwcomp", @"Serialized message to %lu bytes", (unsigned long)[messageData length]);
        BOOL result = [MBTransport sendData:messageData onSocket:_socket];
        NSDebugLLog(@"gwcomp", @"Send result: %@", result ? @"SUCCESS" : @"FAILED");
        if (result && mirror && _state != MBConnectionStateMonitor) {
            // Let the daemon mirror this message to monitor connections
            // (dbus-monitor). Monitor recipients are excluded to avoid
            // recursion.
            [_daemon monitorOutgoingMessage:message];
        }
        return result;
    }
    NSDebugLLog(@"gwcomp", @"Failed to serialize message");
    return NO;
}

- (BOOL)sendMessages:(NSArray *)messages
{
    if (_state != MBConnectionStateActive && 
        _state != MBConnectionStateWaitingForHello && 
        _state != MBConnectionStateMonitor) {
        NSDebugLLog(@"gwcomp", @"Cannot send messages - connection not authenticated (state=%d)", (int)_state);
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
    NSDebugLLog(@"gwcomp", @"Sending %lu messages atomically:", (unsigned long)[messages count]);
    
    for (MBMessage *message in messages) {
        NSDebugLLog(@"gwcomp", @"  - %@", message);
        NSData *messageData = [message serialize];
        if (messageData) {
            [combinedData appendData:messageData];
            NSDebugLLog(@"gwcomp", @"    Serialized to %lu bytes", (unsigned long)[messageData length]);
        } else {
            NSDebugLLog(@"gwcomp", @"    Failed to serialize message");
            return NO;
        }
    }
    
    NSDebugLLog(@"gwcomp", @"Combined message data: %lu bytes total", (unsigned long)[combinedData length]);
    BOOL result = [MBTransport sendData:combinedData onSocket:_socket];
    NSDebugLLog(@"gwcomp", @"Atomic send result: %@", result ? @"SUCCESS" : @"FAILED");
    return result;
}

@synthesize socket = _socket;
@synthesize state = _state;
@synthesize uniqueName = _uniqueName;
@synthesize daemon = _daemon;

@end
