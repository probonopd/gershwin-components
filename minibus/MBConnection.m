#import "MBConnection.h"
#import "MBMessage.h"
#import "MBTransport.h"
#import "MBDaemon.h"

@implementation MBConnection

- (instancetype)initWithSocket:(int)socket daemon:(MBDaemon *)daemon
{
    self = [super init];
    if (self) {
        _socket = socket;
        _daemon = daemon;
        _state = MBConnectionStateWaitingForAuth;
        _readBuffer = [[NSMutableData alloc] init];
        
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
    if (!newData) {
        return @[]; // No data or error
    }
    
    if ([newData length] == 0) {
        // Connection closed
        [self close];
        return @[];
    }
    
    [_readBuffer appendData:newData];
    
    // Handle authentication first
    if (_state == MBConnectionStateWaitingForAuth) {
        if ([self handleAuthentication]) {
            _state = MBConnectionStateWaitingForHello;
            NSLog(@"Authentication completed, state changed to WaitingForHello, buffer has %lu bytes", (unsigned long)[_readBuffer length]);
            // After auth, if there's data in buffer, it's message data from the auth process
            // Don't clear it, just continue processing
        }
        // If auth not complete, we still return empty array
        if (_state == MBConnectionStateWaitingForAuth) {
            return @[];
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
    // Remove any null bytes from the buffer (initial handshake) 
    NSMutableData *cleanBuffer = [NSMutableData data];
    const uint8_t *bytes = [_readBuffer bytes];
    for (NSUInteger i = 0; i < [_readBuffer length]; i++) {
        if (bytes[i] != 0) {
            [cleanBuffer appendBytes:&bytes[i] length:1];
        }
    }
    
    // Look for "BEGIN\n" or "BEGIN\r\n" in the raw data to separate auth from message data
    const uint8_t *cleanBytes = [cleanBuffer bytes];
    NSUInteger cleanLength = [cleanBuffer length];
    
    // Search for "BEGIN" followed by newline
    const char *beginPattern = "BEGIN";
    NSUInteger beginPatternLen = strlen(beginPattern);
    
    for (NSUInteger i = 0; i <= cleanLength - beginPatternLen; i++) {
        if (memcmp(cleanBytes + i, beginPattern, beginPatternLen) == 0) {
            // Found "BEGIN", now look for the newline after it
            NSUInteger afterBegin = i + beginPatternLen;
            NSUInteger messageStart = NSNotFound;
            
            // Skip any whitespace and find the newline
            for (NSUInteger j = afterBegin; j < cleanLength; j++) {
                if (cleanBytes[j] == '\n') {
                    messageStart = j + 1;
                    break;
                } else if (cleanBytes[j] == '\r' && j + 1 < cleanLength && cleanBytes[j + 1] == '\n') {
                    messageStart = j + 2;
                    break;
                }
            }            if (messageStart != NSNotFound && messageStart < cleanLength) {
                // Extract the message data after BEGIN\n
                NSData *messageData = [NSData dataWithBytes:cleanBytes + messageStart 
                                                     length:cleanLength - messageStart];
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
                
                // Don't set buffer yet - this might be incomplete. Just clear for now.
                [_readBuffer setData:[NSData data]];
            } else {
                NSLog(@"BEGIN found, no message data to preserve");
                [_readBuffer setData:[NSData data]];
            }
            
            NSLog(@"Authentication completed for connection %d", _socket);
            return YES;
        }
    }
    
    // Convert to string only for text-based auth processing
    NSString *bufferString = [[NSString alloc] initWithData:cleanBuffer encoding:NSUTF8StringEncoding];
    if (!bufferString) {
        bufferString = [[NSString alloc] initWithData:cleanBuffer encoding:NSISOLatin1StringEncoding];
        if (!bufferString) {
            if ([cleanBuffer length] > 0) {
                NSLog(@"Received non-string auth data, length: %lu", (unsigned long)[cleanBuffer length]);
                const uint8_t *cleanBytes = [cleanBuffer bytes];
                NSMutableString *hexString = [NSMutableString string];
                for (NSUInteger i = 0; i < MIN([cleanBuffer length], 32); i++) {
                    [hexString appendFormat:@"%02x ", cleanBytes[i]];
                }
                NSLog(@"Auth data hex: %@", hexString);
                [_readBuffer setData:[NSData data]];
            }
            return NO;
        }
    }
    
    NSLog(@"Auth buffer: '%@'", bufferString);
    
    // Look for complete auth lines ending in \r\n or just \n
    NSArray *lines = [bufferString componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    
    BOOL hasProcessedAuth = NO;
    
    for (NSString *line in lines) {
        line = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        
        if ([line hasPrefix:@"AUTH"]) {
            // Respond with OK and server GUID
            NSString *response = @"OK 12345678901234567890123456789012\r\n";
            NSData *responseData = [response dataUsingEncoding:NSUTF8StringEncoding];
            BOOL sent = [MBTransport sendData:responseData onSocket:_socket];
            NSLog(@"Sent AUTH OK response: %@", sent ? @"SUCCESS" : @"FAILED");
            hasProcessedAuth = YES;
            continue;
        }
        
        if ([line hasPrefix:@"NEGOTIATE_UNIX_FD"]) {
            // For simplicity, reject Unix FD support
            NSString *response = @"ERROR\r\n";
            NSData *responseData = [response dataUsingEncoding:NSUTF8StringEncoding];
            BOOL sent = [MBTransport sendData:responseData onSocket:_socket];
            NSLog(@"Sent NEGOTIATE_UNIX_FD rejection: %@", sent ? @"SUCCESS" : @"FAILED");
            hasProcessedAuth = YES;
            continue;
        }
        
        if ([line hasPrefix:@"CANCEL"] || [line hasPrefix:@"ERROR"]) {
            NSLog(@"Authentication cancelled or error for connection %d", _socket);
            [self close];
            return NO;
        }
    }
    
    // If we processed AUTH but no BEGIN yet, clear buffer but keep waiting
    if (hasProcessedAuth) {
        [_readBuffer setData:[NSData data]];
    }
    
    // If buffer is getting too large without proper auth, reject
    if ([_readBuffer length] > 512) {
        NSLog(@"Authentication buffer too large, rejecting connection %d", _socket);
        [self close];
        return NO;
    }
    
    return NO; // Not complete yet
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
