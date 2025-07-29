#import <Foundation/Foundation.h>
#import "MBClient.h"
#import "MBMessage.h"

int main(int argc, const char * argv[])
{
    @autoreleasepool {
        NSLog(@"MiniBus Simple Test Client - Testing message format only");
        
        NSString *socketPath = @"/tmp/minibus-socket";
        if (argc > 1) {
            socketPath = [NSString stringWithUTF8String:argv[1]];
        }
        
        MBClient *client = [[MBClient alloc] init];
        
        NSLog(@"Connecting to daemon at %@...", socketPath);
        if (![client connectToPathWithoutHello:socketPath]) {
            NSLog(@"Failed to connect to daemon");
            return 1;
        }
        
        NSLog(@"Connected! Testing ListNames method call...");
        
        // Test ListNames without sending Hello first
        MBMessage *listReply = [client callMethod:@"org.freedesktop.DBus"
                                             path:@"/org/freedesktop/DBus"
                                        interface:@"org.freedesktop.DBus"
                                           member:@"ListNames"
                                        arguments:@[]
                                          timeout:5.0];
        
        if (listReply && listReply.type == MBMessageTypeMethodReturn) {
            NSLog(@"SUCCESS! ListNames returned: %@", listReply.arguments);
        } else if (listReply && listReply.type == MBMessageTypeError) {
            NSLog(@"ERROR from daemon: %@ - %@", listReply.errorName, listReply.arguments);
        } else {
            NSLog(@"Failed to get ListNames response");
        }
        
        NSLog(@"Test completed!");
        [client disconnect];
    }
    
    return 0;
}
