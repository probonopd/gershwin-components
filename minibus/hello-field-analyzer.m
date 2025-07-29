#import <Foundation/Foundation.h>
#import "MBMessage.h"

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        // Create a Hello message exactly like the working one
        MBMessage *helloMessage = [MBMessage methodCallWithDestination:@"org.freedesktop.DBus"
                                                                   path:@"/org/freedesktop/DBus"
                                                              interface:@"org.freedesktop.DBus"
                                                                 member:@"Hello"
                                                              arguments:@[]];
        helloMessage.serial = 1;
        
        NSData *messageData = [helloMessage serialize];
        NSLog(@"MiniBus Hello message length: %lu", (unsigned long)[messageData length]);
        
        // Extract and analyze header fields
        const uint8_t *bytes = [messageData bytes];
        if ([messageData length] >= 16) {
            uint32_t headerFieldsLength = *(uint32_t *)(bytes + 12);
            NSLog(@"Header fields length: 0x%02x (%u bytes)", headerFieldsLength, headerFieldsLength);
            
            // Expected from working: 0x6e = 110 bytes
            // MiniBus produces: 0x70 = 112 bytes
            NSLog(@"Difference from working (110 bytes): %d bytes", (int)headerFieldsLength - 110);
            
            // Dump the header fields section
            NSLog(@"Header fields hex dump:");
            for (uint32_t i = 16; i < 16 + headerFieldsLength && i < [messageData length]; i += 16) {
                NSMutableString *hexLine = [NSMutableString string];
                NSMutableString *asciiLine = [NSMutableString string];
                
                for (int j = 0; j < 16 && i + j < 16 + headerFieldsLength && i + j < [messageData length]; j++) {
                    uint8_t byte = bytes[i + j];
                    [hexLine appendFormat:@"%02x ", byte];
                    if (byte >= 32 && byte <= 126) {
                        [asciiLine appendFormat:@"%c", byte];
                    } else {
                        [asciiLine appendString:@"."];
                    }
                }
                
                NSLog(@"%04x: %-48s %@", i, [hexLine UTF8String], asciiLine);
            }
            
            // Analyze field structure
            NSLog(@"\nAnalyzing field structure:");
            uint32_t pos = 16; // Start of header fields
            uint32_t fieldEnd = 16 + headerFieldsLength;
            int fieldNum = 0;
            
            while (pos < fieldEnd && pos < [messageData length]) {
                // Align to 8-byte boundary for struct
                while (pos % 8 != 0 && pos < fieldEnd) {
                    NSLog(@"Padding byte at 0x%04x: 0x%02x", pos, bytes[pos]);
                    pos++;
                }
                
                if (pos + 4 > fieldEnd) break;
                
                fieldNum++;
                uint32_t fieldStart = pos;
                uint8_t fieldCode = bytes[pos++];
                uint8_t sigLen = bytes[pos++];
                
                NSLog(@"Field %d at 0x%04x: code=%d, sigLen=%d", fieldNum, fieldStart, fieldCode, sigLen);
                
                if (sigLen > 0 && pos + sigLen < fieldEnd) {
                    // Read signature
                    char signature = bytes[pos];
                    NSLog(@"  Signature: '%c'", signature);
                    pos += sigLen + 1; // skip signature + null
                }
                
                // Align to 4-byte boundary for value
                while (pos % 4 != 0 && pos < fieldEnd) {
                    NSLog(@"  Value alignment padding at 0x%04x: 0x%02x", pos, bytes[pos]);
                    pos++;
                }
                
                if (pos + 4 <= fieldEnd) {
                    uint32_t strLen = *(uint32_t *)(bytes + pos);
                    NSLog(@"  String length: %u", strLen);
                    pos += 4;
                    
                    if (pos + strLen + 1 <= fieldEnd) {
                        NSString *str = [[NSString alloc] initWithBytes:bytes + pos
                                                                 length:strLen
                                                               encoding:NSUTF8StringEncoding];
                        NSLog(@"  String value: '%@'", str);
                        pos += strLen + 1; // string + null terminator
                    }
                }
                
                NSLog(@"  Field ends at 0x%04x", pos);
            }
            
            NSLog(@"\nTotal fields parsed: %d", fieldNum);
            NSLog(@"Final position: 0x%04x", pos);
            NSLog(@"Header fields should end at: 0x%04x", fieldEnd);
        }
        
        // Now compare with the working Hello message bytes
        NSLog(@"\n=== WORKING HELLO MESSAGE FOR COMPARISON ===");
        uint8_t workingHello[] = {
            0x6c, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x6e, 0x00, 0x00, 0x00,
            0x01, 0x01, 0x6f, 0x00, 0x15, 0x00, 0x00, 0x00, 0x2f, 0x6f, 0x72, 0x67, 0x2f, 0x66, 0x72, 0x65,
            0x65, 0x64, 0x65, 0x73, 0x6b, 0x74, 0x6f, 0x70, 0x2f, 0x44, 0x42, 0x75, 0x73, 0x00, 0x00, 0x00,
            0x06, 0x01, 0x73, 0x00, 0x14, 0x00, 0x00, 0x00, 0x6f, 0x72, 0x67, 0x2e, 0x66, 0x72, 0x65, 0x65,
            0x64, 0x65, 0x73, 0x6b, 0x74, 0x6f, 0x70, 0x2e, 0x44, 0x42, 0x75, 0x73, 0x00, 0x00, 0x00, 0x00,
            0x02, 0x01, 0x73, 0x00, 0x14, 0x00, 0x00, 0x00, 0x6f, 0x72, 0x67, 0x2e, 0x66, 0x72, 0x65, 0x65,
            0x64, 0x65, 0x73, 0x6b, 0x74, 0x6f, 0x70, 0x2e, 0x44, 0x42, 0x75, 0x73, 0x00, 0x00, 0x00, 0x00,
            0x03, 0x01, 0x73, 0x00, 0x05, 0x00, 0x00, 0x00, 0x48, 0x65, 0x6c, 0x6c, 0x6f, 0x00, 0x00, 0x00
        };
        
        NSLog(@"Working Hello header fields length: 0x6e (%d bytes)", 0x6e);
        NSLog(@"Header fields hex dump (working):");
        for (uint32_t i = 16; i < 16 + 0x6e; i += 16) {
            NSMutableString *hexLine = [NSMutableString string];
            NSMutableString *asciiLine = [NSMutableString string];
            
            for (int j = 0; j < 16 && i + j < 16 + 0x6e; j++) {
                uint8_t byte = workingHello[i + j];
                [hexLine appendFormat:@"%02x ", byte];
                if (byte >= 32 && byte <= 126) {
                    [asciiLine appendFormat:@"%c", byte];
                } else {
                    [asciiLine appendString:@"."];
                }
            }
            
            NSLog(@"%04x: %-48s %@", i, [hexLine UTF8String], asciiLine);
        }
        
        // Byte-by-byte comparison
        NSLog(@"\n=== BYTE-BY-BYTE COMPARISON ===");
        const uint8_t *minibusBytes = [messageData bytes];
        uint32_t minibusHeaderLen = *(uint32_t *)(minibusBytes + 12);
        
        NSLog(@"Comparing header fields (MiniBus vs Working):");
        uint32_t maxLen = MAX(minibusHeaderLen, 0x6e);
        for (uint32_t i = 0; i < maxLen; i++) {
            uint8_t miniByte = (16 + i < [messageData length]) ? minibusBytes[16 + i] : 0x00;
            uint8_t workByte = (16 + i < sizeof(workingHello)) ? workingHello[16 + i] : 0x00;
            
            if (miniByte != workByte) {
                NSLog(@"DIFF at offset %d: MiniBus=0x%02x Working=0x%02x", i, miniByte, workByte);
            }
        }
    }
    
    return 0;
}
