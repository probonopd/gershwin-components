#import <Foundation/Foundation.h>
#import "MBMessage.h"

int main(int argc, char *argv[]) {
    @autoreleasepool {
        // Create a simple ListNames reply message
        NSArray *names = @[@"org.freedesktop.DBus", @":1.1"];
        MBMessage *reply = [MBMessage methodReturnWithReplySerial:1 arguments:@[names]];
        reply.sender = @"org.freedesktop.DBus";
        reply.destination = @":1.1";
        
        NSData *serialized = [reply serialize];
        NSLog(@"Serialized %lu bytes", (unsigned long)[serialized length]);
        
        // Print hex dump
        const uint8_t *bytes = [serialized bytes];
        printf("Hex dump:\n");
        for (NSUInteger i = 0; i < [serialized length]; i++) {
            printf("%02x ", bytes[i]);
            if ((i + 1) % 16 == 0) printf("\n");
        }
        printf("\n");
        
        return 0;
    }
}
