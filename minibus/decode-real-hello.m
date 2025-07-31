#import <Foundation/Foundation.h>

void printHexDump(NSData *data, const char *label) {
    printf("\n%s (%lu bytes):\n", label, [data length]);
    const uint8_t *bytes = [data bytes];
    for (NSUInteger i = 0; i < [data length]; i++) {
        printf("%02x ", bytes[i]);
        if ((i + 1) % 16 == 0) printf("\n");
    }
    if ([data length] % 16 != 0) printf("\n");
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        // Real dbus-daemon Hello reply (from capture)
        uint8_t realHelloBytes[] = {
            0x6c, 0x02, 0x01, 0x01, 0x09, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x3d, 0x00, 0x00, 0x00,
            0x06, 0x01, 0x73, 0x00, 0x04, 0x00, 0x00, 0x00, 0x3a, 0x31, 0x2e, 0x30, 0x00, 0x00, 0x00, 0x00,
            0x05, 0x01, 0x75, 0x00, 0x01, 0x00, 0x00, 0x00, 0x08, 0x01, 0x67, 0x00, 0x01, 0x73, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x3a, 0x31, 0x2e, 0x30,
            0x00
        };
        NSData *realHelloData = [NSData dataWithBytes:realHelloBytes length:sizeof(realHelloBytes)];
        
        printf("=== Real D-Bus Hello Reply Decoder ===\n");
        printHexDump(realHelloData, "Raw bytes");
        
        const uint8_t *bytes = [realHelloData bytes];
        
        printf("\n=== Fixed Header ===\n");
        printf("Endian: 0x%02x ('%c')\n", bytes[0], bytes[0]);
        printf("Type: %d\n", bytes[1]);
        printf("Flags: 0x%02x\n", bytes[2]);
        printf("Version: %d\n", bytes[3]);
        
        uint32_t bodyLength = *(uint32_t *)(bytes + 4);
        uint32_t serial = *(uint32_t *)(bytes + 8);
        uint32_t fieldsLength = *(uint32_t *)(bytes + 12);
        
        printf("Body length: %u (0x%x)\n", bodyLength, bodyLength);
        printf("Serial: %u\n", serial);
        printf("Fields length: %u (0x%x)\n", fieldsLength, fieldsLength);
        
        printf("\n=== Header Fields (starting at offset 16, length %u) ===\n", fieldsLength);
        NSUInteger pos = 16;
        NSUInteger fieldsEnd = pos + fieldsLength;
        
        while (pos < fieldsEnd && pos < [realHelloData length]) {
            if (pos + 4 > [realHelloData length]) break;
            
            uint8_t fieldCode = bytes[pos];
            printf("Field %d at offset %lu:\n", fieldCode, pos);
            
            if (fieldCode == 0) {
                printf("  Padding byte\n");
                pos++;
                continue;
            }
            
            // Decode variant: siglen + signature + null + value
            uint8_t sigLen = bytes[pos + 1];
            char signature = bytes[pos + 2];
            printf("  Variant signature length: %d\n", sigLen);
            printf("  Variant signature: '%c'\n", signature);
            
            pos += 3 + sigLen; // fieldcode + siglen + signature + null
            
            if (signature == 's' || signature == 'o') {
                // String
                // Align to 4-byte boundary
                while (pos % 4 != 0) pos++;
                
                uint32_t strLen = *(uint32_t *)(bytes + pos);
                pos += 4;
                printf("  String length: %u\n", strLen);
                printf("  String value: '");
                for (uint32_t i = 0; i < strLen && pos + i < [realHelloData length]; i++) {
                    printf("%c", bytes[pos + i]);
                }
                printf("'\n");
                pos += strLen + 1; // +1 for null terminator
            } else if (signature == 'u') {
                // uint32
                // Align to 4-byte boundary 
                while (pos % 4 != 0) pos++;
                
                uint32_t value = *(uint32_t *)(bytes + pos);
                pos += 4;
                printf("  uint32 value: %u\n", value);
            } else if (signature == 'g') {
                // signature
                uint8_t sigStrLen = bytes[pos];
                pos++;
                printf("  Signature length: %u\n", sigStrLen);
                printf("  Signature value: '");
                for (uint8_t i = 0; i < sigStrLen && pos + i < [realHelloData length]; i++) {
                    printf("%c", bytes[pos + i]);
                }
                printf("'\n");
                pos += sigStrLen + 1; // +1 for null terminator
            }
            
            // Align to 8-byte boundary for next field
            while (pos % 8 != 0) pos++;
            printf("  Next field at offset %lu\n", pos);
        }
        
        printf("\n=== Body (starting at offset %lu) ===\n", fieldsEnd);
        pos = fieldsEnd;
        
        // The body should be 8-byte aligned from the start of the message
        NSUInteger totalHeaderLen = 16 + fieldsLength;
        NSUInteger alignedHeaderLen = (totalHeaderLen + 7) & ~7; // Round up to multiple of 8
        NSUInteger actualBodyStart = alignedHeaderLen;
        
        printf("Total header length: %lu\n", totalHeaderLen);
        printf("Aligned header length: %lu\n", alignedHeaderLen);
        printf("Body should start at: %lu\n", actualBodyStart);
        printf("Fields end at: %lu\n", fieldsEnd);
        
        if (actualBodyStart < [realHelloData length]) {
            pos = actualBodyStart;
            uint32_t strLen = *(uint32_t *)(bytes + pos);
            pos += 4;
            printf("Body string length: %u\n", strLen);
            printf("Body string: '");
            for (uint32_t i = 0; i < strLen && pos + i < [realHelloData length]; i++) {
                printf("%c", bytes[pos + i]);
            }
            printf("'\n");
        }
    }
    return 0;
}
