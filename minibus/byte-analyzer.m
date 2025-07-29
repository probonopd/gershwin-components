#import <Foundation/Foundation.h>
#import "MBMessage.h"

// Test tool to capture exact byte format for comparison with reference implementation

void printHexDump(NSData *data, NSString *label) {
    printf("\n=== %s ===\n", [label UTF8String]);
    printf("Length: %lu bytes\n", (unsigned long)[data length]);
    
    const uint8_t *bytes = [data bytes];
    for (NSUInteger i = 0; i < [data length]; i += 16) {
        printf("%04lx: ", (unsigned long)i);
        
        // Hex bytes
        for (NSUInteger j = 0; j < 16; j++) {
            if (i + j < [data length]) {
                printf("%02x ", bytes[i + j]);
            } else {
                printf("   ");
            }
            if (j == 7) printf(" ");
        }
        
        printf(" |");
        
        // ASCII representation
        for (NSUInteger j = 0; j < 16 && i + j < [data length]; j++) {
            uint8_t b = bytes[i + j];
            printf("%c", (b >= 32 && b < 127) ? b : '.');
        }
        
        printf("|\n");
    }
    printf("\n");
}

int main() {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    printf("Byte Format Analyzer - comparing minibus vs dbus-send message format\n");
    
    // Create a simple method call message
    MBMessage *message = [MBMessage methodCallWithDestination:@"org.freedesktop.DBus"
                                                         path:@"/org/freedesktop/DBus"
                                                    interface:@"org.freedesktop.DBus"
                                                       member:@"ListNames"
                                                    arguments:@[]];
    message.serial = 1;
    
    NSData *serialized = [message serialize];
    printHexDump(serialized, @"Minibus ListNames Message");
    
    // Break down the header components
    const uint8_t *bytes = [serialized bytes];
    
    printf("Header Analysis:\n");
    printf("Endian: 0x%02x ('%c')\n", bytes[0], bytes[0]);
    printf("Type: %d\n", bytes[1]);
    printf("Flags: %d\n", bytes[2]);
    printf("Version: %d\n", bytes[3]);
    
    uint32_t bodyLength = *(uint32_t*)(bytes + 4);
    uint32_t serial = *(uint32_t*)(bytes + 8);
    uint32_t fieldsLength = *(uint32_t*)(bytes + 12);
    
    printf("Body Length: %u\n", bodyLength);
    printf("Serial: %u\n", serial);
    printf("Fields Length: %u\n", fieldsLength);
    
    printf("\nHeader fields start at offset 16:\n");
    if (fieldsLength > 0 && [serialized length] >= 16 + fieldsLength) {
        NSData *fieldsData = [NSData dataWithBytes:(bytes + 16) length:fieldsLength];
        printHexDump(fieldsData, @"Header Fields Only");
    }
    
    [pool drain];
    return 0;
}
