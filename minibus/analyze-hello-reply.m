#import <Foundation/Foundation.h>
#import "MBMessage.h"

int main(int argc, char *argv[]) {
    @autoreleasepool {
        // Create a Hello reply message like MiniBus does
        MBMessage *reply = [MBMessage methodReturnWithReplySerial:1
                                                        arguments:@[@":1.1"]];
        reply.sender = @"org.freedesktop.DBus";
        
        NSLog(@"MiniBus Hello Reply Message:");
        NSLog(@"Type: %d", reply.type);
        NSLog(@"Reply Serial: %lu", reply.replySerial);  
        NSLog(@"Sender: %@", reply.sender);
        NSLog(@"Arguments: %@", reply.arguments);
        NSLog(@"Signature: %@", reply.signature);
        
        // Serialize it to see the raw bytes
        NSData *data = [reply serialize];
        NSLog(@"Serialized size: %lu bytes", [data length]);
        
        // Print hex dump
        const uint8_t *bytes = [data bytes];
        NSMutableString *hex = [NSMutableString string];
        for (NSUInteger i = 0; i < [data length]; i++) {
            [hex appendFormat:@"%02x ", bytes[i]];
            if ((i + 1) % 16 == 0) [hex appendString:@"\n"];
        }
        NSLog(@"Raw bytes:\n%@", hex);
        
        // Parse it back to verify
        MBMessage *parsed = [MBMessage messageFromData:data atOffset:0];
        if (parsed) {
            NSLog(@"Successfully parsed back: %@", parsed);
        } else {
            NSLog(@"Failed to parse back!");
        }
    }
    return 0;
}
