/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "MBMessage.h"
#import "MBVariant.h"

// D-Bus protocol constants
#define DBUS_HEADER_SIGNATURE "yyyyuua(yv)"
#define DBUS_MAJOR_PROTOCOL_VERSION 1
#define DBUS_LITTLE_ENDIAN 'l'
#define DBUS_BIG_ENDIAN 'B'

// Maximum message size we are willing to parse (128 MiB, per the D-Bus spec)
#define MB_MAX_MESSAGE_SIZE (128u * 1024u * 1024u)

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

#pragma mark - Alignment helpers

static NSUInteger alignTo(NSUInteger pos, NSUInteger alignment) {
    return ((pos + alignment - 1) / alignment) * alignment;
}

static void addPadding(NSMutableData *data, NSUInteger alignment) {
    NSUInteger pos = [data length];
    NSUInteger aligned = alignTo(pos, alignment);
    while (pos < aligned) {
        uint8_t zero = 0;
        [data appendBytes:&zero length:1];
        pos++;
    }
}

// Alignment of a complete type in the D-Bus wire format
static NSUInteger alignmentForTypeChar(unichar c) {
    switch (c) {
        case DBUS_TYPE_BYTE:
        case DBUS_TYPE_SIGNATURE:
        case DBUS_TYPE_VARIANT:
            return 1;
        case DBUS_TYPE_INT16:
        case DBUS_TYPE_UINT16:
            return 2;
        case DBUS_TYPE_BOOLEAN:
        case DBUS_TYPE_INT32:
        case DBUS_TYPE_UINT32:
        case DBUS_TYPE_STRING:
        case DBUS_TYPE_OBJECT_PATH:
        case DBUS_TYPE_ARRAY:
            return 4;
        case DBUS_TYPE_INT64:
        case DBUS_TYPE_UINT64:
        case DBUS_TYPE_DOUBLE:
            return 8;
        case '(':
        case '{':
            return 8;
        default:
            return 1;
    }
}

#pragma mark - Little-endian readers/writers (endian-independent)

static void appendU16LE(NSMutableData *data, uint16_t v) {
    uint8_t b[2] = { (uint8_t)(v & 0xff), (uint8_t)(v >> 8) };
    [data appendBytes:b length:2];
}

static void appendU32LE(NSMutableData *data, uint32_t v) {
    uint8_t b[4] = {
        (uint8_t)(v & 0xff),
        (uint8_t)((v >> 8) & 0xff),
        (uint8_t)((v >> 16) & 0xff),
        (uint8_t)((v >> 24) & 0xff)
    };
    [data appendBytes:b length:4];
}

static void appendU64LE(NSMutableData *data, uint64_t v) {
    uint8_t b[8];
    for (int i = 0; i < 8; i++) {
        b[i] = (uint8_t)((v >> (8 * i)) & 0xff);
    }
    [data appendBytes:b length:8];
}

static uint16_t readU16(const uint8_t *bytes, NSUInteger pos, uint8_t endian) {
    uint16_t v = (uint16_t)bytes[pos] | ((uint16_t)bytes[pos + 1] << 8);
    if (endian == DBUS_BIG_ENDIAN) {
        v = (uint16_t)((v >> 8) | (v << 8));
    }
    return v;
}

static uint32_t readU32(const uint8_t *bytes, NSUInteger pos, uint8_t endian) {
    uint32_t v = (uint32_t)bytes[pos]
               | ((uint32_t)bytes[pos + 1] << 8)
               | ((uint32_t)bytes[pos + 2] << 16)
               | ((uint32_t)bytes[pos + 3] << 24);
    if (endian == DBUS_BIG_ENDIAN) {
        v = __builtin_bswap32(v);
    }
    return v;
}

static uint64_t readU64(const uint8_t *bytes, NSUInteger pos, uint8_t endian) {
    uint64_t v = 0;
    for (int i = 0; i < 8; i++) {
        v |= ((uint64_t)bytes[pos + i]) << (8 * i);
    }
    if (endian == DBUS_BIG_ENDIAN) {
        v = __builtin_bswap64(v);
    }
    return v;
}

#pragma mark - Signature walking

// Extract the first complete type from a signature, advancing *pos.
// Returns nil if the signature is malformed or exhausted.
static NSString *nextCompleteType(NSString *signature, NSUInteger *pos)
{
    NSUInteger len = [signature length];
    if (*pos >= len) {
        return nil;
    }

    NSUInteger start = *pos;
    unichar c = [signature characterAtIndex:start];
    (*pos)++;

    switch (c) {
        case 'a': {
            NSString *element = nextCompleteType(signature, pos);
            if (!element) {
                return nil;
            }
            return [signature substringWithRange:NSMakeRange(start, *pos - start)];
        }
        case '(': {
            int depth = 1;
            while (*pos < len && depth > 0) {
                unichar d = [signature characterAtIndex:(*pos)];
                if (d == '(') depth++;
                else if (d == ')') depth--;
                (*pos)++;
            }
            if (depth != 0) {
                return nil; // unbalanced
            }
            return [signature substringWithRange:NSMakeRange(start, *pos - start)];
        }
        case '{': {
            int depth = 1;
            while (*pos < len && depth > 0) {
                unichar d = [signature characterAtIndex:(*pos)];
                if (d == '{') depth++;
                else if (d == '}') depth--;
                (*pos)++;
            }
            if (depth != 0) {
                return nil;
            }
            return [signature substringWithRange:NSMakeRange(start, *pos - start)];
        }
        case 'y': case 'b': case 'n': case 'q': case 'i': case 'u':
        case 'x': case 't': case 'd': case 's': case 'o': case 'g':
        case 'v':
            return [signature substringWithRange:NSMakeRange(start, 1)];
        default:
            return nil; // unknown type code
    }
}

// Maximum alignment required by any type inside a complete type
// (the alignment used to position the first element of an array).
static NSUInteger alignmentOfCompleteType(NSString *type)
{
    if ([type length] == 0) {
        return 1;
    }
    unichar c = [type characterAtIndex:0];
    if (c == 'a' && [type length] > 1) {
        return alignmentOfCompleteType([type substringFromIndex:1]);
    }
    return alignmentForTypeChar(c);
}

#pragma mark - Value encoding (signature-driven)

// Encode a single complete type into data. Returns NO if the value does not
// fit the signature (message is then considered invalid).
static BOOL encodeValue(NSMutableData *data, id value, NSString *type)
{
    if ([type length] == 0) {
        return NO;
    }
    unichar c = [type characterAtIndex:0];

    switch (c) {
        case 'y': {
            uint8_t v = [value unsignedCharValue];
            [data appendBytes:&v length:1];
            return YES;
        }
        case 'b': {
            addPadding(data, 4);
            uint32_t v = [value boolValue] ? 1 : 0;
            appendU32LE(data, v);
            return YES;
        }
        case 'n': {
            addPadding(data, 2);
            appendU16LE(data, (uint16_t)[value shortValue]);
            return YES;
        }
        case 'q': {
            addPadding(data, 2);
            appendU16LE(data, (uint16_t)[value unsignedShortValue]);
            return YES;
        }
        case 'i': {
            addPadding(data, 4);
            appendU32LE(data, (uint32_t)[value intValue]);
            return YES;
        }
        case 'u': {
            addPadding(data, 4);
            appendU32LE(data, (uint32_t)[value unsignedIntValue]);
            return YES;
        }
        case 'x': {
            addPadding(data, 8);
            appendU64LE(data, (uint64_t)[value longLongValue]);
            return YES;
        }
        case 't': {
            addPadding(data, 8);
            appendU64LE(data, (uint64_t)[value unsignedLongLongValue]);
            return YES;
        }
        case 'd': {
            addPadding(data, 8);
            double v = [value doubleValue];
            uint64_t bits;
            memcpy(&bits, &v, sizeof(bits));
            appendU64LE(data, bits);
            return YES;
        }
        case 's':
        case 'o': {
            if (![value isKindOfClass:[NSString class]]) {
                return NO;
            }
            addPadding(data, 4);
            NSData *utf8 = [(NSString *)value dataUsingEncoding:NSUTF8StringEncoding];
            if (!utf8) {
                return NO;
            }
            appendU32LE(data, (uint32_t)[utf8 length]);
            [data appendData:utf8];
            uint8_t nul = 0;
            [data appendBytes:&nul length:1];
            return YES;
        }
        case 'g': {
            if (![value isKindOfClass:[NSString class]]) {
                return NO;
            }
            NSData *utf8 = [(NSString *)value dataUsingEncoding:NSUTF8StringEncoding];
            if (!utf8 || [utf8 length] > 254) {
                return NO;
            }
            uint8_t len = (uint8_t)[utf8 length];
            [data appendBytes:&len length:1];
            [data appendData:utf8];
            uint8_t nul = 0;
            [data appendBytes:&nul length:1];
            return YES;
        }
        case 'v': {
            NSString *innerSig;
            id innerValue;
            if ([value isKindOfClass:[MBVariant class]]) {
                innerSig = [(MBVariant *)value signature];
                innerValue = [(MBVariant *)value value];
            } else {
                // Convenience: infer the signature for plain values
                innerSig = [MBMessage signatureForArguments:@[value ?: [NSNull null]]];
                innerValue = value ?: @"";
            }
            if (!innerSig || [innerSig length] == 0 || [innerSig length] > 254) {
                return NO;
            }
            if (!encodeValue(data, innerSig, @"g")) {
                return NO;
            }
            return encodeValue(data, innerValue, innerSig);
        }
        case 'a': {
            NSString *elementSig = [type substringFromIndex:1];
            if ([elementSig length] == 0) {
                return NO;
            }

            // Accept NSDictionary directly for a{...} arrays
            NSArray *elements;
            if ([value isKindOfClass:[NSArray class]]) {
                elements = (NSArray *)value;
            } else if ([value isKindOfClass:[NSDictionary class]] && [elementSig hasPrefix:@"{"]) {
                NSMutableArray *pairs = [NSMutableArray array];
                for (id key in (NSDictionary *)value) {
                    [pairs addObject:@[key, [(NSDictionary *)value objectForKey:key]]];
                }
                elements = pairs;
            } else {
                return NO;
            }

            addPadding(data, 4);
            NSUInteger lengthPos = [data length];
            appendU32LE(data, 0);
            addPadding(data, alignmentOfCompleteType(elementSig));
            NSUInteger contentStart = [data length];

            for (id element in elements) {
                id elementValue = element;
                // Dict entries may arrive as 2-element arrays
                if ([elementSig hasPrefix:@"{"]) {
                    if ([element isKindOfClass:[NSDictionary class]]) {
                        NSDictionary *d = (NSDictionary *)element;
                        if ([d count] != 1) {
                            return NO;
                        }
                        id k = [d allKeys][0];
                        elementValue = @[k, [d objectForKey:k]];
                    }
                }
                if (elementValue == [NSNull null]) {
                    // Empty placeholder (e.g. for empty arrays passed as [NSNull])
                    continue;
                }
                if (!encodeValue(data, elementValue, elementSig)) {
                    return NO;
                }
            }

            uint32_t contentLength = (uint32_t)([data length] - contentStart);
            uint8_t *bytes = (uint8_t *)[data mutableBytes];
            memcpy(bytes + lengthPos, &contentLength, 4); // LE on all supported hosts
            return YES;
        }
        case '(': {
            if (![value isKindOfClass:[NSArray class]]) {
                return NO;
            }
            NSString *inner = [type substringWithRange:NSMakeRange(1, [type length] - 2)];
            addPadding(data, 8);
            NSUInteger pos = 0;
            NSUInteger fieldIndex = 0;
            while (pos < [inner length]) {
                NSString *fieldType = nextCompleteType(inner, &pos);
                if (!fieldType) {
                    return NO;
                }
                id fieldValue = (fieldIndex < [value count]) ? [value objectAtIndex:fieldIndex] : [NSNull null];
                if (fieldValue == [NSNull null]) {
                    // Struct fields must all be present; fail if not enough values
                    return NO;
                }
                if (!encodeValue(data, fieldValue, fieldType)) {
                    return NO;
                }
                fieldIndex++;
            }
            return fieldIndex == [value count];
        }
        case '{': {
            if ([value isKindOfClass:[NSDictionary class]]) {
                NSDictionary *d = (NSDictionary *)value;
                if ([d count] != 1) {
                    return NO;
                }
                id k = [d allKeys][0];
                value = @[k, [d objectForKey:k]];
            }
            if (![value isKindOfClass:[NSArray class]] || [value count] != 2) {
                return NO;
            }
            NSString *inner = [type substringWithRange:NSMakeRange(1, [type length] - 2)];
            NSUInteger keyPos = 0;
            NSString *keyType = nextCompleteType(inner, &keyPos);
            NSString *valueType = nextCompleteType(inner, &keyPos);
            if (!keyType || !valueType || keyPos != [inner length]) {
                return NO;
            }
            addPadding(data, 8);
            if (!encodeValue(data, [value objectAtIndex:0], keyType)) {
                return NO;
            }
            return encodeValue(data, [value objectAtIndex:1], valueType);
        }
        default:
            return NO;
    }
}

#pragma mark - Value decoding (signature-driven)

static id decodeValue(const uint8_t *bytes, NSUInteger maxLen, NSString *type,
                      uint8_t endian, NSUInteger *pos);

static id decodeBasic(const uint8_t *bytes, NSUInteger maxLen, unichar c,
                      uint8_t endian, NSUInteger *pos)
{
    switch (c) {
        case 'y': {
            if (*pos + 1 > maxLen) return nil;
            uint8_t v = bytes[*pos];
            *pos += 1;
            return @(v);
        }
        case 'b': {
            *pos = alignTo(*pos, 4);
            if (*pos + 4 > maxLen) return nil;
            uint32_t v = readU32(bytes, *pos, endian);
            *pos += 4;
            return @(v != 0);
        }
        case 'n': {
            *pos = alignTo(*pos, 2);
            if (*pos + 2 > maxLen) return nil;
            uint16_t v = readU16(bytes, *pos, endian);
            *pos += 2;
            return @((int16_t)v);
        }
        case 'q': {
            *pos = alignTo(*pos, 2);
            if (*pos + 2 > maxLen) return nil;
            uint16_t v = readU16(bytes, *pos, endian);
            *pos += 2;
            return @(v);
        }
        case 'i': {
            *pos = alignTo(*pos, 4);
            if (*pos + 4 > maxLen) return nil;
            uint32_t v = readU32(bytes, *pos, endian);
            *pos += 4;
            return @((int32_t)v);
        }
        case 'u': {
            *pos = alignTo(*pos, 4);
            if (*pos + 4 > maxLen) return nil;
            uint32_t v = readU32(bytes, *pos, endian);
            *pos += 4;
            return @(v);
        }
        case 'x': {
            *pos = alignTo(*pos, 8);
            if (*pos + 8 > maxLen) return nil;
            uint64_t v = readU64(bytes, *pos, endian);
            *pos += 8;
            return @((int64_t)v);
        }
        case 't': {
            *pos = alignTo(*pos, 8);
            if (*pos + 8 > maxLen) return nil;
            uint64_t v = readU64(bytes, *pos, endian);
            *pos += 8;
            return @(v);
        }
        case 'd': {
            *pos = alignTo(*pos, 8);
            if (*pos + 8 > maxLen) return nil;
            uint64_t bits = readU64(bytes, *pos, endian);
            double v;
            memcpy(&v, &bits, sizeof(v));
            *pos += 8;
            return @(v);
        }
        case 's':
        case 'o': {
            *pos = alignTo(*pos, 4);
            if (*pos + 4 > maxLen) return nil;
            uint32_t len = readU32(bytes, *pos, endian);
            *pos += 4;
            if (len > MB_MAX_MESSAGE_SIZE || *pos + len + 1 > maxLen) return nil;
            NSString *result = [[NSString alloc] initWithBytes:bytes + *pos
                                                        length:len
                                                      encoding:NSUTF8StringEncoding];
            *pos += len + 1;
            return [result autorelease];
        }
        case 'g': {
            if (*pos + 1 > maxLen) return nil;
            uint8_t len = bytes[*pos];
            *pos += 1;
            if (*pos + len + 1 > maxLen) return nil;
            NSString *result = [[NSString alloc] initWithBytes:bytes + *pos
                                                        length:len
                                                      encoding:NSUTF8StringEncoding];
            *pos += len + 1;
            return [result autorelease];
        }
        default:
            return nil;
    }
}

static id decodeValue(const uint8_t *bytes, NSUInteger maxLen, NSString *type,
                      uint8_t endian, NSUInteger *pos)
{
    if ([type length] == 0) {
        return nil;
    }
    unichar c = [type characterAtIndex:0];

    switch (c) {
        case 'v': {
            id sig = decodeBasic(bytes, maxLen, 'g', endian, pos);
            if (!sig) return nil;
            NSString *innerSig = (NSString *)sig;
            // Validate the inner signature by walking it
            NSUInteger checkPos = 0;
            NSUInteger consumedTotal = 0;
            while (checkPos < [innerSig length]) {
                NSString *t = nextCompleteType(innerSig, &checkPos);
                if (!t) return nil;
                consumedTotal++;
            }
            if (consumedTotal == 0) return nil;
            id value = decodeValue(bytes, maxLen, innerSig, endian, pos);
            if (!value) return nil;
            return [MBVariant variantWithSignature:innerSig value:value];
        }
        case 'a': {
            NSString *elementSig = [type substringFromIndex:1];
            if ([elementSig length] == 0) return nil;
            *pos = alignTo(*pos, 4);
            if (*pos + 4 > maxLen) return nil;
            uint32_t arrayLen = readU32(bytes, *pos, endian);
            *pos += 4;
            NSUInteger arrayEnd = *pos + arrayLen;
            if (arrayLen > MB_MAX_MESSAGE_SIZE || arrayEnd > maxLen) return nil;

            *pos = alignTo(*pos, alignmentOfCompleteType(elementSig));
            NSMutableArray *elements = [NSMutableArray array];
            while (*pos < arrayEnd) {
                NSUInteger before = *pos;
                id element = decodeValue(bytes, maxLen, elementSig, endian, pos);
                if (!element || *pos > arrayEnd || *pos <= before) {
                    return nil;
                }
                [elements addObject:element];
            }
            if (*pos != arrayEnd) return nil;
            return elements;
        }
        case '(': {
            NSString *inner = [type substringWithRange:NSMakeRange(1, [type length] - 2)];
            *pos = alignTo(*pos, 8);
            NSMutableArray *fields = [NSMutableArray array];
            NSUInteger walkPos = 0;
            while (walkPos < [inner length]) {
                NSString *fieldType = nextCompleteType(inner, &walkPos);
                if (!fieldType) return nil;
                id field = decodeValue(bytes, maxLen, fieldType, endian, pos);
                if (!field) return nil;
                [fields addObject:field];
            }
            return fields;
        }
        case '{': {
            NSString *inner = [type substringWithRange:NSMakeRange(1, [type length] - 2)];
            NSUInteger walkPos = 0;
            NSString *keyType = nextCompleteType(inner, &walkPos);
            NSString *valueType = nextCompleteType(inner, &walkPos);
            if (!keyType || !valueType || walkPos != [inner length]) return nil;
            *pos = alignTo(*pos, 8);
            id key = decodeValue(bytes, maxLen, keyType, endian, pos);
            if (!key) return nil;
            id value = decodeValue(bytes, maxLen, valueType, endian, pos);
            if (!value) return nil;
            return @[key, value];
        }
        default:
            return decodeBasic(bytes, maxLen, c, endian, pos);
    }
}

#pragma mark - MBMessage implementation

@implementation MBMessage

@synthesize type = _type;
@synthesize destination = _destination;
@synthesize sender = _sender;
@synthesize path = _path;
@synthesize interface = _interface;
@synthesize member = _member;
@synthesize signature = _signature;
@synthesize arguments = _arguments;
@synthesize serial = _serial;
@synthesize replySerial = _replySerial;
@synthesize errorName = _errorName;

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
    return [message autorelease];
}

+ (instancetype)methodReturnWithReplySerial:(NSUInteger)replySerial
                                  arguments:(NSArray *)arguments
{
    MBMessage *message = [[self alloc] init];
    message.type = MBMessageTypeMethodReturn;
    message.replySerial = replySerial;
    message.arguments = arguments ?: @[];
    message.signature = [self signatureForArguments:message.arguments];
    return [message autorelease];
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
    return [msg autorelease];
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
    return [message autorelease];
}

+ (NSString *)signatureForValue:(id)value
{
    if ([value isKindOfClass:[NSString class]]) {
        return @"s";
    }
    if ([value isKindOfClass:[MBVariant class]]) {
        return @"v";
    }
    if ([value isKindOfClass:[NSNumber class]]) {
        NSNumber *num = (NSNumber *)value;
        const char *objCType = [num objCType];
        if (strcmp(objCType, @encode(BOOL)) == 0 ||
            strcmp(objCType, @encode(bool)) == 0 ||
            (strcmp(objCType, @encode(signed char)) == 0 && [num intValue] >= 0 && [num intValue] <= 1)) {
            return @"b";
        }
        switch (objCType[0]) {
            case 'c': return @"y";
            case 'C': return @"y";
            case 's': return @"n";
            case 'S': return @"q";
            case 'i': return @"i";
            case 'I': return @"u";
            case 'l': return @"x";
            case 'L': return @"t";
            case 'q': return @"x";
            case 'Q': return @"t";
            case 'f':
            case 'd': return @"d";
            default:  return @"u";
        }
    }
    if ([value isKindOfClass:[NSArray class]]) {
        NSArray *array = (NSArray *)value;
        if ([array count] == 0) {
            return @"as";
        }
        // Mixed types or a single homogeneous sequence: a struct when element
        // types differ, otherwise an array of the common element type.
        NSMutableString *elementSigs = [NSMutableString string];
        BOOL homogeneous = YES;
        NSString *first = [self signatureForValue:[array objectAtIndex:0]];
        for (id element in array) {
            NSString *s = [self signatureForValue:element];
            [elementSigs appendString:s];
            if (![s isEqualToString:first]) {
                homogeneous = NO;
            }
        }
        if (homogeneous) {
            return [NSString stringWithFormat:@"a%@", first];
        }
        return [NSString stringWithFormat:@"(%@)", elementSigs];
    }
    if ([value isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)value;
        if ([dict count] == 0) {
            return @"a{sv}";
        }
        NSMutableString *sigs = [NSMutableString string];
        for (id key in dict) {
            [sigs appendFormat:@"{%@%@}",
             [self signatureForValue:key], [self signatureForValue:[dict objectForKey:key]]];
        }
        // All dict entries must share one signature for a valid D-Bus array
        NSString *firstEntry = nil;
        for (id key in dict) {
            NSString *entry = [NSString stringWithFormat:@"{%@%@}",
                               [self signatureForValue:key],
                               [self signatureForValue:[dict objectForKey:key]]];
            if (!firstEntry) {
                firstEntry = entry;
            } else if (![entry isEqualToString:firstEntry]) {
                return @"a{sv}";
            }
        }
        return [NSString stringWithFormat:@"a%@", firstEntry ?: @"{sv}"];
    }
    return @"s";
}

+ (NSString *)signatureForArguments:(NSArray *)arguments
{
    NSMutableString *signature = [NSMutableString string];
    for (id arg in arguments) {
        [signature appendString:[self signatureForValue:arg]];
    }
    return signature;
}

- (NSData *)serialize
{
    NSMutableData *message = [NSMutableData data];

    NSData *headerFieldsData = [self serializeHeaderFields];
    NSData *body = [self serializeBody];
    if (!body) {
        NSDebugLLog(@"gwcomp", @"Failed to serialize message body (signature=%@, args=%@)",
              _signature, _arguments);
        return nil;
    }

    uint8_t endian = DBUS_LITTLE_ENDIAN;
    uint8_t type = (uint8_t)_type;
    uint8_t flags = 0;

    if (_type == MBMessageTypeMethodReturn ||
        _type == MBMessageTypeError ||
        _type == MBMessageTypeSignal) {
        flags |= 0x1; // NO_REPLY_EXPECTED
    }

    uint8_t version = DBUS_MAJOR_PROTOCOL_VERSION;
    uint32_t bodyLength = (uint32_t)[body length];
    uint32_t serial = (uint32_t)(_serial ? _serial : 1);
    uint32_t fieldsLength = (uint32_t)[headerFieldsData length];

    [message appendBytes:&endian length:1];
    [message appendBytes:&type length:1];
    [message appendBytes:&flags length:1];
    [message appendBytes:&version length:1];
    appendU32LE(message, bodyLength);
    appendU32LE(message, serial);
    appendU32LE(message, fieldsLength);

    [message appendData:headerFieldsData];

    // Body starts on an 8-byte boundary
    addPadding(message, 8);
    [message appendData:body];

    return message;
}

- (NSData *)serializeHeaderFields
{
    // Header fields are an ARRAY of STRUCT (BYTE, VARIANT). Each struct is
    // 8-byte aligned; the array data starts at message offset 16 which is
    // already 8-byte aligned.
    NSMutableData *arrayData = [NSMutableData data];

    void (^addField)(uint8_t, MBVariant *) = ^(uint8_t code, MBVariant *variant) {
        if (!variant) return;
        addPadding(arrayData, 8);
        if (!encodeValue(arrayData, @(code), @"y")) return;
        encodeValue(arrayData, variant, @"v");
    };

    void (^addString)(uint8_t, NSString *, unichar typeChar) = ^(uint8_t code, NSString *value, unichar typeChar) {
        if (!value) return;
        NSString *sig = [NSString stringWithFormat:@"%c", typeChar];
        addField(code, [MBVariant variantWithSignature:sig value:value]);
    };

    void (^addUInt32)(uint8_t, uint32_t) = ^(uint8_t code, uint32_t value) {
        if (value == 0) return;
        addField(code, [MBVariant variantWithSignature:@"u" value:@(value)]);
    };

    addString(DBUS_HEADER_FIELD_PATH, _path, DBUS_TYPE_OBJECT_PATH);
    addString(DBUS_HEADER_FIELD_INTERFACE, _interface, DBUS_TYPE_STRING);
    addString(DBUS_HEADER_FIELD_MEMBER, _member, DBUS_TYPE_STRING);
    addString(DBUS_HEADER_FIELD_ERROR_NAME, _errorName, DBUS_TYPE_STRING);
    if (_replySerial > 0) {
        addUInt32(DBUS_HEADER_FIELD_REPLY_SERIAL, (uint32_t)_replySerial);
    }
    addString(DBUS_HEADER_FIELD_DESTINATION, _destination, DBUS_TYPE_STRING);
    addString(DBUS_HEADER_FIELD_SENDER, _sender, DBUS_TYPE_STRING);
    if (_signature && [_signature length] > 0) {
        addString(DBUS_HEADER_FIELD_SIGNATURE, _signature, DBUS_TYPE_SIGNATURE);
    }

    return arrayData;
}

- (NSData *)serializeBody
{
    NSArray *args = _arguments ?: @[];
    NSString *sig = _signature;

    // Fall back to inferred signature when none is set or it does not cover
    // every argument.
    if (!sig || [sig length] == 0) {
        sig = [MBMessage signatureForArguments:args];
    } else {
        NSUInteger units = 0;
        NSUInteger pos = 0;
        while (pos < [sig length]) {
            if (!nextCompleteType(sig, &pos)) {
                break;
            }
            units++;
        }
        if (units < [args count]) {
            NSDebugLLog(@"gwcomp", @"Signature '%@' covers %lu argument(s) but %lu given; using inferred signature",
                  sig, (unsigned long)units, (unsigned long)[args count]);
            sig = [MBMessage signatureForArguments:args];
        }
    }

    NSMutableData *bodyData = [NSMutableData data];
    NSUInteger pos = 0;
    for (id arg in args) {
        NSString *type = nextCompleteType(sig, &pos);
        if (!type) {
            return nil;
        }
        if ([arg isKindOfClass:[NSNull class]]) {
            NSNull *n = (NSNull *)arg;
            (void)n;
            return nil; // NSNull cannot be marshalled
        }
        if (!encodeValue(bodyData, arg, type)) {
            return nil;
        }
    }

    if (pos < [sig length] && [args count] > 0) {
        NSDebugLLog(@"gwcomp", @"Signature '%@' has trailing unparsed types", sig);
        return nil;
    }

    return bodyData;
}

#pragma mark - Parsing

+ (void)parseHeaderFields:(NSData *)data
                    offset:(NSUInteger)offset
                    length:(NSUInteger)length
                endianness:(uint8_t)endianness
                   message:(MBMessage *)message
{
    const uint8_t *bytes = [data bytes];
    NSUInteger pos = offset;
    NSUInteger end = offset + length;

    while (pos < end) {
        // Each field is a struct (y v): code byte, then variant. Structs are
        // 8-byte aligned relative to the start of the message; the array
        // begins at message offset 16, so align within the stream.
        NSUInteger messagePos = 16 + (pos - offset);
        NSUInteger alignedPos = offset + alignTo(messagePos, 8) - 16;
        if (alignedPos > end) {
            break;
        }
        pos = alignedPos;
        if (pos + 1 > end) {
            break;
        }

        uint8_t code = bytes[pos];
        pos += 1;

        // Variant: signature (g) followed by the value
        if (pos + 1 > end) break;
        uint8_t sigLen = bytes[pos];
        pos += 1;
        if (pos + sigLen + 1 > end) break;
        NSString *valueSig = [[NSString alloc] initWithBytes:bytes + pos
                                                      length:sigLen
                                                    encoding:NSUTF8StringEncoding];
        pos += sigLen + 1;
        [valueSig autorelease];

        unichar typeChar = [valueSig length] > 0 ? [valueSig characterAtIndex:0] : 0;
        NSUInteger before = pos;

        switch (code) {
            case DBUS_HEADER_FIELD_PATH:
                if (typeChar == DBUS_TYPE_OBJECT_PATH) {
                    message.path = [self readStringAt:bytes pos:&pos max:end endian:endianness];
                }
                break;
            case DBUS_HEADER_FIELD_INTERFACE:
                if (typeChar == DBUS_TYPE_STRING) {
                    message.interface = [self readStringAt:bytes pos:&pos max:end endian:endianness];
                }
                break;
            case DBUS_HEADER_FIELD_MEMBER:
                if (typeChar == DBUS_TYPE_STRING) {
                    message.member = [self readStringAt:bytes pos:&pos max:end endian:endianness];
                }
                break;
            case DBUS_HEADER_FIELD_ERROR_NAME:
                if (typeChar == DBUS_TYPE_STRING) {
                    message.errorName = [self readStringAt:bytes pos:&pos max:end endian:endianness];
                }
                break;
            case DBUS_HEADER_FIELD_REPLY_SERIAL:
                if (typeChar == DBUS_TYPE_UINT32 && pos + 4 <= end) {
                    pos = alignTo(pos, 4);
                    message.replySerial = readU32(bytes, pos, endianness);
                    pos += 4;
                }
                break;
            case DBUS_HEADER_FIELD_DESTINATION:
                if (typeChar == DBUS_TYPE_STRING) {
                    message.destination = [self readStringAt:bytes pos:&pos max:end endian:endianness];
                }
                break;
            case DBUS_HEADER_FIELD_SENDER:
                if (typeChar == DBUS_TYPE_STRING) {
                    message.sender = [self readStringAt:bytes pos:&pos max:end endian:endianness];
                }
                break;
            case DBUS_HEADER_FIELD_SIGNATURE:
                if (typeChar == DBUS_TYPE_SIGNATURE) {
                    if (pos + 1 <= end) {
                        uint8_t len = bytes[pos];
                        pos += 1;
                        if (pos + len + 1 <= end) {
                            message.signature = [[NSString alloc] initWithBytes:bytes + pos
                                                                        length:len
                                                                      encoding:NSUTF8StringEncoding];
                            [message.signature autorelease];
                            pos += len + 1;
                        }
                    }
                }
                break;
            default:
                // Unknown field: skip the value with the generic decoder
                (void)decodeValue(bytes, end, valueSig, endianness, &pos);
                break;
        }

        if (pos == before) {
            // Decoder did not move; bail out to avoid an endless loop
            break;
        }
    }
}

+ (NSString *)readStringAt:(const uint8_t *)bytes
                       pos:(NSUInteger *)pos
                       max:(NSUInteger)max
                    endian:(uint8_t)endianness
{
    *pos = alignTo(*pos, 4);
    if (*pos + 4 > max) return nil;
    uint32_t len = readU32(bytes, *pos, endianness);
    *pos += 4;
    if (len > MB_MAX_MESSAGE_SIZE || *pos + len + 1 > max) return nil;
    NSString *result = [[NSString alloc] initWithBytes:bytes + *pos
                                                length:len
                                              encoding:NSUTF8StringEncoding];
    *pos += len + 1;
    return [result autorelease];
}

+ (instancetype)messageFromData:(NSData *)data offset:(NSUInteger *)offset
{
    const uint8_t *bytes = [data bytes];
    NSUInteger dataLength = [data length];
    NSUInteger pos = *offset;

    if (pos + 16 > dataLength) {
        return nil; // Not enough data for header
    }

    uint8_t endian = bytes[pos];
    uint8_t messageType = bytes[pos + 1];
    uint8_t flags = bytes[pos + 2];
    uint8_t version = bytes[pos + 3];
    (void)flags;

    if (endian != DBUS_LITTLE_ENDIAN && endian != DBUS_BIG_ENDIAN) {
        return nil;
    }
    if (version != DBUS_MAJOR_PROTOCOL_VERSION) {
        return nil;
    }
    if (messageType < 1 || messageType > 4) {
        return nil;
    }

    uint32_t bodyLength = readU32(bytes, pos + 4, endian);
    uint32_t serial = readU32(bytes, pos + 8, endian);
    uint32_t headerFieldsLength = readU32(bytes, pos + 12, endian);

    if (bodyLength > MB_MAX_MESSAGE_SIZE || headerFieldsLength > MB_MAX_MESSAGE_SIZE) {
        return nil;
    }

    pos += 16;

    NSUInteger headerFieldsEndPos = pos + headerFieldsLength;
    NSUInteger bodyStartPos = alignTo(headerFieldsEndPos, 8);
    NSUInteger totalMessageLength = bodyStartPos + bodyLength;

    if (totalMessageLength > dataLength - *offset) {
        return nil; // Not enough data for complete message
    }

    MBMessage *message = [[self alloc] init];
    message.type = (MBMessageType)messageType;
    message.serial = serial;

    if (headerFieldsLength > 0) {
        [self parseHeaderFields:data
                         offset:pos
                         length:headerFieldsLength
                     endianness:endian
                        message:message];
    }

    if (bodyLength > 0 && message.signature) {
        NSData *bodyData = [NSData dataWithBytes:bytes + bodyStartPos length:bodyLength];
        message.arguments = [self parseArgumentsFromBodyData:bodyData
                                                   signature:message.signature
                                                  endianness:endian];
    }

    *offset += totalMessageLength;
    return [message autorelease];
}

+ (NSArray *)messagesFromData:(NSData *)data
{
    NSUInteger consumedBytes = 0;
    return [self messagesFromData:data consumedBytes:&consumedBytes];
}

+ (NSUInteger)messageLengthFromData:(NSData *)data
{
    const uint8_t *bytes = [data bytes];
    NSUInteger dataLength = [data length];

    if (dataLength < 16) {
        return 0;
    }

    uint8_t endian = bytes[0];
    uint8_t messageType = bytes[1];
    uint8_t version = bytes[3];

    if ((endian != DBUS_LITTLE_ENDIAN && endian != DBUS_BIG_ENDIAN) ||
        version != DBUS_MAJOR_PROTOCOL_VERSION ||
        messageType < 1 || messageType > 4) {
        return NSNotFound;
    }

    uint32_t bodyLength = readU32(bytes, 4, endian);
    uint32_t headerFieldsLength = readU32(bytes, 12, endian);

    if (bodyLength > MB_MAX_MESSAGE_SIZE || headerFieldsLength > MB_MAX_MESSAGE_SIZE) {
        return NSNotFound;
    }

    NSUInteger total = alignTo(16 + headerFieldsLength, 8) + bodyLength;
    return total;
}

+ (NSArray *)messagesFromData:(NSData *)data consumedBytes:(NSUInteger *)consumedBytes
{
    NSMutableArray *messages = [NSMutableArray array];
    NSUInteger offset = 0;

    while (offset < [data length]) {
        NSUInteger before = offset;
        MBMessage *message = [self messageFromData:data offset:&offset];
        if (!message) {
            // Incomplete or invalid trailing data: leave it in the buffer
            offset = before;
            break;
        }
        [messages addObject:message];
    }

    if (consumedBytes) {
        *consumedBytes = offset;
    }
    return messages;
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
    NSUInteger sigPos = 0;

    while (sigPos < [signature length]) {
        NSString *type = nextCompleteType(signature, &sigPos);
        if (!type) {
            NSDebugLLog(@"gwcomp", @"Malformed signature '%@' while parsing body", signature);
            break;
        }
        pos = alignTo(pos, alignmentOfCompleteType(type));
        id value = decodeValue(bytes, maxLen, type, endianness, &pos);
        if (!value) {
            NSDebugLLog(@"gwcomp", @"Failed to parse argument %lu of signature '%@' at body offset %lu",
                  (unsigned long)[arguments count], signature, (unsigned long)pos);
            break;
        }
        [arguments addObject:value];
    }

    return arguments;
}

- (void)dealloc
{
    [_destination release];
    [_sender release];
    [_path release];
    [_interface release];
    [_member release];
    [_signature release];
    [_arguments release];
    [_errorName release];
    [super dealloc];
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<MBMessage type=%u dest=%@ iface=%@ member=%@ sig=%@ serial=%lu replySerial=%lu>",
            (unsigned)_type, _destination, _interface, _member, _signature,
            (unsigned long)_serial, (unsigned long)_replySerial];
}

@end
