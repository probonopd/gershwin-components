#import <Foundation/Foundation.h>
#import "DSStore.h"
#import "DSStoreEntry.h"

int main(int argc, const char * argv[]) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    printf("Testing .DS_Store creation...\n");
    
    // Create a new .DS_Store file
    DSStore *store = [DSStore createStoreAtPath:@"/workspaces/gershwin-components/test.DS_Store" withEntries:nil];
    if (!store) {
        printf("Failed to create DSStore object\n");
        [pool drain];
        return 1;
    }
    
    // Add a test entry (icon position)
    DSStoreEntry *entry = [[DSStoreEntry alloc] initWithFilename:@"test.txt" 
                                                            code:@"Iloc" 
                                                            type:@"blob"
                                                           value:[NSData dataWithBytes:"\x00\x00\x00\x64\x00\x00\x00\x64\xff\xff\xff\xff\xff\xff\x00\x00" length:16]];
    [store setEntry:entry];
    [entry release];
    
    // Save the file
    if ([store save]) {
        printf("Successfully created test.DS_Store!\n");
        
        // List entries to verify
        NSArray *entries = [store entries];
        printf("Created %lu entries:\n", (unsigned long)[entries count]);
        for (DSStoreEntry *e in entries) {
            printf("  %s -> %s (%s)\n", 
                   [[e filename] UTF8String], 
                   [[e code] UTF8String],
                   [[e type] UTF8String]);
        }
    } else {
        printf("Failed to save .DS_Store file\n");
    }
    
    [pool drain];
    return 0;
}
