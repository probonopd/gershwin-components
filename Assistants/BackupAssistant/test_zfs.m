//
// test_zfs.m
// Test program for ZFS utility functions
//

#import <Foundation/Foundation.h>
#import "BAZFSUtility.h"

int main(int argc, char *argv[])
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    NSLog(@"=================================================================");
    NSLog(@"=== ZFS UTILITY TEST PROGRAM ===");
    NSLog(@"=================================================================");
    
    // Test 1: Check ZFS availability
    NSLog(@"\n--- TEST 1: ZFS Availability ---");
    BOOL zfsAvailable = [BAZFSUtility isZFSAvailable];
    NSLog(@"ZFS Available: %@", zfsAvailable ? @"YES" : @"NO");
    
    if (!zfsAvailable) {
        NSLog(@"ERROR: ZFS not available, cannot continue tests");
        [pool release];
        return 1;
    }
    
    // Test 2: Check if disk has ZFS pool
    NSLog(@"\n--- TEST 2: Disk ZFS Pool Check ---");
    NSString *testDisk = @"da0";
    BOOL hasPool = [BAZFSUtility diskHasZFSPool:testDisk];
    NSLog(@"Disk %@ has ZFS pool: %@", testDisk, hasPool ? @"YES" : @"NO");
    
    if (hasPool) {
        NSString *poolName = [BAZFSUtility getPoolNameFromDisk:testDisk];
        NSLog(@"Pool name on disk: %@", poolName ?: @"(unknown)");
        
        if (poolName) {
            // Test 3: Check if pool is imported
            NSLog(@"\n--- TEST 3: Pool Import Status ---");
            BOOL poolExists = [BAZFSUtility poolExists:poolName];
            NSLog(@"Pool '%@' is imported: %@", poolName, poolExists ? @"YES" : @"NO");
            
            // Test 4: Test destroy pool workflow (the critical test!)
            NSLog(@"\n--- TEST 4: Destroy Pool Workflow ---");
            NSLog(@"Testing the exact scenario that was failing...");
            
            if (poolExists) {
                NSLog(@"Pool is imported, testing export first...");
                BOOL exported = [BAZFSUtility exportPool:poolName];
                NSLog(@"Export result: %@", exported ? @"SUCCESS" : @"FAILURE");
            } else {
                NSLog(@"Pool is not imported (exported state)");
            }
            
            NSLog(@"Now testing destroy on exported pool...");
            BOOL destroyed = [BAZFSUtility destroyPool:poolName];
            NSLog(@"Destroy result: %@", destroyed ? @"SUCCESS" : @"FAILURE");
            
            if (destroyed) {
                NSLog(@"✅ SUCCESS: Destroy pool workflow completed successfully!");
                
                // Verify pool is really gone
                BOOL stillExists = [BAZFSUtility poolExists:poolName];
                NSLog(@"Pool still exists after destroy: %@", stillExists ? @"YES" : @"NO");
                
                // Check disk labels to see if pool data is gone
                BOOL diskStillHasPool = [BAZFSUtility diskHasZFSPool:testDisk];
                NSLog(@"Disk still has ZFS pool data: %@", diskStillHasPool ? @"YES" : @"NO");
            } else {
                NSLog(@"❌ FAILURE: Destroy pool workflow failed!");
            }
        }
    }
    
    // Test 5: Test creating a new pool
    NSLog(@"\n--- TEST 5: Create New Pool ---");
    NSString *newPoolName = @"test_backup_pool";
    NSLog(@"Testing pool creation: %@", newPoolName);
    
    BOOL created = [BAZFSUtility createPool:newPoolName onDisk:testDisk];
    NSLog(@"Pool creation result: %@", created ? @"SUCCESS" : @"FAILURE");
    
    if (created) {
        NSLog(@"✅ SUCCESS: Pool creation completed!");
        
        // Clean up - destroy the test pool
        NSLog(@"Cleaning up test pool...");
        BOOL cleanedUp = [BAZFSUtility destroyPool:newPoolName];
        NSLog(@"Cleanup result: %@", cleanedUp ? @"SUCCESS" : @"FAILURE");
    }
    
    NSLog(@"\n=================================================================");
    NSLog(@"=== ZFS UTILITY TEST COMPLETE ===");
    NSLog(@"=================================================================");
    
    [pool release];
    return 0;
}
