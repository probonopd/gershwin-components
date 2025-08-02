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
            // Try to detect the number type
            NSNumber *num = (NSNumber *)arg;
            const char *objCType = [num objCType];
            
            if (strcmp(objCType, @encode(BOOL)) == 0 || 
                strcmp(objCType, @encode(bool)) == 0) {
                [signature appendString:@"b"]; // Boolean
            } else if (strcmp(objCType, @encode(uint8_t)) == 0 ||
                       strcmp(objCType, @encode(char)) == 0) {
                [signature appendString:@"y"]; // Byte
            } else if (strcmp(objCType, @encode(int16_t)) == 0) {
                [signature appendString:@"n"]; // int16
            } else if (strcmp(objCType, @encode(uint16_t)) == 0) {
                [signature appendString:@"q"]; // uint16
            } else if (strcmp(objCType, @encode(int32_t)) == 0 ||
                       strcmp(objCType, @encode(int)) == 0) {
                [signature appendString:@"i"]; // int32
            } else if (strcmp(objCType, @encode(uint32_t)) == 0 ||
                       strcmp(objCType, @encode(unsigned int)) == 0) {
                [signature appendString:@"u"]; // uint32
            } else if (strcmp(objCType, @encode(int64_t)) == 0 ||
                       strcmp(objCType, @encode(long long)) == 0) {
                [signature appendString:@"x"]; // int64
            } else if (strcmp(objCType, @encode(uint64_t)) == 0 ||
                       strcmp(objCType, @encode(unsigned long long)) == 0) {
                [signature appendString:@"t"]; // uint64
            } else if (strcmp(objCType, @encode(double)) == 0) {
                [signature appendString:@"d"]; // double
            } else if (strcmp(objCType, @encode(float)) == 0) {
                [signature appendString:@"d"]; // float promoted to double
            } else {
                [signature appendString:@"u"]; // Default to uint32
            }
        } else if ([arg isKindOfClass:[NSArray class]]) {
            NSArray *array = (NSArray *)arg;
            if ([array count] > 0) {
                id firstElement = [array objectAtIndex:0];
                
                // Check if this looks like a struct by examining contents
                // A struct array typically contains mixed types (not all the same)
                BOOL looksLikeStruct = NO;
                if ([array count] > 1) {
                    Class firstClass = [firstElement class];
                    for (NSUInteger i = 1; i < [array count]; i++) {
                        if (![[array objectAtIndex:i] isKindOfClass:firstClass]) {
                            looksLikeStruct = YES;
                            break;
                        }
                    }
                }
                
                if (looksLikeStruct) {
                    // Generate struct signature (sus) for string-uint32-string pattern
                    [signature appendString:@"("];
                    for (id element in array) {
                        if ([element isKindOfClass:[NSString class]]) {
                            [signature appendString:@"s"];
                        } else if ([element isKindOfClass:[NSNumber class]]) {
                            // Default numbers to uint32 in structs
                            [signature appendString:@"u"];
                        } else {
                            [signature appendString:@"s"]; // Unknown types as string
                        }
                    }
                    [signature appendString:@")"];
                } else if ([firstElement isKindOfClass:[NSString class]]) {
                    [signature appendString:@"as"]; // Array of strings
                } else if ([firstElement isKindOfClass:[NSDictionary class]]) {
                    [signature appendString:@"a{sv}"]; // Array of string-variant dictionaries
                } else if ([firstElement isKindOfClass:[NSNumber class]]) {
                    [signature appendString:@"au"]; // Array of uint32
                } else {
                    [signature appendString:@"as"]; // Array of strings (default for unknown types)
                }
            } else {
                [signature appendString:@"as"]; // Empty array defaults to strings
            }
        } else if ([arg isKindOfClass:[NSDictionary class]]) {
            [signature appendString:@"a{sv}"]; // Dictionary as array of string-variant pairs
        } else if ([arg isKindOfClass:[NSNull class]]) {
            [signature appendString:@"s"]; // Null as empty string (D-Bus doesn't have null type)
        } else {
            [signature appendString:@"s"]; // Unknown types as string representation
        }
    }
    return signature;
}

- (NSData *)serialize
{
    NSLog(@"Serializing message type=%d, replySerial=%lu", (int)_type, (unsigned long)_replySerial);
    
    // CRITICAL FIX: Validate message before serialization
    // Don't serialize messages with invalid variant signatures  
    if (_signature && [_signature isEqualToString:@"v"]) {
        if (!_arguments || [_arguments count] == 0 || [_arguments containsObject:[NSNull null]]) {
            NSLog(@"ERROR: Refusing to serialize message with empty variant signature 'v'");
            NSLog(@"       This would create an invalid D-Bus message");
            NSLog(@"       Type=%d, Serial=%lu, Destination=%@", (int)_type, (unsigned long)_serial, _destination);
            return nil; // Return nil to prevent sending invalid message
        }
    }
    
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
    // Special case: if signature indicates array type but no arguments, serialize empty array
    if ((!_arguments || [_arguments count] == 0) && _signature && [_signature hasPrefix:@"a"]) {
        NSMutableData *bodyData = [NSMutableData data];
        // Align to 4 bytes for array length
        addPadding(bodyData, 4);
        uint32_t arrayLength = 0;  // Empty array
        [bodyData appendBytes:&arrayLength length:4];
        return bodyData;
    }
    
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
            NSNumber *num = (NSNumber *)arg;
            const char *objCType = [num objCType];
            
            if (strcmp(objCType, @encode(BOOL)) == 0 || 
                strcmp(objCType, @encode(bool)) == 0) {
                // Boolean - stored as uint32
                addPadding(bodyData, 4);
                uint32_t boolVal = [num boolValue] ? 1 : 0;
                [bodyData appendBytes:&boolVal length:4];
                
            } else if (strcmp(objCType, @encode(uint8_t)) == 0 ||
                       strcmp(objCType, @encode(char)) == 0) {
                // Byte - no alignment
                uint8_t byteVal = [num unsignedCharValue];
                [bodyData appendBytes:&byteVal length:1];
                
            } else if (strcmp(objCType, @encode(int16_t)) == 0) {
                // int16 - 2-byte aligned
                addPadding(bodyData, 2);
                int16_t int16Val = [num shortValue];
                [bodyData appendBytes:&int16Val length:2];
                
            } else if (strcmp(objCType, @encode(uint16_t)) == 0) {
                // uint16 - 2-byte aligned
                addPadding(bodyData, 2);
                uint16_t uint16Val = [num unsignedShortValue];
                [bodyData appendBytes:&uint16Val length:2];
                
            } else if (strcmp(objCType, @encode(int32_t)) == 0 ||
                       strcmp(objCType, @encode(int)) == 0) {
                // int32 - 4-byte aligned
                addPadding(bodyData, 4);
                int32_t int32Val = [num intValue];
                [bodyData appendBytes:&int32Val length:4];
                
            } else if (strcmp(objCType, @encode(uint32_t)) == 0 ||
                       strcmp(objCType, @encode(unsigned int)) == 0) {
                // uint32 - 4-byte aligned
                addPadding(bodyData, 4);
                uint32_t uint32Val = [num unsignedIntValue];
                [bodyData appendBytes:&uint32Val length:4];
                
            } else if (strcmp(objCType, @encode(int64_t)) == 0 ||
                       strcmp(objCType, @encode(long long)) == 0) {
                // int64 - 8-byte aligned
                addPadding(bodyData, 8);
                int64_t int64Val = [num longLongValue];
                [bodyData appendBytes:&int64Val length:8];
                
            } else if (strcmp(objCType, @encode(uint64_t)) == 0 ||
                       strcmp(objCType, @encode(unsigned long long)) == 0) {
                // uint64 - 8-byte aligned
                addPadding(bodyData, 8);
                uint64_t uint64Val = [num unsignedLongLongValue];
                [bodyData appendBytes:&uint64Val length:8];
                
            } else if (strcmp(objCType, @encode(double)) == 0 ||
                       strcmp(objCType, @encode(float)) == 0) {
                // double - 8-byte aligned
                addPadding(bodyData, 8);
                double doubleVal = [num doubleValue];
                [bodyData appendBytes:&doubleVal length:8];
                
            } else {
                // Default to uint32
                addPadding(bodyData, 4);
                uint32_t value = [num unsignedIntValue];
                [bodyData appendBytes:&value length:4];
            }
            
        } else if ([arg isKindOfClass:[NSArray class]]) {
            // Check if this should be serialized as a STRUCT or regular array
            NSArray *array = (NSArray *)arg;
            BOOL isStruct = (_signature && [_signature containsString:@"("]);
            
            if (isStruct) {
                // Serialize as STRUCT - align to 8-byte boundary
                NSLog(@"DEBUG: Serializing STRUCT with %lu fields", [array count]);
                
                addPadding(bodyData, 8);
                
                // Serialize each field in the struct
                for (id field in array) {
                    if ([field isKindOfClass:[NSString class]]) {
                        // String field
                        NSString *str = (NSString *)field;
                        addPadding(bodyData, 4);
                        uint32_t strLen = (uint32_t)[str lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
                        [bodyData appendBytes:&strLen length:4];
                        [bodyData appendData:[str dataUsingEncoding:NSUTF8StringEncoding]];
                        uint8_t nullTerm = 0;
                        [bodyData appendBytes:&nullTerm length:1];
                        
                    } else if ([field isKindOfClass:[NSNumber class]]) {
                        NSNumber *num = (NSNumber *)field;
                        const char *objCType = [num objCType];
                        
                        if (strcmp(objCType, @encode(BOOL)) == 0) {
                            // Boolean field
                            addPadding(bodyData, 4);
                            uint32_t boolVal = [num boolValue] ? 1 : 0;
                            [bodyData appendBytes:&boolVal length:4];
                            
                        } else if (strcmp(objCType, @encode(uint32_t)) == 0 ||
                                   strcmp(objCType, @encode(unsigned int)) == 0) {
                            // uint32 field
                            addPadding(bodyData, 4);
                            uint32_t uint32Val = [num unsignedIntValue];
                            [bodyData appendBytes:&uint32Val length:4];
                            
                        } else if (strcmp(objCType, @encode(int32_t)) == 0 ||
                                   strcmp(objCType, @encode(int)) == 0) {
                            // int32 field
                            addPadding(bodyData, 4);
                            int32_t int32Val = [num intValue];
                            [bodyData appendBytes:&int32Val length:4];
                            
                        } else {
                            // Default to uint32
                            addPadding(bodyData, 4);
                            uint32_t value = [num unsignedIntValue];
                            [bodyData appendBytes:&value length:4];
                        }
                    } else {
                        // Other field types - skip for now
                        NSLog(@"DEBUG: Skipping unsupported struct field type: %@", [field class]);
                    }
                }
            } else {
                // Serialize as regular arrays
                // Align to 4 bytes for array length
                addPadding(bodyData, 4);
                
                // Placeholder for array length - we'll update this later
                NSUInteger lengthPosition = [bodyData length];
                uint32_t placeholder = 0;
                [bodyData appendBytes:&placeholder length:4];
                
                // Determine element alignment and serialize content
                if ([array count] > 0) {
                id firstElement = [array objectAtIndex:0];
                
                if ([firstElement isKindOfClass:[NSString class]]) {
                    // Array of strings - 4-byte alignment for each string
                    addPadding(bodyData, 4);
                    NSUInteger arrayContentStart = [bodyData length];
                    
                    for (NSString *item in array) {
                        if ([item isKindOfClass:[NSString class]]) {
                            addPadding(bodyData, 4);
                            uint32_t itemLen = (uint32_t)[item lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
                            [bodyData appendBytes:&itemLen length:4];
                            [bodyData appendData:[item dataUsingEncoding:NSUTF8StringEncoding]];
                            uint8_t nullTerm = 0;
                            [bodyData appendBytes:&nullTerm length:1];
                        }
                    }
                    
                    uint32_t actualArrayLength = (uint32_t)([bodyData length] - arrayContentStart);
                    [bodyData replaceBytesInRange:NSMakeRange(lengthPosition, 4) withBytes:&actualArrayLength];
                    
                } else if ([firstElement isKindOfClass:[NSDictionary class]]) {
                    // Array of dictionaries a{sv} - 8-byte alignment for dict entries
                    addPadding(bodyData, 8);
                    NSUInteger arrayContentStart = [bodyData length];
                    
                    for (NSDictionary *dict in array) {
                        if ([dict isKindOfClass:[NSDictionary class]]) {
                            for (NSString *key in dict) {
                                // Each dictionary entry is 8-byte aligned
                                addPadding(bodyData, 8);
                                
                                // Serialize key (string)
                                addPadding(bodyData, 4);
                                uint32_t keyLen = (uint32_t)[key lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
                                [bodyData appendBytes:&keyLen length:4];
                                [bodyData appendData:[key dataUsingEncoding:NSUTF8StringEncoding]];
                                uint8_t nullTerm = 0;
                                [bodyData appendBytes:&nullTerm length:1];
                                
                                // Serialize value as variant
                                id value = [dict objectForKey:key];
                                [MBMessage serializeVariant:value toData:bodyData];
                            }
                        }
                    }
                    
                    uint32_t actualArrayLength = (uint32_t)([bodyData length] - arrayContentStart);
                    [bodyData replaceBytesInRange:NSMakeRange(lengthPosition, 4) withBytes:&actualArrayLength];
                    
                } else {
                    // Other array types - just put empty array for now
                    uint32_t actualArrayLength = 0;
                    [bodyData replaceBytesInRange:NSMakeRange(lengthPosition, 4) withBytes:&actualArrayLength];
                }
            } else {
                // Empty array
                uint32_t actualArrayLength = 0;
                [bodyData replaceBytesInRange:NSMakeRange(lengthPosition, 4) withBytes:&actualArrayLength];
            }
            }
            
        } else if ([arg isKindOfClass:[NSDictionary class]]) {
            // Serialize dictionary as array of key-value pairs a{sv}
            NSDictionary *dict = (NSDictionary *)arg;
            
            addPadding(bodyData, 4);
            NSUInteger lengthPosition = [bodyData length];
            uint32_t placeholder = 0;
            [bodyData appendBytes:&placeholder length:4];
            
            addPadding(bodyData, 8);
            NSUInteger arrayContentStart = [bodyData length];
            
            for (NSString *key in dict) {
                // CRITICAL: Skip invalid dictionary entries that could cause GLib crashes
                if (!key || [key length] == 0) {
                    NSLog(@"WARNING: Skipping invalid dictionary key (empty or nil)");
                    continue;
                }
                
                id value = [dict objectForKey:key];
                
                // CRITICAL: Ensure we have a valid value
                if (!value) {
                    NSLog(@"WARNING: Skipping dictionary entry '%@' with nil value", key);
                    continue;
                }
                
                addPadding(bodyData, 8);
                
                // Serialize key
                addPadding(bodyData, 4);
                uint32_t keyLen = (uint32_t)[key lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
                [bodyData appendBytes:&keyLen length:4];
                [bodyData appendData:[key dataUsingEncoding:NSUTF8StringEncoding]];
                uint8_t nullTerm = 0;
                [bodyData appendBytes:&nullTerm length:1];
                
                // Serialize value as variant
                [MBMessage serializeVariant:value toData:bodyData];
            }
            
            uint32_t actualArrayLength = (uint32_t)([bodyData length] - arrayContentStart);
            [bodyData replaceBytesInRange:NSMakeRange(lengthPosition, 4) withBytes:&actualArrayLength];
        }
    }
    
    return bodyData;
}

+ (void)serializeVariant:(id)value toData:(NSMutableData *)data
{
    // Serialize variant according to D-Bus specification:
    // 1 byte signature length (without nul), signature with nul, then aligned value
    
    if (value == nil || value == [NSNull null]) {
        // Serialize nil as empty string variant
        NSLog(@"DEBUG: Serializing null/nil value as empty string variant");
        [self serializeVariantWithSignature:@"s" value:@"" toData:data];
        return;
    }
    
    if ([value isKindOfClass:[NSString class]]) {
        [self serializeVariantWithSignature:@"s" value:value toData:data];
        
    } else if ([value isKindOfClass:[NSNumber class]]) {
        NSNumber *num = (NSNumber *)value;
        const char *objCType = [num objCType];
        
        if (strcmp(objCType, @encode(BOOL)) == 0 || strcmp(objCType, @encode(bool)) == 0) {
            [self serializeVariantWithSignature:@"b" value:value toData:data];
        } else if (strcmp(objCType, @encode(double)) == 0 || strcmp(objCType, @encode(float)) == 0) {
            [self serializeVariantWithSignature:@"d" value:value toData:data];
        } else if (strcmp(objCType, @encode(int64_t)) == 0 || strcmp(objCType, @encode(long long)) == 0) {
            [self serializeVariantWithSignature:@"x" value:value toData:data];
        } else if (strcmp(objCType, @encode(uint64_t)) == 0 || strcmp(objCType, @encode(unsigned long long)) == 0) {
            [self serializeVariantWithSignature:@"t" value:value toData:data];
        } else if (strcmp(objCType, @encode(int32_t)) == 0 || strcmp(objCType, @encode(int)) == 0) {
            [self serializeVariantWithSignature:@"i" value:value toData:data];
        } else {
            // Default to uint32
            [self serializeVariantWithSignature:@"u" value:value toData:data];
        }
        
    } else if ([value isKindOfClass:[NSArray class]]) {
        NSArray *array = (NSArray *)value;
        
        if ([array count] == 0) {
            // Empty array - serialize as array of strings (as)
            [self serializeVariantWithSignature:@"as" value:array toData:data];
        } else {
            // Determine if this should be a struct or an array
            BOOL isHomogeneous = YES;
            Class firstClass = [[array objectAtIndex:0] class];
            
            for (NSUInteger i = 1; i < [array count]; i++) {
                if (![[array objectAtIndex:i] isKindOfClass:firstClass]) {
                    isHomogeneous = NO;
                    break;
                }
            }
            
            if (isHomogeneous && [firstClass isSubclassOfClass:[NSString class]]) {
                // Array of strings
                [self serializeVariantWithSignature:@"as" value:array toData:data];
            } else if (isHomogeneous && [firstClass isSubclassOfClass:[NSNumber class]]) {
                // Array of numbers (assume uint32)
                [self serializeVariantWithSignature:@"au" value:array toData:data];
            } else {
                // Mixed types - serialize as struct
                NSMutableString *structSig = [NSMutableString stringWithString:@"("];
                for (id element in array) {
                    [structSig appendString:[self getSignatureForValue:element]];
                }
                [structSig appendString:@")"];
                
                [self serializeVariantWithSignature:structSig value:array toData:data];
            }
        }
        
    } else if ([value isKindOfClass:[NSDictionary class]]) {
        // Dictionary - serialize as a{sv} (dictionary of string to variant)
        [self serializeVariantWithSignature:@"a{sv}" value:value toData:data];
        
    } else {
        // Default to string representation
        NSString *str = [value description];
        [self serializeVariantWithSignature:@"s" value:str toData:data];
    }
}

// Helper method to serialize a variant with a specific signature
+ (void)serializeVariantWithSignature:(NSString *)signature 
                                value:(id)value 
                               toData:(NSMutableData *)data
{
    if (!signature || [signature length] == 0) {
        NSLog(@"ERROR: Cannot serialize variant with empty signature");
        return;
    }
    
    // Write signature length (without nul terminator)
    uint8_t sigLen = (uint8_t)[signature lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    [data appendBytes:&sigLen length:1];
    
    // Write signature with nul terminator
    [data appendData:[signature dataUsingEncoding:NSUTF8StringEncoding]];
    uint8_t nullTerm = 0;
    [data appendBytes:&nullTerm length:1];
    
    // Serialize the value according to its signature
    [self serializeValue:value withSignature:signature toData:data];
}

// Helper method to serialize a value according to its D-Bus signature
+ (void)serializeValue:(id)value 
         withSignature:(NSString *)signature 
                toData:(NSMutableData *)data
{
    if (!signature || [signature length] == 0) return;
    
    unichar typeChar = [signature characterAtIndex:0];
    
    switch (typeChar) {
        case 's': {
            // String
            NSString *str = [value isKindOfClass:[NSString class]] ? value : [value description];
            addPadding(data, 4);
            uint32_t strLen = (uint32_t)[str lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
            [data appendBytes:&strLen length:4];
            [data appendData:[str dataUsingEncoding:NSUTF8StringEncoding]];
            uint8_t nullTerm = 0;
            [data appendBytes:&nullTerm length:1];
            break;
        }
        
        case 'u': {
            // uint32
            addPadding(data, 4);
            uint32_t uint32Val = [value isKindOfClass:[NSNumber class]] ? [(NSNumber*)value unsignedIntValue] : 0;
            [data appendBytes:&uint32Val length:4];
            break;
        }
        
        case 'i': {
            // int32
            addPadding(data, 4);
            int32_t int32Val = [value isKindOfClass:[NSNumber class]] ? [(NSNumber*)value intValue] : 0;
            [data appendBytes:&int32Val length:4];
            break;
        }
        
        case 'b': {
            // Boolean
            addPadding(data, 4);
            uint32_t boolVal = [value isKindOfClass:[NSNumber class]] ? ([(NSNumber*)value boolValue] ? 1 : 0) : 0;
            [data appendBytes:&boolVal length:4];
            break;
        }
        
        case 'd': {
            // Double
            addPadding(data, 8);
            double doubleVal = [value isKindOfClass:[NSNumber class]] ? [(NSNumber*)value doubleValue] : 0.0;
            [data appendBytes:&doubleVal length:8];
            break;
        }
        
        case 'x': {
            // int64
            addPadding(data, 8);
            int64_t int64Val = [value isKindOfClass:[NSNumber class]] ? [(NSNumber*)value longLongValue] : 0;
            [data appendBytes:&int64Val length:8];
            break;
        }
        
        case 't': {
            // uint64
            addPadding(data, 8);
            uint64_t uint64Val = [value isKindOfClass:[NSNumber class]] ? [(NSNumber*)value unsignedLongLongValue] : 0;
            [data appendBytes:&uint64Val length:8];
            break;
        }
        
        default:
            NSLog(@"ERROR: Unsupported type '%c' in signature '%@'", typeChar, signature);
            break;
    }
}

// Helper method to get signature for a value
+ (NSString *)getSignatureForValue:(id)value
{
    if ([value isKindOfClass:[NSString class]]) {
        return @"s";
    } else if ([value isKindOfClass:[NSNumber class]]) {
        return @"u"; // Default to uint32
    } else {
        return @"s"; // Default to string for unknown types
    }
}

// Helper method to serialize array
+ (void)serializeArray:(NSArray *)array 
  withElementSignature:(NSString *)elementSig 
                toData:(NSMutableData *)data
{
    // Array serialization: length (uint32) + padding + elements
    addPadding(data, 4);
    
    // Reserve space for length
    NSUInteger lengthPosition = [data length];
    uint32_t arrayLength = 0;
    [data appendBytes:&arrayLength length:4];
    
    NSUInteger arrayContentStart = [data length];
    
    for (id element in array) {
        [self serializeValue:element withSignature:elementSig toData:data];
    }
    
    // Update actual array length
    uint32_t actualArrayLength = (uint32_t)([data length] - arrayContentStart);
    [data replaceBytesInRange:NSMakeRange(lengthPosition, 4) withBytes:&actualArrayLength];
}

// Helper method to serialize struct
+ (void)serializeStruct:(NSArray *)structArray 
          withSignature:(NSString *)signature 
                 toData:(NSMutableData *)data
{
    // Struct serialization: align to 8-byte boundary + elements
    addPadding(data, 8);
    
    // Simple struct serialization - just serialize each element as string
    for (id element in structArray) {
        [self serializeValue:element withSignature:@"s" toData:data];
    }
}

// Message parsing implementation based on D-Bus specification
+ (instancetype)messageFromData:(NSData *)data offset:(NSUInteger *)offset
{
    const uint8_t *bytes = [data bytes];
    NSUInteger dataLength = [data length];
    NSUInteger pos = *offset;
    
    if (pos + 16 > dataLength) {
        return nil; // Not enough data for header
    }
    
    // Read fixed header (16 bytes)
    uint8_t endian = bytes[pos];
    uint8_t messageType = bytes[pos + 1];
    uint8_t flags = bytes[pos + 2];
    uint8_t version = bytes[pos + 3];
    
    // Check validity
    if (endian != DBUS_LITTLE_ENDIAN && endian != DBUS_BIG_ENDIAN) {
        return nil;
    }
    if (version != DBUS_MAJOR_PROTOCOL_VERSION) {
        return nil;
    }
    if (messageType < 1 || messageType > 4) {
        return nil;
    }
    
    // Read lengths (always little-endian for now)
    uint32_t bodyLength = *(uint32_t *)(bytes + pos + 4);
    uint32_t serial = *(uint32_t *)(bytes + pos + 8);
    uint32_t headerFieldsLength = *(uint32_t *)(bytes + pos + 12);
    
    pos += 16; // Move past fixed header
    
    // Calculate total message length including padding
    NSUInteger headerFieldsEndPos = pos + headerFieldsLength;
    NSUInteger bodyStartPos = alignTo(headerFieldsEndPos, 8);
    NSUInteger totalMessageLength = bodyStartPos + bodyLength;
    
    if (totalMessageLength > dataLength - *offset) {
        return nil; // Not enough data for complete message
    }
    
    // Create message
    MBMessage *message = [[MBMessage alloc] init];
    message.type = (MBMessageType)messageType;
    message.serial = serial;
    
    // Parse header fields if present
    if (headerFieldsLength > 0) {
        [self parseHeaderFields:data 
                         offset:pos 
                         length:headerFieldsLength 
                      endianness:endian 
                        message:message];
    }
    
    // Parse body if present
    if (bodyLength > 0 && message.signature) {
        NSData *bodyData = [NSData dataWithBytes:bytes + bodyStartPos length:bodyLength];
        message.arguments = [self parseArgumentsFromBodyData:bodyData 
                                                   signature:message.signature 
                                                  endianness:endian];
    }
    
    *offset += totalMessageLength;
    return message;
}

+ (NSArray *)messagesFromData:(NSData *)data
{
    NSUInteger consumedBytes = 0;
    return [self messagesFromData:data consumedBytes:&consumedBytes];
}

+ (NSArray *)messagesFromData:(NSData *)data consumedBytes:(NSUInteger *)consumedBytes
{
    NSMutableArray *messages = [NSMutableArray array];
    NSUInteger offset = 0;
    
    while (offset < [data length]) {
        MBMessage *message = [self messageFromData:data offset:&offset];
        if (message) {
            [messages addObject:message];
        } else {
            break; // Can't parse more messages
        }
    }
    
    *consumedBytes = offset;
    return messages;
}

// Helper method to parse header fields
+ (void)parseHeaderFields:(NSData *)data 
                   offset:(NSUInteger)pos 
                   length:(NSUInteger)length 
                endianness:(uint8_t)endianness 
                  message:(MBMessage *)message
{
    NSLog(@"DEBUG: parseHeaderFields called - pos=%lu, length=%lu", pos, length);
    const uint8_t *bytes = [data bytes];
    NSUInteger endPos = pos + length;
    
    // DEBUG: Hex dump of header fields data
    NSLog(@"DEBUG: Header fields hex dump:");
    for (NSUInteger i = pos; i < endPos && i < pos + 64; i += 16) {
        NSMutableString *hexLine = [NSMutableString string];
        for (NSUInteger j = i; j < i + 16 && j < endPos; j++) {
            [hexLine appendFormat:@"%02x ", bytes[j]];
        }
        NSLog(@"  %04lx: %@", i - pos, hexLine);
    }
    
    int fieldCount = 0;
    
    // Header fields are an array of (BYTE, VARIANT) structs
    while (pos < endPos) {
        NSLog(@"DEBUG: Field %d - pos=%lu, endPos=%lu", fieldCount, pos, endPos);
        if (pos + 8 > endPos) {
            NSLog(@"DEBUG: Not enough bytes for field alignment, breaking");
            break; // Need at least 8 bytes for alignment
        }
        
        // Align to 8-byte boundary for struct
        NSUInteger oldPos = pos;
        pos = alignTo(pos, 8);
        NSLog(@"DEBUG: Aligned from %lu to %lu", oldPos, pos);
        if (pos >= endPos) {
            NSLog(@"DEBUG: Alignment pushed past end, breaking");
            break;
        }
        
        // Read field code (BYTE)
        uint8_t fieldCode = bytes[pos];
        pos++;
        NSLog(@"DEBUG: Field code: %u", fieldCode);
        
        // Read variant signature length
        if (pos >= endPos) {
            NSLog(@"DEBUG: No space for signature length, breaking");
            break;
        }
        uint8_t sigLen = bytes[pos];
        pos++;
        NSLog(@"DEBUG: Signature length: %u", sigLen);
        
        // Read signature
        if (pos + sigLen + 1 > endPos) {
            NSLog(@"DEBUG: Not enough space for signature, breaking");
            break; // +1 for null terminator
        }
        NSString *signature = [[NSString alloc] initWithBytes:bytes + pos 
                                                       length:sigLen 
                                                     encoding:NSUTF8StringEncoding];
        pos += sigLen + 1; // Skip null terminator
        NSLog(@"DEBUG: Signature: '%@'", signature);
        
        fieldCount++;
        
        // Parse value based on signature
        NSUInteger bytesConsumed = 0;
        id value = [self parseValueFromBytes:bytes + pos 
                                   maxLength:endPos - pos 
                                   signature:signature 
                                  endianness:endianness 
                               bytesConsumed:&bytesConsumed];
        
        NSLog(@"DEBUG: Parsed value: '%@', consumed %lu bytes", value, bytesConsumed);
        
        // Update position with consumed bytes
        pos += bytesConsumed;
        
        // Set header field
        switch (fieldCode) {
            case DBUS_HEADER_FIELD_PATH:
                message.path = value;
                break;
            case DBUS_HEADER_FIELD_INTERFACE:
                message.interface = value;
                break;
            case DBUS_HEADER_FIELD_MEMBER:
                message.member = value;
                break;
            case DBUS_HEADER_FIELD_ERROR_NAME:
                message.errorName = value;
                break;
            case DBUS_HEADER_FIELD_REPLY_SERIAL:
                message.replySerial = [value unsignedIntegerValue];
                break;
            case DBUS_HEADER_FIELD_DESTINATION:
                message.destination = value;
                break;
            case DBUS_HEADER_FIELD_SENDER:
                message.sender = value;
                break;
            case DBUS_HEADER_FIELD_SIGNATURE:
                // Validate signature field - reject invalid "v" signatures
                if (value && [value isEqualToString:@"v"]) {
                    NSLog(@"WARNING: Received message with invalid signature 'v', replacing with empty");
                    message.signature = @"";
                } else {
                    message.signature = value;
                }
                break;
        }
    }
}

// Helper method to parse a value from bytes
+ (id)parseValueFromBytes:(const uint8_t *)bytes 
                maxLength:(NSUInteger)maxLen 
                signature:(NSString *)signature 
               endianness:(uint8_t)endianness 
            bytesConsumed:(NSUInteger *)pos
{
    if (!signature || [signature length] == 0) {
        *pos = 0;
        return nil;
    }
    
    unichar typeChar = [signature characterAtIndex:0];
    NSUInteger startPos = *pos;
    
    switch (typeChar) {
        case 's': {
            // String: 4-byte length + string + null terminator
            *pos = alignTo(*pos, 4);
            if (*pos + 4 > maxLen) return nil;
            
            uint32_t strLen = *(uint32_t *)(bytes + *pos);
            *pos += 4;
            
            if (*pos + strLen + 1 > maxLen) return nil;
            
            NSString *result = [[NSString alloc] initWithBytes:bytes + *pos 
                                                        length:strLen 
                                                      encoding:NSUTF8StringEncoding];
            *pos += strLen + 1; // Skip null terminator
            return result;
        }
        
        case 'u': {
            // uint32
            *pos = alignTo(*pos, 4);
            if (*pos + 4 > maxLen) return nil;
            
            uint32_t value = *(uint32_t *)(bytes + *pos);
            *pos += 4;
            return @(value);
        }
        
        case 'i': {
            // int32
            *pos = alignTo(*pos, 4);
            if (*pos + 4 > maxLen) return nil;
            
            int32_t value = *(int32_t *)(bytes + *pos);
            *pos += 4;
            return @(value);
        }
        
        case 'o': {
            // Object path - same format as string
            *pos = alignTo(*pos, 4);
            if (*pos + 4 > maxLen) return nil;
            
            uint32_t strLen = *(uint32_t *)(bytes + *pos);
            *pos += 4;
            
            if (*pos + strLen + 1 > maxLen) return nil;
            
            NSString *result = [[NSString alloc] initWithBytes:bytes + *pos 
                                                        length:strLen 
                                                      encoding:NSUTF8StringEncoding];
            *pos += strLen + 1; // Skip null terminator
            return result;
        }
        
        case 'g': {
            // Signature - length is 1 byte, no padding
            if (*pos + 1 > maxLen) return nil;
            
            uint8_t sigLen = bytes[*pos];
            *pos += 1;
            
            if (*pos + sigLen + 1 > maxLen) return nil;
            
            NSString *result = [[NSString alloc] initWithBytes:bytes + *pos 
                                                        length:sigLen 
                                                      encoding:NSUTF8StringEncoding];
            *pos += sigLen + 1; // Skip null terminator
            return result;
        }
        
        default:
            // Unsupported type - skip it
            NSLog(@"WARNING: Unsupported type '%c' in signature '%@'", typeChar, signature);
            return nil;
    }
}

+ (NSArray *)parseArgumentsFromBodyData:(NSData *)bodyData 
                              signature:(NSString *)signature 
                             endianness:(uint8_t)endianness
{
    if (!signature || [signature length] == 0 || !bodyData || [bodyData length] == 0) {
        return @[];
    }
    
    NSMutableArray *arguments = [NSMutableArray array];
    const uint8_t *bytes = [bodyData bytes];
    NSUInteger maxLen = [bodyData length];
    NSUInteger pos = 0;
    
    // Parse each character in the signature
    for (NSUInteger i = 0; i < [signature length]; i++) {
        unichar typeChar = [signature characterAtIndex:i];
        
        id value = [self parseValueFromBytes:bytes 
                                   maxLength:maxLen 
                                   signature:[NSString stringWithCharacters:&typeChar length:1] 
                                  endianness:endianness 
                               bytesConsumed:&pos];
        
        if (value) {
            [arguments addObject:value];
        } else {
            // If we can't parse a value, stop parsing
            NSLog(@"WARNING: Failed to parse argument %lu of signature '%@'", i, signature);
            break;
        }
        
        if (pos >= maxLen) {
            break; // No more data to parse
        }
    }
    
    return arguments;
}

@end
