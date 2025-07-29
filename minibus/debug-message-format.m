#import <Foundation/Foundation.h>
#import "MBMessage.h"

int main() {
    @autoreleasepool {
        NSLog(@"Creating test ListNames reply message...");
        
        // Create the same message that minibus would send for ListNames
        MBMessage *message = [MBMessage methodReturnWithReplySerial:19
                                                           arguments:@[@[@"org.freedesktop.DBus", @"org.xfce.Panel", @":1.1"]]];
        message.destination = @":1.1";
        message.serial = 1;
        message.sender = @"org.freedesktop.DBus";
        
        NSData *serialized = [message serialize];
        NSLog(@"Serialized %lu bytes", (unsigned long)[serialized length]);
        
        // Print hex dump
        const uint8_t *bytes = [serialized bytes];
        NSMutableString *hexStr = [NSMutableString string];
        for (NSUInteger i = 0; i < [serialized length]; i++) {
            if (i % 16 == 0) [hexStr appendFormat:@"\n%04lx: ", (unsigned long)i];
            [hexStr appendFormat:@"%02x ", bytes[i]];
        }
        NSLog(@"Hex dump: %@", hexStr);
        
        // Also show the structure breakdown
        NSLog(@"\nMessage structure:");
        NSLog(@"Fixed header (16 bytes):");
        if ([serialized length] >= 16) {
            NSLog(@"  Endian: %02x ('%c')", bytes[0], bytes[0]);
            NSLog(@"  Type: %02x", bytes[1]);
            NSLog(@"  Flags: %02x", bytes[2]);
            NSLog(@"  Version: %02x", bytes[3]);
            uint32_t bodyLen = *(uint32_t*)(bytes + 4);
            uint32_t serial = *(uint32_t*)(bytes + 8);
            uint32_t fieldsLen = *(uint32_t*)(bytes + 12);
            NSLog(@"  Body length: %u", bodyLen);
            NSLog(@"  Serial: %u", serial);
            NSLog(@"  Header fields length: %u", fieldsLen);
        }
    }
    return 0;
}
