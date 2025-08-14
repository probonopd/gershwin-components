// Simple test program for destroyPool method
// Build with: clang19 -framework Foundation -I/System/Library/Frameworks/GNUstep.framework/Headers test_destroy.m BAZFSUtility.m -lobjc

#import <Foundation/Foundation.h>
#import "BAZFSUtility.h"

int main() {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    NSLog(@"Testing destroyPool method on exported backup_pool...");
    
    BOOL result = [BAZFSUtility destroyPool:@"backup_pool"];
    
    NSLog(@"Result: %@", result ? @"SUCCESS" : @"FAILURE");
    
    [pool release];
    return result ? 0 : 1;
}
