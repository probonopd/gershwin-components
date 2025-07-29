#include <Foundation/NSAutoreleasePool.h>
#include <Foundation/NSString.h>
#import <Foundation/Foundation.h>
#import "MBClient.h"
#import "MBMessage.h"

int main(int argc, char *argv[]) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    printf("Minibus Hello-only test against real dbus-daemon\n");
    
    // Connect to the dbus socket specified in DBUS_SESSION_BUS_ADDRESS
    const char *address = getenv("DBUS_SESSION_BUS_ADDRESS");
    if (!address) {
        printf("DBUS_SESSION_BUS_ADDRESS not set\n");
        [pool drain];
        return 1;
    }
    
    printf("Connecting to: %s\n", address);
    
    // Parse the address to extract the socket path
    NSString *addressStr = [NSString stringWithUTF8String:address];
    NSString *socketPath = nil;
    
    // Look for unix:path=
    NSRange pathRange = [addressStr rangeOfString:@"unix:path="];
    if (pathRange.location != NSNotFound) {
        NSUInteger start = pathRange.location + pathRange.length;
        NSRange commaRange = [addressStr rangeOfString:@"," options:0 range:NSMakeRange(start, [addressStr length] - start)];
        NSUInteger end = (commaRange.location != NSNotFound) ? commaRange.location : [addressStr length];
        socketPath = [addressStr substringWithRange:NSMakeRange(start, end - start)];
    }
    
    if (!socketPath) {
        printf("Could not parse socket path from address\n");
        [pool drain];
        return 1;
    }
    
    printf("Socket path: %s\n", [socketPath UTF8String]);
    
    MBClient *client = [[MBClient alloc] init];
    
    // Connect without sending Hello first to control the message manually
    if (![client connectToPathWithoutHello:socketPath]) {
        printf("Failed to connect and authenticate\n");
        [client release];
        [pool drain];
        return 1;
    }
    
    printf("Successfully connected and authenticated! Now sending Hello manually...\n");
    
    // Create and send Hello message manually
    MBMessage *helloMsg = [MBMessage methodCallWithDestination:@"org.freedesktop.DBus"
                                                          path:@"/org/freedesktop/DBus" 
                                                     interface:@"org.freedesktop.DBus"
                                                        member:@"Hello"
                                                     arguments:@[]];
    
    printf("Sending Hello message manually...\n");
    if ([client sendMessage:helloMsg]) {
        printf("Hello message sent successfully\n");
        
        // Try to read reply manually 
        printf("Waiting for Hello reply...\n");
        sleep(1);
        
        NSArray *messages = [client processMessages];
        if ([messages count] > 0) {
            printf("Received %lu messages:\n", (unsigned long)[messages count]);
            for (MBMessage *msg in messages) {
                printf("Message type: %d\n", (int)msg.type);
                if (msg.arguments) {
                    printf("Arguments: %s\n", [[msg.arguments description] UTF8String]);
                }
            }
        } else {
            printf("No messages received\n");
        }
    } else {
        printf("Failed to send Hello message\n");
    }
    
    [client disconnect];
    [client release];
    [pool drain];
    return 0;
}
