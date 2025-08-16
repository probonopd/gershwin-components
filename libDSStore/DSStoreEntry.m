//
//  DSStoreEntry.m
//  libDSStore
//
//  DS_Store entry implementation based on Python ds_store reference
//

#import "DSStoreEntry.h"

@implementation DSStoreEntry

@synthesize filename = _filename;
@synthesize code = _code;
@synthesize type = _type;
@synthesize value = _value;

- (id)initWithFilename:(NSString *)filename code:(NSString *)code type:(NSString *)type value:(id)value {
    self = [super init];
    if (self) {
        self.filename = filename;
        self.code = code;
        self.type = type;
        self.value = value;
    }
    return self;
}

- (void)dealloc {
    [_filename release];
    [_code release];
    [_type release];
    [_value release];
    [super dealloc];
}

- (NSUInteger)byteLength {
    NSData *utf16Data = [self.filename dataUsingEncoding:NSUTF16BigEndianStringEncoding];
    NSUInteger length = 4 + [utf16Data length] + 8; // 4 bytes for length + filename + 4 bytes code + 4 bytes type
    
    NSString *entryType = self.type;
    
    if ([entryType isEqualToString:@"bool"]) {
        length += 1;
    } else if ([entryType isEqualToString:@"long"] || [entryType isEqualToString:@"shor"]) {
        length += 4;
    } else if ([entryType isEqualToString:@"blob"]) {
        if ([self.value isKindOfClass:[NSData class]]) {
            length += 4 + [(NSData *)self.value length];
        }
    } else if ([entryType isEqualToString:@"ustr"]) {
        if ([self.value isKindOfClass:[NSString class]]) {
            NSData *valueUtf16 = [(NSString *)self.value dataUsingEncoding:NSUTF16BigEndianStringEncoding];
            length += 4 + [valueUtf16 length];
        }
    } else if ([entryType isEqualToString:@"type"]) {
        length += 4;
    } else if ([entryType isEqualToString:@"comp"] || [entryType isEqualToString:@"dutc"]) {
        length += 8;
    }
    
    return length;
}

static uint32_t swapBytes32(uint32_t value) {
    return ((value & 0xFF000000) >> 24) |
           ((value & 0x00FF0000) >> 8) |
           ((value & 0x0000FF00) << 8) |
           ((value & 0x000000FF) << 24);
}

static uint64_t swapBytes64(uint64_t value) {
    return ((value & 0xFF00000000000000ULL) >> 56) |
           ((value & 0x00FF000000000000ULL) >> 40) |
           ((value & 0x0000FF0000000000ULL) >> 24) |
           ((value & 0x000000FF00000000ULL) >> 8) |
           ((value & 0x00000000FF000000ULL) << 8) |
           ((value & 0x0000000000FF0000ULL) << 24) |
           ((value & 0x000000000000FF00ULL) << 40) |
           ((value & 0x00000000000000FFULL) << 56);
}

- (NSData *)encode {
    NSMutableData *data = [NSMutableData data];
    
    // Write filename length and filename in UTF-16BE
    NSData *utf16Data = [self.filename dataUsingEncoding:NSUTF16BigEndianStringEncoding];
    uint32_t filenameLength = swapBytes32([utf16Data length] / 2);
    [data appendBytes:&filenameLength length:4];
    [data appendData:utf16Data];
    
    // Write code (4 bytes)
    NSData *codeData = [self.code dataUsingEncoding:NSASCIIStringEncoding];
    if ([codeData length] >= 4) {
        [data appendBytes:[codeData bytes] length:4];
    } else {
        // Pad with zeros if code is shorter than 4 bytes
        char codeBuf[4] = {0};
        memcpy(codeBuf, [codeData bytes], [codeData length]);
        [data appendBytes:codeBuf length:4];
    }
    
    // Write type (4 bytes)  
    NSData *typeData = [self.type dataUsingEncoding:NSASCIIStringEncoding];
    if ([typeData length] >= 4) {
        [data appendBytes:[typeData bytes] length:4];
    } else {
        // Pad with zeros if type is shorter than 4 bytes
        char typeBuf[4] = {0};
        memcpy(typeBuf, [typeData bytes], [typeData length]);
        [data appendBytes:typeBuf length:4];
    }
    
    // Write value based on type
    if ([self.type isEqualToString:@"bool"]) {
        BOOL boolValue = [self.value boolValue];
        uint8_t byteValue = boolValue ? 1 : 0;
        [data appendBytes:&byteValue length:1];
    } else if ([self.type isEqualToString:@"long"] || [self.type isEqualToString:@"shor"]) {
        uint32_t longValue = swapBytes32([self.value unsignedIntValue]);
        [data appendBytes:&longValue length:4];
    } else if ([self.type isEqualToString:@"blob"]) {
        if ([self.value isKindOfClass:[NSData class]]) {
            NSData *blobData = (NSData *)self.value;
            uint32_t blobLength = swapBytes32([blobData length]);
            [data appendBytes:&blobLength length:4];
            [data appendData:blobData];
        }
    } else if ([self.type isEqualToString:@"ustr"]) {
        if ([self.value isKindOfClass:[NSString class]]) {
            NSData *valueUtf16 = [(NSString *)self.value dataUsingEncoding:NSUTF16BigEndianStringEncoding];
            uint32_t stringLength = swapBytes32([valueUtf16 length] / 2);
            [data appendBytes:&stringLength length:4];
            [data appendData:valueUtf16];
        }
    } else if ([self.type isEqualToString:@"type"]) {
        if ([self.value isKindOfClass:[NSString class]]) {
            NSData *typeValue = [(NSString *)self.value dataUsingEncoding:NSASCIIStringEncoding];
            if ([typeValue length] >= 4) {
                [data appendBytes:[typeValue bytes] length:4];
            } else {
                char typeBuf[4] = {0};
                memcpy(typeBuf, [typeValue bytes], [typeValue length]);
                [data appendBytes:typeBuf length:4];
            }
        }
    } else if ([self.type isEqualToString:@"comp"] || [self.type isEqualToString:@"dutc"]) {
        uint64_t longLongValue = swapBytes64([self.value unsignedLongLongValue]);
        [data appendBytes:&longLongValue length:8];
    }
    
    return data;
}

- (NSComparisonResult)compare:(DSStoreEntry *)other {
    NSString *selfLower = [self.filename lowercaseString];
    NSString *otherLower = [other.filename lowercaseString];
    
    NSComparisonResult result = [selfLower compare:otherLower];
    if (result == NSOrderedSame) {
        return [self.code compare:other.code];
    }
    return result;
}

@end
