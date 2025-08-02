#import <Foundation/Foundation.h>
#import "MBMessage.h"

void dumpHex(NSData *data, NSString *label) {
    const uint8_t *bytes = [data bytes];
    NSLog(@"%@ (%lu bytes):", label, [data length]);
    for (NSUInteger i = 0; i < [data length]; i += 16) {
        NSMutableString *hexLine = [NSMutableString string];
        NSMutableString *asciiLine = [NSMutableString string];
        for (NSUInteger j = 0; j < 16 && i + j < [data length]; j++) {
            uint8_t byte = bytes[i + j];
            [hexLine appendFormat:@"%02x ", byte];
            [asciiLine appendFormat:@"%c", (byte >= 32 && byte < 127) ? byte : '.'];
        }
        NSLog(@"%04lx: %-48s %@", i, [hexLine UTF8String], asciiLine);
    }
}

int main(int argc, const char * argv[])
{
    @autoreleasepool {
        NSLog(@"Testing variant serialization...");
        
        // Test different variant types to see what we're producing
        NSMutableData *testData = [NSMutableData data];
        
        NSLog(@"\n=== Test 1: Empty string variant ===");
        [MBMessage serializeVariant:@"" toData:testData];
        dumpHex(testData, @"Empty string variant");
        
        [testData setLength:0];
        
        NSLog(@"\n=== Test 2: Non-empty string variant ===");
        [MBMessage serializeVariant:@"hello" toData:testData];
        dumpHex(testData, @"Non-empty string variant");
        
        [testData setLength:0];
        
        NSLog(@"\n=== Test 3: Integer variant ===");
        [MBMessage serializeVariant:@42 toData:testData];
        dumpHex(testData, @"Integer variant");
        
        [testData setLength:0];
        
        NSLog(@"\n=== Test 4: nil/null variant ===");
        [MBMessage serializeVariant:nil toData:testData];
        dumpHex(testData, @"nil/null variant");
        
        // According to D-Bus spec, a string variant should be:
        // Signature: 1 byte length (1) + 's' + null terminator = [01 73 00]
        // Value: 4 byte length + string data + null terminator
        //
        // For empty string:
        // Signature: [01 73 00] (3 bytes)
        // Value: [00 00 00 00 00] (5 bytes: length=0, then null terminator)
        // Total: 8 bytes
        
        NSLog(@"\n=== Expected for empty string variant ===");
        NSLog(@"Signature: 01 73 00 (length=1, 's', null)");
        NSLog(@"Value: 00 00 00 00 00 (length=0, null terminator)");
        NSLog(@"Total: 8 bytes");
        
        NSLog(@"\n=== Manual construction test ===");
        NSMutableData *manual = [NSMutableData data];
        uint8_t sigLen = 1;
        [manual appendBytes:&sigLen length:1];
        uint8_t sig = 's';
        [manual appendBytes:&sig length:1];
        uint8_t sigNull = 0;
        [manual appendBytes:&sigNull length:1];
        
        // Add padding to 4-byte boundary
        while ([manual length] % 4 != 0) {
            [manual appendBytes:&sigNull length:1];
        }
        
        uint32_t strLen = 0;
        [manual appendBytes:&strLen length:4];
        [manual appendBytes:&sigNull length:1];
        
        dumpHex(manual, @"Manual empty string variant");
    }
    
    return 0;
}
