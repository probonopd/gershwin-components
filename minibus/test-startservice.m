#import "MBMessage.h"

int main() {
    @autoreleasepool {
        NSLog(@"Testing StartServiceByName argument parsing...");
        
        // Create a test StartServiceByName message similar to what GLib would send
        MBMessage *message = [[MBMessage alloc] init];
        message.type = MBMessageTypeMethodCall;
        message.path = @"/org/freedesktop/DBus";
        message.interface = @"org.freedesktop.DBus";
        message.member = @"StartServiceByName";
        message.destination = @"org.freedesktop.DBus";
        message.signature = @"su";
        message.serial = 123;
        
        // Test arguments: service name + flags
        message.arguments = @[@"org.gtk.vfs.Daemon", @0];
        
        // Serialize the message
        NSData *serialized = [message serialize];
        NSLog(@"Serialized StartServiceByName message: %lu bytes", [serialized length]);
        
        // Parse it back
        NSUInteger offset = 0;
        MBMessage *parsed = [MBMessage messageFromData:serialized offset:&offset];
        
        if (parsed) {
            NSLog(@"Parsed message successfully:");
            NSLog(@"  Member: %@", parsed.member);
            NSLog(@"  Signature: %@", parsed.signature);
            NSLog(@"  Arguments count: %lu", [parsed.arguments count]);
            for (NSUInteger i = 0; i < [parsed.arguments count]; i++) {
                NSLog(@"    Arg[%lu]: %@ (type: %@)", i, parsed.arguments[i], [parsed.arguments[i] class]);
            }
            
            // Test the condition that fails
            if ([parsed.arguments count] < 2) {
                NSLog(@"ERROR: Would fail argument count check!");
            } else {
                NSLog(@"SUCCESS: Arguments look correct");
                NSString *serviceName = parsed.arguments[0];
                NSUInteger flags = [parsed.arguments[1] unsignedIntegerValue];
                NSLog(@"  Service: %@, Flags: %lu", serviceName, flags);
            }
        } else {
            NSLog(@"FAILED to parse message back!");
        }
        
        [message release];
        return 0;
    }
}
