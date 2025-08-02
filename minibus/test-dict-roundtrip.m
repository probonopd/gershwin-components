#include <Foundation/Foundation.h>
#include "MBMessage.h"

int main(int argc, char *argv[]) {
    @autoreleasepool {
        NSLog(@"Testing dictionary roundtrip...");
        
        // Create a simple a{sv} message
        MBMessage *msg = [[MBMessage alloc] init];
        msg.type = MBMessageTypeMethodCall;
        msg.destination = @"org.test.Service";
        msg.interface = @"org.test.Interface";
        msg.member = @"TestMethod";
        msg.path = @"/test/path";
        msg.signature = @"a{sv}";
        
        // Create dictionary array
        NSMutableArray *dictArray = [NSMutableArray array];
        
        // Add a simple dictionary entry: {"key1": 42}
        NSDictionary *dict1 = @{@"key1": @42};
        [dictArray addObject:dict1];
        
        // Add another: {"key2": "hello"}
        NSDictionary *dict2 = @{@"key2": @"hello"};
        [dictArray addObject:dict2];
        
        msg.arguments = @[dictArray];
        
        NSLog(@"Original message arguments: %@", msg.arguments);
        
        // Serialize the message
        NSData *serialized = [msg serialize];
        NSLog(@"Serialized to %lu bytes", [serialized length]);
        
        // Show hexdump of body portion
        const uint8_t *bytes = [serialized bytes];
        NSLog(@"Full message hex dump:");
        for (NSUInteger i = 0; i < [serialized length]; i += 16) {
            NSMutableString *line = [NSMutableString string];
            [line appendFormat:@"%04lx: ", i];
            for (NSUInteger j = 0; j < 16 && i + j < [serialized length]; j++) {
                [line appendFormat:@"%02x ", bytes[i + j]];
            }
            NSLog(@"%@", line);
        }
        
        // Parse it back
        MBMessage *parsed = [MBMessage messageFromData:serialized offset:NULL];
        if (parsed) {
            NSLog(@"✓ Successfully parsed message back");
            NSLog(@"Parsed arguments: %@", parsed.arguments);
            NSLog(@"Parsed signature: %@", parsed.signature);
            
            // Check if arguments match
            if ([parsed.arguments count] == 1 && [[parsed.arguments objectAtIndex:0] isKindOfClass:[NSArray class]]) {
                NSArray *parsedDictArray = [parsed.arguments objectAtIndex:0];
                NSLog(@"✓ Parsed dictionary array with %lu entries", [parsedDictArray count]);
                
                for (NSUInteger i = 0; i < [parsedDictArray count]; i++) {
                    id entry = [parsedDictArray objectAtIndex:i];
                    NSLog(@"  Entry %lu: %@ (class: %@)", i, entry, [entry class]);
                }
            } else {
                NSLog(@"✗ Parsed arguments structure doesn't match expected");
            }
        } else {
            NSLog(@"✗ Failed to parse message back");
        }
        
        [msg release];
        [parsed release];
    }
    
    return 0;
}
