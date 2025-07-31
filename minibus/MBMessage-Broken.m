#import "MBMessage.h"
#import <arpa/inet.h>

// D-Bus protocol constants
#define DBUS_HEADER_SIGNATURE "yyyyuua(yv)"
#define DBUS_MAJOR_PROTOCOL_VERSION 1
#define DBUS_LITTLE_ENDIAN 'l'
#define DBUS_BIG_ENDIAN 'B'

// Header field codes
typedef enum {
    DBUS_HEADER_FIELD_INVALID = 0,
    DBUS_HEADER_FIELD_PATH = 1,
    DBUS_HEADER_FIELD_INTERFACE = 2,
    DBUS_HEADER_FIELD_MEMBER = 3,
    DBUS_HEADER_FIELD_ERROR_NAME = 4,
    DBUS_HEADER_FIELD_REPLY_SERIAL = 5,
    DBUS_HEADER_FIELD_DESTINATION = 6,
    DBUS_HEADER_FIELD_SENDER = 7,
    DBUS_HEADER_FIELD_SIGNATURE = 8
} MBHeaderFieldCode;

// D-Bus type signatures
#define DBUS_TYPE_INVALID       '\0'
#define DBUS_TYPE_BYTE          'y'
#define DBUS_TYPE_BOOLEAN       'b'
#define DBUS_TYPE_INT16         'n'
#define DBUS_TYPE_UINT16        'q'
#define DBUS_TYPE_INT32         'i'
#define DBUS_TYPE_UINT32        'u'
#define DBUS_TYPE_INT64         'x'
#define DBUS_TYPE_UINT64        't'
#define DBUS_TYPE_DOUBLE        'd'
#define DBUS_TYPE_STRING        's'
#define DBUS_TYPE_OBJECT_PATH   'o'
#define DBUS_TYPE_SIGNATURE     'g'
#define DBUS_TYPE_ARRAY         'a'
#define DBUS_TYPE_VARIANT       'v'
#define DBUS_TYPE_STRUCT        'r'
#define DBUS_TYPE_DICT_ENTRY    'e'

// Helper functions for alignment - match GLib implementation exactly
static NSUInteger alignTo(NSUInteger pos, NSUInteger alignment) {
    return ((pos + alignment - 1) / alignment) * alignment;
}

// Ensure correct padding is added to data
static void addPadding(NSMutableData *data, NSUInteger alignment) {
    NSUInteger pos = [data length];
    NSUInteger aligned = alignTo(pos, alignment);
    while (pos < aligned) {
        uint8_t zero = 0;
        [data appendBytes:&zero length:1];
        pos++;
    }
}



@implementation MBMessage

+ (instancetype)methodCallWithDestination:(NSString *)destination
                                     path:(NSString *)path
                                interface:(NSString *)interface
                                   member:(NSString *)member
                                arguments:(NSArray *)arguments
{
    MBMessage *message = [[self alloc] init];
    message.type = MBMessageTypeMethodCall;
    message.destination = destination;
    message.path = path;
    message.interface = interface;
    message.member = member;
    message.arguments = arguments ?: @[];
    message.signature = [self signatureForArguments:message.arguments];
    return message;
}

+ (instancetype)methodReturnWithReplySerial:(NSUInteger)replySerial
                                  arguments:(NSArray *)arguments
{
    MBMessage *message = [[self alloc] init];
    message.type = MBMessageTypeMethodReturn;
    message.replySerial = replySerial;
    message.arguments = arguments ?: @[];
    message.signature = [self signatureForArguments:message.arguments];
    return message;
}

+ (instancetype)errorWithName:(NSString *)errorName
                  replySerial:(NSUInteger)replySerial
                      message:(NSString *)message
{
    MBMessage *msg = [[self alloc] init];
    msg.type = MBMessageTypeError;
    msg.errorName = errorName;
    msg.replySerial = replySerial;
    msg.arguments = message ? @[message] : @[];
    msg.signature = [self signatureForArguments:msg.arguments];
    return msg;
}

+ (instancetype)signalWithPath:(NSString *)path
                     interface:(NSString *)interface
                        member:(NSString *)member
                     arguments:(NSArray *)arguments
{
    MBMessage *message = [[self alloc] init];
    message.type = MBMessageTypeSignal;
    message.path = path;
    message.interface = interface;
    message.member = member;
    message.arguments = arguments ?: @[];
    message.signature = [self signatureForArguments:message.arguments];
    return message;
}

+ (NSString *)signatureForArguments:(NSArray *)arguments
{
    if (!arguments || [arguments count] == 0) {
        return @"";
    }
    
    NSMutableString *signature = [NSMutableString string];
    for (id arg in arguments) {
        if ([arg isKindOfClass:[NSString class]]) {
            [signature appendString:@"s"];
        } else if ([arg isKindOfClass:[NSNumber class]]) {
            // For simplicity, treat all numbers as uint32
            [signature appendString:@"u"];
        } else if ([arg isKindOfClass:[NSArray class]]) {
            [signature appendString:@"as"]; // Array of strings for simplicity
        } else {
            [signature appendString:@"v"]; // Variant for unknown types
        }
    }
    return signature;
}

- (NSData *)serialize
{
    NSLog(@"Serializing message type=%d, replySerial=%lu", (int)_type, (unsigned long)_replySerial);
    
    NSMutableData *message = [NSMutableData data];
    
    // Serialize header fields and body
    NSData *headerFieldsData = [self serializeHeaderFields];
    NSData *body = [self serializeBody];
    
    // Fixed header (16 bytes total)
    uint8_t endian = DBUS_LITTLE_ENDIAN;
    uint8_t type = (uint8_t)_type;
    uint8_t flags = 0;
    
    // Set NO_REPLY_EXPECTED flag appropriately
    if (_type == MBMessageTypeMethodReturn || 
        _type == MBMessageTypeError || 
        _type == MBMessageTypeSignal) {
        flags |= 0x1; // NO_REPLY_EXPECTED
    }
    
    uint8_t version = DBUS_MAJOR_PROTOCOL_VERSION;
    uint32_t bodyLength = (uint32_t)[body length];
    uint32_t serial = (uint32_t)(_serial ? _serial : 1);
    
    // Header fields array length (just the data length, not including padding)
    uint32_t fieldsLength = (uint32_t)[headerFieldsData length];
    
    NSLog(@"Header fields data length: %u bytes", fieldsLength);
    
    // Write fixed header
    [message appendBytes:&endian length:1];
    [message appendBytes:&type length:1];
    [message appendBytes:&flags length:1];
    [message appendBytes:&version length:1];
    [message appendBytes:&bodyLength length:4];
    [message appendBytes:&serial length:4];
    [message appendBytes:&fieldsLength length:4];
    
    // Add header fields data
    [message appendData:headerFieldsData];
    
    // Add padding to align body to 8-byte boundary
    addPadding(message, 8);
    
    // Add body
    [message appendData:body];
    
    NSLog(@"Final message length: %lu bytes", (unsigned long)[message length]);
    return message;
}
    
    NSLog(@"Header calculation: base=%lu, data=%lu, fieldsLength=%u, padding=%lu", 
          (unsigned long)baseHeaderLength, (unsigned long)headerFieldsDataLength, 
          fieldsLength, (unsigned long)paddingNeeded);
    
    [message appendBytes:&endian length:1];
    [message appendBytes:&type length:1];
    [message appendBytes:&flags length:1];
    [message appendBytes:&version length:1];
    [message appendBytes:&bodyLength length:4];
    [message appendBytes:&serial length:4];
    [message appendBytes:&fieldsLength length:4];
    
    // Add header fields data
    [message appendData:headerFieldsData];
    
    // Add padding to align body to 8-byte boundary
    addPadding(message, 8);
    
    // Add body
    [message appendData:body];
    
    NSLog(@"Final message length: %lu bytes", (unsigned long)[message length]);
    return message;
}

- (NSData *)serializeHeaderFields
{
    // Based on GLib gdbusmessage.c implementation
    // Header fields are an ARRAY of STRUCT(yv) - each struct must be 8-byte aligned
    
    NSMutableData *arrayData = [NSMutableData data];
    
    // Helper to add a string header field with proper D-Bus alignment
    void (^addStringField)(uint8_t, NSString *) = ^(uint8_t code, NSString *value) {
        if (!value) return;
        
        // STRUCT alignment: always 8-byte boundary (GLib: ensure_input_padding(buf, 8))
        addPadding(arrayData, 8);
        
        // Field code (BYTE)
        [arrayData appendBytes:&code length:1];
        
        // VARIANT: 1-byte signature + padding + content
        uint8_t sigLen = 1;
        [arrayData appendBytes:&sigLen length:1];
        
        // Signature type
        uint8_t typeSig;
        if (code == DBUS_HEADER_FIELD_PATH) {
            typeSig = DBUS_TYPE_OBJECT_PATH;  // 'o'
        } else if (code == DBUS_HEADER_FIELD_SIGNATURE) {
            typeSig = DBUS_TYPE_SIGNATURE;    // 'g'
        } else {
            typeSig = DBUS_TYPE_STRING;       // 's'
        }
        [arrayData appendBytes:&typeSig length:1];
        
        uint8_t nullTerm = 0;
        [arrayData appendBytes:&nullTerm length:1];
        
        // For STRING/OBJECT_PATH: align to 4 bytes for length, then length+data+null
        // For SIGNATURE: no alignment (1-byte aligned), then length+data+null
        if (typeSig == DBUS_TYPE_SIGNATURE) {
            // SIGNATURE: length byte + data + null (no alignment padding)
            NSData *sigData = [value dataUsingEncoding:NSUTF8StringEncoding];
            uint8_t sigStrLen = (uint8_t)[sigData length];
            [arrayData appendBytes:&sigStrLen length:1];
            [arrayData appendData:sigData];
            [arrayData appendBytes:&nullTerm length:1];
        } else {
            // STRING/OBJECT_PATH: 4-byte align + 4-byte length + data + null
            addPadding(arrayData, 4);
            uint32_t strLen = (uint32_t)[value lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
            [arrayData appendBytes:&strLen length:4];
            [arrayData appendData:[value dataUsingEncoding:NSUTF8StringEncoding]];
            [arrayData appendBytes:&nullTerm length:1];
    
    // Helper to add a uint32 header field
    void (^addUInt32Field)(uint8_t, uint32_t) = ^(uint8_t code, uint32_t value) {
        if (value == 0) return;
        
        // STRUCT alignment: always 8-byte boundary  
        addPadding(arrayData, 8);
        
        // Field code (BYTE)
        [arrayData appendBytes:&code length:1];
        
        // VARIANT: 1-byte signature + padding + content
        uint8_t sigLen = 1;
        [arrayData appendBytes:&sigLen length:1];
        uint8_t typeSig = DBUS_TYPE_UINT32; // 'u'
        [arrayData appendBytes:&typeSig length:1];
        uint8_t nullTerm = 0;
        [arrayData appendBytes:&nullTerm length:1];
        
        // UINT32: align to 4 bytes then write value
        addPadding(arrayData, 4);
        [arrayData appendBytes:&value length:4];
    };
    
    // Add header fields in order based on D-Bus spec requirements
    // Required fields vary by message type
    
    // First, determine which field will be the last one
    BOOL hasSignature = (_signature && [_signature length] > 0);
    BOOL hasSender = (_sender != nil);
    BOOL hasReplySerial = (_replySerial > 0);
    BOOL hasErrorName = (_errorName != nil);
    BOOL hasMember = (_member != nil);
    BOOL hasInterface = (_interface != nil);
    BOOL hasDestination = (_destination != nil);
    BOOL hasPath = (_path != nil);
    
    // Determine field order for different message types to match real dbus-daemon
    // For Hello replies: DESTINATION, REPLY_SERIAL, SIGNATURE (no SENDER)
    // For signals: PATH, DESTINATION, INTERFACE, MEMBER, SIGNATURE, SENDER
    // For method calls: PATH, INTERFACE, MEMBER, DESTINATION, SIGNATURE
    
    // Calculate which field is last based on actual fields present and message type
    BOOL pathIsLast = NO;
    BOOL destinationIsLast = NO;
    BOOL interfaceIsLast = NO;
    BOOL memberIsLast = NO;
    BOOL errorNameIsLast = NO;
    BOOL replySerialIsLast = NO;
    BOOL signatureIsLast = NO;
    BOOL senderIsLast = NO;
    
    if (_type == MBMessageTypeMethodReturn) {
        // For Hello replies: DESTINATION, REPLY_SERIAL, SIGNATURE (no SENDER)
        if (hasSignature) signatureIsLast = YES;
        else if (hasReplySerial) replySerialIsLast = YES;
        else if (hasDestination) destinationIsLast = YES;
    } else if (_type == MBMessageTypeSignal) {
        // For signals: PATH, DESTINATION, INTERFACE, MEMBER, SIGNATURE, SENDER
        if (hasSender) senderIsLast = YES;
        else if (hasSignature) signatureIsLast = YES;
        else if (hasMember) memberIsLast = YES;
        else if (hasInterface) interfaceIsLast = YES;
        else if (hasDestination) destinationIsLast = YES;
        else if (hasPath) pathIsLast = YES;
    } else {
        // For other message types, use a reasonable order
        if (hasSignature) signatureIsLast = YES;
        else if (hasSender) senderIsLast = YES;
        else if (hasReplySerial) replySerialIsLast = YES;
        else if (hasErrorName) errorNameIsLast = YES;
        else if (hasMember) memberIsLast = YES;
        else if (hasInterface) interfaceIsLast = YES;
        else if (hasDestination) destinationIsLast = YES;
        else if (hasPath) pathIsLast = YES;
    }
    
    // Add fields in the exact order that real dbus-daemon uses
    // For Hello replies: DESTINATION (field 6), REPLY_SERIAL (field 5), SIGNATURE (field 8)
    // For other messages: follow standard order but exclude SENDER unless it's needed
    
    if (_type == MBMessageTypeMethodReturn && _replySerial > 0 && !_interface && !_member) {
        // This looks like a Hello reply - use exact field order from real dbus-daemon
        if (_destination) addStringField(DBUS_HEADER_FIELD_DESTINATION, _destination, !hasReplySerial && !hasSignature);
        if (_replySerial > 0) addUInt32Field(DBUS_HEADER_FIELD_REPLY_SERIAL, (uint32_t)_replySerial, !hasSignature);
        if (_signature && [_signature length] > 0) addSignatureField(DBUS_HEADER_FIELD_SIGNATURE, _signature, YES);
        // Don't add SENDER for Hello replies - real daemon doesn't include it
    } else {
        // For other message types, use standard field order
        if (_path) addStringField(DBUS_HEADER_FIELD_PATH, _path, pathIsLast);
        if (_destination) addStringField(DBUS_HEADER_FIELD_DESTINATION, _destination, destinationIsLast);
        if (_interface) addStringField(DBUS_HEADER_FIELD_INTERFACE, _interface, interfaceIsLast);
        if (_member) addStringField(DBUS_HEADER_FIELD_MEMBER, _member, memberIsLast);
        if (_errorName) addStringField(DBUS_HEADER_FIELD_ERROR_NAME, _errorName, errorNameIsLast);
        if (_replySerial > 0) addUInt32Field(DBUS_HEADER_FIELD_REPLY_SERIAL, (uint32_t)_replySerial, replySerialIsLast);
        if (_signature && [_signature length] > 0) addSignatureField(DBUS_HEADER_FIELD_SIGNATURE, _signature, signatureIsLast);
        
        // Only add SENDER field if it's actually required for this message type
        // For Hello replies and other simple cases, don't add SENDER
        BOOL shouldAddSender = NO;
        if (_type == MBMessageTypeSignal || 
            (_type == MBMessageTypeMethodCall && _sender && ![_sender isEqualToString:@"org.freedesktop.DBus"])) {
            shouldAddSender = YES;
        }
        
        if (_sender && shouldAddSender) {
            addStringField(DBUS_HEADER_FIELD_SENDER, _sender, senderIsLast);
        }
    }
    
    // Return the raw array data - the length is specified in the fixed header
    return arrayData;
}

- (NSData *)serializeBody
{
    if (!_arguments || [_arguments count] == 0) {
        return [NSData data];
    }
    
    NSMutableData *bodyData = [NSMutableData data];
    
    for (id arg in _arguments) {
        if ([arg isKindOfClass:[NSString class]]) {
            NSString *str = (NSString *)arg;
            uint32_t strLen = (uint32_t)[str lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
            [bodyData appendBytes:&strLen length:4];
            [bodyData appendData:[str dataUsingEncoding:NSUTF8StringEncoding]];
            uint8_t nullTerm = 0;
            [bodyData appendBytes:&nullTerm length:1];
        } else if ([arg isKindOfClass:[NSNumber class]]) {
            uint32_t value = [arg unsignedIntValue];
            [bodyData appendBytes:&value length:4];
        } else if ([arg isKindOfClass:[NSArray class]]) {
            // Serialize array of strings
            NSArray *array = (NSArray *)arg;
            uint32_t arrayLen = 0;
            
            // First pass: calculate total array length
            for (NSString *item in array) {
                if ([item isKindOfClass:[NSString class]]) {
                    uint32_t itemLen = (uint32_t)[item lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
                    arrayLen += 4 + itemLen + 1; // length + string + null terminator
                }
            }
            
            // Write array length
            [bodyData appendBytes:&arrayLen length:4];
            
            // Second pass: write array elements
            for (NSString *item in array) {
                if ([item isKindOfClass:[NSString class]]) {
                    uint32_t itemLen = (uint32_t)[item lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
                    [bodyData appendBytes:&itemLen length:4];
                    [bodyData appendData:[item dataUsingEncoding:NSUTF8StringEncoding]];
                    uint8_t nullTerm = 0;
                    [bodyData appendBytes:&nullTerm length:1];
                }
            }
        }
    }
    
    return bodyData;
}

+ (instancetype)messageFromData:(NSData *)data offset:(NSUInteger *)offset
{
    NSLog(@"messageFromData: starting parse at offset %lu, data length %lu", (unsigned long)*offset, (unsigned long)[data length]);
    
    if (*offset + 16 > [data length]) {
        NSLog(@"messageFromData: not enough data for header (need 16 bytes, have %lu)", (unsigned long)([data length] - *offset));
        return nil; // Not enough data for header - don't advance offset
    }
    
    const uint8_t *bytes = [data bytes];
    NSUInteger pos = *offset;
    NSUInteger originalOffset = *offset;
    
    // Read fixed header
    uint8_t endian = bytes[pos++];
    NSLog(@"messageFromData: endian byte 0x%02x ('%c')", endian, endian);
    
    if (endian != DBUS_LITTLE_ENDIAN && endian != DBUS_BIG_ENDIAN) {
        NSLog(@"messageFromData: invalid endianness: 0x%02x - searching for next valid message", endian);
        
        // Search for the next valid D-Bus message header
        NSUInteger searchOffset = originalOffset + 1;
        NSUInteger maxSearchBytes = MIN(1024, [data length] - searchOffset); // Don't search too far
        
        for (NSUInteger i = 0; i < maxSearchBytes; i++) {
            uint8_t testEndian = bytes[searchOffset + i];
            if (testEndian == DBUS_LITTLE_ENDIAN || testEndian == DBUS_BIG_ENDIAN) {
                // Found potential valid endian, check if it looks like a real message header
                if (searchOffset + i + 16 <= [data length]) {
                    uint8_t type = bytes[searchOffset + i + 1];
                    uint8_t version = bytes[searchOffset + i + 3];
                    if (type >= 1 && type <= 4 && version == DBUS_MAJOR_PROTOCOL_VERSION) {
                        NSLog(@"Found potential valid message at offset %lu", (unsigned long)(searchOffset + i));
                        *offset = searchOffset + i;
                        return nil; // Try parsing from this new offset
                    }
                }
            }
        }
        
        // No valid message found, skip the rest of the data
        NSLog(@"No valid D-Bus message found, skipping to end of data");
        *offset = [data length];
        return nil;
    }
    
    BOOL littleEndian = (endian == DBUS_LITTLE_ENDIAN);
    
    MBMessage *message = [[self alloc] init];
    message.type = (MBMessageType)bytes[pos++];
    uint8_t flags __attribute__((unused)) = bytes[pos++];
    uint8_t version = bytes[pos++];
    
    NSLog(@"messageFromData: type=%d, flags=%d, version=%d", message.type, flags, version);
    
    if (version != DBUS_MAJOR_PROTOCOL_VERSION) {
        NSLog(@"messageFromData: unsupported protocol version: %d - advancing offset by 4", version);
        *offset = originalOffset + 4; // Advance by 4 bytes to skip this header
        return nil;
    }
    
    // Debug: show more raw bytes from position 4
    if (*offset + 32 <= [data length]) {
        NSMutableString *hexStr = [NSMutableString string];
        for (int i = 0; i < 32 && *offset + i < [data length]; i++) {
            [hexStr appendFormat:@"%02x ", bytes[*offset + i]];
        }
        NSLog(@"Raw message bytes from offset %lu: %@", (unsigned long)*offset, hexStr);
    }
    
    // Body length and serial - read individual bytes to check structure
    if (pos + 12 > [data length]) {
        NSLog(@"messageFromData: not enough data for full header");
        return nil; // Not enough data - don't advance offset
    }
    
    // Check if this looks like a valid D-Bus message structure
    // Body length should be small for a Hello message
    uint32_t bodyLengthRaw = *(uint32_t *)(bytes + pos);
    if (bodyLengthRaw > 1000000) { // Sanity check - huge body length suggests parsing error
        NSLog(@"messageFromData: suspicious body length 0x%08x - advancing offset by 16", bodyLengthRaw);
        *offset = originalOffset + 16; // Advance by header size to skip this message
        return nil;
    }
    
    uint32_t bodyLength, serial, headerFieldsLength;
    
    // Read raw bytes first
    bodyLength = *(uint32_t *)(bytes + pos);
    pos += 4;
    serial = *(uint32_t *)(bytes + pos);
    pos += 4;
    headerFieldsLength = *(uint32_t *)(bytes + pos);
    pos += 4;
    
    // Convert endianness if needed
    if (!littleEndian) {
        bodyLength = ntohl(bodyLength);
        serial = ntohl(serial);
        headerFieldsLength = ntohl(headerFieldsLength);
    }
    
    message.serial = serial;
    NSLog(@"messageFromData: bodyLength=%u, serial=%u", bodyLength, serial);
    
    // Validate maximum message size (134,217,728 bytes = 128 MiB)
    NSUInteger totalMessageSize = 16 + headerFieldsLength + bodyLength;
    if (totalMessageSize > 134217728) {
        NSLog(@"messageFromData: message size %lu exceeds maximum allowed (134217728 bytes) - rejecting", (unsigned long)totalMessageSize);
        *offset = originalOffset + 16; // Advance by header size to skip this message
        return nil;
    }
    
    // Additional boundary check: make sure the entire message fits in available data
    if (*offset + totalMessageSize > [data length]) {
        NSLog(@"messageFromData: message claims size %lu but only %lu bytes available from offset %lu", 
              (unsigned long)totalMessageSize, (unsigned long)([data length] - *offset), (unsigned long)*offset);
        return nil; // Don't advance offset - wait for more data
    }
    
    NSLog(@"messageFromData: headerFieldsLength=%u", headerFieldsLength);
    
    // Check if we have enough data for the basic header and header fields
    NSUInteger minNeeded = 16 + headerFieldsLength;
    if (*offset + minNeeded > [data length]) {
        NSLog(@"messageFromData: not enough data for header fields (need %lu, have %lu)", 
              (unsigned long)minNeeded, (unsigned long)([data length] - *offset));
        return nil;
    }
    
    // Parse header fields (simplified but more robust)
    NSUInteger headerFieldsEnd = pos + headerFieldsLength;
    NSUInteger maxFieldIterations = 50; // Prevent infinite loops in header parsing
    NSUInteger fieldIterationCount = 0;
    
    NSLog(@"messageFromData: parsing header fields from %lu to %lu", (unsigned long)pos, (unsigned long)headerFieldsEnd);
    
    while (pos < headerFieldsEnd && pos + 8 <= [data length] && fieldIterationCount < maxFieldIterations) {
        fieldIterationCount++;
        NSUInteger oldPos = pos;
        
        // Each header field is a struct: (BYTE fieldcode, VARIANT value)
        
        uint8_t fieldCode = bytes[pos++];
        NSLog(@"messageFromData: parsing field code %d at pos %lu (field iteration %lu)", fieldCode, (unsigned long)(pos-1), (unsigned long)fieldIterationCount);
        
        if (fieldCode == 0) {
            // Field code 0 means padding, skip padding bytes
            while (pos < headerFieldsEnd && bytes[pos] == 0) pos++;
            if (pos >= headerFieldsEnd) break;
            continue; // Continue to next field
        }
        
        // Variant signature - should be 1 byte length + signature + null + aligned value
        if (pos >= headerFieldsEnd) break;
        uint8_t sigLen = bytes[pos++];
        NSLog(@"messageFromData: signature length %d", sigLen);
        
        if (sigLen == 0 || pos + sigLen >= headerFieldsEnd) {
            NSLog(@"messageFromData: invalid signature length, advancing by 8");
            pos += 8; // Skip some bytes and continue
            continue;
        }
        
        // Read signature
        char signature = bytes[pos];
        NSLog(@"messageFromData: signature '%c' (0x%02x)", signature, signature);
        pos += sigLen + 1; // signature + null terminator
        // DO NOT align here! D-Bus header field variant value follows immediately after signature null terminator
        // Parse value based on signature
        if (signature == 's' || signature == 'o') { // string or object path
            uint32_t strLen = *(uint32_t *)(bytes + pos);
            if (!littleEndian) {
                strLen = ntohl(strLen); // Convert from network (big-endian) to host order
            }
            pos += 4;
            NSLog(@"messageFromData: string length %u", strLen);
            if (strLen > 1024 || pos + strLen + 1 > headerFieldsEnd) {
                NSLog(@"messageFromData: string too long or not enough data");
                break;
            }
            NSString *str = [[NSString alloc] initWithBytes:bytes + pos
                                                     length:strLen
                                                   encoding:NSUTF8StringEncoding];
            pos += strLen + 1; // +1 for null terminator
            NSLog(@"messageFromData: field %d = '%@'", fieldCode, str);
            switch (fieldCode) {
                case DBUS_HEADER_FIELD_DESTINATION:
                    message.destination = str;
                    break;
                case DBUS_HEADER_FIELD_PATH:
                    message.path = str;
                    break;
                case DBUS_HEADER_FIELD_INTERFACE:
                    message.interface = str;
                    break;
                case DBUS_HEADER_FIELD_MEMBER:
                    message.member = str;
                    break;
                case DBUS_HEADER_FIELD_SENDER:
                    message.sender = str;
                    break;
            }
        } else if (signature == 'u') { // uint32
            uint32_t value = *(uint32_t *)(bytes + pos);
            if (!littleEndian) {
                value = ntohl(value);
            }
            pos += 4;
            NSLog(@"messageFromData: field %d = %u", fieldCode, value);
            switch (fieldCode) {
                case DBUS_HEADER_FIELD_REPLY_SERIAL:
                    message.replySerial = value;
                    break;
            }
        } else if (signature == 'g') { // signature
            // Signature format: length byte + signature string + null terminator
            if (pos >= headerFieldsEnd) {
                NSLog(@"messageFromData: not enough data for signature length");
                break;
            }
            uint8_t sigLen = bytes[pos++];
            NSLog(@"messageFromData: signature length %u", sigLen);
            if (sigLen > 255 || pos + sigLen + 1 > headerFieldsEnd) {
                NSLog(@"messageFromData: signature too long or not enough data");
                break;
            }
            NSString *sigStr = [[NSString alloc] initWithBytes:bytes + pos
                                                       length:sigLen
                                                     encoding:NSUTF8StringEncoding];
            pos += sigLen + 1; // +1 for null terminator
            NSLog(@"messageFromData: field %d signature = '%@'", fieldCode, sigStr);
            switch (fieldCode) {
                case DBUS_HEADER_FIELD_SIGNATURE:
                    message.signature = sigStr;
                    break;
            }
        } else {
            // Skip unknown field type
            NSLog(@"messageFromData: skipping unknown signature '%c'", signature);
            pos += 8; // Skip some bytes and continue
        }
        
        // CPU protection: if we're not making progress, break
        if (pos == oldPos) {
            NSLog(@"Header field parsing stuck at position %lu, breaking", (unsigned long)pos);
            break;
        }
        
        // Additional protection: if we've hit the iteration limit
        if (fieldIterationCount >= maxFieldIterations) {
            NSLog(@"Hit maximum field iteration limit (%lu), stopping header field parsing", (unsigned long)maxFieldIterations);
            break;
        }
    }
    // Ensure we're at the end of header fields
    NSUInteger oldPos = pos;
    pos = *offset + 16 + headerFieldsLength; // Skip to end of header fields from original offset
    NSLog(@"messageFromData: position jump from %lu to %lu (offset=%lu, headerFieldsLength=%u)", 
          (unsigned long)oldPos, (unsigned long)pos, (unsigned long)*offset, headerFieldsLength);
    
    // Align to 8-byte boundary for body  
    NSUInteger unalignedPos = pos;
    pos = alignTo(pos, 8);
    NSLog(@"messageFromData: alignment: %lu -> %lu (added %lu padding bytes)", 
          (unsigned long)unalignedPos, (unsigned long)pos, (unsigned long)(pos - unalignedPos));
    
    // Parse body using signature
    if (bodyLength > 0 && message.signature) {
        NSLog(@"messageFromData: body parsing starts at pos=%lu, bodyLength=%u, bodyEnd=%lu", 
              (unsigned long)pos, bodyLength, (unsigned long)(pos + bodyLength));
        
        // Check if we have enough data for the body
        if (pos + bodyLength > [data length]) {
            NSLog(@"messageFromData: not enough data for body (need %u more bytes)", 
                  (unsigned)(pos + bodyLength - [data length]));
            return nil;
        }
        
        NSMutableArray *arguments = [NSMutableArray array];
        NSUInteger bodyEnd = pos + bodyLength;
        const char *sig = [message.signature UTF8String];
        NSUInteger sigIndex = 0;
        NSUInteger sigLen = [message.signature length];
        
        NSLog(@"messageFromData: parsing body with signature '%@'", message.signature);
        
        while (pos < bodyEnd && sigIndex < sigLen) {
            char sigChar = sig[sigIndex];
            NSLog(@"messageFromData: parsing argument %lu with signature char '%c' at pos %lu", (unsigned long)sigIndex, sigChar, (unsigned long)pos);
            
            switch (sigChar) {
                case 's': { // String
                    if (pos + 4 > bodyEnd) {
                        NSLog(@"messageFromData: not enough data for string length");
                        goto done_parsing;
                    }
                    
                    // Debug: show the raw bytes being read for string length
                    NSLog(@"messageFromData: reading string length from pos %lu (bodyEnd=%lu)", 
                          (unsigned long)pos, (unsigned long)bodyEnd);
                    if (pos + 4 <= [data length]) {
                        NSLog(@"messageFromData: raw string length bytes: %02x %02x %02x %02x", 
                              bytes[pos], bytes[pos+1], bytes[pos+2], bytes[pos+3]);
                    }
                    
                    uint32_t strLen = *(uint32_t *)(bytes + pos);
                    uint32_t rawStrLen = strLen; // Keep original for debugging
                    if (!littleEndian) {
                        strLen = ntohl(strLen);
                    }
                    NSLog(@"messageFromData: string length raw=0x%08x converted=%u (littleEndian=%s)", 
                          rawStrLen, strLen, littleEndian ? "yes" : "no");
                    
                    // Additional validation: string length should be reasonable
                    if (strLen > bodyLength || strLen > 1048576) { // Max 1MB string
                        NSLog(@"messageFromData: invalid string length %u (bodyLength=%u) - rejecting message", 
                              strLen, bodyLength);
                        goto done_parsing;
                    }
                    
                    pos += 4;
                    
                    if (pos + strLen + 1 > bodyEnd) {
                        NSLog(@"messageFromData: not enough data for string content (need %u bytes)", strLen + 1);
                        goto done_parsing;
                    }
                    
                    NSString *str = [[NSString alloc] initWithBytes:bytes + pos
                                                             length:strLen
                                                           encoding:NSUTF8StringEncoding];
                    if (str) {
                        [arguments addObject:str];
                        NSLog(@"messageFromData: parsed string argument: '%@'", str);
                    } else {
                        NSLog(@"messageFromData: failed to parse string");
                        [arguments addObject:@""];
                    }
                    pos += strLen + 1; // +1 for null terminator
                    break;
                }
                
                case 'u': { // uint32
                    if (pos + 4 > bodyEnd) {
                        NSLog(@"messageFromData: not enough data for uint32");
                        goto done_parsing;
                    }
                    
                    uint32_t num = *(uint32_t *)(bytes + pos);
                    if (!littleEndian) {
                        num = ntohl(num);
                    }
                    [arguments addObject:@(num)];
                    NSLog(@"messageFromData: parsed uint32 argument: %u", num);
                    pos += 4;
                    break;
                }
                
                case 'i': { // int32
                    if (pos + 4 > bodyEnd) {
                        NSLog(@"messageFromData: not enough data for int32");
                        goto done_parsing;
                    }
                    
                    int32_t num = *(int32_t *)(bytes + pos);
                    if (!littleEndian) {
                        num = ntohl(num);
                    }
                    [arguments addObject:@(num)];
                    NSLog(@"messageFromData: parsed int32 argument: %d", num);
                    pos += 4;
                    break;
                }
                
                case 'a': { // Array - read the element type and parse the array
                    if (sigIndex + 1 >= sigLen) {
                        NSLog(@"messageFromData: array signature incomplete");
                        goto done_parsing;
                    }
                    
                    // Get the element type (next character in signature)
                    char elementType = sig[sigIndex + 1];
                    NSLog(@"messageFromData: parsing array of type '%c'", elementType);
                    
                    // Read array length (number of bytes in array)
                    if (pos + 4 > bodyEnd) {
                        NSLog(@"messageFromData: not enough data for array length");
                        goto done_parsing;
                    }
                    
                    uint32_t arrayLength = *(uint32_t *)(bytes + pos);
                    if (!littleEndian) {
                        arrayLength = ntohl(arrayLength);
                    }
                    pos += 4;
                    
                    NSLog(@"messageFromData: array length %u bytes", arrayLength);
                    
                    if (pos + arrayLength > bodyEnd) {
                        NSLog(@"messageFromData: not enough data for array content");
                        goto done_parsing;
                    }
                    
                    NSMutableArray *arrayElements = [NSMutableArray array];
                    NSUInteger arrayEnd = pos + arrayLength;
                    
                    // Parse elements based on element type
                    if (elementType == 's') { // Array of strings
                        while (pos < arrayEnd) {
                            if (pos + 4 > arrayEnd) break;
                            
                            uint32_t strLen = *(uint32_t *)(bytes + pos);
                            if (!littleEndian) {
                                strLen = ntohl(strLen);
                            }
                            pos += 4;
                            
                            if (pos + strLen + 1 > arrayEnd) {
                                NSLog(@"messageFromData: string in array too long");
                                break;
                            }
                            
                            NSString *str = [[NSString alloc] initWithBytes:bytes + pos
                                                                     length:strLen
                                                                   encoding:NSUTF8StringEncoding];
                            if (str) {
                                [arrayElements addObject:str];
                                NSLog(@"messageFromData: parsed array string element: '%@'", str);
                            }
                            pos += strLen + 1; // +1 for null terminator
                        }
                    } else {
                        NSLog(@"messageFromData: unsupported array element type '%c'", elementType);
                        pos = arrayEnd; // Skip the entire array
                    }
                    
                    [arguments addObject:arrayElements];
                    sigIndex++; // Skip the element type character too
                    break;
                }
                
                default:
                    NSLog(@"messageFromData: unsupported signature char '%c', skipping", sigChar);
                    // Skip unknown types by advancing minimally
                    if (pos + 4 <= bodyEnd) {
                        pos += 4;
                    } else {
                        goto done_parsing;
                    }
                    break;
            }
            
            sigIndex++;
        }
        
        done_parsing:
        message.arguments = arguments;
        pos = bodyEnd; // Ensure we're at the end of the body
    } else if (bodyLength > 0) {
        // Fallback: no signature, try to parse as before
        NSMutableArray *arguments = [NSMutableArray array];
        NSUInteger bodyEnd = pos + bodyLength;
        
        NSLog(@"messageFromData: no signature available, using fallback parsing");
        
        while (pos < bodyEnd) {
            if (pos + 4 > bodyEnd) break;
            
            // Try to read as string first
            uint32_t strLen = *(uint32_t *)(bytes + pos);
            if (!littleEndian) {
                strLen = ntohl(strLen);
            }
            if (strLen < 1024 && pos + 4 + strLen + 1 <= bodyEnd) { // Reasonable string length
                pos += 4;
                NSString *str = [[NSString alloc] initWithBytes:bytes + pos
                                                         length:strLen
                                                       encoding:NSUTF8StringEncoding];
                if (str) {
                    [arguments addObject:str];
                    pos += strLen + 1; // +1 for null terminator
                    continue;
                }
            }
            
            // Try as number
            if (pos + 4 <= bodyEnd) {
                uint32_t num = *(uint32_t *)(bytes + pos);
                if (!littleEndian) {
                    num = ntohl(num);
                }
                [arguments addObject:@(num)];
                pos += 4;
            } else {
                break;
            }
        }
        
        message.arguments = arguments;
        pos = bodyEnd;
    }
    
    NSLog(@"messageFromData: final offset %lu (was %lu)", (unsigned long)pos, (unsigned long)*offset);
    *offset = pos;
    return message;
}

+ (NSArray *)messagesFromData:(NSData *)data
{
    NSMutableArray *messages = [NSMutableArray array];
    NSUInteger offset = 0;
    NSUInteger maxIterations = 10000; // Prevent infinite loops
    NSUInteger iterationCount = 0;
    
    NSLog(@"Parsing messages from %lu bytes of data", (unsigned long)[data length]);
    
    // Debug: show first 32 bytes
    if ([data length] > 0) {
        const uint8_t *bytes = [data bytes];
        NSMutableString *hexString = [NSMutableString string];
        for (NSUInteger i = 0; i < MIN([data length], 32); i++) {
            [hexString appendFormat:@"%02x ", bytes[i]];
        }
        NSLog(@"Message data hex: %@", hexString);
    }
    
    while (offset < [data length] && iterationCount < maxIterations) {
        NSUInteger oldOffset = offset;
        iterationCount++;
        
        NSLog(@"Trying to parse message at offset %lu (iteration %lu)", (unsigned long)offset, (unsigned long)iterationCount);
        MBMessage *message = [self messageFromData:data offset:&offset];
        if (message) {
            NSLog(@"Successfully parsed message: %@", message);
            [messages addObject:message];
        } else {
            NSLog(@"Failed to parse message at offset %lu", (unsigned long)offset);
            // Safety check: if offset hasn't advanced, break to prevent infinite loop
            if (offset == oldOffset) {
                NSLog(@"Offset didn't advance, breaking to prevent infinite loop");
                break;
            }
            
            // Additional safety: if we're making very small progress, skip ahead
            if (offset - oldOffset < 4 && iterationCount > 10) {
                NSLog(@"Making very slow progress, skipping ahead by 16 bytes");
                offset = oldOffset + 16;
            }
        }
        
        // CPU protection: if we've done too many iterations, stop
        if (iterationCount >= maxIterations) {
            NSLog(@"Hit maximum iteration limit (%lu), stopping message parsing to prevent CPU overload", (unsigned long)maxIterations);
            break;
        }
    }
    
    NSLog(@"Parsed %lu messages total in %lu iterations", (unsigned long)[messages count], (unsigned long)iterationCount);
    return messages;
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<MBMessage type=%d dest=%@ path=%@ iface=%@ member=%@ args=%@>",
            (int)_type, _destination, _path, _interface, _member, _arguments];
}

@end
