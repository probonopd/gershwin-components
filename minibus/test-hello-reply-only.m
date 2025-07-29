#import <Foundation/Foundation.h>
#import "MBMessage.h"

int main(int argc, char *argv[]) {
    @autoreleasepool {
        // Create Hello reply exactly as MBDaemon does
        MBMessage *reply = [MBMessage methodReturnWithReplySerial:1
                                                        arguments:@[@":1.0"]];
        reply.destination = @":1.0";  // Reply is addressed to the client
        reply.sender = @"org.freedesktop.DBus";  // Bus daemon is the sender
        
        NSLog(@"Hello Reply Properties:");
        NSLog(@"  Type: %d", reply.type);
        NSLog(@"  Reply Serial: %ld", reply.replySerial);
        NSLog(@"  Destination: %@", reply.destination);
        NSLog(@"  Signature: %@", reply.signature);
        NSLog(@"  Arguments: %@", reply.arguments);
        
        NSData *data = [reply serialize];
        
        printf("Hello Reply Only (%lu bytes):\n", (unsigned long)[data length]);
        const uint8_t *bytes = [data bytes];
        for (NSUInteger i = 0; i < [data length]; i += 16) {
            for (NSUInteger j = 0; j < 16 && i + j < [data length]; j++) {
                printf("%02x ", bytes[i + j]);
            }
            printf("\n");
        }
        
        return 0;
    }
}
