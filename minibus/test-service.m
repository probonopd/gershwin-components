#import <Foundation/Foundation.h>
#import "MBClient.h"
#import "MBMessage.h"

int main(int argc, const char * argv[])
{
    @autoreleasepool {
        NSString *socketPath = @"/tmp/minibus-socket";
        NSString *serviceName = @"com.example.TestService";
        int sleepTime = 10;
        
        // Parse command line arguments
        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "-socket") == 0 && i + 1 < argc) {
                socketPath = [NSString stringWithUTF8String:argv[i + 1]];
                i++;
            } else if (strcmp(argv[i], "-name") == 0 && i + 1 < argc) {
                serviceName = [NSString stringWithUTF8String:argv[i + 1]];
                i++;
            } else if (strcmp(argv[i], "-sleep") == 0 && i + 1 < argc) {
                sleepTime = atoi(argv[i + 1]);
                i++;
            }
        }
        
        NSLog(@"Test Service Starting:");
        NSLog(@"  Socket: %@", socketPath);
        NSLog(@"  Service Name: %@", serviceName);
        NSLog(@"  Sleep Time: %d seconds", sleepTime);
        NSLog(@"  DBUS_STARTER_ADDRESS: %s", getenv("DBUS_STARTER_ADDRESS") ?: "(not set)");
        NSLog(@"  DBUS_STARTER_BUS_TYPE: %s", getenv("DBUS_STARTER_BUS_TYPE") ?: "(not set)");
        
        // Use DBUS_STARTER_ADDRESS if provided by the daemon
        const char *starterAddress = getenv("DBUS_STARTER_ADDRESS");
        if (starterAddress) {
            NSString *starterAddressStr = [NSString stringWithUTF8String:starterAddress];
            NSLog(@"Using starter address: %@", starterAddressStr);
            
            // Parse D-Bus address format: unix:path=/tmp/socket
            if ([starterAddressStr hasPrefix:@"unix:path="]) {
                socketPath = [starterAddressStr substringFromIndex:10]; // Skip "unix:path="
                NSLog(@"Parsed socket path: %@", socketPath);
            } else {
                NSLog(@"Unknown D-Bus address format: %@", starterAddressStr);
                socketPath = starterAddressStr; // Fallback
            }
        }
        
        MBClient *client = [[MBClient alloc] init];
        
        NSLog(@"Connecting to daemon at %@...", socketPath);
        if (![client connectToPath:socketPath]) {
            NSLog(@"Failed to connect to daemon");
            return 1;
        }
        
        NSLog(@"Connected! Unique name: %@", client.uniqueName);
        
        // Register the service name
        NSLog(@"Registering service name: %@", serviceName);
        if ([client requestName:serviceName]) {
            NSLog(@"Successfully registered name: %@", serviceName);
        } else {
            NSLog(@"Failed to register name: %@", serviceName);
            return 1;
        }
        
        NSLog(@"Service activated successfully! Sleeping for %d seconds...", sleepTime);
        sleep(sleepTime);
        
        NSLog(@"Test service exiting");
        [client disconnect];
        [client release];
    }
    return 0;
}
