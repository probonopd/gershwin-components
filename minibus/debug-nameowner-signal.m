#import "MBMessage.h"
#import "MBTransport.h"

int main(int argc, char *argv[]) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    // This is the hex data from the MiniBus log showing the NameOwnerChanged signal
    // Let's construct it and see what's wrong
    
    printf("Creating a NameOwnerChanged signal to test parsing...\n");
    
    MBMessage *signal = [[MBMessage alloc] init];
    signal.type = MBMessageTypeSignal;
    signal.interface = @"org.freedesktop.DBus";
    signal.member = @"NameOwnerChanged";
    signal.path = @"/org/freedesktop/DBus";
    signal.destination = nil; // Broadcast signal
    signal.sender = @"org.freedesktop.DBus";
    signal.signature = @"sss"; // Three strings: name, old_owner, new_owner
    signal.arguments = @[@"org.xfce.Xfconf", @"", @":1.2"];
    signal.serial = 1;
    
    printf("Serializing NameOwnerChanged signal...\n");
    NSData *serialized = [signal serialize];
    printf("Serialized %lu bytes\n", [serialized length]);
    
    // Hex dump
    const uint8_t *bytes = [serialized bytes];
    printf("Hex dump:\n");
    for (NSUInteger i = 0; i < [serialized length]; i += 16) {
        printf("%04lx: ", i);
        for (NSUInteger j = 0; j < 16 && i + j < [serialized length]; j++) {
            printf("%02x ", bytes[i + j]);
        }
        printf("\n");
    }
    
    // Now try to parse it back
    printf("\nParsing back the signal...\n");
    NSUInteger consumed = 0;
    NSArray *messages = [MBMessage messagesFromData:serialized consumedBytes:&consumed];
    
    printf("Parsed %lu messages, consumed %lu bytes\n", [messages count], consumed);
    
    if ([messages count] > 0) {
        MBMessage *parsed = [messages objectAtIndex:0];
        printf("Parsed message:\n");
        printf("  Type: %d\n", parsed.type);
        printf("  Interface: %s\n", [parsed.interface UTF8String]);
        printf("  Member: %s\n", [parsed.member UTF8String]);
        printf("  Arguments: %lu\n", [parsed.arguments count]);
        
        for (NSUInteger i = 0; i < [parsed.arguments count]; i++) {
            id arg = [parsed.arguments objectAtIndex:i];
            printf("    [%lu]: %s\n", i, [[arg description] UTF8String]);
        }
    }
    
    [signal release];
    [pool release];
    return 0;
}
