#import <Foundation/Foundation.h>
#import "MBClient.h"
#import "MBMessage.h"

int main(int argc, const char * argv[])
{
    @autoreleasepool {
        NSString *socketPath = @"/tmp/minibus-socket";
        NSString *serviceName = @"com.example.TestService";
        
        if (argc > 1) {
            socketPath = [NSString stringWithUTF8String:argv[1]];
        }
        if (argc > 2) {
            serviceName = [NSString stringWithUTF8String:argv[2]];
        }
        
        NSLog(@"Testing StartServiceByName for %@", serviceName);
        
        MBClient *client = [[MBClient alloc] init];
        
        if (![client connectToPath:socketPath]) {
            NSLog(@"Failed to connect to daemon");
            return 1;
        }
        
        NSLog(@"Connected! Unique name: %@", client.uniqueName);
        
        NSLog(@"Sending StartServiceByName request...");
        MBMessage *reply = [client callMethod:@"org.freedesktop.DBus"
                                         path:@"/org/freedesktop/DBus"
                                    interface:@"org.freedesktop.DBus"
                                       member:@"StartServiceByName"
                                    arguments:@[serviceName, @0]
                                      timeout:30.0];
        
        if (reply && reply.type == MBMessageTypeMethodReturn) {
            if ([reply.arguments count] > 0) {
                NSUInteger result = [[reply.arguments objectAtIndex:0] unsignedIntegerValue];
                switch (result) {
                    case 1:
                        NSLog(@"SUCCESS: Service was already running");
                        break;
                    case 2:
                        NSLog(@"SUCCESS: Service was started");
                        break;
                    default:
                        NSLog(@"SUCCESS: StartServiceByName returned %lu", (unsigned long)result);
                        break;
                }
            } else {
                NSLog(@"SUCCESS: StartServiceByName completed");
            }
        } else if (reply && reply.type == MBMessageTypeError) {
            NSLog(@"ERROR: StartServiceByName failed: %@", reply.errorName);
            if ([reply.arguments count] > 0) {
                NSLog(@"Error message: %@", [reply.arguments objectAtIndex:0]);
            }
            return 1;
        } else {
            NSLog(@"ERROR: No reply or timeout");
            return 1;
        }
        
        [client disconnect];
        [client release];
    }
    return 0;
}
