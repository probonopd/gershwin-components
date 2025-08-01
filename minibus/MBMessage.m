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
    uint8_t flags = bytes[pos + 2];
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
    
    // Validate lengths for sanity - more strict bounds
    if (fieldsLength > 32768 || bodyLength > 16777216) { // Max 32KB for fields, 16MB for body
        return nil;
    }
    
    // Validate serial number (must be non-zero for valid messages)
    if (serial == 0) {
        return nil;
    }
    
    // Debug: Enable debugging for specific problematic message
    BOOL debugParsing = (serial == 3 || serial == 2); // Debug specific serials
    
    if (debugParsing || pos > 0) {
        printf("Fixed header at pos %lu: endian=%c type=%u bodyLen=%u serial=%u fieldsLen=%u\n",
               pos, endianness, messageType, bodyLength, serial, fieldsLength);
    }
    
    // Calculate total message length
    NSUInteger headerFieldsEnd = pos + 16 + fieldsLength;
    NSUInteger bodyStart = alignTo(headerFieldsEnd, 8);
    NSUInteger totalLength = bodyStart + bodyLength;
    
    if (totalLength > [data length]) {
        return nil;
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
        NSData *bodyData = [NSData dataWithBytes:(bytes + bodyStart) length:bodyLength];
        message.arguments = [self parseArgumentsFromBodyData:bodyData signature:message.signature];
    } else {
        message.arguments = @[];
    }
    
    // Debug: Check if this message has null critical fields (indicates parsing failure)
    if (!message.destination && !message.interface && !message.member) {
        printf("PARSING ERROR - Message serial %lu has all null fields!\n", (unsigned long)message.serial);
        printf("Original position in buffer: %lu\n", pos);
        printf("Fields section: %lu to %lu (length=%u)\n", pos + 16, pos + 16 + fieldsLength, fieldsLength);
        printf("Raw message data:\n");
        for (NSUInteger i = pos; i < MIN(pos + totalLength, [data length]); i += 16) {
            printf("%04lx: ", i);
            for (NSUInteger j = 0; j < 16 && i + j < [data length]; j++) {
                printf("%02x ", bytes[i + j]);
            }
            printf("\n");
        }
        printf("Header: endian=%c type=%u bodyLen=%u serial=%lu fieldsLen=%u\n",
               endianness, messageType, bodyLength, (unsigned long)message.serial, fieldsLength);
        printf("HeaderFieldsEnd=%lu BodyStart=%lu TotalLength=%lu\n", 
               headerFieldsEnd, bodyStart, totalLength);
        
        // Let's manually parse the first header field to debug
        NSUInteger debugPos = pos + 16;
        if (debugPos + 4 < [data length]) {
            printf("First header field bytes: %02x %02x %02x %02x\n", 
                   bytes[debugPos], bytes[debugPos+1], bytes[debugPos+2], bytes[debugPos+3]);
        }
    }
    
    // Skip to next message
    if (offset) {
        *offset = pos + totalLength;
    }
    
    return message;
}

+ (NSArray *)messagesFromData:(NSData *)data consumedBytes:(NSUInteger *)consumedBytes
{
    NSMutableArray *messages = [NSMutableArray array];
    NSUInteger offset = 0;
    NSUInteger lastSuccessfulOffset = 0;
    NSUInteger consecutiveFailures = 0;
    const NSUInteger MAX_CONSECUTIVE_FAILURES = 16; // Reduced limit
    const NSUInteger MAX_SKIP_BYTES = 512; // Don't skip more than 512 bytes total
    NSUInteger totalSkippedBytes = 0;
    
    while (offset < [data length]) {
        NSUInteger oldOffset = offset;
        MBMessage *message = [self messageFromData:data offset:&offset];
        if (!message) {
            consecutiveFailures++;
            
            // Check if we have enough data for a complete message
            if (oldOffset + 16 <= [data length]) {
                // We have at least a header, but parsing failed
                // If we've had too many consecutive failures, stop trying
                if (consecutiveFailures > MAX_CONSECUTIVE_FAILURES || totalSkippedBytes >= MAX_SKIP_BYTES) {
                    NSLog(@"Too many consecutive parsing failures (%lu) or bytes skipped (%lu), discarding buffer", 
                          consecutiveFailures, totalSkippedBytes);
                    // Clear the entire buffer to prevent infinite loops
                    if (consumedBytes) {
                        *consumedBytes = [data length];
                    }
                    break;
                }
                
                // Look for next potential D-Bus message start (endian byte)
                const uint8_t *bytes = [data bytes];
                NSUInteger searchOffset = oldOffset + 1;
                BOOL foundValidStart = NO;
                
                while (searchOffset < [data length] && (searchOffset - oldOffset) < 64) {
                    if (bytes[searchOffset] == DBUS_LITTLE_ENDIAN || bytes[searchOffset] == DBUS_BIG_ENDIAN) {
                        // Found potential start, check if it looks like a valid header
                        if (searchOffset + 4 < [data length]) {
                            uint8_t type = bytes[searchOffset + 1];
                            uint8_t version = bytes[searchOffset + 3];
                            if (type >= 1 && type <= 4 && version == 1) {
                                foundValidStart = YES;
                                NSLog(@"Found potential D-Bus message at offset %lu (skipped %lu bytes)", 
                                      searchOffset, searchOffset - oldOffset);
                                offset = searchOffset;
                                totalSkippedBytes += (searchOffset - oldOffset);
                                break;
                            }
                        }
                    }
                    searchOffset++;
                }
                
                if (!foundValidStart) {
                    // This means the data is corrupted, skip ahead by 1 byte and try again
                    NSLog(@"Failed to parse message at offset %lu, skipping 1 byte", oldOffset);
                    offset = oldOffset + 1;
                    totalSkippedBytes++;
                    continue;
                }
            } else {
                // Not enough data for a complete header, wait for more data
                break;
            }
        }
        
        // Successfully parsed a message
        consecutiveFailures = 0;
        
        if (offset == oldOffset) {
            // No progress made, prevent infinite loop
            NSLog(@"No progress in message parsing at offset %lu", offset);
            break;
        }
        [messages addObject:message];
        lastSuccessfulOffset = offset;
    }
    
    if (consumedBytes) {
        *consumedBytes = lastSuccessfulOffset;
    }
    
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

+ (NSArray *)parseArgumentsFromBodyData:(NSData *)bodyData signature:(NSString *)signature
{
    if (!bodyData || [bodyData length] == 0 || !signature || [signature length] == 0) {
        return @[];
    }
    
    const uint8_t *bytes = [bodyData bytes];
    NSUInteger pos = 0;
    NSMutableArray *arguments = [NSMutableArray array];
    
    // Parse each signature character
    for (NSUInteger i = 0; i < [signature length]; i++) {
        unichar typeChar = [signature characterAtIndex:i];
        
        if (typeChar == 's') {
            // String - align to 4-byte boundary
            pos = alignTo(pos, 4);
            
            if (pos + 4 > [bodyData length]) break;
            
            uint32_t strLen = *(uint32_t *)(bytes + pos);
            strLen = NSSwapLittleIntToHost(strLen); // Assume little-endian
            pos += 4;
            
            if (pos + strLen + 1 > [bodyData length]) break;
            
            NSString *value = [[NSString alloc] initWithBytes:(bytes + pos) 
                                                       length:strLen 
                                                     encoding:NSUTF8StringEncoding];
            [arguments addObject:value];
            [value release];
            pos += strLen + 1; // +1 for null terminator
            
        } else if (typeChar == 'u') {
            // uint32 - align to 4-byte boundary
            pos = alignTo(pos, 4);
            
            if (pos + 4 > [bodyData length]) break;
            
            uint32_t value = *(uint32_t *)(bytes + pos);
            value = NSSwapLittleIntToHost(value);
            [arguments addObject:@(value)];
            pos += 4;
            
        } else if (typeChar == 'i') {
            // int32 - align to 4-byte boundary
            pos = alignTo(pos, 4);
            
            if (pos + 4 > [bodyData length]) break;
            
            int32_t value = *(int32_t *)(bytes + pos);
            value = NSSwapLittleIntToHost(value);
            [arguments addObject:@(value)];
            pos += 4;
            
        } else {
            // Unknown type, skip
            break;
        }
    }
    
    return [arguments copy];
}

@end
