#import <Foundation/Foundation.h>
#import "MBMessage.h"

int main(int argc, char *argv[]) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    // Create test data that mimics the problematic payload from the error
    // This is a simplified version of the 68-byte message that caused the issue
    NSMutableData *testData = [NSMutableData data];
    
    // D-Bus fixed header (16 bytes)
    uint8_t header[] = {
        0x6c,               // little endian
        0x02,               // method return message
        0x01,               // flags
        0x01,               // version
        0x04, 0x00, 0x00, 0x00,  // body length = 4
        0x1a, 0x00, 0x00, 0x00,  // serial = 26
        0x2f, 0x00, 0x00, 0x00   // header fields length = 47
    };
    [testData appendBytes:header length:16];
    
    // Header fields - these mimic the problematic signature field
    // Field 8 (signature): type='g', length=1, value="v"
    uint8_t fields[] = {
        // First field padding to 8-byte boundary
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        
        // Field 8 - signature field (this is where the problem was)
        0x08,               // field code = 8 (signature)
        0x01,               // variant signature length = 1
        0x67,               // variant signature type = 'g' (signature)
        0x00,               // null terminator
        
        0x01,               // signature length = 1 
        0x76,               // signature = "v" (THIS IS THE PROBLEM - invalid!)
        0x00,               // null terminator
        0x00,               // padding
        
        // End of fields
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    };
    [testData appendBytes:fields length:47];
    
    // Pad to 8-byte boundary for body
    while ([testData length] % 8 != 0) {
        uint8_t pad = 0;
        [testData appendBytes:&pad length:1];
    }
    
    // Body data (4 bytes as specified in header)
    uint8_t body[] = { 0x00, 0x00, 0x00, 0x00 };
    [testData appendBytes:body length:4];
    
    printf("Testing variant signature validation with problematic message:\n");
    printf("Total test data length: %lu bytes\n", [testData length]);
    
    // Hex dump the test data
    const uint8_t *bytes = [testData bytes];
    for (NSUInteger i = 0; i < [testData length]; i += 16) {
        printf("%04lx: ", i);
        for (NSUInteger j = 0; j < 16 && i + j < [testData length]; j++) {
            printf("%02x ", bytes[i + j]);
        }
        printf("\n");
    }
    
    printf("\nAttempting to parse message with invalid signature field 'v'...\n");
    
    // Try to parse this problematic message
    NSArray *messages = [MBMessage messagesFromData:testData];
    
    printf("Parsing result: %lu messages parsed\n", [messages count]);
    
    if ([messages count] > 0) {
        MBMessage *msg = [messages objectAtIndex:0];
        printf("Message type: %d\n", (int)msg.type);
        printf("Message signature: '%s'\n", [msg.signature UTF8String] ?: "(null)");
        printf("Message serial: %lu\n", (unsigned long)msg.serial);
        
        // The fix should have replaced the invalid "v" signature with empty string
        if (!msg.signature || [msg.signature isEqualToString:@""]) {
            printf("✓ SUCCESS: Invalid signature 'v' was properly handled\n");
        } else if ([msg.signature isEqualToString:@"v"]) {
            printf("✗ FAILURE: Invalid signature 'v' was not caught by validation\n");
        } else {
            printf("? UNEXPECTED: Signature is '%s' (expected empty string)\n", [msg.signature UTF8String]);
        }
    } else {
        printf("? No messages parsed - this could indicate validation rejected the message\n");
    }
    
    printf("\nTest completed.\n");
    
    [pool release];
    return 0;
}
