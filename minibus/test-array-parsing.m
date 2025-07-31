#import <Foundation/Foundation.h>
#import "MBMessage.h"

int main(int argc, const char * argv[]) {
    (void)argc; (void)argv; // Suppress unused parameter warnings
    @autoreleasepool {
        NSLog(@"Testing array parsing with MBMessage");
        
        // Create a message with an array argument
        NSArray *testArray = @[@"first", @"second", @"third"];
        MBMessage *message = [MBMessage methodCallWithDestination:@"org.test.Service"
                                                             path:@"/org/test/Object"
                                                        interface:@"org.test.Interface"
                                                           member:@"TestMethod"
                                                        arguments:@[testArray]];
        
        NSLog(@"Created message: %@", message);
        NSLog(@"Message signature: %@", [message signature]);
        
        // Serialize the message
        NSData *data = [message serialize];
        NSLog(@"Serialized message to %lu bytes", (unsigned long)[data length]);
        
        // Try to parse it back
        NSLog(@"Attempting to parse message from data...");
        MBMessage *parsedMessage = [MBMessage messageFromData:data offset:0];
        
        if (parsedMessage) {
            NSLog(@"Successfully parsed message: %@", parsedMessage);
            NSLog(@"Parsed arguments: %@", parsedMessage.arguments);
            
            if ([parsedMessage.arguments count] > 0) {
                id firstArg = parsedMessage.arguments[0];
                if ([firstArg isKindOfClass:[NSArray class]]) {
                    NSArray *parsedArray = (NSArray *)firstArg;
                    NSLog(@"Parsed array has %lu elements:", (unsigned long)[parsedArray count]);
                    for (NSUInteger i = 0; i < [parsedArray count]; i++) {
                        NSLog(@"  [%lu]: %@", i, parsedArray[i]);
                    }
                } else {
                    NSLog(@"First argument is not an array: %@", firstArg);
                }
            } else {
                NSLog(@"No arguments parsed");
            }
        } else {
            NSLog(@"Failed to parse message from data");
        }
    }
    return 0;
}
