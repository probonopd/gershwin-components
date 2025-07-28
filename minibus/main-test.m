#import <Foundation/Foundation.h>
#import "MBClient.h"
#import "MBMessage.h"

int main(int argc, const char * argv[])
{
    @autoreleasepool {
        NSLog(@"MiniBus Test Client");
        
        NSString *socketPath = @"/tmp/minibus-socket";
        if (argc > 1) {
            socketPath = [NSString stringWithUTF8String:argv[1]];
        }
        
        MBClient *client = [[MBClient alloc] init];
        
        NSLog(@"Connecting to daemon at %@...", socketPath);
        if (![client connectToPath:socketPath]) {
            NSLog(@"Failed to connect to daemon");
            return 1;
        }
        
        NSLog(@"Connected! Unique name: %@", client.uniqueName);
        
        // Test 1: Request a name
        NSLog(@"Testing name registration...");
        NSString *testName = @"com.example.TestService";
        if ([client requestName:testName]) {
            NSLog(@"Successfully registered name: %@", testName);
        } else {
            NSLog(@"Failed to register name: %@", testName);
        }
        
        // Test 2: List names
        NSLog(@"Testing ListNames...");
        MBMessage *listReply = [client callMethod:@"org.freedesktop.DBus"
                                             path:@"/org/freedesktop/DBus"
                                        interface:@"org.freedesktop.DBus"
                                           member:@"ListNames"
                                        arguments:@[]
                                          timeout:5.0];
        
        if (listReply && listReply.type == MBMessageTypeMethodReturn) {
            NSLog(@"Available names: %@", listReply.arguments);
        } else {
            NSLog(@"Failed to list names");
        }
        
        // Test 3: Get name owner
        NSLog(@"Testing GetNameOwner...");
        MBMessage *ownerReply = [client callMethod:@"org.freedesktop.DBus"
                                              path:@"/org/freedesktop/DBus"
                                         interface:@"org.freedesktop.DBus"
                                            member:@"GetNameOwner"
                                         arguments:@[testName]
                                           timeout:5.0];
        
        if (ownerReply && ownerReply.type == MBMessageTypeMethodReturn) {
            NSLog(@"Owner of %@: %@", testName, ownerReply.arguments);
        } else {
            NSLog(@"Failed to get name owner or name not found");
        }
        
        // Test 4: Send a signal
        NSLog(@"Testing signal emission...");
        if ([client emitSignal:@"/com/example/Test"
                     interface:@"com.example.Test"
                        member:@"TestSignal"
                     arguments:@[@"Hello from test client!", @42]]) {
            NSLog(@"Signal sent successfully");
        } else {
            NSLog(@"Failed to send signal");
        }
        
        // Test 5: Release name
        NSLog(@"Testing name release...");
        if ([client releaseName:testName]) {
            NSLog(@"Successfully released name: %@", testName);
        } else {
            NSLog(@"Failed to release name: %@", testName);
        }
        
        NSLog(@"Test completed successfully!");
        [client disconnect];
    }
    
    return 0;
}
