#import "MBMessage.h"

int main() {
    @autoreleasepool {
        NSLog(@"Testing comprehensive D-Bus type support...");
        
        // Test variant parsing - don't pre-set signature, let it auto-generate
        MBMessage *variantMsg = [[MBMessage alloc] init];
        variantMsg.type = MBMessageTypeMethodCall;
        variantMsg.path = @"/test/path";
        variantMsg.interface = @"test.Interface";
        variantMsg.member = @"TestVariant";
        variantMsg.destination = @"test.destination";
        variantMsg.serial = 1;
        
        // Test with mixed types that will be serialized as variants
        NSArray *variantArgs = @[@"test variant string"];
        variantMsg.arguments = variantArgs;
        variantMsg.signature = [MBMessage signatureForArguments:variantArgs];
        
        NSData *serialized = [variantMsg serialize];
        NSLog(@"Serialized variant message: %lu bytes", [serialized length]);
        
        NSUInteger offset = 0;
        MBMessage *parsed = [MBMessage messageFromData:serialized offset:&offset];
        
        if (parsed) {
            NSLog(@"✓ Variant message parsed successfully");
            NSLog(@"  Arguments count: %lu", [parsed.arguments count]);
            if ([parsed.arguments count] > 0) {
                NSLog(@"  First argument: %@ (type: %@)", 
                      parsed.arguments[0], [parsed.arguments[0] class]);
            }
        } else {
            NSLog(@"✗ Failed to parse variant message");
        }
        
        // Test array of dictionaries a{sv}
        MBMessage *dictArrayMsg = [[MBMessage alloc] init];
        dictArrayMsg.type = MBMessageTypeMethodCall;
        dictArrayMsg.path = @"/test/path";
        dictArrayMsg.interface = @"test.Interface";
        dictArrayMsg.member = @"TestDictArray";
        dictArrayMsg.destination = @"test.destination";
        dictArrayMsg.signature = @"a{sv}";
        dictArrayMsg.serial = 2;
        
        // Create test dictionary array
        NSArray *testDictArray = @[
            @{@"key1": @"string_value", @"key2": @42},
            @{@"key3": @YES, @"key4": @3.14}
        ];
        dictArrayMsg.arguments = @[testDictArray];
        
        NSData *dictSerialized = [dictArrayMsg serialize];
        NSLog(@"Serialized dictionary array message: %lu bytes", [dictSerialized length]);
        
        offset = 0;
        MBMessage *dictParsed = [MBMessage messageFromData:dictSerialized offset:&offset];
        
        if (dictParsed) {
            NSLog(@"✓ Dictionary array message parsed successfully");
            NSLog(@"  Arguments count: %lu", [dictParsed.arguments count]);
            if ([dictParsed.arguments count] > 0) {
                NSLog(@"  First argument type: %@", [dictParsed.arguments[0] class]);
            }
        } else {
            NSLog(@"✗ Failed to parse dictionary array message");
        }
        
        // Test multiple data types
        MBMessage *multiTypeMsg = [[MBMessage alloc] init];
        multiTypeMsg.type = MBMessageTypeMethodCall;
        multiTypeMsg.path = @"/test/path";
        multiTypeMsg.interface = @"test.Interface";
        multiTypeMsg.member = @"TestMultiType";
        multiTypeMsg.destination = @"test.destination";
        multiTypeMsg.serial = 3;
        
        // Test with various NSNumber types
        NSArray *testArgs = @[
            @"test string",           // string
            @42,                      // uint32
            @YES,                     // boolean
            @3.14159,                 // double
            @((int16_t)-1000),       // int16
            @((uint64_t)9876543210ULL) // uint64
        ];
        multiTypeMsg.arguments = testArgs;
        multiTypeMsg.signature = [MBMessage signatureForArguments:testArgs];
        
        NSLog(@"Generated signature: %@", multiTypeMsg.signature);
        
        NSData *multiSerialized = [multiTypeMsg serialize];
        NSLog(@"Serialized multi-type message: %lu bytes", [multiSerialized length]);
        
        offset = 0;
        MBMessage *multiParsed = [MBMessage messageFromData:multiSerialized offset:&offset];
        
        if (multiParsed) {
            NSLog(@"✓ Multi-type message parsed successfully");
            NSLog(@"  Signature: %@", multiParsed.signature);
            NSLog(@"  Arguments count: %lu", [multiParsed.arguments count]);
            for (NSUInteger i = 0; i < [multiParsed.arguments count]; i++) {
                NSLog(@"    Arg[%lu]: %@ (type: %@)", 
                      i, multiParsed.arguments[i], [multiParsed.arguments[i] class]);
            }
        } else {
            NSLog(@"✗ Failed to parse multi-type message");
        }
        
        [variantMsg release];
        [dictArrayMsg release];
        [multiTypeMsg release];
        
        NSLog(@"Comprehensive D-Bus type test completed.");
        return 0;
    }
}
