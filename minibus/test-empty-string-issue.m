#import <Foundation/Foundation.h>
#import "MBMessage.h"

int main(int argc, const char * argv[])
{
    @autoreleasepool {
        NSLog(@"Testing problematic message case...");
        
        // Create the exact message we saw in the logs that caused the problem
        // This should be a single dictionary with multiple key-value pairs
        
        NSMutableDictionary *fullDict = [NSMutableDictionary dictionary];
        [fullDict setObject:@1677721600 forKey:@"/panels/panel-1/enter-opacity"];
        [fullDict setObject:@1 forKey:@"/plugins/plugin-11/plugins/plugin-11/expand"];
        [fullDict setObject:@"" forKey:@"/plugins/plugin-4"];  // Empty string value!
        
        NSArray *arguments = @[fullDict];
        
        // Create message 
        MBMessage *msg = [[MBMessage alloc] init];
        msg.type = 2;  // METHOD_RETURN
        msg.serial = 3;
        msg.destination = @":1.1"; 
        msg.signature = @"a{sv}";
        msg.arguments = arguments;
        
        NSLog(@"Original message arguments: %@", msg.arguments);
        
        // Serialize the message
        NSData *serialized = [msg serialize];
        NSLog(@"Serialized to %lu bytes", [serialized length]);
        
        // Print hex dump of the message
        const uint8_t *bytes = [serialized bytes];
        NSLog(@"Full message hex dump:");
        for (NSUInteger i = 0; i < [serialized length]; i += 16) {
            NSMutableString *hexLine = [NSMutableString string];
            for (NSUInteger j = 0; j < 16 && i + j < [serialized length]; j++) {
                [hexLine appendFormat:@"%02x ", bytes[i + j]];
            }
            NSLog(@"%04lx: %@", i, hexLine);
        }
        
        // Parse it back
        NSUInteger offset = 0;
        MBMessage *parsed = [MBMessage messageFromData:serialized offset:&offset];
        
        if (parsed) {
            NSLog(@"✓ Successfully parsed message back");
            NSLog(@"Parsed arguments: %@", parsed.arguments);
            NSLog(@"Parsed signature: %@", parsed.signature);
            
            // Check specifically the parsed arguments
            if ([parsed.arguments count] > 0 && [[parsed.arguments objectAtIndex:0] isKindOfClass:[NSDictionary class]]) {
                NSDictionary *parsedDict = [parsed.arguments objectAtIndex:0];
                NSLog(@"✓ Parsed dictionary with %lu entries", [parsedDict count]);
                
                for (NSString *key in parsedDict) {
                    id value = [parsedDict objectForKey:key];
                    NSLog(@"  Entry '%@': %@ (class: %@)", key, value, [value class]);
                    
                    // Check for empty string value specifically
                    if ([value isKindOfClass:[NSString class]] && [(NSString*)value length] == 0) {
                        NSLog(@"  ⚠️  Found empty string value for key '%@'", key);
                    }
                }
            }
            
            // Test re-serialization
            NSData *reserialized = [parsed serialize];
            NSLog(@"Re-serialized to %lu bytes", [reserialized length]);
            
            if ([reserialized isEqualToData:serialized]) {
                NSLog(@"✓ Round-trip serialization is consistent");
            } else {
                NSLog(@"❌ Round-trip serialization differs!");
                NSLog(@"Original length: %lu, Re-serialized length: %lu", [serialized length], [reserialized length]);
            }
            
        } else {
            NSLog(@"❌ Failed to parse message back");
        }
        
        [msg release];
    }
    
    return 0;
}
