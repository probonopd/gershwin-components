#import <Foundation/Foundation.h>
#import "MBClient.h"
#import "MBMessage.h"

int main() {
    NSLog(@"Testing StartServiceByName signature fix...");
    
    MBClient *client = [[MBClient alloc] init];
    if (![client connectToPath:@"/tmp/minibus-socket"]) {
        NSLog(@"Failed to connect to MiniBus");
        return 1;
    }
    
    // Test StartServiceByName call for org.freedesktop.DBus (should return DBUS_START_REPLY_ALREADY_RUNNING = 1)
    NSLog(@"Calling StartServiceByName for org.freedesktop.DBus...");
    
    MBMessage *reply = [client callMethod:@"org.freedesktop.DBus"
                                     path:@"/org/freedesktop/DBus"
                                interface:@"org.freedesktop.DBus"
                                   member:@"StartServiceByName"
                                arguments:@[@"org.freedesktop.DBus", @0]
                                  timeout:5.0];
    if (reply) {
        NSLog(@"Got reply:");
        NSLog(@"  Type: %lu", (unsigned long)reply.type);
        NSLog(@"  Signature: '%@'", reply.signature);
        NSLog(@"  Arguments: %@", reply.arguments);
        
        if ([reply.signature isEqualToString:@"u"]) {
            NSLog(@"SUCCESS: StartServiceByName returns correct signature 'u' (uint32)");
        } else {
            NSLog(@"FAILED: StartServiceByName returns incorrect signature '%@' (expected 'u')", reply.signature);
        }
    } else {
        NSLog(@"No reply received");
    }
    
    [client disconnect];
    return 0;
}
