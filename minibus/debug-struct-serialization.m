#import <Foundation/Foundation.h>
#import "MBMessage.h"

// Debug the STRUCT serialization to see what's happening
int main(int argc, const char * argv[])
{
    @autoreleasepool {
        NSLog(@"=== STRUCT Serialization Debug ===");
        
        // Create a simple struct
        NSArray *structData = @[@"test", @(123), @"end"];
        NSLog(@"Input struct: %@", structData);
        
        // Create a message
        MBMessage *message = [MBMessage methodCallWithDestination:@"test.dest"
                                                             path:@"/test"
                                                        interface:@"test.interface"
                                                           member:@"TestMethod"
                                                        arguments:@[structData]];
        
        NSLog(@"Message signature: %@", message.signature);
        
        // Get the body data
        NSData *bodyData = [message serializeBody];
        NSLog(@"Body data length: %lu bytes", [bodyData length]);
        
        // Dump the body data
        const uint8_t *bytes = [bodyData bytes];
        NSLog(@"Body data bytes:");
        for (NSUInteger i = 0; i < [bodyData length]; i += 16) {
            NSMutableString *hexLine = [NSMutableString string];
            NSMutableString *asciiLine = [NSMutableString string];
            for (NSUInteger j = 0; j < 16 && i + j < [bodyData length]; j++) {
                [hexLine appendFormat:@"%02x ", bytes[i + j]];
                char c = bytes[i + j];
                [asciiLine appendFormat:@"%c", (c >= 32 && c <= 126) ? c : '.'];
            }
            NSLog(@"%04lx: %-48s %@", i, [hexLine UTF8String], asciiLine);
        }
        
        // Now let's manually parse this according to D-Bus spec
        NSLog(@"\n=== Manual Parse ===");
        NSUInteger pos = 0;
        
        // STRUCT should be 8-byte aligned first
        pos = ((pos + 7) / 8) * 8;
        NSLog(@"Aligned pos: %lu", pos);
        
        // Field 1: string
        pos = ((pos + 3) / 4) * 4; // 4-byte align for string
        NSLog(@"String pos: %lu", pos);
        if (pos + 4 <= [bodyData length]) {
            uint32_t strLen = *(uint32_t *)(bytes + pos);
            NSLog(@"String length: %u", strLen);
            pos += 4;
            
            if (pos + strLen + 1 <= [bodyData length]) {
                NSString *str = [[NSString alloc] initWithBytes:(bytes + pos)
                                                         length:strLen
                                                       encoding:NSUTF8StringEncoding];
                NSLog(@"String value: '%@'", str);
                pos += strLen + 1;
                [str release];
            }
        }
        
        // Field 2: uint32
        pos = ((pos + 3) / 4) * 4; // 4-byte align for uint32
        NSLog(@"uint32 pos: %lu", pos);
        if (pos + 4 <= [bodyData length]) {
            uint32_t value = *(uint32_t *)(bytes + pos);
            NSLog(@"uint32 value: %u", value);
            pos += 4;
        }
        
        // Field 3: string
        pos = ((pos + 3) / 4) * 4; // 4-byte align for string
        NSLog(@"String2 pos: %lu", pos);
        if (pos + 4 <= [bodyData length]) {
            uint32_t strLen = *(uint32_t *)(bytes + pos);
            NSLog(@"String2 length: %u", strLen);
            pos += 4;
            
            if (pos + strLen + 1 <= [bodyData length]) {
                NSString *str = [[NSString alloc] initWithBytes:(bytes + pos)
                                                         length:strLen
                                                       encoding:NSUTF8StringEncoding];
                NSLog(@"String2 value: '%@'", str);
                pos += strLen + 1;
                [str release];
            }
        }
        
        NSLog(@"Final pos: %lu", pos);
        NSLog(@"\n=== Debug Complete ===");
    }
    return 0;
}
