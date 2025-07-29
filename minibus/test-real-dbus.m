#include <Foundation/NSAutoreleasePool.h>
#include <Foundation/NSString.h>
#import <Foundation/Foundation.h>
#import "MBClient.h"
#import "MBMessage.h"

int main(int argc, char *argv[]) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    printf("Minibus client test against real dbus-daemon\n");
    
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
    
    if (![client connectToPath:socketPath]) {
        printf("Failed to connect and authenticate\n");
        [client release];
        [pool drain];
        return 1;
    }
    
    printf("Successfully connected and got unique name: %s\n", [[client uniqueName] UTF8String]);
    
    // Send ListNames method call and wait for reply
    printf("Sending ListNames message...\n");
    MBMessage *reply = [client callMethod:@"org.freedesktop.DBus"
                                     path:@"/org/freedesktop/DBus" 
                                interface:@"org.freedesktop.DBus"
                                   member:@"ListNames"
                                arguments:@[]
                                  timeout:5.0];
    
    if (reply) {
        printf("SUCCESS! Received reply from real dbus-daemon:\n");
        printf("Reply type: %d\n", (int)reply.type);
        printf("Reply arguments: %s\n", [[reply.arguments description] UTF8String]);
        printf("\nMinibus client can now communicate with real dbus-daemon!\n");
    } else {
        printf("Failed to receive reply from dbus-daemon\n");
    }
    
    [client disconnect];
    [client release];
    [pool drain];
    return reply ? 0 : 1;
}
