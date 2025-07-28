#import <Foundation/Foundation.h>
#import "MBClient.h"
#import "MBMessage.h"

int main(int argc __attribute__((unused)), const char * argv[] __attribute__((unused)))
{
    @autoreleasepool {
        NSLog(@"Simple MiniBus Test");
        
        MBClient *client = [[MBClient alloc] init];
        
        // Connect to daemon
        if (![client connectToPath:@"/tmp/minibus-socket"]) {
            NSLog(@"Failed to connect - is the daemon running?");
            return 1;
        }
        
        NSLog(@"✓ Connected to MiniBus daemon");
        NSLog(@"✓ Unique name: %@", client.uniqueName);
        
        // Simple ping test
        NSLog(@"Testing basic D-Bus functionality...");
        
        MBMessage *reply = [client callMethod:@"org.freedesktop.DBus"
                                         path:@"/org/freedesktop/DBus"
                                    interface:@"org.freedesktop.DBus" 
                                       member:@"ListNames"
                                    arguments:@[]
                                      timeout:3.0];
        
        if (reply && reply.type == MBMessageTypeMethodReturn) {
            NSLog(@"✓ D-Bus method call successful!");
            NSLog(@"✓ Available names: %@", reply.arguments);
        } else {
            NSLog(@"✗ D-Bus method call failed");
            return 1;
        }
        
        NSLog(@"✓ All tests passed - MiniBus is working!");
        
        [client disconnect];
    }
    
    return 0;
}
