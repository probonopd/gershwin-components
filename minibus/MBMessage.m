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
                            [signature appendString:@"v"]; // Variant for other types
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
                    [signature appendString:@"av"]; // Array of variants
                }
            } else {
                [signature appendString:@"as"]; // Empty array defaults to strings
            }
        } else if ([arg isKindOfClass:[NSDictionary class]]) {
            [signature appendString:@"a{sv}"]; // Dictionary as array of string-variant pairs
        } else if ([arg isKindOfClass:[NSNull class]]) {
            [signature appendString:@"v"]; // Null as variant
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
                addPadding(bodyData, 8);
                
                // Serialize key
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
            
            uint32_t actualArrayLength = (uint32_t)([bodyData length] - arrayContentStart);
            [bodyData replaceBytesInRange:NSMakeRange(lengthPosition, 4) withBytes:&actualArrayLength];
        }
    }
    
    return bodyData;
}

+ (void)serializeVariant:(id)value toData:(NSMutableData *)data
{
    if ([value isKindOfClass:[NSString class]]) {
        // String variant
        uint8_t sigLen = 1;
        [data appendBytes:&sigLen length:1];
        uint8_t typeSig = DBUS_TYPE_STRING;
        [data appendBytes:&typeSig length:1];
        uint8_t nullTerm = 0;
        [data appendBytes:&nullTerm length:1];
        
        // String value
        NSString *str = (NSString *)value;
        addPadding(data, 4);
        uint32_t strLen = (uint32_t)[str lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        [data appendBytes:&strLen length:4];
        [data appendData:[str dataUsingEncoding:NSUTF8StringEncoding]];
        [data appendBytes:&nullTerm length:1];
        
    } else if ([value isKindOfClass:[NSNumber class]]) {
        NSNumber *num = (NSNumber *)value;
        const char *objCType = [num objCType];
        
        if (strcmp(objCType, @encode(BOOL)) == 0 || 
            strcmp(objCType, @encode(bool)) == 0) {
            // Boolean variant
            uint8_t sigLen = 1;
            [data appendBytes:&sigLen length:1];
            uint8_t typeSig = DBUS_TYPE_BOOLEAN;
            [data appendBytes:&typeSig length:1];
            uint8_t nullTerm = 0;
            [data appendBytes:&nullTerm length:1];
            
            addPadding(data, 4);
            uint32_t boolVal = [num boolValue] ? 1 : 0;
            [data appendBytes:&boolVal length:4];
            
        } else if (strcmp(objCType, @encode(double)) == 0 ||
                   strcmp(objCType, @encode(float)) == 0) {
            // Double variant
            uint8_t sigLen = 1;
            [data appendBytes:&sigLen length:1];
            uint8_t typeSig = DBUS_TYPE_DOUBLE;
            [data appendBytes:&typeSig length:1];
            uint8_t nullTerm = 0;
            [data appendBytes:&nullTerm length:1];
            
            addPadding(data, 8);
            double doubleVal = [num doubleValue];
            [data appendBytes:&doubleVal length:8];
            
        } else {
            // Default to uint32 variant
            uint8_t sigLen = 1;
            [data appendBytes:&sigLen length:1];
            uint8_t typeSig = DBUS_TYPE_UINT32;
            [data appendBytes:&typeSig length:1];
            uint8_t nullTerm = 0;
            [data appendBytes:&nullTerm length:1];
            
            addPadding(data, 4);
            uint32_t uint32Val = [num unsignedIntValue];
            [data appendBytes:&uint32Val length:4];
        }
        
    } else if ([value isKindOfClass:[NSArray class]]) {
        // Check if this is a struct array
        NSArray *array = (NSArray *)value;
        
        // For variant serialization, treat arrays with mixed types as structs
        BOOL looksLikeStruct = NO;
        if ([array count] > 1) {
            Class firstClass = [[array objectAtIndex:0] class];
            for (NSUInteger i = 1; i < [array count]; i++) {
                if (![[array objectAtIndex:i] isKindOfClass:firstClass]) {
                    looksLikeStruct = YES;
                    break;
                }
            }
        }
        
        if (looksLikeStruct) {
            // Serialize as struct variant - generate signature dynamically
            NSMutableString *structSig = [NSMutableString stringWithString:@"("];
            for (id element in array) {
                if ([element isKindOfClass:[NSString class]]) {
                    [structSig appendString:@"s"];
                } else if ([element isKindOfClass:[NSNumber class]]) {
                    [structSig appendString:@"u"]; // Default to uint32
                } else {
                    [structSig appendString:@"v"]; // Variant for others
                }
            }
            [structSig appendString:@")"];
            
            // Write variant signature
            uint8_t sigLen = (uint8_t)[structSig lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
            [data appendBytes:&sigLen length:1];
            [data appendData:[structSig dataUsingEncoding:NSUTF8StringEncoding]];
            uint8_t nullTerm = 0;
            [data appendBytes:&nullTerm length:1];
            
            // Align to 8 bytes for struct
            addPadding(data, 8);
            
            // Serialize struct fields
            for (id element in array) {
                if ([element isKindOfClass:[NSString class]]) {
                    NSString *str = (NSString *)element;
                    addPadding(data, 4);
                    uint32_t strLen = (uint32_t)[str lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
                    [data appendBytes:&strLen length:4];
                    [data appendData:[str dataUsingEncoding:NSUTF8StringEncoding]];
                    [data appendBytes:&nullTerm length:1];
                    
                } else if ([element isKindOfClass:[NSNumber class]]) {
                    addPadding(data, 4);
                    uint32_t uint32Val = [(NSNumber *)element unsignedIntValue];
                    [data appendBytes:&uint32Val length:4];
                }
            }
        } else {
            // Regular array - serialize as array variant (simplified)
            // For now, just treat as string representation
            NSString *str = [value description];
            uint8_t sigLen = 1;
            [data appendBytes:&sigLen length:1];
            uint8_t typeSig = DBUS_TYPE_STRING;
            [data appendBytes:&typeSig length:1];
            uint8_t nullTerm = 0;
            [data appendBytes:&nullTerm length:1];
            
            addPadding(data, 4);
            uint32_t strLen = (uint32_t)[str lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
            [data appendBytes:&strLen length:4];
            [data appendData:[str dataUsingEncoding:NSUTF8StringEncoding]];
            [data appendBytes:&nullTerm length:1];
        }
        
    } else {
        // Default to string representation
        NSString *str = [value description];
        uint8_t sigLen = 1;
        [data appendBytes:&sigLen length:1];
        uint8_t typeSig = DBUS_TYPE_STRING;
        [data appendBytes:&typeSig length:1];
        uint8_t nullTerm = 0;
        [data appendBytes:&nullTerm length:1];
        
        addPadding(data, 4);
        uint32_t strLen = (uint32_t)[str lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        [data appendBytes:&strLen length:4];
        [data appendData:[str dataUsingEncoding:NSUTF8StringEncoding]];
        [data appendBytes:&nullTerm length:1];
    }
}

// Implement the missing parsing methods

+ (instancetype)messageFromData:(NSData *)data offset:(NSUInteger *)offset
{
    // Basic D-Bus message parsing
    if (!data || [data length] < 16) {
        return nil;
    }
    
    const uint8_t *bytes = [data bytes];
    NSUInteger pos = offset ? *offset : 0;
    
    if (pos + 16 > [data length]) {
        return nil;
    }
    
    // Read fixed header (16 bytes)
    uint8_t endianness = bytes[pos];
    uint8_t messageType = bytes[pos + 1];
    
    // Validate endianness marker first - this is crucial for D-Bus protocol
    if (endianness != DBUS_LITTLE_ENDIAN && endianness != DBUS_BIG_ENDIAN) {
        if (offset) {
            // Don't advance offset for clearly invalid data
            // Let the caller handle the search for next valid message
        }
        return nil;
    }
    
    // Validate message type
    if (messageType < 1 || messageType > 4) {
        return nil;
    }
    
    // Read remaining header fields with proper endianness handling
    // uint8_t flags = bytes[pos + 2];  // Reserved for future use
    uint8_t protocolVersion = bytes[pos + 3];
    
    // Validate protocol version
    if (protocolVersion != 1) {
        return nil;
    }
    
    uint32_t bodyLength = *(uint32_t *)(bytes + pos + 4);
    uint32_t serial = *(uint32_t *)(bytes + pos + 8);
    uint32_t fieldsLength = *(uint32_t *)(bytes + pos + 12);
    
    // Convert from specified endianness to host byte order
    if (endianness == DBUS_LITTLE_ENDIAN) {
        bodyLength = NSSwapLittleIntToHost(bodyLength);
        serial = NSSwapLittleIntToHost(serial);
        fieldsLength = NSSwapLittleIntToHost(fieldsLength);
    } else if (endianness == DBUS_BIG_ENDIAN) {
        bodyLength = NSSwapBigIntToHost(bodyLength);
        serial = NSSwapBigIntToHost(serial);
        fieldsLength = NSSwapBigIntToHost(fieldsLength);
    }
    
    // Validate lengths for sanity - strict bounds to prevent memory exhaustion
    if (fieldsLength > 8192 || bodyLength > 1048576) { // Max 8KB for fields, 1MB for body
        NSLog(@"PARSE FAIL: Message length validation failed - fieldsLength=%u (max 8192), bodyLength=%u (max 1MB)", fieldsLength, bodyLength);
        return nil;
    }
    
    // Additional validation: ensure we're not dealing with clearly corrupted values
    if (fieldsLength > [data length] || bodyLength > [data length]) {
        NSLog(@"PARSE FAIL: Length exceeds buffer - fieldsLength=%u, bodyLength=%u, bufferLength=%lu", fieldsLength, bodyLength, [data length]);
        return nil;
    }
    
    // Validate that fieldsLength is reasonable relative to the buffer position
    if (pos + 16 + fieldsLength > [data length]) {
        NSLog(@"PARSE FAIL: Header fields exceed buffer - pos=%lu, fieldsLength=%u, need %lu, have %lu", pos, fieldsLength, pos + 16 + fieldsLength, [data length]);
        return nil;
    }
    
    // Calculate message length correctly
    NSUInteger headerFieldsEnd = pos + 16 + fieldsLength;
    NSUInteger bodyStart = alignTo(headerFieldsEnd, 8);
    NSUInteger messageLength = (bodyStart - pos) + bodyLength; // Relative to message start
    
    NSLog(@"DEBUG: Body start calculation - pos=%lu, fieldsLength=%u, headerFieldsEnd=%lu, bodyStart=%lu (padding=%lu)", 
          pos, fieldsLength, headerFieldsEnd, bodyStart, bodyStart - headerFieldsEnd);
    
    // Enhanced validation - reject clearly corrupted messages
    if (pos + messageLength > [data length] || messageLength > 2097152) { // Max 2MB total message
        NSLog(@"PARSE FAIL: Total message length invalid - pos=%lu, messageLength=%lu, bufferLength=%lu, max=2MB", pos, messageLength, [data length]);
        return nil;
    }
    
    // Validate that we can fit the complete message in the buffer
    if (bodyStart + bodyLength > [data length]) {
        NSLog(@"PARSE FAIL: Body exceeds buffer - bodyStart=%lu, bodyLength=%u, need %lu, have %lu", bodyStart, bodyLength, bodyStart + bodyLength, [data length]);
        return nil;
    }
    
    // Validate serial number (must be non-zero for valid messages)
    if (serial == 0) {
        NSLog(@"PARSE FAIL: Invalid serial number 0");
        return nil;
    }
    
    // Debug: Enable debugging for specific problematic message
    BOOL debugParsing = (serial == 3 || serial == 2); // Debug specific serials
    
    if (debugParsing || pos > 0) {
        printf("Fixed header at pos %lu: endian=%c type=%u bodyLen=%u serial=%u fieldsLen=%u\n",
               pos, endianness, messageType, bodyLength, serial, fieldsLength);
    }
    
    // Create message object
    MBMessage *message = [[MBMessage alloc] init];
    message.type = messageType;
    message.serial = serial;
    
    if (debugParsing) {
        printf("Parsing message serial %u at offset %lu (total %lu bytes):\n", serial, pos, [data length]);
        for (NSUInteger i = pos; i < MIN(pos + 200, [data length]); i += 16) {
            printf("%04lx: ", i);
            for (NSUInteger j = 0; j < 16 && i + j < [data length]; j++) {
                printf("%02x ", bytes[i + j]);
            }
            printf("\n");
        }
    }
    
    // Parse header fields array
    NSUInteger fieldsPos = pos + 16;
    NSUInteger fieldsEnd = fieldsPos + fieldsLength;
    
    if (debugParsing || pos > 0) {
        printf("Header fields section: %lu to %lu (at pos %lu)\n", fieldsPos, fieldsEnd, pos);
    }
    
    // Header fields are an array of structs: a(yv)
    // Array length is already known (fieldsLength)
    // Each struct element is aligned to 8-byte boundary from start of the message
    while (fieldsPos < fieldsEnd) {
        // Each struct in the array must be 8-byte aligned relative to message start
        NSUInteger posFromMessageStart = fieldsPos - pos;
        NSUInteger alignedPosFromMessageStart = alignTo(posFromMessageStart, 8);
        fieldsPos = pos + alignedPosFromMessageStart;
        
        if (debugParsing || pos > 0) {
            printf("Aligning field: posFromMessageStart=%lu -> alignedPos=%lu, fieldsPos=%lu\n", 
                   posFromMessageStart, alignedPosFromMessageStart, fieldsPos);
        }
        
        if (fieldsPos >= fieldsEnd) break;
        if (fieldsPos + 2 > fieldsEnd) break; // Need at least field code + sig length
        
        uint8_t fieldCode = bytes[fieldsPos];
        fieldsPos += 1;
        
        // Read variant signature length 
        uint8_t sigLen = bytes[fieldsPos];
        fieldsPos += 1;
        
        if (fieldsPos + sigLen + 1 > fieldsEnd) break;
        
        // Read variant signature
        NSString *signature = [[NSString alloc] initWithBytes:(bytes + fieldsPos) 
                                                       length:sigLen 
                                                     encoding:NSUTF8StringEncoding];
        fieldsPos += sigLen + 1; // +1 for null terminator
        
        if (debugParsing || (pos > 0 && (fieldCode > 8 || fieldCode == 0))) {
            printf("Field %u: sig='%s' at fieldsPos %lu (abs %lu, msg pos %lu)\n", 
                   fieldCode, [signature UTF8String], fieldsPos, fieldsPos, pos);
        }
        
        // Parse variant value based on signature
        if ([signature isEqualToString:@"s"] || [signature isEqualToString:@"o"]) {
            // String/ObjectPath: uint32 length + string + null
            // The variant value (uint32 length) should be aligned to 4-byte boundary
            // IMPORTANT: Alignment is relative to the start of the message, not absolute position
            NSUInteger relativePos = fieldsPos - pos;
            NSUInteger alignedRelativePos = alignTo(relativePos, 4);
            fieldsPos = pos + alignedRelativePos;
            
            if (debugParsing || pos > 0) {
                printf("Parsing string field %u: relativePos=%lu, alignedRelativePos=%lu, fieldsPos=%lu\n", 
                       fieldCode, relativePos, alignedRelativePos, fieldsPos);
                if (fieldsPos + 4 <= fieldsEnd) {
                    printf("Reading length from bytes: %02x %02x %02x %02x at position %lu\n",
                           bytes[fieldsPos], bytes[fieldsPos+1], bytes[fieldsPos+2], bytes[fieldsPos+3], fieldsPos);
                }
            }
            
            if (fieldsPos + 4 > fieldsEnd) {
                if (debugParsing || pos > 0) {
                    printf("ERROR: Not enough space for string length at %lu (need 4, have %lu)\n", 
                           fieldsPos, fieldsEnd - fieldsPos);
                }
                [signature release];
                break;
            }
            
            uint32_t strLen = *(uint32_t *)(bytes + fieldsPos);
            if (endianness == DBUS_LITTLE_ENDIAN) {
                strLen = NSSwapLittleIntToHost(strLen);
            } else if (endianness == DBUS_BIG_ENDIAN) {
                strLen = NSSwapBigIntToHost(strLen);
            }
            fieldsPos += 4;
            
            if (debugParsing || pos > 0) {
                printf("String length: %u, remaining space: %lu\n", strLen, fieldsEnd - fieldsPos);
            }
            
            // Impose strict limits on string length to prevent memory exhaustion attacks
            const uint32_t MAX_DBUS_STRING_LENGTH = 65536; // 64KB max for any D-Bus string
            if (strLen > MAX_DBUS_STRING_LENGTH) {
                if (debugParsing || pos > 0) {
                    printf("ERROR: String length %u exceeds maximum allowed (%u), rejecting message\n", 
                           strLen, MAX_DBUS_STRING_LENGTH);
                }
                [signature release];
                [message release];
                return nil;
            }
            
            if (fieldsPos + strLen + 1 > fieldsEnd) {
                if (debugParsing || pos > 0) {
                    printf("ERROR: Not enough space for string data at %lu (need %u+1, have %lu)\n", 
                           fieldsPos, strLen, fieldsEnd - fieldsPos);
                }
                [signature release];
                break;
            }
            
            NSString *value = [[NSString alloc] initWithBytes:(bytes + fieldsPos) 
                                                       length:strLen 
                                                     encoding:NSUTF8StringEncoding];
            fieldsPos += strLen + 1; // +1 for null terminator
            
            if (debugParsing || pos > 0) {
                printf("Parsed field %u value: '%s'\n", fieldCode, [value UTF8String]);
            }
            
            // Set appropriate field
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
                case DBUS_HEADER_FIELD_DESTINATION:
                    message.destination = value;
                    break;
                case DBUS_HEADER_FIELD_SENDER:
                    message.sender = value;
                    break;
                case DBUS_HEADER_FIELD_ERROR_NAME:
                    message.errorName = value;
                    break;
            }
            
            [value release];
            
        } else if ([signature isEqualToString:@"u"]) {
            // uint32 - align to 4-byte boundary relative to message start
            NSUInteger relativePos = fieldsPos - pos;
            NSUInteger alignedRelativePos = alignTo(relativePos, 4);
            fieldsPos = pos + alignedRelativePos;
            
            if (fieldsPos + 4 > fieldsEnd) {
                [signature release];
                break;
            }
            
            uint32_t value = *(uint32_t *)(bytes + fieldsPos);
            if (endianness == DBUS_LITTLE_ENDIAN) {
                value = NSSwapLittleIntToHost(value);
            } else if (endianness == DBUS_BIG_ENDIAN) {
                value = NSSwapBigIntToHost(value);
            }
            fieldsPos += 4;
            
            if (fieldCode == DBUS_HEADER_FIELD_REPLY_SERIAL) {
                message.replySerial = value;
            }
            
        } else if ([signature isEqualToString:@"g"]) {
            // Signature: byte length + signature + null
            if (fieldsPos + 1 > fieldsEnd) {
                [signature release];
                break;
            }
            
            uint8_t sigLen2 = bytes[fieldsPos];
            fieldsPos += 1;
            
            if (fieldsPos + sigLen2 + 1 > fieldsEnd) {
                [signature release];
                break;
            }
            
            NSString *value = [[NSString alloc] initWithBytes:(bytes + fieldsPos) 
                                                       length:sigLen2 
                                                     encoding:NSUTF8StringEncoding];
            fieldsPos += sigLen2 + 1; // +1 for null terminator
            
            if (fieldCode == DBUS_HEADER_FIELD_SIGNATURE) {
                message.signature = value;
            }
            
            [value release];
        }
        
        [signature release];
    }
    
    // Parse message body
    if (bodyLength > 0 && message.signature) {
        NSLog(@"DEBUG: Parsing body for serial %u: pos=%lu, bodyStart=%lu, bodyLength=%u", 
              serial, pos, bodyStart, bodyLength);
        
        // CRITICAL: Validate that bodyStart is within reasonable bounds
        if (bodyStart >= [data length] || bodyStart + bodyLength > [data length]) {
            NSLog(@"ERROR: Body data would exceed buffer bounds (bodyStart=%lu, bodyLength=%u, dataLength=%lu)", 
                  bodyStart, bodyLength, [data length]);
            [message release];
            return nil;
        }
        
        NSData *bodyData = [NSData dataWithBytes:(bytes + bodyStart) length:bodyLength];
        
        // DEBUG: Show message boundary information
        NSLog(@"DEBUG: Message boundaries - messageStart=%lu, headerEnd=%lu, bodyStart=%lu, bodyEnd=%lu", 
              pos, headerFieldsEnd, bodyStart, bodyStart + bodyLength);
        
        // DEBUG: Show the transition area between header and body
        if (headerFieldsEnd < bodyStart) {
            NSUInteger paddingStart = headerFieldsEnd;
            NSUInteger paddingBytes = bodyStart - headerFieldsEnd;
            NSMutableString *paddingHex = [NSMutableString string];
            for (NSUInteger i = 0; i < paddingBytes; i++) {
                [paddingHex appendFormat:@"%02x ", bytes[paddingStart + i]];
            }
            NSLog(@"DEBUG: Padding bytes between header and body (%lu bytes): %@", paddingBytes, paddingHex);
        }
        
        // DEBUG: Log the first few bytes of body data for debugging  
        if (debugParsing || bodyLength <= 50) {
            const uint8_t *bodyBytes = [bodyData bytes];
            NSMutableString *bodyHex = [NSMutableString string];
            for (NSUInteger i = 0; i < MIN(bodyLength, 16); i++) {
                [bodyHex appendFormat:@"%02x ", bodyBytes[i]];
            }
            NSLog(@"DEBUG: Body data (%u bytes) starts: %@", bodyLength, bodyHex);
        }
        
        message.arguments = [self parseArgumentsFromBodyData:bodyData signature:message.signature endianness:endianness];
        
        // If argument parsing failed (resulted in empty array when signature expects arguments), reject the message
        if ([message.arguments count] == 0 && ![message.signature isEqualToString:@""]) {
            NSLog(@"ERROR: Body parsing failed for message with signature '%@' - rejecting message serial %u", 
                  message.signature, serial);
            [message release];
            return nil;
        }
    } else {
        message.arguments = @[];
    }
    
    // Debug: Check if this message has null critical fields (indicates parsing failure)
    if (!message.destination && !message.interface && !message.member) {
        printf("PARSING ERROR - Message serial %lu has all null fields!\n", (unsigned long)message.serial);
        printf("Original position in buffer: %lu\n", pos);
        printf("Fields section: %lu to %lu (length=%u)\n", pos + 16, pos + 16 + fieldsLength, fieldsLength);
        printf("Raw message data:\n");
        for (NSUInteger i = pos; i < MIN(pos + messageLength, [data length]); i += 16) {
            printf("%04lx: ", i);
            for (NSUInteger j = 0; j < 16 && i + j < [data length]; j++) {
                printf("%02x ", bytes[i + j]);
            }
            printf("\n");
        }
        printf("Header: endian=%c type=%u bodyLen=%u serial=%lu fieldsLen=%u\n",
               endianness, messageType, bodyLength, (unsigned long)message.serial, fieldsLength);
        printf("HeaderFieldsEnd=%lu BodyStart=%lu MessageLength=%lu\n", 
               headerFieldsEnd, bodyStart, messageLength);
        
        // Let's manually parse the first header field to debug
        NSUInteger debugPos = pos + 16;
        if (debugPos + 4 < [data length]) {
            printf("First header field bytes: %02x %02x %02x %02x\n", 
                   bytes[debugPos], bytes[debugPos+1], bytes[debugPos+2], bytes[debugPos+3]);
        }
    }
    
    // Skip to next message
    if (offset) {
        *offset = pos + messageLength;
    }
    
    return message;
}

+ (NSArray *)messagesFromData:(NSData *)data consumedBytes:(NSUInteger *)consumedBytes
{
    if (consumedBytes) {
        *consumedBytes = 0;
    }
    
    if (!data || [data length] < 16) {
        // Need at least 16 bytes for a D-Bus header
        return @[];
    }
    
    NSMutableArray *messages = [NSMutableArray array];
    NSUInteger offset = 0;
    const uint8_t *bytes = [data bytes];
    NSUInteger dataLength = [data length];
    
    // ULTRA-VERBOSE DEBUGGING: Show entire buffer on problematic cases
    if (dataLength > 300) {
        NSLog(@"=== VERBOSE MESSAGE PARSING: %lu bytes total ===", dataLength);
        for (NSUInteger i = 0; i < MIN(dataLength, 512); i += 16) {
            NSMutableString *hexLine = [NSMutableString string];
            NSMutableString *asciiLine = [NSMutableString string];
            for (NSUInteger j = 0; j < 16 && i + j < dataLength; j++) {
                uint8_t byte = bytes[i + j];
                [hexLine appendFormat:@"%02x ", byte];
                [asciiLine appendFormat:@"%c", (byte >= 32 && byte < 127) ? byte : '.'];
            }
            NSLog(@"PARSE %04lx: %-48s %@", i, [hexLine UTF8String], asciiLine);
        }
        NSLog(@"=== END VERBOSE DUMP ===");
    }
    
    while (offset < dataLength) {
        NSUInteger messageStart = offset;
        
        // Strict validation: look for valid D-Bus message start
        if (offset + 16 > dataLength) {
            // Not enough data for a complete header
            NSLog(@"PARSE: Not enough data for header at offset %lu (need 16, have %lu)", offset, dataLength - offset);
            break;
        }
        
        // Validate endianness byte
        uint8_t endianness = bytes[offset];
        if (endianness != DBUS_LITTLE_ENDIAN && endianness != DBUS_BIG_ENDIAN) {
            NSLog(@"PARSE: Invalid endianness 0x%02x at offset %lu, searching for valid message", endianness, offset);
            
            // Search for next valid message start within a reasonable range
            BOOL foundValid = NO;
            NSUInteger searchLimit = MIN(offset + 64, dataLength - 16);
            
            for (NSUInteger i = offset + 1; i <= searchLimit; i++) {
                if (bytes[i] == DBUS_LITTLE_ENDIAN || bytes[i] == DBUS_BIG_ENDIAN) {
                    // Found potential endian byte, validate rest of header
                    if (i + 16 <= dataLength) {
                        uint8_t type = bytes[i + 1];
                        uint8_t version = bytes[i + 3];
                        if (type >= 1 && type <= 4 && version == 1) {
                            NSLog(@"PARSE: Found valid D-Bus header at offset %lu (skipped %lu bytes)", i, i - offset);
                            offset = i;
                            foundValid = YES;
                            break;
                        }
                    }
                }
            }
            
            if (!foundValid) {
                NSLog(@"PARSE: No valid D-Bus message found in search range, consuming all remaining data");
                if (consumedBytes) {
                    *consumedBytes = dataLength;
                }
                break;
            }
        }
        
        // Parse the message at current offset
        NSUInteger oldOffset = offset;
        MBMessage *message = [self messageFromData:data offset:&offset];
        
        if (message) {
            [messages addObject:message];
            NSLog(@"PARSE: Successfully parsed message %lu at offset %lu, new offset %lu", 
                  [messages count], messageStart, offset);
        } else {
            // Parsing failed - this is a hard error
            NSLog(@"PARSE: Failed to parse message at offset %lu", oldOffset);
            
            // Show detailed header info for debugging
            if (oldOffset + 16 <= dataLength) {
                uint32_t bodyLength = *(uint32_t *)(bytes + oldOffset + 4);
                uint32_t serial = *(uint32_t *)(bytes + oldOffset + 8);
                uint32_t fieldsLength = *(uint32_t *)(bytes + oldOffset + 12);
                
                // Convert from endianness
                if (bytes[oldOffset] == DBUS_LITTLE_ENDIAN) {
                    bodyLength = NSSwapLittleIntToHost(bodyLength);
                    serial = NSSwapLittleIntToHost(serial);
                    fieldsLength = NSSwapLittleIntToHost(fieldsLength);
                } else {
                    bodyLength = NSSwapBigIntToHost(bodyLength);
                    serial = NSSwapBigIntToHost(serial);
                    fieldsLength = NSSwapBigIntToHost(fieldsLength);
                }
                
                NSLog(@"PARSE: Failed header - endian=%c type=%u version=%u bodyLen=%u serial=%u fieldsLen=%u",
                      bytes[oldOffset], bytes[oldOffset + 1], bytes[oldOffset + 3], 
                      bodyLength, serial, fieldsLength);
                
                // Show raw bytes around the failure point
                NSUInteger dumpStart = (oldOffset > 8) ? oldOffset - 8 : 0;
                NSUInteger dumpEnd = MIN(oldOffset + 32, dataLength);
                NSMutableString *dumpHex = [NSMutableString string];
                for (NSUInteger i = dumpStart; i < dumpEnd; i++) {
                    if (i == oldOffset) {
                        [dumpHex appendFormat:@"[%02x] ", bytes[i]];
                    } else {
                        [dumpHex appendFormat:@"%02x ", bytes[i]];
                    }
                }
                NSLog(@"PARSE: Context bytes: %@", dumpHex);
            }
            
            // Try to advance by 1 byte and continue, but only a few times
            if (offset == oldOffset) {
                offset = oldOffset + 1;
                NSLog(@"PARSE: Advanced by 1 byte to offset %lu to recover", offset);
            }
            
            // Safety check: don't loop forever
            if (offset > oldOffset + 16) {
                NSLog(@"PARSE: Too much advancement, stopping parse to prevent infinite loop");
                break;
            }
        }
        
        // Safety check: ensure we're making progress
        if (offset <= oldOffset) {
            NSLog(@"PARSE: No progress made (offset %lu <= oldOffset %lu), stopping", offset, oldOffset);
            break;
        }
    }
    
    if (consumedBytes) {
        *consumedBytes = offset;
    }
    
    NSLog(@"PARSE: Completed - parsed %lu messages, consumed %lu of %lu bytes", 
          [messages count], offset, dataLength);
    
    return [messages copy];
}

+ (NSArray *)messagesFromData:(NSData *)data
{
    return [self messagesFromData:data consumedBytes:NULL];
}

+ (instancetype)parseFromData:(NSData *)data
{
    return [self messageFromData:data offset:NULL];
}

+ (NSArray *)parseArgumentsFromBodyData:(NSData *)bodyData signature:(NSString *)signature endianness:(uint8_t)endianness
{
    NSLog(@"DEBUG parseArguments: bodyData=%lu bytes, signature='%@', endianness=%u", 
          [bodyData length], signature, endianness);
    
    if (!bodyData || [bodyData length] == 0 || !signature || [signature length] == 0) {
        NSLog(@"DEBUG parseArguments: early return - bodyData=%p length=%lu, signature='%@' length=%lu", 
              bodyData, bodyData ? [bodyData length] : 0, signature ?: @"(null)", signature ? [signature length] : 0);
        return @[];
    }
    
    // Validate bodyData length is reasonable (prevent massive data processing)
    if ([bodyData length] > 1048576) { // Max 1MB body
        NSLog(@"ERROR: Body data too large (%lu bytes), rejecting", [bodyData length]);
        return @[];
    }
    
    // Validate endianness
    if (endianness != DBUS_LITTLE_ENDIAN && endianness != DBUS_BIG_ENDIAN) {
        NSLog(@"ERROR: Invalid endianness %u, rejecting", endianness);
        return @[];
    }
    
    const uint8_t *bytes = [bodyData bytes];
    NSUInteger pos = 0;
    NSMutableArray *arguments = [NSMutableArray array];
    
    // CRITICAL FIX: Handle bodies that start with padding bytes
    // Some D-Bus implementations add extra padding at the start of the body
    // to ensure the first argument is properly aligned
    if ([bodyData length] >= 4 && [signature length] > 0) {
        unichar firstType = [signature characterAtIndex:0];
        
        // Check if we're starting with invalid padding (common issue)
        if (firstType == 's' || firstType == 'o' || firstType == 'g') {
            // String types need 4-byte alignment
            // Check if the first 4 bytes look like a reasonable string length
            uint32_t strLen = *(uint32_t *)(bytes + pos);
            if (endianness == DBUS_LITTLE_ENDIAN) {
                strLen = NSSwapLittleIntToHost(strLen);
            } else {
                strLen = NSSwapBigIntToHost(strLen);
            }
            
            // If string length is unreasonable, try skipping padding bytes
            if (strLen == 0 || strLen > 65536) {
                NSLog(@"DEBUG: First string length %u seems invalid, checking for padding...", strLen);
                
                // Try positions 1, 2, 3 to find the real string length
                for (NSUInteger skipBytes = 1; skipBytes <= 3 && skipBytes < [bodyData length] - 4; skipBytes++) {
                    uint32_t testLen = *(uint32_t *)(bytes + skipBytes);
                    if (endianness == DBUS_LITTLE_ENDIAN) {
                        testLen = NSSwapLittleIntToHost(testLen);
                    } else {
                        testLen = NSSwapBigIntToHost(testLen);
                    }
                    
                    // Check if this looks like a reasonable string length
                    if (testLen > 0 && testLen <= 1024 && skipBytes + 4 + testLen < [bodyData length]) {
                        NSLog(@"DEBUG: Found reasonable string length %u at offset %lu, skipping %lu padding bytes", 
                              testLen, skipBytes, skipBytes);
                        pos = skipBytes;
                        break;
                    }
                }
            }
        }
    }
    
    // Parse each signature character
    for (NSUInteger i = 0; i < [signature length]; i++) {
        unichar typeChar = [signature characterAtIndex:i];
        NSLog(@"DEBUG parseArguments: parsing type '%c' at pos %lu (signature index %lu)", typeChar, pos, i);
        
        if (typeChar == 's') {
            // String - if we haven't already handled padding, align to 4-byte boundary
            // (The initial padding detection may have already positioned us correctly)
            if (pos == 0) {
                pos = alignTo(pos, 4);
            }
            
            if (pos + 4 > [bodyData length]) break;
            
            uint32_t strLen = *(uint32_t *)(bytes + pos);
            NSLog(@"DEBUG parseArguments: at pos %lu, remaining buffer: %lu bytes", pos, [bodyData length] - pos);
            
            // Apply correct endianness conversion based on message header
            // Note: NSSwapLittleIntToHost converts FROM little endian TO host
            // NSSwapBigIntToHost converts FROM big endian TO host
            if (endianness == DBUS_LITTLE_ENDIAN) {
                strLen = NSSwapLittleIntToHost(strLen);
            } else if (endianness == DBUS_BIG_ENDIAN) {
                strLen = NSSwapBigIntToHost(strLen);
            }
            
            NSLog(@"DEBUG parseArguments: raw strLen bytes: %02x %02x %02x %02x, converted: %u (endianness=%c)", 
                  bytes[pos], bytes[pos+1], bytes[pos+2], bytes[pos+3], strLen, endianness);
            
            // Show context around this position
            NSUInteger contextStart = (pos > 8) ? pos - 8 : 0;
            NSUInteger contextEnd = MIN(pos + 16, [bodyData length]);
            NSMutableString *contextHex = [NSMutableString string];
            for (NSUInteger i = contextStart; i < contextEnd; i++) {
                if (i == pos) {
                    [contextHex appendFormat:@"[%02x] ", bytes[i]];
                } else {
                    [contextHex appendFormat:@"%02x ", bytes[i]];
                }
            }
            NSLog(@"DEBUG parseArguments: context around pos %lu: %@", pos, contextHex);
            
            pos += 4;
            
            // Impose strict limits on string length to prevent memory exhaustion
            const uint32_t MAX_DBUS_STRING_LENGTH = 65536; // 64KB max for any D-Bus string
            if (strLen > MAX_DBUS_STRING_LENGTH) {
                NSLog(@"ERROR: Argument string length %u exceeds maximum allowed (%u), truncating", 
                      strLen, MAX_DBUS_STRING_LENGTH);
                break; // Skip rest of arguments to prevent memory issues
            }
            
            // Additional validation: ensure string length doesn't exceed remaining buffer
            if (strLen > [bodyData length] - pos) {
                NSLog(@"ERROR: String length %u exceeds remaining buffer (%lu), truncating", 
                      strLen, [bodyData length] - pos);
                break;
            }
            
            if (pos + strLen + 1 > [bodyData length]) break;
            
            NSString *value = nil;
            if (strLen == 0) {
                // Zero-length string - create empty string explicitly
                value = @"";
                NSLog(@"DEBUG parseArguments: created empty string for zero length");
            } else {
                value = [[NSString alloc] initWithBytes:(bytes + pos) 
                                                 length:strLen 
                                               encoding:NSUTF8StringEncoding];
            }
            
            NSLog(@"DEBUG parseArguments: string value='%@' (nil=%d)", value ?: @"(null)", value == nil);
            if (value) {
                @try {
                    [arguments addObject:value];
                    NSLog(@"DEBUG parseArguments: successfully added string to array");
                } @catch (NSException *e) {
                    NSLog(@"ERROR parseArguments: exception adding string to array: %@", e);
                    @throw e;
                }
                if (strLen > 0) [value release]; // Only release if we allocated it
            } else {
                // Invalid UTF-8, use a placeholder but log the issue
                NSLog(@"WARNING: Invalid UTF-8 string at pos %lu, length %u in body", pos, strLen);
                @try {
                    [arguments addObject:@"<invalid-utf8>"];
                    NSLog(@"DEBUG parseArguments: successfully added invalid-utf8 placeholder");
                } @catch (NSException *e) {
                    NSLog(@"ERROR parseArguments: exception adding invalid-utf8 placeholder: %@", e);
                    @throw e;
                }
            }
            pos += strLen + 1; // +1 for null terminator
            
        } else if (typeChar == 'u') {
            // uint32 - align to 4-byte boundary
            pos = alignTo(pos, 4);
            
            if (pos + 4 > [bodyData length]) break;
            
            uint32_t value = *(uint32_t *)(bytes + pos);
            
            // Apply correct endianness conversion
            if (endianness == DBUS_LITTLE_ENDIAN) {
                value = NSSwapLittleIntToHost(value);
            } else if (endianness == DBUS_BIG_ENDIAN) {
                value = NSSwapBigIntToHost(value);
            }
            
            NSLog(@"DEBUG parseArguments: uint32 value=%u", value);
            @try {
                [arguments addObject:@(value)];
                NSLog(@"DEBUG parseArguments: successfully added uint32 to array");
            } @catch (NSException *e) {
                NSLog(@"ERROR parseArguments: exception adding uint32 to array: %@", e);
                @throw e;
            }
            pos += 4;
            
        } else if (typeChar == 'i') {
            // int32 - align to 4-byte boundary
            pos = alignTo(pos, 4);
            
            if (pos + 4 > [bodyData length]) break;
            
            int32_t value = *(int32_t *)(bytes + pos);
            
            // Apply correct endianness conversion
            if (endianness == DBUS_LITTLE_ENDIAN) {
                value = NSSwapLittleIntToHost(value);
            } else if (endianness == DBUS_BIG_ENDIAN) {
                value = NSSwapBigIntToHost(value);
            }
            [arguments addObject:@(value)];
            pos += 4;
            
        } else if (typeChar == 'a') {
            // Array - align to 4-byte boundary for array length
            pos = alignTo(pos, 4);
            
            if (pos + 4 > [bodyData length]) break;
            
            uint32_t arrayLen = *(uint32_t *)(bytes + pos);
            
            // Apply correct endianness conversion
            if (endianness == DBUS_LITTLE_ENDIAN) {
                arrayLen = NSSwapLittleIntToHost(arrayLen);
            } else if (endianness == DBUS_BIG_ENDIAN) {
                arrayLen = NSSwapBigIntToHost(arrayLen);
            }
            
            pos += 4;
            
            NSLog(@"DEBUG parseArguments: array length=%u at pos %lu", arrayLen, pos);
            
            // Validate array length to prevent memory exhaustion
            if (arrayLen > 65536) { // Max 64KB for arrays
                NSLog(@"ERROR: Array length %u exceeds maximum allowed (65536), skipping", arrayLen);
                break;
            }
            
            if (pos + arrayLen > [bodyData length]) {
                NSLog(@"ERROR: Array data exceeds buffer bounds, skipping");
                break;
            }
            
            // Parse complex array types including a{sv}
            if (i + 1 < [signature length]) {
                unichar elementType = [signature characterAtIndex:i + 1];
                NSLog(@"DEBUG parseArguments: array element type='%c'", elementType);
                
                if (elementType == 's') {
                    // Array of strings
                    NSMutableArray *stringArray = [NSMutableArray array];
                    NSUInteger arrayEnd = pos + arrayLen;
                    
                    while (pos < arrayEnd) {
                        pos = alignTo(pos, 4);
                        if (pos + 4 > arrayEnd) break;
                        
                        uint32_t strLen = *(uint32_t *)(bytes + pos);
                        if (endianness == DBUS_LITTLE_ENDIAN) {
                            strLen = NSSwapLittleIntToHost(strLen);
                        } else if (endianness == DBUS_BIG_ENDIAN) {
                            strLen = NSSwapBigIntToHost(strLen);
                        }
                        pos += 4;
                        
                        if (pos + strLen + 1 > arrayEnd) break;
                        
                        NSString *str = [[NSString alloc] initWithBytes:(bytes + pos)
                                                                 length:strLen
                                                               encoding:NSUTF8StringEncoding];
                        if (str) {
                            [stringArray addObject:str];
                            [str release];
                        }
                        pos += strLen + 1;
                    }
                    
                    [arguments addObject:stringArray];
                    i++; // Skip element type
                    
                } else if (elementType == '{') {
                    // Dictionary array a{...} - parse as array of dictionaries
                    NSMutableArray *dictArray = [NSMutableArray array];
                    NSUInteger arrayEnd = pos + arrayLen;
                    
                    // Find the complete signature for the dictionary entry
                    NSUInteger dictStart = i + 2;
                    NSUInteger dictEnd = dictStart;
                    NSUInteger braceCount = 1;
                    while (dictEnd < [signature length] && braceCount > 0) {
                        unichar c = [signature characterAtIndex:dictEnd];
                        if (c == '{') braceCount++;
                        else if (c == '}') braceCount--;
                        dictEnd++;
                    }
                    
                    if (braceCount == 0 && dictEnd > dictStart) {
                        NSString *dictSig = [signature substringWithRange:NSMakeRange(dictStart, dictEnd - dictStart - 1)];
                        NSLog(@"DEBUG parseArguments: dictionary signature='%@'", dictSig);
                        
                        // Parse each dictionary entry (8-byte aligned)
                        while (pos < arrayEnd) {
                            pos = alignTo(pos, 8); // Dictionary entries are 8-byte aligned
                            if (pos >= arrayEnd) break;
                            
                            NSMutableDictionary *dictEntry = [NSMutableDictionary dictionary];
                            
                            // Parse dictionary entry based on signature
                            if ([dictSig hasPrefix:@"sv"]) {
                                // String key, variant value
                                pos = alignTo(pos, 4);
                                if (pos + 4 > arrayEnd) break;
                                
                                uint32_t keyLen = *(uint32_t *)(bytes + pos);
                                if (endianness == DBUS_LITTLE_ENDIAN) {
                                    keyLen = NSSwapLittleIntToHost(keyLen);
                                } else {
                                    keyLen = NSSwapBigIntToHost(keyLen);
                                }
                                pos += 4;
                                
                                if (pos + keyLen + 1 > arrayEnd) break;
                                
                                NSString *key = [[NSString alloc] initWithBytes:(bytes + pos)
                                                                         length:keyLen
                                                                       encoding:NSUTF8StringEncoding];
                                pos += keyLen + 1;
                                
                                // Parse variant value
                                if (pos + 1 > arrayEnd) {
                                    [key release];
                                    break;
                                }
                                
                                uint8_t varSigLen = bytes[pos];
                                pos += 1;
                                
                                if (pos + varSigLen + 1 > arrayEnd) {
                                    [key release];
                                    break;
                                }
                                
                                NSString *varSig = [[NSString alloc] initWithBytes:(bytes + pos)
                                                                            length:varSigLen
                                                                          encoding:NSUTF8StringEncoding];
                                pos += varSigLen + 1;
                                
                                // Parse the variant value based on its signature
                                id value = [self parseVariantValue:bytes + pos
                                                            maxLen:arrayEnd - pos
                                                         signature:varSig
                                                        endianness:endianness
                                                      bytesConsumed:&pos];
                                
                                if (key && value) {
                                    [dictEntry setObject:value forKey:key];
                                }
                                
                                [key release];
                                [varSig release];
                            }
                            
                            if ([dictEntry count] > 0) {
                                [dictArray addObject:dictEntry];
                            }
                        }
                        
                        [arguments addObject:dictArray];
                        i = dictEnd - 1; // Will be incremented by main loop
                    } else {
                        // Malformed dictionary signature
                        [arguments addObject:@[]];
                        pos += arrayLen;
                        i = dictEnd - 1;
                    }
                    
                } else {
                    // Other array types - create placeholder
                    NSLog(@"DEBUG parseArguments: unsupported array element type '%c', creating placeholder", elementType);
                    [arguments addObject:@[]];
                    pos += arrayLen;
                    i++; // Skip element type
                }
            } else {
                // Malformed signature
                NSLog(@"ERROR: Array type 'a' not followed by element type in signature");
                break;
            }
            
        } else if (typeChar == 'v') {
            // Variant - signature length + signature + value
            if (pos + 1 > [bodyData length]) break;
            
            uint8_t varSigLen = bytes[pos];
            pos += 1;
            
            if (pos + varSigLen + 1 > [bodyData length]) break;
            
            NSString *varSig = [[NSString alloc] initWithBytes:(bytes + pos)
                                                        length:varSigLen
                                                      encoding:NSUTF8StringEncoding];
            pos += varSigLen + 1; // +1 for null terminator
            
            NSLog(@"DEBUG parseArguments: variant signature='%@'", varSig);
            
            // Parse the variant value
            id value = [self parseVariantValue:bytes + pos
                                       maxLen:[bodyData length] - pos
                                    signature:varSig
                                   endianness:endianness
                                 bytesConsumed:&pos];
            
            if (value) {
                [arguments addObject:value];
            } else {
                [arguments addObject:[NSNull null]];
            }
            
            [varSig release];
            
        } else if (typeChar == 'b') {
            // Boolean - align to 4-byte boundary, stored as uint32
            pos = alignTo(pos, 4);
            
            if (pos + 4 > [bodyData length]) break;
            
            uint32_t boolVal = *(uint32_t *)(bytes + pos);
            if (endianness == DBUS_LITTLE_ENDIAN) {
                boolVal = NSSwapLittleIntToHost(boolVal);
            } else if (endianness == DBUS_BIG_ENDIAN) {
                boolVal = NSSwapBigIntToHost(boolVal);
            }
            
            [arguments addObject:@(boolVal != 0)];
            pos += 4;
            
        } else if (typeChar == 'y') {
            // Byte - no alignment needed
            if (pos + 1 > [bodyData length]) break;
            
            uint8_t byteVal = bytes[pos];
            [arguments addObject:@(byteVal)];
            pos += 1;
            
        } else if (typeChar == 'n') {
            // int16 - align to 2-byte boundary
            pos = alignTo(pos, 2);
            
            if (pos + 2 > [bodyData length]) break;
            
            int16_t int16Val = *(int16_t *)(bytes + pos);
            if (endianness == DBUS_LITTLE_ENDIAN) {
                int16Val = NSSwapLittleShortToHost(int16Val);
            } else if (endianness == DBUS_BIG_ENDIAN) {
                int16Val = NSSwapBigShortToHost(int16Val);
            }
            
            [arguments addObject:@(int16Val)];
            pos += 2;
            
        } else if (typeChar == 'q') {
            // uint16 - align to 2-byte boundary
            pos = alignTo(pos, 2);
            
            if (pos + 2 > [bodyData length]) break;
            
            uint16_t uint16Val = *(uint16_t *)(bytes + pos);
            if (endianness == DBUS_LITTLE_ENDIAN) {
                uint16Val = NSSwapLittleShortToHost(uint16Val);
            } else if (endianness == DBUS_BIG_ENDIAN) {
                uint16Val = NSSwapBigShortToHost(uint16Val);
            }
            
            [arguments addObject:@(uint16Val)];
            pos += 2;
            
        } else if (typeChar == 'x') {
            // int64 - align to 8-byte boundary
            pos = alignTo(pos, 8);
            
            if (pos + 8 > [bodyData length]) break;
            
            int64_t int64Val = *(int64_t *)(bytes + pos);
            if (endianness == DBUS_LITTLE_ENDIAN) {
                int64Val = NSSwapLittleLongLongToHost(int64Val);
            } else if (endianness == DBUS_BIG_ENDIAN) {
                int64Val = NSSwapBigLongLongToHost(int64Val);
            }
            
            [arguments addObject:@(int64Val)];
            pos += 8;
            
        } else if (typeChar == 't') {
            // uint64 - align to 8-byte boundary
            pos = alignTo(pos, 8);
            
            if (pos + 8 > [bodyData length]) break;
            
            uint64_t uint64Val = *(uint64_t *)(bytes + pos);
            if (endianness == DBUS_LITTLE_ENDIAN) {
                uint64Val = NSSwapLittleLongLongToHost(uint64Val);
            } else if (endianness == DBUS_BIG_ENDIAN) {
                uint64Val = NSSwapBigLongLongToHost(uint64Val);
            }
            
            [arguments addObject:@(uint64Val)];
            pos += 8;
            
        } else if (typeChar == 'd') {
            // double - align to 8-byte boundary
            pos = alignTo(pos, 8);
            
            if (pos + 8 > [bodyData length]) break;
            
            uint64_t rawDouble = *(uint64_t *)(bytes + pos);
            if (endianness == DBUS_LITTLE_ENDIAN) {
                rawDouble = NSSwapLittleLongLongToHost(rawDouble);
            } else if (endianness == DBUS_BIG_ENDIAN) {
                rawDouble = NSSwapBigLongLongToHost(rawDouble);
            }
            
            double doubleVal;
            memcpy(&doubleVal, &rawDouble, sizeof(double));
            [arguments addObject:@(doubleVal)];
            pos += 8;
            
        } else if (typeChar == 'o') {
            // Object path - same as string but with validation
            pos = alignTo(pos, 4);
            
            if (pos + 4 > [bodyData length]) break;
            
            uint32_t strLen = *(uint32_t *)(bytes + pos);
            if (endianness == DBUS_LITTLE_ENDIAN) {
                strLen = NSSwapLittleIntToHost(strLen);
            } else if (endianness == DBUS_BIG_ENDIAN) {
                strLen = NSSwapBigIntToHost(strLen);
            }
            
            pos += 4;
            
            if (strLen > 65536) {
                NSLog(@"ERROR: Object path length %u exceeds maximum", strLen);
                break;
            }
            
            if (pos + strLen + 1 > [bodyData length]) break;
            
            NSString *objectPath = [[NSString alloc] initWithBytes:(bytes + pos)
                                                            length:strLen
                                                          encoding:NSUTF8StringEncoding];
            if (objectPath) {
                [arguments addObject:objectPath];
                [objectPath release];
            } else {
                [arguments addObject:@"<invalid-object-path>"];
            }
            pos += strLen + 1;
            
        } else if (typeChar == '(') {
            // STRUCT - starts with '(' and ends with ')' - align to 8-byte boundary
            pos = alignTo(pos, 8);
            
            NSLog(@"DEBUG parseArguments: parsing STRUCT starting at pos %lu", pos);
            
            // Find the matching closing parenthesis
            NSUInteger structStart = i + 1;
            NSUInteger structEnd = structStart;
            NSUInteger parenCount = 1;
            while (structEnd < [signature length] && parenCount > 0) {
                unichar c = [signature characterAtIndex:structEnd];
                if (c == '(') parenCount++;
                else if (c == ')') parenCount--;
                structEnd++;
            }
            
            if (parenCount == 0 && structEnd > structStart) {
                NSString *structSig = [signature substringWithRange:NSMakeRange(structStart, structEnd - structStart - 1)];
                NSLog(@"DEBUG parseArguments: struct signature='%@'", structSig);
                
                // Parse the struct fields recursively
                // NSUInteger structStartPos = pos;  // Reserved for debugging
                NSMutableArray *structFields = [NSMutableArray array];
                
                for (NSUInteger j = 0; j < [structSig length]; j++) {
                    unichar fieldType = [structSig characterAtIndex:j];
                    
                    // Parse each field according to its type
                    id fieldValue = nil;
                    
                    if (fieldType == 's') {
                        // String field
                        pos = alignTo(pos, 4);
                        if (pos + 4 > [bodyData length]) break;
                        
                        uint32_t strLen = *(uint32_t *)(bytes + pos);
                        if (endianness == DBUS_LITTLE_ENDIAN) {
                            strLen = NSSwapLittleIntToHost(strLen);
                        } else if (endianness == DBUS_BIG_ENDIAN) {
                            strLen = NSSwapBigIntToHost(strLen);
                        }
                        pos += 4;
                        
                        if (strLen <= 65536 && pos + strLen + 1 <= [bodyData length]) {
                            fieldValue = [[NSString alloc] initWithBytes:(bytes + pos)
                                                                  length:strLen
                                                                encoding:NSUTF8StringEncoding];
                            pos += strLen + 1;
                            if (fieldValue) {
                                [structFields addObject:fieldValue];
                                [fieldValue release];
                            } else {
                                [structFields addObject:@"<invalid-utf8>"];
                            }
                        }
                        
                    } else if (fieldType == 'u') {
                        // uint32 field
                        pos = alignTo(pos, 4);
                        if (pos + 4 <= [bodyData length]) {
                            uint32_t value = *(uint32_t *)(bytes + pos);
                            if (endianness == DBUS_LITTLE_ENDIAN) {
                                value = NSSwapLittleIntToHost(value);
                            } else if (endianness == DBUS_BIG_ENDIAN) {
                                value = NSSwapBigIntToHost(value);
                            }
                            [structFields addObject:@(value)];
                            pos += 4;
                        }
                        
                    } else if (fieldType == 'i') {
                        // int32 field
                        pos = alignTo(pos, 4);
                        if (pos + 4 <= [bodyData length]) {
                            int32_t value = *(int32_t *)(bytes + pos);
                            if (endianness == DBUS_LITTLE_ENDIAN) {
                                value = NSSwapLittleIntToHost(value);
                            } else if (endianness == DBUS_BIG_ENDIAN) {
                                value = NSSwapBigIntToHost(value);
                            }
                            [structFields addObject:@(value)];
                            pos += 4;
                        }
                        
                    } else if (fieldType == 'b') {
                        // boolean field
                        pos = alignTo(pos, 4);
                        if (pos + 4 <= [bodyData length]) {
                            uint32_t boolVal = *(uint32_t *)(bytes + pos);
                            if (endianness == DBUS_LITTLE_ENDIAN) {
                                boolVal = NSSwapLittleIntToHost(boolVal);
                            } else if (endianness == DBUS_BIG_ENDIAN) {
                                boolVal = NSSwapBigIntToHost(boolVal);
                            }
                            [structFields addObject:@(boolVal != 0)];
                            pos += 4;
                        }
                        
                    } else {
                        // Other types - add placeholder for now
                        NSLog(@"DEBUG parseArguments: unsupported struct field type '%c'", fieldType);
                        [structFields addObject:[NSNull null]];
                    }
                }
                
                NSLog(@"DEBUG parseArguments: parsed struct with %lu fields", [structFields count]);
                [arguments addObject:structFields];
                i = structEnd - 1; // Will be incremented by main loop
            } else {
                // Malformed struct signature
                NSLog(@"ERROR: Malformed struct signature starting at position %lu", i);
                [arguments addObject:@[]];
            }
            
        } else {
            // Unknown type, skip
            NSLog(@"DEBUG parseArguments: unknown type '%c', stopping parse", typeChar);
            break;
        }
    }
    
    return [arguments copy];
}

// Backwards-compatible method that assumes little-endian (for existing code)
+ (NSArray *)parseArgumentsFromBodyData:(NSData *)bodyData signature:(NSString *)signature
{
    return [self parseArgumentsFromBodyData:bodyData signature:signature endianness:DBUS_LITTLE_ENDIAN];
}

+ (id)parseVariantValue:(const uint8_t *)bytes 
                maxLen:(NSUInteger)maxLen
             signature:(NSString *)signature
            endianness:(uint8_t)endianness
         bytesConsumed:(NSUInteger *)pos
{
    if (!signature || [signature length] == 0 || !bytes || maxLen == 0) {
        return nil;
    }
    
    // NSUInteger originalPos = *pos;  // Reserved for debugging
    unichar typeChar = [signature characterAtIndex:0];
    
    switch (typeChar) {
        case 's': {
            // String
            *pos = alignTo(*pos, 4);
            if (*pos + 4 > maxLen) return nil;
            
            uint32_t strLen = *(uint32_t *)(bytes + *pos);
            if (endianness == DBUS_LITTLE_ENDIAN) {
                strLen = NSSwapLittleIntToHost(strLen);
            } else if (endianness == DBUS_BIG_ENDIAN) {
                strLen = NSSwapBigIntToHost(strLen);
            }
            *pos += 4;
            
            if (strLen > 65536 || *pos + strLen + 1 > maxLen) return nil;
            
            NSString *str = [[NSString alloc] initWithBytes:(bytes + *pos)
                                                     length:strLen
                                                   encoding:NSUTF8StringEncoding];
            *pos += strLen + 1;
            return [str autorelease];
        }
        
        case 'u': {
            // uint32
            *pos = alignTo(*pos, 4);
            if (*pos + 4 > maxLen) return nil;
            
            uint32_t value = *(uint32_t *)(bytes + *pos);
            if (endianness == DBUS_LITTLE_ENDIAN) {
                value = NSSwapLittleIntToHost(value);
            } else if (endianness == DBUS_BIG_ENDIAN) {
                value = NSSwapBigIntToHost(value);
            }
            *pos += 4;
            return @(value);
        }
        
        case 'i': {
            // int32
            *pos = alignTo(*pos, 4);
            if (*pos + 4 > maxLen) return nil;
            
            int32_t value = *(int32_t *)(bytes + *pos);
            if (endianness == DBUS_LITTLE_ENDIAN) {
                value = NSSwapLittleIntToHost(value);
            } else if (endianness == DBUS_BIG_ENDIAN) {
                value = NSSwapBigIntToHost(value);
            }
            *pos += 4;
            return @(value);
        }
        
        case 'b': {
            // Boolean
            *pos = alignTo(*pos, 4);
            if (*pos + 4 > maxLen) return nil;
            
            uint32_t boolVal = *(uint32_t *)(bytes + *pos);
            if (endianness == DBUS_LITTLE_ENDIAN) {
                boolVal = NSSwapLittleIntToHost(boolVal);
            } else if (endianness == DBUS_BIG_ENDIAN) {
                boolVal = NSSwapBigIntToHost(boolVal);
            }
            *pos += 4;
            return @(boolVal != 0);
        }
        
        case 'y': {
            // Byte
            if (*pos + 1 > maxLen) return nil;
            uint8_t byteVal = bytes[*pos];
            *pos += 1;
            return @(byteVal);
        }
        
        case 'd': {
            // Double
            *pos = alignTo(*pos, 8);
            if (*pos + 8 > maxLen) return nil;
            
            uint64_t rawDouble = *(uint64_t *)(bytes + *pos);
            if (endianness == DBUS_LITTLE_ENDIAN) {
                rawDouble = NSSwapLittleLongLongToHost(rawDouble);
            } else if (endianness == DBUS_BIG_ENDIAN) {
                rawDouble = NSSwapBigLongLongToHost(rawDouble);
            }
            
            double doubleVal;
            memcpy(&doubleVal, &rawDouble, sizeof(double));
            *pos += 8;
            return @(doubleVal);
        }
        
        case 'o': {
            // Object path (same as string)
            *pos = alignTo(*pos, 4);
            if (*pos + 4 > maxLen) return nil;
            
            uint32_t strLen = *(uint32_t *)(bytes + *pos);
            if (endianness == DBUS_LITTLE_ENDIAN) {
                strLen = NSSwapLittleIntToHost(strLen);
            } else if (endianness == DBUS_BIG_ENDIAN) {
                strLen = NSSwapBigIntToHost(strLen);
            }
            *pos += 4;
            
            if (strLen > 65536 || *pos + strLen + 1 > maxLen) return nil;
            
            NSString *str = [[NSString alloc] initWithBytes:(bytes + *pos)
                                                     length:strLen
                                                   encoding:NSUTF8StringEncoding];
            *pos += strLen + 1;
            return [str autorelease];
        }
        
        case 'r': {
            // STRUCT - parse according to D-Bus spec, aligned to 8-byte boundary
            *pos = alignTo(*pos, 8);
            
            // For a struct in a variant, we need to parse it as a complete signature
            // Since we only have the 'r' type, we'll create a generic struct placeholder
            NSMutableArray *structArray = [NSMutableArray array];
            
            // Parse as a simple struct with basic fields - in real usage, 
            // the signature would specify the complete struct signature
            // For now, return an empty array to indicate a struct
            NSLog(@"DEBUG: STRUCT type 'r' encountered in variant, creating placeholder");
            return structArray;
        }
        
        default:
            // Unsupported variant type - skip and return placeholder
            NSLog(@"WARNING: Unsupported variant type '%c', returning null", typeChar);
            return [NSNull null];
    }
}

@end
