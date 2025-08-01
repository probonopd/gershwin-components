#import <Foundation/Foundation.h>
#import "MBMessage.h"

// Test program to verify STRUCT type parsing and serialization
int main(int argc, const char * argv[])
{
    @autoreleasepool {
        NSLog(@"=== STRUCT Type Test ===");
        
        // Test 1: Create a struct with mixed types (string, uint32, string)
        NSArray *structData = @[@"test-string", @(12345), @"another-string"];
        NSLog(@"Test 1: Creating STRUCT with data: %@", structData);
        
        // Generate signature for this struct
        NSString *signature = [MBMessage signatureForArguments:@[structData]];
        NSLog(@"Generated signature: %@", signature);
        
        // Test 2: Create a message with struct arguments
        MBMessage *message = [MBMessage methodCallWithDestination:@"com.example.StructTest"
                                                             path:@"/com/example/StructTest"
                                                        interface:@"com.example.StructTest"
                                                           member:@"TestMethod"
                                                        arguments:@[structData]];
        
        NSLog(@"Created message with STRUCT argument");
        NSLog(@"Message signature: %@", message.signature);
        
        // Test 3: Serialize the message
        NSData *serialized = [message serialize];
        NSLog(@"Serialized message length: %lu bytes", [serialized length]);
        
        // Test 4: Parse the message back
        MBMessage *parsed = [MBMessage parseFromData:serialized];
        if (parsed) {
            NSLog(@"Successfully parsed message back");
            NSLog(@"Parsed signature: %@", parsed.signature);
            NSLog(@"Parsed arguments: %@", parsed.arguments);
            
            if ([parsed.arguments count] > 0) {
                id parsedStruct = [parsed.arguments objectAtIndex:0];
                if ([parsedStruct isKindOfClass:[NSArray class]]) {
                    NSArray *structArray = (NSArray *)parsedStruct;
                    NSLog(@"Parsed struct has %lu fields:", [structArray count]);
                    for (NSUInteger i = 0; i < [structArray count]; i++) {
                        NSLog(@"  Field %lu: %@ (class: %@)", i, [structArray objectAtIndex:i], 
                              [[structArray objectAtIndex:i] class]);
                    }
                } else {
                    NSLog(@"Parsed argument is not an array: %@ (class: %@)", parsedStruct, [parsedStruct class]);
                }
            }
        } else {
            NSLog(@"ERROR: Failed to parse message back");
        }
        
        // Test 5: Create a more complex struct with nested types
        NSArray *complexStruct = @[@"outer-string", @(999), @[@"inner-string", @(888)]];
        NSLog(@"\nTest 5: Complex nested struct: %@", complexStruct);
        
        NSString *complexSig = [MBMessage signatureForArguments:@[complexStruct]];
        NSLog(@"Complex struct signature: %@", complexSig);
        
        // Test 6: Test struct in variant
        NSLog(@"\nTest 6: Testing struct as variant");
        NSMutableData *variantData = [NSMutableData data];
        [MBMessage serializeVariant:structData toData:variantData];
        NSLog(@"Serialized struct variant: %lu bytes", [variantData length]);
        
        // Dump some bytes for debugging
        const uint8_t *bytes = [variantData bytes];
        NSLog(@"First 64 bytes of variant data:");
        for (NSUInteger i = 0; i < MIN(64, [variantData length]); i += 16) {
            NSMutableString *hexLine = [NSMutableString string];
            NSMutableString *asciiLine = [NSMutableString string];
            for (NSUInteger j = 0; j < 16 && i + j < [variantData length]; j++) {
                [hexLine appendFormat:@"%02x ", bytes[i + j]];
                char c = bytes[i + j];
                [asciiLine appendFormat:@"%c", (c >= 32 && c <= 126) ? c : '.'];
            }
            NSLog(@"%04lx: %-48s %@", i, [hexLine UTF8String], asciiLine);
        }
        
        NSLog(@"\n=== STRUCT Test Complete ===");
    }
    return 0;
}
