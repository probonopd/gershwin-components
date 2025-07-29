#import "MBClient.h"
#import "MBMessage.h"
#import "MBTransport.h"

@implementation MBClient

- (instancetype)init
{
    self = [super init];
    if (self) {
        _socket = -1;
        _nextSerial = 1;
        _readBuffer = [[NSMutableData alloc] init];
        _pendingCalls = [[NSMutableDictionary alloc] init];
    }
    return self;
}

- (void)dealloc
{
    [self disconnect];
    [super dealloc];
}

- (BOOL)connectToPath:(NSString *)socketPath
{
    if (_socket >= 0) {
        [self disconnect];
    }
    
    _socket = [MBTransport connectToUnixSocket:socketPath];
    if (_socket < 0) {
        NSLog(@"Failed to connect to D-Bus daemon at %@", socketPath);
        return NO;
    }
    
    // Perform D-Bus authentication according to spec (matching real dbus-send)
    // Step 1: Send null byte + AUTH command
    NSMutableData *authData = [NSMutableData data];
    uint8_t nullByte = 0;
    [authData appendBytes:&nullByte length:1];
    NSString *authCommand = @"AUTH EXTERNAL 31303031\r\n";
    [authData appendData:[authCommand dataUsingEncoding:NSUTF8StringEncoding]];
    
    NSLog(@"Sending auth command: %@", authCommand);
    if (![MBTransport sendData:authData onSocket:_socket]) {
        NSLog(@"Failed to send authentication");
        [self disconnect];
        return NO;
    }
    
    // Step 2: Wait for OK response
    NSLog(@"Waiting for OK response...");
    usleep(100000); // 100ms
    NSData *authResponse = [MBTransport receiveDataFromSocket:_socket];
    if (!authResponse || [authResponse length] == 0) {
        NSLog(@"No auth response received");
        [self disconnect];
        return NO;
    }
    
    NSString *responseStr = [[NSString alloc] initWithData:authResponse encoding:NSUTF8StringEncoding];
    NSLog(@"Auth response received (%lu bytes): %@", (unsigned long)[authResponse length], responseStr);
    [responseStr autorelease];
    
    if (![responseStr hasPrefix:@"OK "]) {
        NSLog(@"Authentication failed - expected OK, got: %@", responseStr);
        [self disconnect];
        return NO;
    }
    
    // Step 3: Negotiate Unix FD passing (like real dbus-send)
    NSString *negotiateCommand = @"NEGOTIATE_UNIX_FD\r\n";
    NSData *negotiateData = [negotiateCommand dataUsingEncoding:NSUTF8StringEncoding];
    NSLog(@"Sending NEGOTIATE_UNIX_FD command");
    if (![MBTransport sendData:negotiateData onSocket:_socket]) {
        NSLog(@"Failed to send NEGOTIATE_UNIX_FD");
        [self disconnect];
        return NO;
    }
    
    // Step 4: Wait for AGREE_UNIX_FD response
    usleep(100000); // 100ms
    NSData *fdResponse = [MBTransport receiveDataFromSocket:_socket];
    if (!fdResponse || [fdResponse length] == 0) {
        NSLog(@"No FD negotiation response received");
        [self disconnect];
        return NO;
    }
    
    NSString *fdResponseStr = [[NSString alloc] initWithData:fdResponse encoding:NSUTF8StringEncoding];
    NSLog(@"FD negotiation response: %@", fdResponseStr);
    [fdResponseStr autorelease];
    
    if (![fdResponseStr hasPrefix:@"AGREE_UNIX_FD"]) {
        NSLog(@"Unix FD negotiation failed - expected AGREE_UNIX_FD, got: %@", fdResponseStr);
        [self disconnect];
        return NO;
    }
    
    // Step 5: Send BEGIN
    NSString *beginCommand = @"BEGIN\r\n";
    NSData *beginData = [beginCommand dataUsingEncoding:NSUTF8StringEncoding];
    NSLog(@"Sending BEGIN command");
    if (![MBTransport sendData:beginData onSocket:_socket]) {
        NSLog(@"Failed to send BEGIN");
        [self disconnect];
        return NO;
    }
    
    NSLog(@"Authentication completed successfully");
    
    // Send Hello message to get unique name
    MBMessage *helloMessage = [MBMessage methodCallWithDestination:@"org.freedesktop.DBus"
                                                               path:@"/org/freedesktop/DBus"
                                                          interface:@"org.freedesktop.DBus"
                                                             member:@"Hello"
                                                          arguments:@[]];
    helloMessage.serial = _nextSerial++;
    
    NSLog(@"Sending Hello message: %@", helloMessage);
    
    if (![self sendMessage:helloMessage]) {
        NSLog(@"Failed to send Hello message");
        [self disconnect];
        return NO;
    }
    
    NSLog(@"Hello message sent, waiting for reply...");
    
    // Wait for Hello reply
    NSTimeInterval timeout = 5.0;
    NSTimeInterval startTime = [NSDate timeIntervalSinceReferenceDate];
    
    while ([NSDate timeIntervalSinceReferenceDate] - startTime < timeout) {
        NSArray *messages = [self processMessages];
        for (MBMessage *message in messages) {
            if (message.type == MBMessageTypeMethodReturn && 
                message.replySerial == helloMessage.serial) {
                if ([message.arguments count] > 0) {
                    _uniqueName = [message.arguments[0] copy];
                    NSLog(@"Connected to D-Bus daemon, unique name: %@", _uniqueName);
                    return YES;
                }
            }
        }
        usleep(10000); // 10ms
    }
    
    NSLog(@"Timeout waiting for Hello reply");
    [self disconnect];
    return NO;
}

- (void)disconnect
{
    if (_socket >= 0) {
        [MBTransport closeSocket:_socket];
        _socket = -1;
    }
    _uniqueName = nil;
    [_readBuffer setData:[NSData data]];
    [_pendingCalls removeAllObjects];
}

- (BOOL)connected
{
    return _socket >= 0 && _uniqueName != nil;
}

- (MBMessage *)callMethod:(NSString *)destination
                     path:(NSString *)path
                interface:(NSString *)interface
                   member:(NSString *)member
                arguments:(NSArray *)arguments
                  timeout:(NSTimeInterval)timeout
{
    if (![self connected]) {
        NSLog(@"Not connected to D-Bus daemon");
        return nil;
    }
    
    MBMessage *message = [MBMessage methodCallWithDestination:destination
                                                         path:path
                                                    interface:interface
                                                       member:member
                                                    arguments:arguments];
    message.serial = _nextSerial++;
    
    if (![self sendMessage:message]) {
        NSLog(@"Failed to send method call");
        return nil;
    }
    
    // Wait for reply
    NSTimeInterval startTime = [NSDate timeIntervalSinceReferenceDate];
    
    while ([NSDate timeIntervalSinceReferenceDate] - startTime < timeout) {
        NSArray *messages = [self processMessages];
        for (MBMessage *reply in messages) {
            if ((reply.type == MBMessageTypeMethodReturn || reply.type == MBMessageTypeError) &&
                reply.replySerial == message.serial) {
                return reply;
            }
        }
        usleep(10000); // 10ms
    }
    
    NSLog(@"Timeout waiting for method reply");
    return nil;
}

- (BOOL)callMethodAsync:(NSString *)destination
                   path:(NSString *)path
              interface:(NSString *)interface
                 member:(NSString *)member
              arguments:(NSArray *)arguments
                  reply:(void(^)(MBMessage *reply))replyBlock
{
    if (![self connected]) {
        NSLog(@"Not connected to D-Bus daemon");
        return NO;
    }
    
    MBMessage *message = [MBMessage methodCallWithDestination:destination
                                                         path:path
                                                    interface:interface
                                                       member:member
                                                    arguments:arguments];
    message.serial = _nextSerial++;
    
    if (replyBlock) {
        _pendingCalls[@(message.serial)] = [replyBlock copy];
    }
    
    return [self sendMessage:message];
}

- (BOOL)emitSignal:(NSString *)path
         interface:(NSString *)interface
            member:(NSString *)member
         arguments:(NSArray *)arguments
{
    if (![self connected]) {
        NSLog(@"Not connected to D-Bus daemon");
        return NO;
    }
    
    MBMessage *message = [MBMessage signalWithPath:path
                                         interface:interface
                                            member:member
                                         arguments:arguments];
    message.serial = _nextSerial++;
    
    return [self sendMessage:message];
}

- (BOOL)requestName:(NSString *)name
{
    MBMessage *reply = [self callMethod:@"org.freedesktop.DBus"
                                   path:@"/org/freedesktop/DBus"
                              interface:@"org.freedesktop.DBus"
                                 member:@"RequestName"
                              arguments:@[name, @0]
                                timeout:5.0];
    
    if (reply && reply.type == MBMessageTypeMethodReturn && [reply.arguments count] > 0) {
        NSUInteger result = [reply.arguments[0] unsignedIntegerValue];
        return result == 1; // DBUS_REQUEST_NAME_REPLY_PRIMARY_OWNER
    }
    
    return NO;
}

- (BOOL)releaseName:(NSString *)name
{
    MBMessage *reply = [self callMethod:@"org.freedesktop.DBus"
                                   path:@"/org/freedesktop/DBus"
                              interface:@"org.freedesktop.DBus"
                                 member:@"ReleaseName"
                              arguments:@[name]
                                timeout:5.0];
    
    if (reply && reply.type == MBMessageTypeMethodReturn && [reply.arguments count] > 0) {
        NSUInteger result = [reply.arguments[0] unsignedIntegerValue];
        return result == 1; // DBUS_RELEASE_NAME_REPLY_RELEASED
    }
    
    return NO;
}

- (NSArray *)processMessages
{
    if (_socket < 0) {
        return @[];
    }
    
    // Read new data
    NSData *newData = [MBTransport receiveDataFromSocket:_socket];
    if (!newData) {
        return @[];
    }
    
    if ([newData length] == 0) {
        // Connection closed
        [self disconnect];
        return @[];
    }
    
    [_readBuffer appendData:newData];
    
    // Parse messages
    NSArray *messages = [MBMessage messagesFromData:_readBuffer];
    if ([messages count] > 0) {
        // Remove processed data (simplified)
        [_readBuffer setData:[NSData data]];
        
        // Handle async replies
        for (MBMessage *message in messages) {
            if ((message.type == MBMessageTypeMethodReturn || message.type == MBMessageTypeError)) {
                void(^replyBlock)(MBMessage *) = _pendingCalls[@(message.replySerial)];
                if (replyBlock) {
                    replyBlock(message);
                    [_pendingCalls removeObjectForKey:@(message.replySerial)];
                }
            }
        }
    }
    
    return messages;
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
    
    NSLog(@"Sending message data: %lu bytes", (unsigned long)[data length]);
    // Debug: show first 32 bytes
    if ([data length] > 0) {
        const uint8_t *bytes = [data bytes];
        NSMutableString *hexString = [NSMutableString string];
        for (NSUInteger i = 0; i < MIN([data length], 32); i++) {
            [hexString appendFormat:@"%02x ", bytes[i]];
        }
        NSLog(@"Message bytes: %@", hexString);
    }
    
    return [MBTransport sendData:data onSocket:_socket];
}

- (BOOL)connectToPathWithoutHello:(NSString *)socketPath
{
    if (_socket >= 0) {
        [self disconnect];
    }
    
    _socket = [MBTransport connectToUnixSocket:socketPath];
    if (_socket < 0) {
        NSLog(@"Failed to connect to D-Bus daemon at %@", socketPath);
        return NO;
    }
    
    // Perform D-Bus authentication according to spec (matching real dbus-send)
    // Step 1: Send null byte + AUTH command
    NSMutableData *authData = [NSMutableData data];
    uint8_t nullByte = 0;
    [authData appendBytes:&nullByte length:1];
    NSString *authCommand = @"AUTH EXTERNAL 31303031\r\n";
    [authData appendData:[authCommand dataUsingEncoding:NSUTF8StringEncoding]];
    
    NSLog(@"Sending auth command: %@", authCommand);
    if (![MBTransport sendData:authData onSocket:_socket]) {
        NSLog(@"Failed to send authentication");
        [self disconnect];
        return NO;
    }
    
    // Step 2: Wait for OK response
    NSLog(@"Waiting for OK response...");
    usleep(100000); // 100ms
    NSData *authResponse = [MBTransport receiveDataFromSocket:_socket];
    if (!authResponse || [authResponse length] == 0) {
        NSLog(@"No auth response received");
        [self disconnect];
        return NO;
    }
    
    NSString *responseStr = [[NSString alloc] initWithData:authResponse encoding:NSUTF8StringEncoding];
    NSLog(@"Auth response received (%lu bytes): %@", (unsigned long)[authResponse length], responseStr);
    [responseStr autorelease];
    
    if (![responseStr hasPrefix:@"OK "]) {
        NSLog(@"Authentication failed - expected OK, got: %@", responseStr);
        [self disconnect];
        return NO;
    }
    
    // Step 3: Negotiate Unix FD passing (like real dbus-send)
    NSString *negotiateCommand = @"NEGOTIATE_UNIX_FD\r\n";
    NSData *negotiateData = [negotiateCommand dataUsingEncoding:NSUTF8StringEncoding];
    NSLog(@"Sending NEGOTIATE_UNIX_FD command");
    if (![MBTransport sendData:negotiateData onSocket:_socket]) {
        NSLog(@"Failed to send NEGOTIATE_UNIX_FD");
        [self disconnect];
        return NO;
    }
    
    // Step 4: Wait for AGREE_UNIX_FD response
    usleep(100000); // 100ms
    NSData *fdResponse = [MBTransport receiveDataFromSocket:_socket];
    if (!fdResponse || [fdResponse length] == 0) {
        NSLog(@"No FD negotiation response received");
        [self disconnect];
        return NO;
    }
    
    NSString *fdResponseStr = [[NSString alloc] initWithData:fdResponse encoding:NSUTF8StringEncoding];
    NSLog(@"FD negotiation response: %@", fdResponseStr);
    [fdResponseStr autorelease];
    
    if (![fdResponseStr hasPrefix:@"AGREE_UNIX_FD"]) {
        NSLog(@"Unix FD negotiation failed - expected AGREE_UNIX_FD, got: %@", fdResponseStr);
        [self disconnect];
        return NO;
    }
    
    // Step 5: Send BEGIN
    NSString *beginCommand = @"BEGIN\r\n";
    NSData *beginData = [beginCommand dataUsingEncoding:NSUTF8StringEncoding];
    NSLog(@"Sending BEGIN command");
    if (![MBTransport sendData:beginData onSocket:_socket]) {
        NSLog(@"Failed to send BEGIN");
        [self disconnect];
        return NO;
    }
    
    NSLog(@"Authentication completed successfully - ready for D-Bus messages");
    
    // Set a dummy unique name for testing
    _uniqueName = @":test.connection";
    
    return YES;
}

@end
