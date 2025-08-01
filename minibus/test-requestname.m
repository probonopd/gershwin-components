#import <Foundation/Foundation.h>
#import "MBClient.h"

int main(int argc, char *argv[]) {
    @autoreleasepool {
        NSLog(@"Testing RequestName functionality");
        
        // Connect to daemon
        MBClient *client = [[MBClient alloc] init];
        
        if (![client connectToPath:@"/tmp/minibus-socket"]) {
            NSLog(@"Failed to connect to daemon");
            return 1;
        }
        
        NSLog(@"Connected successfully, unique name: %@", client.uniqueName);
        
        // Test name acquisition
        NSString *testName = @"org.test.Panel";
        NSLog(@"Requesting name: %@", testName);
        
        if ([client requestName:testName]) {
            NSLog(@"SUCCESS: Name acquired successfully!");
        } else {
            NSLog(@"FAILED: Could not acquire name");
            return 1;
        }
        
        // Try to request the same name again (should get ALREADY_OWNER)
        NSLog(@"Requesting the same name again...");
        if ([client requestName:testName]) {
            NSLog(@"SUCCESS: Already owned name (expected)");
        } else {
            NSLog(@"FAILED: Should have returned ALREADY_OWNER");
            return 1;
        }
        
        [client disconnect];
        NSLog(@"Test completed successfully!");
        return 0;
    }
}
