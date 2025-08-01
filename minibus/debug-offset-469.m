// Debug tool for analyzing parsing failure at specific offset
#import <Foundation/Foundation.h>
#import "MBMessage.h"

int main() {
    @autoreleasepool {
        NSString *bufferFile = @"/tmp/minibus-buffer-debug.log";
        
        if (![[NSFileManager defaultManager] fileExistsAtPath:bufferFile]) {
            printf("Buffer debug file not found: %s\n", [bufferFile UTF8String]);
            return 1;
        }
        
        NSData *data = [NSData dataWithContentsOfFile:bufferFile];
        printf("Loaded buffer with %lu bytes\n", [data length]);
        
        // Try to parse the message at offset 469 specifically
        NSUInteger offset = 469;
        const uint8_t *bytes = [data bytes];
        
        printf("Analyzing data at offset %lu:\n", offset);
        if (offset + 64 < [data length]) {
            printf("Raw bytes from offset %lu:\n", offset);
            for (NSUInteger i = 0; i < 64 && offset + i < [data length]; i += 16) {
                printf("%04lx: ", offset + i);
                for (NSUInteger j = 0; j < 16 && offset + i + j < [data length]; j++) {
                    printf("%02x ", bytes[offset + i + j]);
                }
                printf("\n");
            }
        }
        
        // Check if this looks like a valid D-Bus message start
        if (offset + 16 <= [data length]) {
            uint8_t endian = bytes[offset];
            uint8_t type = bytes[offset + 1];
            uint8_t flags = bytes[offset + 2];
            uint8_t version = bytes[offset + 3];
            
            printf("\nHeader analysis at offset %lu:\n", offset);
            printf("Endianness: %02x (%s)\n", endian, 
                   endian == 0x6c ? "little-endian" : endian == 0x42 ? "big-endian" : "INVALID");
            printf("Type: %u (%s)\n", type, 
                   type == 1 ? "method_call" : type == 2 ? "method_return" : 
                   type == 3 ? "error" : type == 4 ? "signal" : "INVALID");
            printf("Flags: %02x\n", flags);
            printf("Version: %u\n", version);
            
            if (endian == 0x6c || endian == 0x42) {
                uint32_t bodyLength = *(uint32_t *)(bytes + offset + 4);
                uint32_t serial = *(uint32_t *)(bytes + offset + 8);
                uint32_t fieldsLength = *(uint32_t *)(bytes + offset + 12);
                
                // Apply endianness
                if (endian == 0x6c) { // little-endian
                    bodyLength = NSSwapLittleIntToHost(bodyLength);
                    serial = NSSwapLittleIntToHost(serial);
                    fieldsLength = NSSwapLittleIntToHost(fieldsLength);
                } else { // big-endian
                    bodyLength = NSSwapBigIntToHost(bodyLength);
                    serial = NSSwapBigIntToHost(serial);
                    fieldsLength = NSSwapBigIntToHost(fieldsLength);
                }
                
                printf("Body length: %u\n", bodyLength);
                printf("Serial: %u\n", serial);
                printf("Fields length: %u\n", fieldsLength);
                
                // Calculate expected message bounds
                NSUInteger headerFieldsEnd = offset + 16 + fieldsLength;
                NSUInteger bodyStart = (headerFieldsEnd + 7) & ~7; // 8-byte align
                NSUInteger messageEnd = bodyStart + bodyLength;
                
                printf("Header fields end: %lu\n", headerFieldsEnd);
                printf("Body start (aligned): %lu\n", bodyStart);
                printf("Message end: %lu\n", messageEnd);
                printf("Buffer length: %lu\n", [data length]);
                
                if (messageEnd > [data length]) {
                    printf("ERROR: Message would extend beyond buffer!\n");
                } else {
                    printf("Message bounds look valid.\n");
                }
            }
        }
        
        // Try to parse this specific message using our parser
        printf("\nAttempting to parse with MBMessage:\n");
        MBMessage *message = [MBMessage messageFromData:data offset:&offset];
        if (message) {
            printf("Successfully parsed message:\n");
            printf("  Type: %u\n", message.type);
            printf("  Serial: %lu\n", message.serial);
            printf("  Member: %s\n", message.member ? [message.member UTF8String] : "(null)");
            printf("  Interface: %s\n", message.interface ? [message.interface UTF8String] : "(null)");
            printf("  Destination: %s\n", message.destination ? [message.destination UTF8String] : "(null)");
            printf("  Arguments: %lu\n", [message.arguments count]);
        } else {
            printf("FAILED to parse message (returned nil)\n");
        }
    }
    return 0;
}
