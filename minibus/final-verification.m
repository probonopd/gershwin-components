#import <Foundation/Foundation.h>
#import "MBMessage.h"

void printBytes(NSData *data, NSString *label) {
    const uint8_t *bytes = (const uint8_t *)[data bytes];
    printf("%s (%lu bytes):\n", [label UTF8String], (unsigned long)[data length]);
    
    for (NSUInteger i = 0; i < [data length]; i++) {
        printf("%02x ", bytes[i]);
        if ((i + 1) % 16 == 0) printf("\n");
    }
    if ([data length] % 16 != 0) printf("\n");
    printf("\n");
}

int main() {
    @autoreleasepool {
        printf("=== Final MiniBus Message Serialization Verification ===\n\n");
        
        // Create the exact Hello reply that MiniBus generates
        MBMessage *helloReply = [MBMessage methodReturnWithReplySerial:1 arguments:@[@":1.0"]];
        helloReply.sender = @"org.freedesktop.DBus";
        helloReply.destination = @":1.0";
        
        NSData *serialized = [helloReply serialize];
        printBytes(serialized, @"MiniBus Hello Reply");
        
        // Parse the known real daemon reply for comparison
        uint8_t realDaemonBytes[] = {
            0x6c, 0x02, 0x01, 0x01, 0x09, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x3d, 0x00, 0x00, 0x00,
            0x06, 0x01, 0x73, 0x00, 0x04, 0x00, 0x00, 0x00, 0x3a, 0x31, 0x2e, 0x30, 0x00, 0x00, 0x00, 0x00,
            0x05, 0x01, 0x75, 0x00, 0x01, 0x00, 0x00, 0x00, 0x08, 0x01, 0x67, 0x00, 0x01, 0x73, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x3a, 0x31, 0x2e, 0x30,
            0x00
        };
        
        NSData *realData = [NSData dataWithBytes:realDaemonBytes length:sizeof(realDaemonBytes)];
        printBytes(realData, @"Real dbus-daemon Hello Reply");
        
        // Compare byte by byte
        BOOL identical = [serialized isEqualToData:realData];
        printf("Byte-for-byte comparison: %s\n", identical ? "✅ IDENTICAL" : "❌ DIFFERENT");
        
        if (!identical) {
            printf("\nDifferences:\n");
            const uint8_t *minibusBytes = (const uint8_t *)[serialized bytes];
            const uint8_t *realBytes = (const uint8_t *)[realData bytes];
            NSUInteger minLen = MIN([serialized length], [realData length]);
            
            for (NSUInteger i = 0; i < minLen; i++) {
                if (minibusBytes[i] != realBytes[i]) {
                    printf("Position %lu: MiniBus=0x%02x, Real=0x%02x\n", 
                           (unsigned long)i, minibusBytes[i], realBytes[i]);
                }
            }
        }
        
        printf("\n=== D-Bus Message Header Analysis ===\n");
        printf("Endian: %s (0x%02x)\n", 
               realDaemonBytes[0] == 0x6c ? "Little-endian" : "Big-endian", realDaemonBytes[0]);
        printf("Message type: %u (METHOD_RETURN)\n", realDaemonBytes[1]);
        printf("Flags: %u\n", realDaemonBytes[2]);
        printf("Protocol version: %u\n", realDaemonBytes[3]);
        
        uint32_t bodyLength = *((uint32_t*)(realDaemonBytes + 4));
        uint32_t serial = *((uint32_t*)(realDaemonBytes + 8));
        uint32_t fieldsLength = *((uint32_t*)(realDaemonBytes + 12));
        
        printf("Body length: %u bytes\n", bodyLength);
        printf("Serial: %u\n", serial);
        printf("Header fields length: %u (0x%02x) bytes\n", fieldsLength, fieldsLength);
        
        printf("\n=== Final Result ===\n");
        printf("MiniBus D-Bus message serialization: %s\n", 
               identical ? "✅ PERFECT - Byte-for-byte identical to real dbus-daemon" 
                        : "❌ INCORRECT");
        
        return identical ? 0 : 1;
    }
}
