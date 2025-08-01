#import <Foundation/Foundation.h>
#import "MBMessage.h"

int main(int argc, char *argv[]) {
    @autoreleasepool {
        // Read the actual problematic buffer from the daemon log
        // This comes from: Buffer hex: 6c 01 00 01 a2 00 00 00 02 00 00 00 79 00 00 00 
        // which had 486 bytes total and contained 2 messages
        
        // Let's generate test data by connecting to a real dbus daemon and capturing the exact bytes
        printf("Debugging multi-message parsing issue...\n");
        
        // For now, let's test by creating a simple multi-message buffer
        NSMutableData *testBuffer = [NSMutableData data];
        
        // Create first message: Hello message (128 bytes based on log)
        uint8_t hello[] = {
            0x6c, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x6e, 0x00, 0x00, 0x00,
            // Header fields and body would follow...
        };
        
        // For debugging, let's just test what happens if we manually add the problematic buffer
        // from the log
        printf("Would need actual buffer data to test this properly.\n");
        printf("The issue is that in a multi-message buffer, the 2nd message gets null fields.\n");
        printf("This suggests the header field alignment calculation is wrong.\n");
        
        return 0;
    }
}
