/*
 * Test complex array and struct parsing - specifically signature 'a(ssasib)'
 * This targets the exact message type that was causing failures in the XFCE test
 */

#import <Foundation/Foundation.h>
#import "MBMessage.h"

int main(int argc, char *argv[]) {
    @autoreleasepool {
        NSLog(@"Testing complex signature 'a(ssasib)' parsing...");
        
        // Try to parse a message with the problematic signature
        // This signature represents: array of (string, string, array of strings, int32, boolean)
        
        // Create some test data that represents this structure
        NSMutableData *testData = [NSMutableData data];
        
        // Array length (4-byte aligned)
        uint32_t arrayLength = 20; // Small test array
        [testData appendBytes:&arrayLength length:4];
        
        // First struct element: (string, string, array of strings, int32, boolean)
        // Struct alignment is 8-byte boundary
        
        // String 1: "test1"
        uint32_t str1Len = 5;
        [testData appendBytes:&str1Len length:4];
        [testData appendBytes:"test1" length:6]; // +1 for null terminator
        
        NSLog(@"Created test data with %lu bytes", [testData length]);
        
        // Test our parsing function directly
        NSUInteger pos = 0;
        NSUInteger maxLen = [testData length];
        
        NSArray *result = [MBMessage parseArgumentsFromBodyData:testData 
                                                      signature:@"a(ssasib)" 
                                                     endianness:'l'];
        
        if (result) {
            NSLog(@"SUCCESS: Parsed arguments: %@", result);
        } else {
            NSLog(@"FAILED: Could not parse arguments");
        }
    }
    
    return 0;
}
