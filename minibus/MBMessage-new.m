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

static void appendUInt32(NSMutableData *data, uint32_t value) {
    appendAligned(data, &value, 4, 4);
}

static void appendByte(NSMutableData *data, uint8_t value) {
    [data appendBytes:&value length:1];
}

static void appendString(NSMutableData *data, NSString *str) {
    if (!str) str = @"";
    NSData *strData = [str dataUsingEncoding:NSUTF8StringEncoding];
    uint32_t length = (uint32_t)[strData length];
    
    // String length (4-byte aligned)
    appendUInt32(data, length);
    // String data
    [data appendData:strData];
    // Null terminator
    uint8_t nullByte = 0;
    [data appendBytes:&nullByte length:1];
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
    
    // Helper to add a header field with string value
    void (^addStringField)(uint8_t, NSString *) = ^(uint8_t fieldCode, NSString *value) {
        if (!value) return;
        
        // Align struct to 8-byte boundary
        NSUInteger currentLength = [fieldsData length];
        NSUInteger alignedLength = alignTo(currentLength, 8);
        NSUInteger padding = alignedLength - currentLength;
        
        if (padding > 0) {
            uint8_t zero = 0;
            for (NSUInteger i = 0; i < padding; i++) {
                [fieldsData appendBytes:&zero length:1];
            }
        }
        
        // Field code (byte)
        [fieldsData appendBytes:&fieldCode length:1];
        
        // Signature for string: "s"
        uint8_t sigLen = 1;
        [fieldsData appendBytes:&sigLen length:1];
        uint8_t strSig = DBUS_TYPE_STRING;
        [fieldsData appendBytes:&strSig length:1];
        uint8_t nullTerm = 0;
        [fieldsData appendBytes:&nullTerm length:1];
        
        // String value (4-byte aligned)
        appendString(fieldsData, value);
    };
    
    // Helper to add a header field with uint32 value
    void (^addUInt32Field)(uint8_t, uint32_t) = ^(uint8_t fieldCode, uint32_t value) {
        if (value == 0) return;
        
        // Align struct to 8-byte boundary
        NSUInteger currentLength = [fieldsData length];
        NSUInteger alignedLength = alignTo(currentLength, 8);
        NSUInteger padding = alignedLength - currentLength;
        
        if (padding > 0) {
            uint8_t zero = 0;
            for (NSUInteger i = 0; i < padding; i++) {
                [fieldsData appendBytes:&zero length:1];
            }
        }
        
        // Field code (byte)
        [fieldsData appendBytes:&fieldCode length:1];
        
        // Signature for uint32: "u"
        uint8_t sigLen = 1;
        [fieldsData appendBytes:&sigLen length:1];
        uint8_t u32Sig = DBUS_TYPE_UINT32;
        [fieldsData appendBytes:&u32Sig length:1];
        uint8_t nullTerm = 0;
        [fieldsData appendBytes:&nullTerm length:1];
        
        // uint32 value (4-byte aligned)
        appendUInt32(fieldsData, value);
    };
    
    // Add fields in order
    addStringField(DBUS_HEADER_FIELD_PATH, _path);
    addStringField(DBUS_HEADER_FIELD_INTERFACE, _interface);
    addStringField(DBUS_HEADER_FIELD_MEMBER, _member);
    addStringField(DBUS_HEADER_FIELD_ERROR_NAME, _errorName);
    addUInt32Field(DBUS_HEADER_FIELD_REPLY_SERIAL, (uint32_t)_replySerial);
    addStringField(DBUS_HEADER_FIELD_DESTINATION, _destination);
    addStringField(DBUS_HEADER_FIELD_SENDER, _sender);
    addStringField(DBUS_HEADER_FIELD_SIGNATURE, _signature);
    
    return fieldsData;
}

- (NSData *)serializeBody
{
    if (!_arguments || [_arguments count] == 0) {
        return [NSData data];
    }
    
    NSMutableData *bodyData = [NSMutableData data];
    
    for (id arg in _arguments) {
        if ([arg isKindOfClass:[NSString class]]) {
            appendString(bodyData, (NSString *)arg);
        } else if ([arg isKindOfClass:[NSNumber class]]) {
            uint32_t value = [arg unsignedIntValue];
            appendUInt32(bodyData, value);
        }
    }
    
    return bodyData;
}

+ (instancetype)messageFromData:(NSData *)data offset:(NSUInteger *)offset
{
    if ([data length] < 16) {
        return nil; // Not enough data for header
    }
    
    const uint8_t *bytes = [data bytes];
    NSUInteger pos = *offset;
    
    // Read fixed header
    uint8_t endian = bytes[pos++];
    if (endian != DBUS_LITTLE_ENDIAN && endian != DBUS_BIG_ENDIAN) {
        NSLog(@"Invalid endianness: %c", endian);
        return nil;
    }
    
    MBMessage *message = [[self alloc] init];
    message.type = (MBMessageType)bytes[pos++];
    uint8_t flags __attribute__((unused)) = bytes[pos++];
    uint8_t version = bytes[pos++];
    
    if (version != DBUS_MAJOR_PROTOCOL_VERSION) {
        NSLog(@"Unsupported protocol version: %d", version);
        return nil;
    }
    
    // Body length and serial
    uint32_t bodyLength = *(uint32_t *)(bytes + pos);
    pos += 4;
    uint32_t serial = *(uint32_t *)(bytes + pos);
    pos += 4;
    message.serial = serial;
    
    // Header fields array length
    uint32_t headerFieldsLength = *(uint32_t *)(bytes + pos);
    pos += 4;
    
    // Parse header fields (simplified)
    NSUInteger headerFieldsEnd = pos + headerFieldsLength;
    while (pos < headerFieldsEnd && pos < [data length]) {
        if (pos + 4 > [data length]) break;
        
        // Align to 8-byte boundary for struct
        NSUInteger alignedPos = alignTo(pos, 8);
        pos = alignedPos;
        
        if (pos + 4 > [data length]) break;
        
        uint8_t fieldCode = bytes[pos++];
        uint8_t sigLen = bytes[pos++];
        if (sigLen == 0) break;
        
        pos += sigLen + 1; // Skip signature + null terminator
        
        // Align to field value boundary
        pos = alignTo(pos, 4);
        
        if (pos + 4 > [data length]) break;
        
        // Read string value (simplified)
        if (fieldCode == DBUS_HEADER_FIELD_DESTINATION ||
            fieldCode == DBUS_HEADER_FIELD_PATH ||
            fieldCode == DBUS_HEADER_FIELD_INTERFACE ||
            fieldCode == DBUS_HEADER_FIELD_MEMBER ||
            fieldCode == DBUS_HEADER_FIELD_SENDER ||
            fieldCode == DBUS_HEADER_FIELD_SIGNATURE ||
            fieldCode == DBUS_HEADER_FIELD_ERROR_NAME) {
            
            uint32_t strLen = *(uint32_t *)(bytes + pos);
            pos += 4;
            
            if (pos + strLen + 1 > [data length]) break;
            
            NSString *str = [[NSString alloc] initWithBytes:bytes + pos
                                                     length:strLen
                                                   encoding:NSUTF8StringEncoding];
            pos += strLen + 1; // +1 for null terminator
            
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
                case DBUS_HEADER_FIELD_SIGNATURE:
                    message.signature = str;
                    break;
                case DBUS_HEADER_FIELD_ERROR_NAME:
                    message.errorName = str;
                    break;
            }
        } else if (fieldCode == DBUS_HEADER_FIELD_REPLY_SERIAL) {
            uint32_t replySerial = *(uint32_t *)(bytes + pos);
            pos += 4;
            message.replySerial = replySerial;
        } else {
            // Skip unknown field
            pos += 4; // Assume 4-byte value
        }
    }
    
    // Align to 8-byte boundary for body
    pos = alignTo(pos, 8);
    
    // Parse body (simplified - just strings and numbers)
    if (bodyLength > 0 && pos + bodyLength <= [data length]) {
        NSMutableArray *arguments = [NSMutableArray array];
        NSUInteger bodyEnd = pos + bodyLength;
        
        while (pos < bodyEnd) {
            if (pos + 4 > bodyEnd) break;
            
            // Try to read as string first
            uint32_t strLen = *(uint32_t *)(bytes + pos);
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
                [arguments addObject:@(num)];
                pos += 4;
            } else {
                break;
            }
        }
        
        message.arguments = arguments;
    }
    
    *offset = pos;
    return message;
}

+ (NSArray *)messagesFromData:(NSData *)data
{
    NSMutableArray *messages = [NSMutableArray array];
    NSUInteger offset = 0;
    
    while (offset < [data length]) {
        MBMessage *message = [self messageFromData:data offset:&offset];
        if (message) {
            [messages addObject:message];
        } else {
            break;
        }
    }
    
    return messages;
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<MBMessage type=%d dest=%@ path=%@ iface=%@ member=%@ args=%@>",
            (int)_type, _destination, _path, _interface, _member, _arguments];
}

@end
