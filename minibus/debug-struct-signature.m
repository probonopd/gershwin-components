#import <Foundation/Foundation.h>
#import "MBMessage.h"

// Debug the STRUCT serialization in detail
int main(int argc, const char * argv[])
{
    @autoreleasepool {
        NSLog(@"=== STRUCT Serialization Detail Debug ===");
        
        // Create a simple struct
        NSArray *structData = @[@"test", @(123), @"end"];
        NSLog(@"Input struct: %@", structData);
        
        // Test signature generation first
        NSString *signature = [MBMessage signatureForArguments:@[structData]];
        NSLog(@"Generated signature: '%@'", signature);
        NSLog(@"Signature contains '(': %@", [signature containsString:@"("] ? @"YES" : @"NO");
        
        // Create a message manually to control the signature
        MBMessage *message = [[MBMessage alloc] init];
        message.type = 1; // METHOD_CALL
        message.destination = @"test.dest";
        message.path = @"/test";
        message.interface = @"test.interface";
        message.member = @"TestMethod";
        message.arguments = @[structData];
        message.signature = @"(sus)"; // Force the signature
        
        NSLog(@"Message signature: '%@'", message.signature);
        NSLog(@"Message signature contains '(': %@", [message.signature containsString:@"("] ? @"YES" : @"NO");
        
        // Let's test what happens during serialization
        NSLog(@"About to serialize body...");
        
        // Check argument type
        id arg = [message.arguments objectAtIndex:0];
        NSLog(@"Argument class: %@", [arg class]);
        NSLog(@"Is NSArray: %@", [arg isKindOfClass:[NSArray class]] ? @"YES" : @"NO");
        
        [message release];
        NSLog(@"\n=== Debug Complete ===");
    }
    return 0;
}
