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
    NSMutableString *signature = [NSMutableString string];
    for (id arg in arguments) {
        if ([arg isKindOfClass:[NSString class]]) {
            [signature appendString:@"s"];
        } else if ([arg isKindOfClass:[NSNumber class]]) {
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
        }
    };
    
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
    
    // Add header fields in required order
    if (_path) {
        addStringField(DBUS_HEADER_FIELD_PATH, _path);
    }
    
    if (_interface) {
        addStringField(DBUS_HEADER_FIELD_INTERFACE, _interface);
    }
    
    if (_member) {
        addStringField(DBUS_HEADER_FIELD_MEMBER, _member);
    }
    
    if (_errorName) {
        addStringField(DBUS_HEADER_FIELD_ERROR_NAME, _errorName);
    }
    
    if (_replySerial > 0) {
        addUInt32Field(DBUS_HEADER_FIELD_REPLY_SERIAL, (uint32_t)_replySerial);
    }
    
    if (_destination) {
        addStringField(DBUS_HEADER_FIELD_DESTINATION, _destination);
    }
    
    if (_sender) {
        addStringField(DBUS_HEADER_FIELD_SENDER, _sender);
    }
    
    if (_signature && [_signature length] > 0) {
        addStringField(DBUS_HEADER_FIELD_SIGNATURE, _signature);
    }
    
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
            // Align to 4 bytes for string length
            addPadding(bodyData, 4);
            uint32_t strLen = (uint32_t)[str lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
            [bodyData appendBytes:&strLen length:4];
            [bodyData appendData:[str dataUsingEncoding:NSUTF8StringEncoding]];
            uint8_t nullTerm = 0;
            [bodyData appendBytes:&nullTerm length:1];
        } else if ([arg isKindOfClass:[NSNumber class]]) {
            // Align to 4 bytes for uint32
            addPadding(bodyData, 4);
            uint32_t value = [arg unsignedIntValue];
            [bodyData appendBytes:&value length:4];
        } else if ([arg isKindOfClass:[NSArray class]]) {
            // Serialize array of strings
            NSArray *array = (NSArray *)arg;
            
            // Calculate total array data length (not including the length field itself)
            NSUInteger arrayDataStart = [bodyData length] + 4; // After the length field
            
            // Align to 4 bytes for array length
            addPadding(bodyData, 4);
            
            // Placeholder for array length - we'll update this later
            NSUInteger lengthPosition = [bodyData length];
            uint32_t placeholder = 0;
            [bodyData appendBytes:&placeholder length:4];
            
            // Align array contents to element alignment (4 bytes for strings)
            addPadding(bodyData, 4);
            NSUInteger arrayContentStart = [bodyData length];
            
            // Write array elements
            for (NSString *item in array) {
                if ([item isKindOfClass:[NSString class]]) {
                    // Align each string to 4 bytes
                    addPadding(bodyData, 4);
                    uint32_t itemLen = (uint32_t)[item lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
                    [bodyData appendBytes:&itemLen length:4];
                    [bodyData appendData:[item dataUsingEncoding:NSUTF8StringEncoding]];
                    uint8_t nullTerm = 0;
                    [bodyData appendBytes:&nullTerm length:1];
                }
            }
            
            // Update array length field with actual content length
            uint32_t actualArrayLength = (uint32_t)([bodyData length] - arrayContentStart);
            [bodyData replaceBytesInRange:NSMakeRange(lengthPosition, 4) withBytes:&actualArrayLength];
        }
    }
    
    return bodyData;
}

// Rest of the parsing and utility methods would go here...
// For now, let's focus on the serialization which is the main issue

+ (instancetype)parseFromData:(NSData *)data
{
    // Simplified parsing - we'll implement this later if needed
    return nil;
}

@end
