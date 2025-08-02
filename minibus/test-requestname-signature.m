#import <Foundation/Foundation.h>
#import "MBClient.h"
#import "MBMessage.h"

int main() {
    NSLog(@"Testing RequestName signature fix...");
    
    MBClient *client = [[MBClient alloc] init];
    if (![client connectToPath:@"/tmp/minibus-socket"]) {
        NSLog(@"Failed to connect to MiniBus");
        return 1;
    }
    
    // Test RequestName call 
    NSLog(@"Calling RequestName for com.test.SignatureTest...");
    
    MBMessage *reply = [client callMethod:@"org.freedesktop.DBus"
                                     path:@"/org/freedesktop/DBus"
                                interface:@"org.freedesktop.DBus"
                                   member:@"RequestName"
                                arguments:@[@"com.test.SignatureTest", @0]
                                  timeout:5.0];
    if (reply) {
        NSLog(@"Got reply:");
        NSLog(@"  Type: %lu", (unsigned long)reply.type);
        NSLog(@"  Signature: '%@'", reply.signature);
        NSLog(@"  Arguments: %@", reply.arguments);
        
        if ([reply.signature isEqualToString:@"u"]) {
            NSLog(@"SUCCESS: RequestName returns correct signature 'u' (uint32)");
        } else {
            NSLog(@"FAILED: RequestName returns incorrect signature '%@' (expected 'u')", reply.signature);
        }
    } else {
        NSLog(@"No reply received");
    }
    
    [client disconnect];
    return 0;
}
