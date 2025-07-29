#import "MBConnection.h"
#import "MBMessage.h"
#import "MBTransport.h"
#import "MBDaemon.h"
#import <sys/socket.h>
#import <sys/ucred.h>

@implementation MBConnection

- (instancetype)initWithSocket:(int)socket daemon:(MBDaemon *)daemon
{
    self = [super init];
    if (self) {
        _socket = socket;
        _daemon = daemon;
        _state = MBConnectionStateWaitingForAuth;
        _readBuffer = [[NSMutableData alloc] init];
        _authProcessed = NO;
        
        // Note: D-Bus spec says client sends null byte first, not server
        NSLog(@"New connection created for socket %d", _socket);
    }
    return self;
}

- (void)dealloc
{
    [self close];
    [super dealloc];
}

- (BOOL)sendMessage:(MBMessage *)message
{
    if (_socket < 0) {
        return NO;
    }
    
    NSData *data = [message serialize];
    if (!data) {
        NSLog(@"Failed to serialize message");
        return NO;
    }
    
    NSLog(@"Sending reply message: %@ (%lu bytes)", message, (unsigned long)[data length]);
    
    // Debug: show first 32 bytes of reply
    if ([data length] > 0) {
        const uint8_t *bytes = [data bytes];
        NSMutableString *hexString = [NSMutableString string];
        for (NSUInteger i = 0; i < MIN([data length], 32); i++) {
            [hexString appendFormat:@"%02x ", bytes[i]];
        }
        NSLog(@"Reply bytes: %@", hexString);
    }
    
    return [MBTransport sendData:data onSocket:_socket];
}

- (NSArray *)processIncomingData
{
    if (_socket < 0) {
        return @[];
    }
    
    // Read new data
    NSData *newData = [MBTransport receiveDataFromSocket:_socket];
    if (newData == nil) {
        // Connection closed or real error - close this connection
        NSLog(@"Connection closed on socket %d", _socket);
        [self close];
        return @[];
    }
    
    if ([newData length] == 0) {
        // No data available right now, but connection is still open
        return @[];
    }
    
    [_readBuffer appendData:newData];
    
    // Handle authentication first
    if (_state == MBConnectionStateWaitingForAuth) {
        if ([self handleAuthentication]) {
            _state = MBConnectionStateWaitingForHello;
            NSLog(@"Authentication completed, state changed to WaitingForHello, buffer has %lu bytes", (unsigned long)[_readBuffer length]);
            // If there's message data in buffer after auth, process it now
            // Don't return early - continue to message processing
        } else {
            return @[]; // Auth not complete yet
        }
    }
    
    // Parse messages from buffer
    if ([_readBuffer length] > 0) {
        NSLog(@"Received %lu bytes for message parsing", (unsigned long)[_readBuffer length]);
        
        // Debug: show raw message bytes
        const uint8_t *bytes = [_readBuffer bytes];
        NSMutableString *hexString = [NSMutableString string];
        for (NSUInteger i = 0; i < MIN([_readBuffer length], 32); i++) {
            [hexString appendFormat:@"%02x ", bytes[i]];
        }
        NSLog(@"Message bytes: %@", hexString);
    }
    
    NSArray *messages = [MBMessage messagesFromData:_readBuffer];
    if ([messages count] > 0) {
        // Remove processed data from buffer (simplified)
        // In a real implementation, we'd track exactly how much data was consumed
        [_readBuffer setData:[NSData data]];
    }
    
    return messages;
}

- (BOOL)handleAuthentication
{
    // First, find "BEGIN" in the raw buffer to separate auth from message data
    const uint8_t *rawBytes = [_readBuffer bytes];
    NSUInteger rawLength = [_readBuffer length];
    
    // Debug: show raw authentication data
    NSMutableString *hexString = [NSMutableString string];
    NSMutableString *printableString = [NSMutableString string];
    for (NSUInteger i = 0; i < MIN(rawLength, 100); i++) {
        [hexString appendFormat:@"%02x ", rawBytes[i]];
        char c = rawBytes[i];
        if (c >= 32 && c <= 126) {
            [printableString appendFormat:@"%c", c];
        } else {
            [printableString appendString:@"."];
        }
    }
    NSLog(@"Raw auth data hex: %@", hexString);
    NSLog(@"Raw auth data printable: %@", printableString);
    
    const char *beginPattern = "BEGIN";
    NSUInteger beginPatternLen = strlen(beginPattern);
    NSUInteger authEnd = NSNotFound;
    NSUInteger messageStart = NSNotFound;
    
    // Find "BEGIN" followed by newline in raw data
    for (NSUInteger i = 0; i <= rawLength - beginPatternLen; i++) {
        if (memcmp(rawBytes + i, beginPattern, beginPatternLen) == 0) {
            // Found BEGIN, check if it's followed by newline
            NSUInteger afterBegin = i + beginPatternLen;
            
            // Skip whitespace after BEGIN
            while (afterBegin < rawLength && (rawBytes[afterBegin] == ' ' || rawBytes[afterBegin] == '\t')) {
                afterBegin++;
            }
            
            // Check for newline
            if (afterBegin < rawLength && rawBytes[afterBegin] == '\r') {
                if (afterBegin + 1 < rawLength && rawBytes[afterBegin + 1] == '\n') {
                    authEnd = i;
                    messageStart = afterBegin + 2; // After \r\n
                } else {
                    authEnd = i;
                    messageStart = afterBegin + 1; // After \r
                }
                break;
            } else if (afterBegin < rawLength && rawBytes[afterBegin] == '\n') {
                authEnd = i;
                messageStart = afterBegin + 1; // After \n
                break;
            }
        }
    }
    
    if (authEnd == NSNotFound) {
        // No complete BEGIN found yet - process auth commands so far
        NSMutableData *authBuffer = [NSMutableData data];
        for (NSUInteger i = 0; i < rawLength; i++) {
            if (rawBytes[i] != 0) {
                [authBuffer appendBytes:&rawBytes[i] length:1];
            }
        }
        
        NSString *authString = [[NSString alloc] initWithData:authBuffer encoding:NSUTF8StringEncoding];
        if (authString) {
            NSArray *lines = [authString componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
            
            for (NSString *line in lines) {
                line = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                
                if ([line hasPrefix:@"AUTH"]) {
                    NSString *response = @"OK 12345678901234567890123456789012\r\n";
                    NSData *responseData = [response dataUsingEncoding:NSUTF8StringEncoding];
                    BOOL sent = [MBTransport sendData:responseData onSocket:_socket];
                    NSLog(@"Sent AUTH OK response: %@", sent ? @"SUCCESS" : @"FAILED");
                    _authProcessed = YES;
                }
                
                if ([line hasPrefix:@"NEGOTIATE_UNIX_FD"]) {
                    // Respond with OK to indicate success but no Unix FD support
                    NSString *response = @"OK\r\n";
                    NSData *responseData = [response dataUsingEncoding:NSUTF8StringEncoding];
                    BOOL sent = [MBTransport sendData:responseData onSocket:_socket];
                    NSLog(@"Sent NEGOTIATE_UNIX_FD response: %@", sent ? @"SUCCESS" : @"FAILED");
                }
                
                if ([line hasPrefix:@"CANCEL"] || [line hasPrefix:@"ERROR"]) {
                    NSLog(@"Authentication cancelled or error for connection %d, line: '%@'", _socket, line);
                    [self close];
                    return NO;
                }
            }
        }
        
        return NO; // Not complete yet
    }
    
    // We found BEGIN - extract auth part (before BEGIN) and clean it (remove null bytes)
    NSMutableData *authBuffer = [NSMutableData data];
    for (NSUInteger i = 0; i < authEnd; i++) {
        if (rawBytes[i] != 0) {
            [authBuffer appendBytes:&rawBytes[i] length:1];
        }
    }
    
    // Convert auth buffer to string for processing
    NSString *authString = [[NSString alloc] initWithData:authBuffer encoding:NSUTF8StringEncoding];
    if (!authString) {
        authString = [[NSString alloc] initWithData:authBuffer encoding:NSISOLatin1StringEncoding];
        if (!authString) {
            NSLog(@"Failed to decode auth data");
            return NO;
        }
    }
    
    NSLog(@"Auth buffer: '%@'", authString);
    NSLog(@"Processing auth lines...");
    
    // Process auth commands
    NSArray *lines = [authString componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    BOOL hasProcessedAuth = NO;
    
    for (NSString *line in lines) {
        line = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSLog(@"Processing auth line: '%@'", line);
        
        if ([line hasPrefix:@"AUTH EXTERNAL"]) {
            // Extract the hex-encoded UID if provided
            NSArray *parts = [line componentsSeparatedByString:@" "];
            uid_t claimedUID = getuid(); // Default to current user
            
            if ([parts count] >= 3) {
                NSString *hexUID = parts[2];
                // Decode hex UID
                NSMutableString *decodedUID = [NSMutableString string];
                for (NSUInteger i = 0; i < [hexUID length]; i += 2) {
                    NSString *hexChar = [hexUID substringWithRange:NSMakeRange(i, 2)];
                    unsigned int charValue;
                    [[NSScanner scannerWithString:hexChar] scanHexInt:&charValue];
                    [decodedUID appendFormat:@"%c", (char)charValue];
                }
                claimedUID = [decodedUID intValue];
                NSLog(@"Client claims UID: %d", claimedUID);
            }
            
            // Verify socket credentials
            if ([self verifySocketCredentials:_socket withClaimedUID:claimedUID]) {
                NSString *response = @"OK 12345678901234567890123456789012\r\n";
                NSData *responseData = [response dataUsingEncoding:NSUTF8StringEncoding];
                BOOL sent = [MBTransport sendData:responseData onSocket:_socket];
                NSLog(@"Sent EXTERNAL AUTH OK response: %@", sent ? @"SUCCESS" : @"FAILED");
                hasProcessedAuth = YES;
                _authProcessed = YES;
            } else {
                NSString *response = @"REJECTED EXTERNAL\r\n";
                NSData *responseData = [response dataUsingEncoding:NSUTF8StringEncoding];
                [MBTransport sendData:responseData onSocket:_socket];
                NSLog(@"Rejected EXTERNAL authentication - UID mismatch");
                [self close];
                return NO;
            }
        }
        else if ([line hasPrefix:@"AUTH"]) {
            NSString *response = @"OK 12345678901234567890123456789012\r\n";
            NSData *responseData = [response dataUsingEncoding:NSUTF8StringEncoding];
            BOOL sent = [MBTransport sendData:responseData onSocket:_socket];
            NSLog(@"Sent AUTH OK response: %@", sent ? @"SUCCESS" : @"FAILED");
            hasProcessedAuth = YES;
            _authProcessed = YES;
        }
        
        if ([line hasPrefix:@"NEGOTIATE_UNIX_FD"]) {
            // Respond with ERROR to indicate no Unix FD support 
            NSString *response = @"ERROR \"Unix FD passing not supported\"\r\n";
            NSData *responseData = [response dataUsingEncoding:NSUTF8StringEncoding];
            BOOL sent = [MBTransport sendData:responseData onSocket:_socket];
            NSLog(@"Sent NEGOTIATE_UNIX_FD response: %@", sent ? @"SUCCESS" : @"FAILED");
        }
        
        if ([line hasPrefix:@"BEGIN"]) {
            NSLog(@"Received BEGIN - authentication completed");
            // No response needed for BEGIN, just complete authentication
        }
        
        if ([line hasPrefix:@"CANCEL"] || [line hasPrefix:@"ERROR"]) {
            NSLog(@"Authentication cancelled or error for connection %d, line: '%@'", _socket, line);
            [self close];
            return NO;
        }
    }
    
    if (!hasProcessedAuth && !_authProcessed) {
        NSLog(@"No AUTH command processed yet");
        return NO;
    }
    
    // Extract message data (after BEGIN\r\n) without modifying it
    if (messageStart < rawLength) {
        NSData *messageData = [NSData dataWithBytes:rawBytes + messageStart 
                                             length:rawLength - messageStart];
        NSLog(@"BEGIN found, preserving %lu bytes of message data", (unsigned long)[messageData length]);
        
        // Debug: show what we're preserving
        if ([messageData length] > 0) {
            const uint8_t *msgBytes = [messageData bytes];
            NSMutableString *hexString = [NSMutableString string];
            for (NSUInteger i = 0; i < MIN([messageData length], 32); i++) {
                [hexString appendFormat:@"%02x ", msgBytes[i]];
            }
            NSLog(@"Preserved message data: %@", hexString);
        }
        
        // Replace buffer with preserved message data
        [_readBuffer setData:messageData];
    } else {
        NSLog(@"BEGIN found, no message data to preserve");
        [_readBuffer setData:[NSData data]];
    }
    
    NSLog(@"Authentication completed for connection %d", _socket);
    return YES;
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

- (void)close
{
    if (_socket >= 0) {
        [MBTransport closeSocket:_socket];
        _socket = -1;
    }
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<MBConnection socket=%d state=%d unique=%@>", 
            _socket, (int)_state, _uniqueName];
}

@end
