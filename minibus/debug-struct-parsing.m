#import <Foundation/Foundation.h>
#import "MBMessage.h"

// Debug the STRUCT parsing in detail
int main(int argc, const char * argv[])
{
    @autoreleasepool {
        NSLog(@"=== STRUCT Parsing Debug ===");
        
        // Create a simple struct and serialize it
        NSArray *structData = @[@"test", @(123), @"end"];
        NSLog(@"Input struct: %@", structData);
        
        MBMessage *message = [MBMessage methodCallWithDestination:@"test.dest"
                                                             path:@"/test"
                                                        interface:@"test.interface"
                                                           member:@"TestMethod"
                                                        arguments:@[structData]];
        
        NSLog(@"Message signature: '%@'", message.signature);
        
        // Serialize it
        NSData *serialized = [message serialize];
        NSLog(@"Serialized length: %lu bytes", [serialized length]);
        
        // Now let's manually debug the parsing
        MBMessage *parsed = [MBMessage parseFromData:serialized];
        if (parsed) {
            NSLog(@"Parsed successfully");
            NSLog(@"Parsed signature: '%@'", parsed.signature);
            NSLog(@"Parsed arguments count: %lu", [parsed.arguments count]);
            
            if ([parsed.arguments count] > 0) {
                id arg = [parsed.arguments objectAtIndex:0];
                NSLog(@"First argument class: %@", [arg class]);
                if ([arg isKindOfClass:[NSArray class]]) {
                    NSArray *arr = (NSArray *)arg;
                    NSLog(@"Parsed struct fields: %lu", [arr count]);
                    for (NSUInteger i = 0; i < [arr count]; i++) {
                        id field = [arr objectAtIndex:i];
                        NSLog(@"  Field %lu: %@ (class: %@)", i, field, [field class]);
                    }
                }
            }
        } else {
            NSLog(@"ERROR: Parsing failed");
        }
        
        NSLog(@"\n=== Manual struct body parsing ===");
        
        // Let's manually parse just the body to see what happens
        NSData *bodyData = [message serializeBody];
        NSLog(@"Body data: %lu bytes", [bodyData length]);
        
        const uint8_t *bytes = [bodyData bytes];
        NSLog(@"Body bytes:");
        for (NSUInteger i = 0; i < [bodyData length]; i += 8) {
            NSMutableString *hexLine = [NSMutableString string];
            for (NSUInteger j = 0; j < 8 && i + j < [bodyData length]; j++) {
                [hexLine appendFormat:@"%02x ", bytes[i + j]];
            }
            NSLog(@"%04lx: %@", i, hexLine);
        }
        
        // Parse arguments manually 
        NSString *signature = @"(sus)";
        NSArray *parsedArgs = [MBMessage parseArgumentsFromBodyData:bodyData signature:signature endianness:'l'];
        NSLog(@"Manual parse result: %@", parsedArgs);
        if ([parsedArgs count] > 0) {
            id arg = [parsedArgs objectAtIndex:0];
            if ([arg isKindOfClass:[NSArray class]]) {
                NSArray *arr = (NSArray *)arg;
                NSLog(@"Manual parsed struct fields: %lu", [arr count]);
                for (NSUInteger i = 0; i < [arr count]; i++) {
                    id field = [arr objectAtIndex:i];
                    NSLog(@"  Manual field %lu: %@ (class: %@)", i, field, [field class]);
                }
            }
        }
        
        NSLog(@"\n=== Debug Complete ===");
    }
    return 0;
}
