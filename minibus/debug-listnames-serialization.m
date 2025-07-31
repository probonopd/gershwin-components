#import <Foundation/Foundation.h>
#import "MBMessage.h"

int main(void) {
    @autoreleasepool {
        NSLog(@"=== TESTING LISTNAMES SERIALIZATION ===");
        
        // Create the same array that would be sent in ListNames
        NSArray *names = @[@"org.freedesktop.DBus", @"org.xfce.Panel", @":1.1"];
        
        // Create a ListNames reply message
        MBMessage *reply = [MBMessage methodReturnWithReplySerial:19 arguments:@[names]];
        reply.sender = @"org.freedesktop.DBus";
        reply.destination = @":1.1";
        
        NSLog(@"Reply signature: %@", reply.signature);
        NSLog(@"Reply arguments: %@", reply.arguments);
        
        // Serialize it
        NSData *serialized = [reply serialize];
        NSLog(@"Serialized to %lu bytes", (unsigned long)[serialized length]);
        
        // Print hex dump
        const uint8_t *bytes = [serialized bytes];
        for (NSUInteger i = 0; i < [serialized length]; i += 16) {
            printf("%04lx: ", (unsigned long)i);
            for (NSUInteger j = 0; j < 16 && i + j < [serialized length]; j++) {
                printf("%02x ", bytes[i + j]);
            }
            printf("\\n");
        }
        
        // Try to parse it back
        NSLog(@"\\n=== TESTING PARSING ===");
        NSUInteger offset = 0;
        MBMessage *parsed = [MBMessage messageFromData:serialized offset:&offset];
        
        if (parsed) {
            NSLog(@"Successfully parsed back!");
            NSLog(@"Parsed signature: %@", parsed.signature);
            NSLog(@"Parsed arguments: %@", parsed.arguments);
        } else {
            NSLog(@"FAILED to parse back!");
        }
    }
    return 0;
}
