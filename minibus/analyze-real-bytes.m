#import <Foundation/Foundation.h>

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        // Real daemon bytes from the hex dump
        uint8_t realBytes[] = {
            0x6c, 0x02, 0x01, 0x01, 0x09, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x3d, 0x00, 0x00, 0x00,
            0x06, 0x01, 0x73, 0x00, 0x04, 0x00, 0x00, 0x00, 0x3a, 0x31, 0x2e, 0x30, 0x00, 0x00, 0x00, 0x00,
            0x05, 0x01, 0x75, 0x00, 0x01, 0x00, 0x00, 0x00, 0x08, 0x01, 0x67, 0x00, 0x01, 0x73, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x3a, 0x31, 0x2e, 0x30,
            0x00
        };
        
        NSLog(@"=== Real daemon message analysis ===");
        NSLog(@"Total length: %lu bytes", sizeof(realBytes));
        
        // Parse fixed header
        NSLog(@"\n--- Fixed Header (16 bytes) ---");
        NSLog(@"Endian: 0x%02x", realBytes[0]);
        NSLog(@"Type: 0x%02x", realBytes[1]);
        NSLog(@"Flags: 0x%02x", realBytes[2]);
        NSLog(@"Version: 0x%02x", realBytes[3]);
        
        uint32_t bodyLength = *(uint32_t*)(realBytes + 4);
        uint32_t serial = *(uint32_t*)(realBytes + 8);
        uint32_t fieldsLength = *(uint32_t*)(realBytes + 12);
        
        NSLog(@"Body length: %u", bodyLength);
        NSLog(@"Serial: %u", serial);
        NSLog(@"Fields length: %u", fieldsLength);
        
        // Parse header fields
        NSLog(@"\n--- Header Fields (%u bytes starting at offset 16) ---", fieldsLength);
        
        uint8_t *fieldsStart = realBytes + 16;
        uint8_t *fieldsEnd = fieldsStart + fieldsLength;
        uint8_t *bodyStart = fieldsEnd;
        
        NSLog(@"Fields start at: %ld, end at: %ld", fieldsStart - realBytes, fieldsEnd - realBytes);
        NSLog(@"Body starts at: %ld", bodyStart - realBytes);
        
        // Parse each field
        uint8_t *pos = fieldsStart;
        int fieldNum = 1;
        while (pos < fieldsEnd) {
            if (*pos == 0) {
                NSLog(@"Padding byte at offset %ld", pos - realBytes);
                pos++;
                continue;
            }
            
            NSLog(@"\nField %d at offset %ld:", fieldNum++, pos - realBytes);
            uint8_t fieldCode = *pos++;
            NSLog(@"  Field code: %u", fieldCode);
            
            uint8_t sigLen = *pos++;
            NSLog(@"  Signature length: %u", sigLen);
            
            NSLog(@"  Signature: ");
            for (int i = 0; i < sigLen; i++) {
                printf("%c", *pos++);
            }
            printf("\n");
            
            uint8_t nullTerm = *pos++;
            NSLog(@"  Null terminator: 0x%02x", nullTerm);
            
            // Align to 4 for the value
            while ((pos - realBytes) % 4 != 0) {
                NSLog(@"  Value alignment padding at %ld: 0x%02x", pos - realBytes, *pos);
                pos++;
            }
            
            if (fieldCode == 6 || fieldCode == 7) { // String fields
                uint32_t strLen = *(uint32_t*)pos;
                pos += 4;
                NSLog(@"  String length: %u", strLen);
                NSLog(@"  String value: ");
                for (uint32_t i = 0; i < strLen; i++) {
                    printf("%c", *pos++);
                }
                printf("\n");
                pos++; // null terminator
            } else if (fieldCode == 5) { // uint32 field
                uint32_t value = *(uint32_t*)pos;
                pos += 4;
                NSLog(@"  Uint32 value: %u", value);
            } else if (fieldCode == 8) { // signature field
                uint8_t sigStrLen = *pos++;
                NSLog(@"  Signature string length: %u", sigStrLen);
                NSLog(@"  Signature string: ");
                for (int i = 0; i < sigStrLen; i++) {
                    printf("%c", *pos++);
                }
                printf("\n");
                pos++; // null terminator
            }
            
            // Align to 8 for next struct
            while (pos < fieldsEnd && (pos - fieldsStart) % 8 != 0) {
                NSLog(@"  Struct alignment padding at %ld: 0x%02x", pos - realBytes, *pos);
                pos++;
            }
        }
        
        NSLog(@"\n--- Body (%u bytes starting at offset %ld) ---", bodyLength, bodyStart - realBytes);
        for (uint32_t i = 0; i < bodyLength && (bodyStart + i - realBytes) < sizeof(realBytes); i++) {
            NSLog(@"Body[%u] = 0x%02x ('%c')", i, bodyStart[i], bodyStart[i] >= 32 && bodyStart[i] < 127 ? bodyStart[i] : '.');
        }
    }
    return 0;
}
