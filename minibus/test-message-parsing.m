#import <Foundation/Foundation.h>
#import "MBMessage.h"

static void debug_hexdump(NSData *data, NSString *prefix) {
    const uint8_t *bytes = [data bytes];
    NSUInteger length = [data length];
    
    printf("%s (%lu bytes):\n", [prefix UTF8String], length);
    for (NSUInteger i = 0; i < length; i += 16) {
        printf("%04lx: ", i);
        
        // Print hex bytes
        for (NSUInteger j = 0; j < 16; j++) {
            if (i + j < length) {
                printf("%02x ", bytes[i + j]);
            } else {
                printf("   ");
            }
        }
        
        printf(" ");
        
        // Print ASCII
        for (NSUInteger j = 0; j < 16 && i + j < length; j++) {
            uint8_t byte = bytes[i + j];
            printf("%c", (byte >= 32 && byte < 127) ? byte : '.');
        }
        
        printf("\n");
    }
    printf("\n");
}

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        // This is the raw bytes from the problematic message that creates the null fields
        // Let's examine what's in our test to understand the parsing
        
        // Simple test - a basic D-Bus method call message bytes
        uint8_t testBytes[] = {
            0x6c, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x6e, 0x00, 0x00, 0x00,
            0x01, 0x01, 0x6f, 0x00, 0x15, 0x00, 0x00, 0x00, 0x2f, 0x6f, 0x72, 0x67, 0x2f, 0x66, 0x72, 0x65,
            0x65, 0x64, 0x65, 0x73, 0x6b, 0x74, 0x6f, 0x70, 0x2f, 0x44, 0x42, 0x75, 0x73, 0x00, 0x00, 0x00,
            0x02, 0x01, 0x73, 0x00, 0x14, 0x00, 0x00, 0x00, 0x6f, 0x72, 0x67, 0x2e, 0x66, 0x72, 0x65, 0x65,
            0x64, 0x65, 0x73, 0x6b, 0x74, 0x6f, 0x70, 0x2e, 0x44, 0x42, 0x75, 0x73, 0x00, 0x00, 0x00, 0x00,
            0x03, 0x01, 0x73, 0x00, 0x0f, 0x00, 0x00, 0x00, 0x53, 0x74, 0x61, 0x72, 0x74, 0x53, 0x65, 0x72,
            0x76, 0x69, 0x63, 0x65, 0x42, 0x79, 0x4e, 0x61, 0x6d, 0x65, 0x00, 0x00, 0x06, 0x01, 0x73, 0x00,
            0x14, 0x00, 0x00, 0x00, 0x6f, 0x72, 0x67, 0x2e, 0x66, 0x72, 0x65, 0x65, 0x64, 0x65, 0x73, 0x6b,
            0x74, 0x6f, 0x70, 0x2e, 0x44, 0x42, 0x75, 0x73, 0x00, 0x00, 0x00, 0x00, 0x08, 0x01, 0x67, 0x00,
            0x02, 0x73, 0x75, 0x00
        };
        
        NSData *testData = [NSData dataWithBytes:testBytes length:sizeof(testBytes)];
        
        printf("Testing message parsing with known StartServiceByName message:\n");
        debug_hexdump(testData, @"Raw bytes");
        
        MBMessage *message = [MBMessage messageFromData:testData offset:NULL];
        if (message) {
            printf("Parsed message successfully:\n");
            printf("  Type: %u\n", message.type);
            printf("  Serial: %lu\n", message.serial);
            printf("  Path: %s\n", message.path ? [message.path UTF8String] : "(null)");
            printf("  Interface: %s\n", message.interface ? [message.interface UTF8String] : "(null)");
            printf("  Member: %s\n", message.member ? [message.member UTF8String] : "(null)");
            printf("  Destination: %s\n", message.destination ? [message.destination UTF8String] : "(null)");
            printf("  Signature: %s\n", message.signature ? [message.signature UTF8String] : "(null)");
            if (message.arguments) {
                printf("  Arguments: %s\n", [[message.arguments description] UTF8String]);
            }
        } else {
            printf("Failed to parse message!\n");
        }
        
        // Now test parsing multiple messages from a buffer
        NSMutableData *multiData = [NSMutableData data];
        [multiData appendData:testData];  // First message
        [multiData appendData:testData];  // Second message (duplicate for testing)
        
        printf("\nTesting multiple message parsing:\n");
        debug_hexdump(multiData, @"Multi-message buffer");
        
        NSArray *messages = [MBMessage messagesFromData:multiData];
        printf("Parsed %lu messages\n", [messages count]);
        
        for (NSUInteger i = 0; i < [messages count]; i++) {
            MBMessage *msg = messages[i];
            printf("Message %lu: type=%u, serial=%lu, destination=%s\n", 
                   i, msg.type, msg.serial, 
                   msg.destination ? [msg.destination UTF8String] : "(null)");
        }
    }
    
    return 0;
}
