#import <Foundation/Foundation.h>
#import "MBMessage.h"

void printHexDump(NSData *data, const char *label) {
    printf("\n%s (%lu bytes):\n", label, [data length]);
    const uint8_t *bytes = [data bytes];
    for (NSUInteger i = 0; i < [data length]; i++) {
        printf("%02x ", bytes[i]);
        if ((i + 1) % 16 == 0) printf("\n");
    }
    if ([data length] % 16 != 0) printf("\n");
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        printf("=== MiniBus Hello Reply Format Analysis ===\n");
        
        // Create MiniBus Hello reply
        MBMessage *reply = [MBMessage methodReturnWithReplySerial:1 arguments:@[@":1.0"]];
        reply.sender = @"org.freedesktop.DBus";
        reply.destination = @":1.0";  // Real Hello replies include the destination
        NSData *minibusData = [reply serialize];
        
        // Create MiniBus NameAcquired signal
        MBMessage *nameAcquired = [MBMessage signalWithPath:@"/org/freedesktop/DBus"
                                                  interface:@"org.freedesktop.DBus"
                                                     member:@"NameAcquired"
                                                  arguments:@[@":1.0"]];
        nameAcquired.sender = @"org.freedesktop.DBus";
        nameAcquired.destination = @":1.0";
        NSData *signalData = [nameAcquired serialize];
        
        printHexDump(minibusData, "MiniBus Hello Reply");
        printHexDump(signalData, "MiniBus NameAcquired Signal");
        
        // Real dbus-daemon Hello reply (from our test-real-dbus output)
        uint8_t realHelloBytes[] = {
            0x6c, 0x02, 0x01, 0x01, 0x09, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x3d, 0x00, 0x00, 0x00,
            0x06, 0x01, 0x73, 0x00, 0x04, 0x00, 0x00, 0x00, 0x3a, 0x31, 0x2e, 0x30, 0x00, 0x00, 0x00, 0x00,
            0x05, 0x01, 0x75, 0x00, 0x01, 0x00, 0x00, 0x00, 0x08, 0x01, 0x67, 0x00, 0x01, 0x73, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x3a, 0x31, 0x2e, 0x30,
            0x00
        };
        NSData *realHelloData = [NSData dataWithBytes:realHelloBytes length:sizeof(realHelloBytes)];
        printHexDump(realHelloData, "Real dbus-daemon Hello Reply");
        
        // Compare byte by byte
        printf("\n=== Byte-by-byte comparison ===\n");
        printf("Position | MiniBus | Real | Difference\n");
        printf("---------|---------|------|----------\n");
        
        NSUInteger maxLen = MAX([minibusData length], [realHelloData length]);
        const uint8_t *mb = [minibusData bytes];
        const uint8_t *real = [realHelloData bytes];
        
        for (NSUInteger i = 0; i < maxLen; i++) {
            uint8_t mbByte = (i < [minibusData length]) ? mb[i] : 0x00;
            uint8_t realByte = (i < [realHelloData length]) ? real[i] : 0x00;
            
            if (mbByte != realByte || i >= [minibusData length] || i >= [realHelloData length]) {
                printf("   %3lu   |   %02x    |  %02x  | %s\n", 
                       i, mbByte, realByte,
                       (mbByte != realByte) ? "DIFF" : "");
            }
        }
        
        printf("\nSizes: MiniBus=%lu bytes, Real=%lu bytes\n", 
               [minibusData length], [realHelloData length]);
    }
    return 0;
}
