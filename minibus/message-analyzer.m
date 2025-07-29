#import <Foundation/Foundation.h>

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) {
            printf("Usage: %s <hex-data>\n", argv[0]);
            return 1;
        }
        
        NSString *hexString = [NSString stringWithUTF8String:argv[1]];
        
        // Remove spaces and convert to data
        hexString = [hexString stringByReplacingOccurrencesOfString:@" " withString:@""];
        if ([hexString length] % 2 != 0) {
            printf("Error: Hex string must have even length\n");
            return 1;
        }
        
        NSMutableData *data = [NSMutableData data];
        for (NSUInteger i = 0; i < [hexString length]; i += 2) {
            NSString *byteString = [hexString substringWithRange:NSMakeRange(i, 2)];
            unsigned int byteValue;
            [[NSScanner scannerWithString:byteString] scanHexInt:&byteValue];
            uint8_t byte = (uint8_t)byteValue;
            [data appendBytes:&byte length:1];
        }
        
        printf("Analyzing D-Bus message (%lu bytes):\n", [data length]);
        
        if ([data length] < 16) {
            printf("Error: Message too short for header\n");
            return 1;
        }
        
        const uint8_t *bytes = [data bytes];
        
        // Parse fixed header
        uint8_t endian = bytes[0];
        uint8_t type = bytes[1];
        uint8_t flags = bytes[2];
        uint8_t version = bytes[3];
        uint32_t bodyLength = *(uint32_t *)(bytes + 4);
        uint32_t serial = *(uint32_t *)(bytes + 8);
        uint32_t fieldsLength = *(uint32_t *)(bytes + 12);
        
        printf("Fixed Header:\n");
        printf("  Endian: 0x%02x ('%c')\n", endian, endian);
        printf("  Type: %d\n", type);
        printf("  Flags: 0x%02x\n", flags);
        printf("  Version: %d\n", version);
        printf("  Body Length: %u\n", bodyLength);
        printf("  Serial: %u\n", serial);
        printf("  Fields Length: %u\n", fieldsLength);
        
        // Parse header fields
        printf("Header Fields (%u bytes claimed, starting at offset 16):\n", fieldsLength);
        
        NSUInteger fieldsStart = 16;
        NSUInteger fieldsEnd = fieldsStart + fieldsLength;
        
        if (fieldsEnd > [data length]) {
            printf("Error: Fields length extends beyond message\n");
            return 1;
        }
        
        // Hex dump of header fields
        printf("  Hex dump: ");
        for (NSUInteger i = fieldsStart; i < fieldsEnd; i++) {
            printf("%02x ", bytes[i]);
            if ((i - fieldsStart + 1) % 16 == 0) printf("\n            ");
        }
        printf("\n");
        
        // Calculate body start (aligned to 8-byte boundary)
        NSUInteger bodyStart = fieldsEnd;
        NSUInteger aligned = (bodyStart + 7) & ~7; // Align to 8-byte boundary
        NSUInteger padding = aligned - bodyStart;
        
        printf("Body Info:\n");
        printf("  Fields End: %lu\n", fieldsEnd);
        printf("  Body Start (aligned): %lu\n", aligned);
        printf("  Padding: %lu bytes\n", padding);
        printf("  Expected Body Length: %u\n", bodyLength);
        
        if (aligned + bodyLength <= [data length]) {
            printf("  Body Hex: ");
            for (NSUInteger i = aligned; i < aligned + bodyLength; i++) {
                printf("%02x ", bytes[i]);
            }
            printf("\n");
        }
        
        printf("Total Message Length: %lu bytes\n", [data length]);
    }
    return 0;
}
