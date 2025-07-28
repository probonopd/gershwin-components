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

// Helper functions for alignment
static NSUInteger alignTo(NSUInteger pos, NSUInteger alignment) {
    return (pos + alignment - 1) & ~(alignment - 1);
}

static void appendAligned(NSMutableData *data, const void *bytes, NSUInteger length, NSUInteger alignment) {
    // Pad to alignment
    NSUInteger currentLength = [data length];
    NSUInteger alignedLength = alignTo(currentLength, alignment);
    NSUInteger padding = alignedLength - currentLength;
    
    if (padding > 0) {
        uint8_t zero = 0;
        for (NSUInteger i = 0; i < padding; i++) {
            [data appendBytes:&zero length:1];
        }
    }
    
    [data appendBytes:bytes length:length];
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
    NSMutableData *message = [NSMutableData data];
    
    // Serialize header fields first to get length
    NSData *headerFields = [self serializeHeaderFields];
    NSData *body = [self serializeBody];
    
    // Fixed header (16 bytes)
    uint8_t endian = DBUS_LITTLE_ENDIAN;
    uint8_t type = (uint8_t)_type;
    uint8_t flags = 0;
    uint8_t version = DBUS_MAJOR_PROTOCOL_VERSION;
    uint32_t bodyLength = (uint32_t)[body length];
    uint32_t serial = (uint32_t)(_serial ? _serial : 1);
    uint32_t fieldsLength = (uint32_t)[headerFields length];
    
    [message appendBytes:&endian length:1];
    [message appendBytes:&type length:1];
    [message appendBytes:&flags length:1];
    [message appendBytes:&version length:1];
    [message appendBytes:&bodyLength length:4];
    [message appendBytes:&serial length:4];
    [message appendBytes:&fieldsLength length:4];
    
    // Header fields
    [message appendData:headerFields];
    
    // Align to 8-byte boundary for body
    NSUInteger currentLength = [message length];
    NSUInteger alignedLength = alignTo(currentLength, 8);
    NSUInteger padding = alignedLength - currentLength;
    
    if (padding > 0) {
        uint8_t zero = 0;
        for (NSUInteger i = 0; i < padding; i++) {
            [message appendBytes:&zero length:1];
        }
    }
    
    // Body
    [message appendData:body];
    
    return message;
}

- (NSData *)serializeHeaderFields
{
    NSMutableData *fieldsData = [NSMutableData data];
    
    // Helper to add a string header field
    void (^addStringField)(uint8_t, NSString *) = ^(uint8_t code, NSString *value) {
        if (!value) return;
        
        [fieldsData appendBytes:&code length:1];
        uint8_t variant = 1; // Signature for string = "s"
        [fieldsData appendBytes:&variant length:1];
        uint8_t strSig = 's';
        [fieldsData appendBytes:&strSig length:1];
        uint8_t nullTerm = 0;
        [fieldsData appendBytes:&nullTerm length:1];
        
        // Align to 4-byte boundary for string length
        while ([fieldsData length] % 4 != 0) {
            uint8_t padding = 0;
            [fieldsData appendBytes:&padding length:1];
        }
        
        uint32_t strLen = (uint32_t)[value lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        [fieldsData appendBytes:&strLen length:4];
        [fieldsData appendData:[value dataUsingEncoding:NSUTF8StringEncoding]];
        [fieldsData appendBytes:&nullTerm length:1];
    };
    
    // Helper to add a uint32 header field
    void (^addUInt32Field)(uint8_t, uint32_t) = ^(uint8_t code, uint32_t value) {
        if (value == 0) return;
        
        [fieldsData appendBytes:&code length:1];
        uint8_t variant = 1; // Signature for uint32 = "u"
        [fieldsData appendBytes:&variant length:1];
        uint8_t uintSig = 'u';
        [fieldsData appendBytes:&uintSig length:1];
        uint8_t nullTerm = 0;
        [fieldsData appendBytes:&nullTerm length:1];
        
        // Align to 4-byte boundary for uint32
        while ([fieldsData length] % 4 != 0) {
            uint8_t padding = 0;
            [fieldsData appendBytes:&padding length:1];
        }
        
        [fieldsData appendBytes:&value length:4];
    };
    
    // Add header fields
    addStringField(DBUS_HEADER_FIELD_PATH, _path);
    addStringField(DBUS_HEADER_FIELD_INTERFACE, _interface);
    addStringField(DBUS_HEADER_FIELD_MEMBER, _member);
    addStringField(DBUS_HEADER_FIELD_ERROR_NAME, _errorName);
    addStringField(DBUS_HEADER_FIELD_DESTINATION, _destination);
    addStringField(DBUS_HEADER_FIELD_SENDER, _sender);
    addStringField(DBUS_HEADER_FIELD_SIGNATURE, _signature);
    addUInt32Field(DBUS_HEADER_FIELD_REPLY_SERIAL, (uint32_t)_replySerial);
    
    // Wrap in array structure
    NSMutableData *arrayData = [NSMutableData data];
    uint32_t arrayLength = (uint32_t)[fieldsData length];
    [arrayData appendBytes:&arrayLength length:4];
    [arrayData appendData:fieldsData];
    
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
        }
    }
    
    return bodyData;
}

+ (instancetype)messageFromData:(NSData *)data offset:(NSUInteger *)offset
{
    NSLog(@"messageFromData: starting parse at offset %lu, data length %lu", (unsigned long)*offset, (unsigned long)[data length]);
    
    if (*offset + 16 > [data length]) {
        NSLog(@"messageFromData: not enough data for header (need 16 bytes, have %lu)", (unsigned long)([data length] - *offset));
        return nil; // Not enough data for header
    }
    
    const uint8_t *bytes = [data bytes];
    NSUInteger pos = *offset;
    
    // Read fixed header
    uint8_t endian = bytes[pos++];
    NSLog(@"messageFromData: endian byte 0x%02x ('%c')", endian, endian);
    
    if (endian != DBUS_LITTLE_ENDIAN && endian != DBUS_BIG_ENDIAN) {
        NSLog(@"messageFromData: invalid endianness: 0x%02x", endian);
        return nil;
    }
    
    BOOL littleEndian = (endian == DBUS_LITTLE_ENDIAN);
    
    MBMessage *message = [[self alloc] init];
    message.type = (MBMessageType)bytes[pos++];
    uint8_t flags __attribute__((unused)) = bytes[pos++];
    uint8_t version = bytes[pos++];
    
    NSLog(@"messageFromData: type=%d, flags=%d, version=%d", message.type, flags, version);
    
    if (version != DBUS_MAJOR_PROTOCOL_VERSION) {
        NSLog(@"messageFromData: unsupported protocol version: %d", version);
        return nil;
    }
    
    // Body length and serial
    uint32_t bodyLength = *(uint32_t *)(bytes + pos);
    if (!littleEndian) {
        bodyLength = ntohl(bodyLength);
    }
    pos += 4;
    uint32_t serial = *(uint32_t *)(bytes + pos);
    if (!littleEndian) {
        serial = ntohl(serial);
    }
    pos += 4;
    message.serial = serial;
    
    NSLog(@"messageFromData: bodyLength=%u, serial=%u", bodyLength, serial);
    
    // Header fields array length
    uint32_t headerFieldsLength = *(uint32_t *)(bytes + pos);
    if (!littleEndian) {
        headerFieldsLength = ntohl(headerFieldsLength);
    }
    pos += 4;
    
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
    NSLog(@"messageFromData: parsing header fields from %lu to %lu", (unsigned long)pos, (unsigned long)headerFieldsEnd);
    
    while (pos < headerFieldsEnd && pos + 8 <= [data length]) {
        // Each header field is a struct: (BYTE fieldcode, VARIANT value)
        
        uint8_t fieldCode = bytes[pos++];
        NSLog(@"messageFromData: parsing field code %d at pos %lu", fieldCode, (unsigned long)(pos-1));
        
        if (fieldCode == 0) {
            NSLog(@"messageFromData: found end of header fields at pos %lu", (unsigned long)(pos-1));
            break; // End of fields
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
        
        // Align to 4-byte boundary for value
        while (pos % 4 != 0 && pos < headerFieldsEnd) pos++;
        
        if (pos + 4 > headerFieldsEnd) {
            NSLog(@"messageFromData: not enough data for field value, skipping");
            break;
        }
        
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
        } else {
            // Skip unknown field type
            NSLog(@"messageFromData: skipping unknown signature '%c'", signature);
            pos += 8; // Skip some bytes and continue
        }
    }
    // Ensure we're at the end of header fields
    pos = 16 + headerFieldsLength; // Skip to end of header fields
    
    // Align to 8-byte boundary for body  
    pos = alignTo(pos, 8);
    
    // Parse body (simplified - just strings and numbers)
    if (bodyLength > 0) {
        // Check if we have enough data for the body
        if (pos + bodyLength > [data length]) {
            NSLog(@"messageFromData: not enough data for body (need %u more bytes)", 
                  (unsigned)(pos + bodyLength - [data length]));
            return nil;
        }
        
        NSMutableArray *arguments = [NSMutableArray array];
        NSUInteger bodyEnd = pos + bodyLength;
        
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
        pos = bodyEnd; // Ensure we're at the end of the body
    }
    
    NSLog(@"messageFromData: final offset %lu (was %lu)", (unsigned long)pos, (unsigned long)*offset);
    *offset = pos;
    return message;
}

+ (NSArray *)messagesFromData:(NSData *)data
{
    NSMutableArray *messages = [NSMutableArray array];
    NSUInteger offset = 0;
    
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
    
    while (offset < [data length]) {
        NSLog(@"Trying to parse message at offset %lu", (unsigned long)offset);
        MBMessage *message = [self messageFromData:data offset:&offset];
        if (message) {
            NSLog(@"Successfully parsed message: %@", message);
            [messages addObject:message];
        } else {
            NSLog(@"Failed to parse message at offset %lu", (unsigned long)offset);
            break;
        }
    }
    
    NSLog(@"Parsed %lu messages total", (unsigned long)[messages count]);
    return messages;
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<MBMessage type=%d dest=%@ path=%@ iface=%@ member=%@ args=%@>",
            (int)_type, _destination, _path, _interface, _member, _arguments];
}

@end
