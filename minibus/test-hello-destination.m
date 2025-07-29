#import <Foundation/Foundation.h>
#import "MBMessage.h"

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
        printf("=== Testing Actual Hello Handler Logic ===\n");
        
        // Simulate what the Hello handler does
        NSString *uniqueName = @":1.0";
        NSUInteger messageSerial = 1;
        
        // Create reply as Hello handler does  
        MBMessage *reply = [MBMessage methodReturnWithReplySerial:messageSerial
                                                        arguments:@[uniqueName]];
        reply.destination = uniqueName;  // This is what we changed
        
        printf("Reply properties:\n");
        printf("  Type: %d\n", reply.type);
        printf("  Reply Serial: %lu\n", reply.replySerial);
        printf("  Destination: %s\n", reply.destination ? [reply.destination UTF8String] : "nil");
        printf("  Sender: %s\n", reply.sender ? [reply.sender UTF8String] : "nil");
        printf("  Arguments: %s\n", [[reply.arguments description] UTF8String]);
        printf("  Signature: %s\n", reply.signature ? [reply.signature UTF8String] : "nil");
        
        NSData *replyData = [reply serialize];
        printHexDump(replyData, "MiniBus Hello Reply with destination");
        
        // Compare with real daemon
        uint8_t realHelloBytes[] = {
            0x6c, 0x02, 0x01, 0x01, 0x09, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x3d, 0x00, 0x00, 0x00,
            0x06, 0x01, 0x73, 0x00, 0x04, 0x00, 0x00, 0x00, 0x3a, 0x31, 0x2e, 0x30, 0x00, 0x00, 0x00, 0x00,
            0x05, 0x01, 0x75, 0x00, 0x01, 0x00, 0x00, 0x00, 0x08, 0x01, 0x67, 0x00, 0x01, 0x73, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x3a, 0x31, 0x2e, 0x30,
            0x00
        };
        NSData *realHelloData = [NSData dataWithBytes:realHelloBytes length:sizeof(realHelloBytes)];
        printHexDump(realHelloData, "Real dbus-daemon Hello Reply");
        
        printf("\nField analysis:\n");
        printf("Real daemon fields: DESTINATION=':1.0', REPLY_SERIAL=1, SIGNATURE='s'\n");
        printf("MiniBus fields: ");
        
        if (reply.destination) printf("DESTINATION='%s', ", [reply.destination UTF8String]);
        if (reply.sender) printf("SENDER='%s', ", [reply.sender UTF8String]);
        printf("REPLY_SERIAL=%lu, ", reply.replySerial);
        if (reply.signature) printf("SIGNATURE='%s'", [reply.signature UTF8String]);
        printf("\n");
    }
    return 0;
}
