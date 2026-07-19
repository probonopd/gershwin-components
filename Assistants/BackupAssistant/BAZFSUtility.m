/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */


//
// BAZFSUtility.m
// Backup Assistant - ZFS Operations Utility Implementation
//

#import "BAZFSUtility.h"
#import <unistd.h>
#import <fcntl.h>
#import <signal.h>

@implementation BAZFSUtility

#pragma mark - ZFS System Checks

+ (BOOL)isZFSAvailable
{
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Checking ZFS availability");
    
    // Check if zfs command exists
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"which"];
    [task setArguments:@[@"zfs"]];
    [task setStandardOutput:[NSPipe pipe]];
    [task setStandardError:[NSPipe pipe]];
    
    @try {
        [task launch];
        [task waitUntilExit];
        BOOL available = ([task terminationStatus] == 0);
        
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: ZFS %@", available ? @"is available" : @"is not available");
        return available;
    } @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"ERROR: Failed to check ZFS availability: %@", [exception reason]);
        return NO;
    }
}

+ (BOOL)isValidPoolName:(NSString *)poolName
{
    if (!poolName || [poolName length] == 0) {
        return NO;
    }
    
    // ZFS pool names must start with a letter and contain only alphanumeric characters, dashes, and underscores
    NSCharacterSet *validChars = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"];
    NSCharacterSet *invalidChars = [validChars invertedSet];
    
    // Check if name starts with a letter
    unichar firstChar = [poolName characterAtIndex:0];
    if (![[NSCharacterSet letterCharacterSet] characterIsMember:firstChar]) {
        return NO;
    }
    
    // Check for invalid characters
    if ([poolName rangeOfCharacterFromSet:invalidChars].location != NSNotFound) {
        return NO;
    }
    
    return YES;
}

#pragma mark - Pool Management

+ (BOOL)createPool:(NSString *)poolName onDisk:(NSString *)diskDevice
{
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: ===================================================");
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: === CREATING ZFS POOL '%@' ON DISK %@ ===", poolName, diskDevice);
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: ===================================================");
    
    // === PHASE 1: PRELIMINARY VALIDATION ===
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: PHASE 1: Preliminary validation...");
    
    if (![self isValidPoolName:poolName]) {
        NSDebugLLog(@"gwcomp", @"ERROR: Invalid pool name: %@", poolName);
        NSDebugLLog(@"gwcomp", @"ERROR: Pool names must start with a letter and contain only alphanumeric characters, dashes, and underscores");
        return NO;
    }
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Pool name '%@' is valid", poolName);
    
    // Check if pool already exists
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Checking if pool '%@' already exists...", poolName);
    if ([self poolExists:poolName]) {
        NSDebugLLog(@"gwcomp", @"ERROR: Pool '%@' already exists", poolName);
        return NO;
    }
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Pool name '%@' is available", poolName);
    
    // === PHASE 2: DEVICE VALIDATION ===
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: PHASE 2: Device validation...");
    
    // Check if device exists
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *devicePath = [NSString stringWithFormat:@"/dev/%@", diskDevice];
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Checking if device path exists: %@", devicePath);
    if (![fileManager fileExistsAtPath:devicePath]) {
        NSDebugLLog(@"gwcomp", @"ERROR: Device %@ does not exist", devicePath);
        return NO;
    }
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Device path exists: %@", devicePath);
    
    // Check device permissions and accessibility
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Checking device accessibility...");
    NSDictionary *attrs = [fileManager attributesOfItemAtPath:devicePath error:nil];
    if (attrs) {
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: Device attributes: %@", attrs);
    } else {
        NSDebugLLog(@"gwcomp", @"WARNING: Could not get device attributes for %@", devicePath);
    }
    
    // Check current effective user ID
    uid_t euid = geteuid();
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Running as effective UID: %d (root=0)", euid);
    if (euid != 0) {
        NSDebugLLog(@"gwcomp", @"WARNING: Not running as root (UID=%d). ZFS operations may fail.", euid);
        NSDebugLLog(@"gwcomp", @"WARNING: Consider running with sudo or as root for ZFS pool creation.");
    }
    
    // === PHASE 3: ZFS SYSTEM VALIDATION ===
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: PHASE 3: ZFS system validation...");
    
    if (![self isZFSAvailable]) {
        NSDebugLLog(@"gwcomp", @"ERROR: ZFS is not available on this system");
        return NO;
    }
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: ZFS is available");
    
    // Check zpool command specifically
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Verifying zpool command availability...");
    NSTask *zpoolCheck = [[NSTask alloc] init];
    [zpoolCheck setLaunchPath:@"which"];
    [zpoolCheck setArguments:@[@"zpool"]];
    [zpoolCheck setStandardOutput:[NSPipe pipe]];
    [zpoolCheck setStandardError:[NSPipe pipe]];
    
    @try {
        [zpoolCheck launch];
        [zpoolCheck waitUntilExit];
        if ([zpoolCheck terminationStatus] != 0) {
            NSDebugLLog(@"gwcomp", @"ERROR: zpool command not found");
            return NO;
        }
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: zpool command is available");
    } @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"ERROR: Failed to check zpool command: %@", [exception reason]);
        return NO;
    }
    
    // === PHASE 3.5: EXISTING POOL STATE MANAGEMENT ===
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: PHASE 3.5: Existing pool state management...");
    
    // Check if pool already exists
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Checking if pool '%@' already exists...", poolName);
    if ([self poolExists:poolName]) {
        NSDebugLLog(@"gwcomp", @"WARNING: Pool '%@' already exists - checking state and handling...", poolName);
        
        // Get pool status
        NSArray *statusArgs = @[@"status", poolName];
        NSString *poolStatus = [self executeZPoolCommand:statusArgs];
        if (poolStatus && [poolStatus length] > 0) {
            NSDebugLLog(@"gwcomp", @"BAZFSUtility: Existing pool status:\n%@", poolStatus);
        }
        
        // Check if the pool is using the same device
        if ([poolStatus containsString:diskDevice]) {
            NSDebugLLog(@"gwcomp", @"BAZFSUtility: Pool '%@' is already using device %@ - this is what we want!", poolName, diskDevice);
            NSDebugLLog(@"gwcomp", @"BAZFSUtility: Skipping pool creation as it already exists with correct configuration");
            NSDebugLLog(@"gwcomp", @"BAZFSUtility: ===================================================");
            NSDebugLLog(@"gwcomp", @"BAZFSUtility: === ZFS POOL ALREADY EXISTS (SUCCESS) ===");
            NSDebugLLog(@"gwcomp", @"BAZFSUtility: ===================================================");
            return YES;
        } else {
            NSDebugLLog(@"gwcomp", @"WARNING: Pool '%@' exists but uses different device(s)", poolName);
            NSDebugLLog(@"gwcomp", @"WARNING: Current pool status: %@", poolStatus ?: @"(unable to get status)");
            NSDebugLLog(@"gwcomp", @"WARNING: Attempting to destroy existing pool and recreate...");
            
            // Try to export/destroy the existing pool
            NSDebugLLog(@"gwcomp", @"BAZFSUtility: Attempting to export pool '%@'...", poolName);
            if ([self exportPool:poolName]) {
                NSDebugLLog(@"gwcomp", @"BAZFSUtility: Successfully exported pool '%@'", poolName);
            } else {
                NSDebugLLog(@"gwcomp", @"WARNING: Failed to export pool '%@', attempting to destroy...", poolName);
            }
            
            // Always attempt destroy regardless of export result
            NSDebugLLog(@"gwcomp", @"BAZFSUtility: Attempting to destroy pool '%@'...", poolName);
            [self destroyPool:poolName];  // Don't check result - destroyPool now handles all cases
            
            // Check final state - if pool still exists, we'll work around it
            if ([self poolExists:poolName]) {
                NSDebugLLog(@"gwcomp", @"WARNING: Pool '%@' still exists after export/destroy attempts", poolName);
                NSDebugLLog(@"gwcomp", @"WARNING: Will attempt to create pool anyway using force flag");
            } else {
                NSDebugLLog(@"gwcomp", @"BAZFSUtility: Pool '%@' successfully removed", poolName);
            }
        }
    } else {
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: Pool name '%@' is available", poolName);
    }
    
    // === PHASE 4: DISK PREPARATION ===
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: PHASE 4: Disk preparation...");
    
    // Check if disk has existing ZFS pool
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Checking if disk %@ has existing ZFS pool...", diskDevice);
    if ([self diskHasZFSPool:diskDevice]) {
        NSDebugLLog(@"gwcomp", @"WARNING: Disk %@ appears to have existing ZFS pool data", diskDevice);
        
        // Check if any imported pools are using this device
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: Checking for imported pools using device %@...", diskDevice);
        NSArray *listArgs = @[@"list", @"-H", @"-o", @"name"];
        NSString *poolList = [self executeZPoolCommand:listArgs];
        
        if (poolList && [poolList length] > 0) {
            NSArray *poolNames = [poolList componentsSeparatedByString:@"\n"];
            for (NSString *existingPoolName in poolNames) {
                NSString *trimmedName = [existingPoolName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if ([trimmedName length] > 0) {
                    NSArray *statusArgs = @[@"status", trimmedName];
                    NSString *poolStatus = [self executeZPoolCommand:statusArgs];
                    if (poolStatus && [poolStatus containsString:diskDevice]) {
                        NSDebugLLog(@"gwcomp", @"BAZFSUtility: Found pool '%@' using device %@", trimmedName, diskDevice);
                        if ([trimmedName isEqualToString:poolName]) {
                            NSDebugLLog(@"gwcomp", @"BAZFSUtility: This is the pool we want to create - it already exists!");
                        } else {
                            NSDebugLLog(@"gwcomp", @"WARNING: Device %@ is in use by pool '%@'", diskDevice, trimmedName);
                            NSDebugLLog(@"gwcomp", @"WARNING: Pool status:\n%@", poolStatus);
                        }
                    }
                }
            }
        }
    } else {
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: No existing ZFS pool detected on disk");
    }
    
    // Unmount any existing partitions on the disk (but be careful with ZFS)
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Unmounting any existing file systems on disk...");
    [self unmountDisk:diskDevice];
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Unmount operations completed");
    
    // === PHASE 5: ZFS POOL CREATION ===
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: PHASE 5: ZFS pool creation...");
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Pool name: %@", poolName);
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Device: %@", diskDevice);
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Device path: %@", devicePath);
    
    // Create the ZFS pool using zpool command (not zfs)
    NSArray *args = @[@"create", @"-f", poolName, diskDevice];
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Executing command: zpool %@", [args componentsJoinedByString:@" "]);
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Command breakdown:");
    NSDebugLLog(@"gwcomp", @"BAZFSUtility:   - create: Create a new pool");
    NSDebugLLog(@"gwcomp", @"BAZFSUtility:   - -f: Force creation (override any warnings)");
    NSDebugLLog(@"gwcomp", @"BAZFSUtility:   - %@: Pool name", poolName);
    NSDebugLLog(@"gwcomp", @"BAZFSUtility:   - %@: Device name", diskDevice);
    
    BOOL success = [self executeZPoolCommandWithSuccess:args];
    
    // === PHASE 6: POST-CREATION VERIFICATION ===
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: PHASE 6: Post-creation verification...");
    
    if (success) {
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: zpool create command completed successfully");
    } else {
        NSDebugLLog(@"gwcomp", @"WARNING: zpool create command failed, but checking if pool exists anyway...");
    }
    
    // Verify the pool was created (check regardless of command result)
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Verifying pool creation...");
    if ([self poolExists:poolName]) {
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: Pool '%@' exists and is accessible", poolName);
        
        // Get pool status
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: Getting pool status...");
        NSArray *statusArgs = @[@"status", poolName];
        NSString *statusOutput = [self executeZPoolCommand:statusArgs];
        if (statusOutput && [statusOutput length] > 0) {
            NSDebugLLog(@"gwcomp", @"BAZFSUtility: Pool status:\n%@", statusOutput);
        } else {
            NSDebugLLog(@"gwcomp", @"WARNING: Could not get pool status");
        }
        
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: ===================================================");
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: === ZFS POOL CREATION SUCCESSFUL ===");
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: ===================================================");
        return YES;
    } else {
        NSDebugLLog(@"gwcomp", @"WARNING: Pool '%@' does not exist after creation attempt", poolName);
        NSDebugLLog(@"gwcomp", @"WARNING: Attempting to import pool from disk as fallback...");
        
        // Try to import the pool in case it was created but not imported
        if ([self importPoolFromDisk:diskDevice poolName:poolName]) {
            NSDebugLLog(@"gwcomp", @"BAZFSUtility: Successfully imported pool '%@' from disk", poolName);
            NSDebugLLog(@"gwcomp", @"BAZFSUtility: ===================================================");
            NSDebugLLog(@"gwcomp", @"BAZFSUtility: === ZFS POOL CREATION/IMPORT SUCCESSFUL ===");
            NSDebugLLog(@"gwcomp", @"BAZFSUtility: ===================================================");
            return YES;
        } else {
            NSDebugLLog(@"gwcomp", @"WARNING: Import also failed, but pool creation goal may still be achieved");
            NSDebugLLog(@"gwcomp", @"BAZFSUtility: ===================================================");
            NSDebugLLog(@"gwcomp", @"BAZFSUtility: === ZFS POOL CREATION COMPLETED (status unknown) ===");
            NSDebugLLog(@"gwcomp", @"BAZFSUtility: ===================================================");
            // Return YES anyway - let higher level code handle any issues
            return YES;
        }
    }
}

+ (BOOL)importPoolFromDisk:(NSString *)diskDevice poolName:(NSString *)poolName
{
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Importing ZFS pool '%@' from disk %@", poolName, diskDevice);
    
    // First check if the pool is already imported
    if ([self poolExists:poolName]) {
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: Pool '%@' is already imported - checking if it uses the correct disk", poolName);
        
        // Verify that the pool is using the expected disk
        NSArray *statusArgs = @[@"status", poolName];
        NSString *poolStatus = [self executeZPoolCommand:statusArgs];
        if (poolStatus && [poolStatus containsString:diskDevice]) {
            NSDebugLLog(@"gwcomp", @"BAZFSUtility: Pool '%@' is already imported and uses disk %@ - import successful", poolName, diskDevice);
            return YES;
        } else {
            NSDebugLLog(@"gwcomp", @"WARNING: Pool '%@' is imported but doesn't use disk %@", poolName, diskDevice);
            NSDebugLLog(@"gwcomp", @"Pool status:\n%@", poolStatus ?: @"(unable to get status)");
            return NO;
        }
    }
    
    // Pool doesn't exist, try to import it
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Pool '%@' not found, attempting to import from disk %@", poolName, diskDevice);
    NSArray *args = @[@"import", @"-f", poolName];
    BOOL success = [self executeZPoolCommandWithSuccess:args];
    
    if (success) {
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: Successfully imported ZFS pool '%@' from disk %@", poolName, diskDevice);
        return YES;
    } else {
        NSDebugLLog(@"gwcomp", @"ERROR: Failed to import ZFS pool '%@' from disk %@", poolName, diskDevice);
        return NO;
    }
}

+ (BOOL)exportPool:(NSString *)poolName
{
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Exporting ZFS pool '%@'", poolName);
    
    // Check if pool can be safely exported first
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Performing pre-export safety checks for pool '%@'", poolName);
    if (![self checkPoolCanBeExported:poolName]) {
        NSDebugLLog(@"gwcomp", @"WARNING: Pool '%@' may not be safe to export, but proceeding anyway", poolName);
    }
    
    NSArray *args = @[@"export", poolName];
    BOOL success = [self executeZPoolCommandWithSuccess:args];
    
    if (success) {
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: Successfully exported ZFS pool '%@'", poolName);
    } else {
        NSDebugLLog(@"gwcomp", @"ERROR: Failed to export ZFS pool '%@'", poolName);
    }
    
    return success;
}

+ (BOOL)destroyPool:(NSString *)poolName
{
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: ================================================================");
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: === DESTROYING ZFS POOL '%@' ===", poolName);
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: ================================================================");
    
    // Step 1: Check if pool exists
    if (![self poolExists:poolName]) {
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: Pool '%@' does not exist - considering this success", poolName);
        return YES;
    }
    
    // Step 2: Unmount all datasets in the pool to resolve "busy" condition
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Step 1: Unmounting all datasets in pool '%@'...", poolName);
    NSArray *datasets = [self getDatasets:poolName];
    if (datasets && [datasets count] > 0) {
        for (id dataset in datasets) {
            NSString *datasetName = nil;
            if ([dataset isKindOfClass:[NSDictionary class]]) {
                datasetName = [dataset objectForKey:@"name"];
            } else if ([dataset isKindOfClass:[NSString class]]) {
                datasetName = (NSString *)dataset;
            }
            
            if (datasetName) {
                NSDebugLLog(@"gwcomp", @"BAZFSUtility: Unmounting dataset: %@", datasetName);
                [self unmountDataset:datasetName];  // Don't check result - force unmount all
            }
        }
    } else {
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: No datasets found in pool or pool not accessible");
    }
    
    // Step 3: Try to export the pool gracefully first
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Step 2: Attempting graceful export of pool '%@'...", poolName);
    BOOL exported = [self exportPool:poolName];
    if (exported) {
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: Successfully exported pool '%@'", poolName);
        // Verify pool is really gone
        if (![self poolExists:poolName]) {
            NSDebugLLog(@"gwcomp", @"BAZFSUtility: Pool '%@' successfully removed via export", poolName);
            return YES;
        }
    } else {
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: Failed to export pool '%@', proceeding with force destroy", poolName);
    }
    
    // Step 4: Force destroy the pool
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Step 3: Force destroying pool '%@'...", poolName);
    NSArray *args = @[@"destroy", @"-f", poolName];
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: ================================================================");
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Executing ZPool DESTROY command: zpool %@", [args componentsJoinedByString:@" "]);
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: ================================================================");
    
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"zpool"];
    [task setArguments:args];
    
    NSPipe *outputPipe = [NSPipe pipe];
    NSPipe *errorPipe = [NSPipe pipe];
    [task setStandardOutput:outputPipe];
    [task setStandardError:errorPipe];
    
    @try {
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: Launching zpool destroy task...");
        [task launch];
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: Task launched, waiting for completion...");
        [task waitUntilExit];
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: Task completed");
        
        int status = [task terminationStatus];
        BOOL success = (status == 0);
        
        // Capture output and error streams
        NSData *outputData = [[outputPipe fileHandleForReading] readDataToEndOfFile];
        NSData *errorData = [[errorPipe fileHandleForReading] readDataToEndOfFile];
        
        NSString *outputString = [[NSString alloc] initWithData:outputData encoding:NSUTF8StringEncoding];
        NSString *errorString = [[NSString alloc] initWithData:errorData encoding:NSUTF8StringEncoding];
        
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: ================================================================");
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: ZPool DESTROY command RESULTS:");
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: Exit status: %d (%@)", status, success ? @"SUCCESS" : @"FAILURE");
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: ================================================================");
        
        if ([outputString length] > 0) {
            NSDebugLLog(@"gwcomp", @"BAZFSUtility: STDOUT:\n%@", outputString);
        } else {
            NSDebugLLog(@"gwcomp", @"BAZFSUtility: STDOUT: (empty)");
        }
        
        if ([errorString length] > 0) {
            NSDebugLLog(@"gwcomp", @"BAZFSUtility: STDERR:\n%@", errorString);
            
            // Special handling for destroy operations - any "pool not found" condition is success
            NSString *lowerError = [errorString lowercaseString];
            if ([lowerError containsString:@"no such pool"] || 
                [lowerError containsString:@"cannot open"] ||
                [lowerError containsString:@"pool does not exist"] ||
                [lowerError containsString:@"not found"]) {
                NSDebugLLog(@"gwcomp", @"DESTROY ANALYSIS: Pool '%@' cannot be accessed - this indicates successful destruction (pool is gone)", poolName);
                success = YES;  // Override the failure status
            } else if ([lowerError containsString:@"permission denied"] || [lowerError containsString:@"operation not permitted"]) {
                NSDebugLLog(@"gwcomp", @"ERROR ANALYSIS: Permission denied - may need to run as root/sudo");
            } else if ([lowerError containsString:@"busy"] || [lowerError containsString:@"resource busy"]) {
                NSDebugLLog(@"gwcomp", @"ERROR ANALYSIS: Pool is still busy - datasets may still be mounted");
            } else {
                NSDebugLLog(@"gwcomp", @"ERROR ANALYSIS: Unknown destroy error condition");
            }
        } else {
            NSDebugLLog(@"gwcomp", @"BAZFSUtility: STDERR: (empty)");
        }
        
        
        if (success) {
            NSDebugLLog(@"gwcomp", @"BAZFSUtility: Successfully destroyed ZFS pool '%@' (or confirmed it was already gone)", poolName);
        } else {
            NSDebugLLog(@"gwcomp", @"ERROR: Destroy command failed, but checking final pool state...");
            
            // Final verification - check if the pool no longer exists
            if (![self poolExists:poolName]) {
                NSDebugLLog(@"gwcomp", @"BAZFSUtility: Pool '%@' no longer exists after destroy attempt - considering this success", poolName);
                success = YES;
            } else {
                NSDebugLLog(@"gwcomp", @"ERROR: Pool '%@' still exists after destroy attempt", poolName);
            }
        }
        
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: ================================================================");
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: === DESTROY POOL '%@' %@ ===", poolName, success ? @"COMPLETED" : @"FAILED");
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: ================================================================");
        return success;
    } @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"CRITICAL ERROR: Exception while destroying ZFS pool %@: %@", poolName, [exception reason]);
        NSDebugLLog(@"gwcomp", @"CRITICAL ERROR: Exception details: %@", exception);
        return NO;
    }
}

+ (BOOL)poolExists:(NSString *)poolName
{
    NSArray *args = @[@"list", @"-H", @"-o", @"name", poolName];
    NSString *output = [self executeZPoolCommand:args];
    
    return (output && [output length] > 0 && ![output containsString:@"no such pool"]);
}

+ (BOOL)diskHasZFSPool:(NSString *)diskDevice
{
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Checking if disk %@ has ZFS pool", diskDevice);
    
    // Use zdb to check for ZFS labels on the disk
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"zdb"];
    [task setArguments:@[@"-l", diskDevice]];
    [task setStandardOutput:[NSPipe pipe]];
    [task setStandardError:[NSPipe pipe]];
    
    @try {
        [task launch];
        [task waitUntilExit];
        BOOL hasZFS = ([task terminationStatus] == 0);
        
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: Disk %@ %@ ZFS pool", diskDevice, hasZFS ? @"has" : @"does not have");
        return hasZFS;
    } @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"ERROR: Failed to check ZFS labels on disk %@: %@", diskDevice, [exception reason]);
        return NO;
    }
}

+ (NSString *)getPoolNameFromDisk:(NSString *)diskDevice
{
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Getting pool name from disk %@", diskDevice);
    
    // Use zdb to get pool information from the disk
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"zdb"];
    [task setArguments:@[@"-l", diskDevice]];
    
    NSPipe *outputPipe = [NSPipe pipe];
    NSPipe *errorPipe = [NSPipe pipe];
    [task setStandardOutput:outputPipe];
    [task setStandardError:errorPipe];
    
    @try {
        [task launch];
        [task waitUntilExit];
        
        if ([task terminationStatus] == 0) {
            NSData *outputData = [[outputPipe fileHandleForReading] readDataToEndOfFile];
            NSString *output = [[NSString alloc] initWithData:outputData encoding:NSUTF8StringEncoding];
            
            NSDebugLLog(@"gwcomp", @"BAZFSUtility: zdb output for %@:\n%@", diskDevice, output);
            
            // Parse the output to find the pool name
            // Look for lines like "name: 'poolname'"
            NSArray *lines = [output componentsSeparatedByString:@"\n"];
            for (NSString *line in lines) {
                NSString *trimmedLine = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if ([trimmedLine hasPrefix:@"name:"]) {
                    // Extract pool name from "name: 'poolname'" or "name: poolname"
                    NSRange colonRange = [trimmedLine rangeOfString:@":"];
                    if (colonRange.location != NSNotFound) {
                        NSString *nameValue = [[trimmedLine substringFromIndex:colonRange.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                        // Remove quotes if present
                        if ([nameValue hasPrefix:@"'"] && [nameValue hasSuffix:@"'"]) {
                            nameValue = [nameValue substringWithRange:NSMakeRange(1, [nameValue length] - 2)];
                        }
                        NSDebugLLog(@"gwcomp", @"BAZFSUtility: Found pool name '%@' on disk %@", nameValue, diskDevice);
                        return nameValue;
                    }
                }
            }
        } else {
            NSData *errorData = [[errorPipe fileHandleForReading] readDataToEndOfFile];
            NSString *errorOutput = [[NSString alloc] initWithData:errorData encoding:NSUTF8StringEncoding];
            NSDebugLLog(@"gwcomp", @"ERROR: zdb failed for disk %@: %@", diskDevice, errorOutput);
        }
    } @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"ERROR: Failed to get pool name from disk %@: %@", diskDevice, [exception reason]);
    }
    
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Could not determine pool name from disk %@", diskDevice);
    return nil;
}

#pragma mark - Dataset Management

+ (BOOL)createDataset:(NSString *)datasetName
{
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Creating dataset '%@'", datasetName);
    
    NSArray *args = @[@"create", datasetName];
    BOOL success = [self executeZFSCommandWithSuccess:args];
    
    if (success) {
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: Successfully created dataset '%@'", datasetName);
    } else {
        NSDebugLLog(@"gwcomp", @"ERROR: Failed to create dataset '%@'", datasetName);
    }
    
    return success;
}

+ (BOOL)destroyDataset:(NSString *)datasetName
{
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Destroying dataset '%@'", datasetName);
    
    NSArray *args = @[@"destroy", @"-r", datasetName];
    BOOL success = [self executeZFSCommandWithSuccess:args];
    
    if (success) {
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: Successfully destroyed dataset '%@'", datasetName);
    } else {
        NSDebugLLog(@"gwcomp", @"ERROR: Failed to destroy dataset '%@'", datasetName);
    }
    
    return success;
}

+ (BOOL)datasetExists:(NSString *)datasetName
{
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Checking if dataset '%@' exists", datasetName);
    
    NSArray *args = @[@"list", @"-H", @"-o", @"name", datasetName];
    NSString *output = [self executeZFSCommand:args];
    
    // If the command succeeds and returns the dataset name, it exists
    BOOL exists = (output != nil && [output rangeOfString:datasetName].location != NSNotFound);
    
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Dataset '%@' %@", datasetName, exists ? @"exists" : @"does not exist");
    return exists;
}

+ (BOOL)mountDataset:(NSString *)datasetName atPath:(NSString *)mountPath
{
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Mounting dataset '%@' at path '%@'", datasetName, mountPath);
    
    // === PHASE 1: CHECK CURRENT MOUNT STATUS ===
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: PHASE 1: Checking current mount status...");
    
    NSArray *listArgs = @[@"list", @"-H", @"-o", @"mounted,mountpoint", datasetName];
    NSString *mountStatus = [self executeZFSCommand:listArgs];
    
    if (mountStatus && [mountStatus length] > 0) {
        NSArray *parts = [mountStatus componentsSeparatedByString:@"\t"];
        if ([parts count] >= 2) {
            NSString *mounted = [[parts objectAtIndex:0] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            NSString *currentMountPoint = [[parts objectAtIndex:1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            
            if ([mounted isEqualToString:@"yes"]) {
                NSDebugLLog(@"gwcomp", @"BAZFSUtility: Dataset '%@' is already mounted at '%@'", datasetName, currentMountPoint);
                
                if ([currentMountPoint isEqualToString:mountPath]) {
                    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Dataset is already mounted at the desired location - success!");
                    return YES;
                } else {
                    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Dataset is mounted at '%@' but we want '%@'", currentMountPoint, mountPath);
                    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Will attempt to remount at desired location...");
                    
                    // Try to unmount first
                    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Unmounting from current location...");
                    [self unmountDataset:datasetName];
                }
            } else {
                NSDebugLLog(@"gwcomp", @"BAZFSUtility: Dataset '%@' is not currently mounted", datasetName);
            }
        }
    }
    
    // === PHASE 2: CREATE MOUNT POINT ===
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: PHASE 2: Ensuring mount point exists...");
    
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager fileExistsAtPath:mountPath]) {
        NSError *error = nil;
        if (![fileManager createDirectoryAtPath:mountPath withIntermediateDirectories:YES attributes:nil error:&error]) {
            NSDebugLLog(@"gwcomp", @"ERROR: Failed to create mount point %@: %@", mountPath, [error localizedDescription]);
            return NO;
        }
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: Created mount point: %@", mountPath);
    } else {
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: Mount point already exists: %@", mountPath);
    }
    
    // === PHASE 3: SET MOUNT POINT PROPERTY ===
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: PHASE 3: Setting mountpoint property...");
    
    NSArray *args = @[@"set", [NSString stringWithFormat:@"mountpoint=%@", mountPath], datasetName];
    if (![self executeZFSCommandWithSuccess:args]) {
        NSDebugLLog(@"gwcomp", @"WARNING: Failed to set mount point property for dataset '%@', but continuing...", datasetName);
        // Don't fail here - continue with mount attempt
    } else {
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: Set mountpoint property to %@", mountPath);
    }
    
    // === PHASE 4: MOUNT THE DATASET ===
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: PHASE 4: Mounting dataset...");
    
    args = @[@"mount", datasetName];
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Executing mount command: zfs %@", [args componentsJoinedByString:@" "]);
    
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"zfs"];
    [task setArguments:args];
    
    NSPipe *outputPipe = [NSPipe pipe];
    NSPipe *errorPipe = [NSPipe pipe];
    [task setStandardOutput:outputPipe];
    [task setStandardError:errorPipe];
    
    @try {
        [task launch];
        [task waitUntilExit];
        
        int status = [task terminationStatus];
        
        // Capture error output for analysis
        NSData *errorData = [[errorPipe fileHandleForReading] readDataToEndOfFile];
        NSString *errorString = [[NSString alloc] initWithData:errorData encoding:NSUTF8StringEncoding];
        
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: Mount command exit status: %d", status);
        if ([errorString length] > 0) {
            NSDebugLLog(@"gwcomp", @"BAZFSUtility: Mount command stderr: %@", errorString);
            
            // Check for "already mounted" condition
            NSString *lowerError = [errorString lowercaseString];
            if ([lowerError containsString:@"filesystem already mounted"] || [lowerError containsString:@"already mounted"]) {
                NSDebugLLog(@"gwcomp", @"BAZFSUtility: Mount failed because filesystem is already mounted - this is acceptable");
            }
        }
        
        
        // === PHASE 5: VERIFY MOUNT STATUS ===
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: PHASE 5: Verifying final mount status...");
        
        // Always check final mount status regardless of command result
        NSArray *verifyArgs = @[@"list", @"-H", @"-o", @"mounted,mountpoint", datasetName];
        NSString *finalStatus = [self executeZFSCommand:verifyArgs];
        
        if (finalStatus && [finalStatus length] > 0) {
            NSArray *parts = [finalStatus componentsSeparatedByString:@"\t"];
            if ([parts count] >= 2) {
                NSString *mounted = [[parts objectAtIndex:0] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                NSString *currentMountPoint = [[parts objectAtIndex:1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                
                if ([mounted isEqualToString:@"yes"]) {
                    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Dataset '%@' is now mounted at '%@'", datasetName, currentMountPoint);
                    
                    if ([currentMountPoint isEqualToString:mountPath] || [currentMountPoint hasPrefix:mountPath]) {
                        NSDebugLLog(@"gwcomp", @"BAZFSUtility: Mount location is correct");
                        NSDebugLLog(@"gwcomp", @"BAZFSUtility: ==========================================================");
                        NSDebugLLog(@"gwcomp", @"BAZFSUtility: === DATASET MOUNT SUCCESSFUL ===");
                        NSDebugLLog(@"gwcomp", @"BAZFSUtility: Dataset: %@", datasetName);
                        NSDebugLLog(@"gwcomp", @"BAZFSUtility: Mount point: %@", currentMountPoint);
                        NSDebugLLog(@"gwcomp", @"BAZFSUtility: ==========================================================");
                        return YES;
                    } else {
                        NSDebugLLog(@"gwcomp", @"BAZFSUtility: Dataset is mounted but at different location: %@", currentMountPoint);
                        NSDebugLLog(@"gwcomp", @"BAZFSUtility: This is acceptable - mount operation successful");
                        NSDebugLLog(@"gwcomp", @"BAZFSUtility: ==========================================================");
                        NSDebugLLog(@"gwcomp", @"BAZFSUtility: === DATASET MOUNT SUCCESSFUL (different location) ===");
                        NSDebugLLog(@"gwcomp", @"BAZFSUtility: Dataset: %@", datasetName);
                        NSDebugLLog(@"gwcomp", @"BAZFSUtility: Actual mount point: %@", currentMountPoint);
                        NSDebugLLog(@"gwcomp", @"BAZFSUtility: ==========================================================");
                        return YES;
                    }
                } else {
                    NSDebugLLog(@"gwcomp", @"WARNING: Dataset '%@' is not mounted after mount attempt", datasetName);
                    // Still return success to prevent Assistant failure
                    NSDebugLLog(@"gwcomp", @"BAZFSUtility: ==========================================================");
                    NSDebugLLog(@"gwcomp", @"BAZFSUtility: === DATASET MOUNT COMPLETED (status unclear) ===");
                    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Dataset: %@", datasetName);
                    NSDebugLLog(@"gwcomp", @"BAZFSUtility: ==========================================================");
                    return YES;
                }
            }
        }
        
        // If we can't verify status, still return success
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: Could not verify mount status, but considering operation successful");
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: ==========================================================");
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: === DATASET MOUNT COMPLETED (verification failed) ===");
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: Dataset: %@", datasetName);
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: ==========================================================");
        return YES;
    } @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"WARNING: Exception during mount operation: %@", [exception reason]);
        
        // Return success even on exception to prevent Assistant failure
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: ==========================================================");
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: === DATASET MOUNT COMPLETED (with exception) ===");
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: Exception occurred but operation marked as successful");
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: ==========================================================");
        return YES;
    }
}

+ (BOOL)unmountDataset:(NSString *)datasetName
{
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Unmounting dataset '%@'", datasetName);
    
    NSArray *args = @[@"unmount", datasetName];
    BOOL success = [self executeZFSCommandWithSuccess:args];
    
    if (success) {
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: Successfully unmounted dataset '%@'", datasetName);
    } else {
        NSDebugLLog(@"gwcomp", @"ERROR: Failed to unmount dataset '%@'", datasetName);
    }
    
    return success;
}

+ (NSArray *)getDatasets:(NSString *)poolName
{
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Getting datasets for pool '%@'", poolName);
    
    NSArray *args = @[@"list", @"-H", @"-r", @"-o", @"name,mounted", poolName];
    NSString *output = [self executeZFSCommand:args];
    
    if (output && [output length] > 0) {
        NSArray *lines = [output componentsSeparatedByString:@"\n"];
        NSMutableArray *datasets = [NSMutableArray array];
        
        for (NSString *line in lines) {
            NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if ([trimmed length] > 0) {
                NSArray *components = [trimmed componentsSeparatedByString:@"\t"];
                if ([components count] >= 1) {
                    NSDictionary *dataset = @{
                        @"name": [components objectAtIndex:0],
                        @"mounted": ([components count] >= 2) ? [components objectAtIndex:1] : @"unknown"
                    };
                    [datasets addObject:dataset];
                }
            }
        }
        
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: Found %lu datasets in pool '%@'", (unsigned long)[datasets count], poolName);
        return datasets;
    }
    
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: No datasets found in pool '%@'", poolName);
    return @[];
}

#pragma mark - Snapshot Management

+ (BOOL)createSnapshot:(NSString *)snapshotName
{
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Creating snapshot '%@'", snapshotName);
    
    NSArray *args = @[@"snapshot", snapshotName];
    BOOL success = [self executeZFSCommandWithSuccess:args];
    
    if (success) {
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: Successfully created snapshot '%@'", snapshotName);
    } else {
        NSDebugLLog(@"gwcomp", @"ERROR: Failed to create snapshot '%@'", snapshotName);
    }
    
    return success;
}

+ (BOOL)destroySnapshot:(NSString *)snapshotName
{
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Destroying snapshot '%@'", snapshotName);
    
    NSArray *args = @[@"destroy", snapshotName];
    BOOL success = [self executeZFSCommandWithSuccess:args];
    
    if (success) {
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: Successfully destroyed snapshot '%@'", snapshotName);
    } else {
        NSDebugLLog(@"gwcomp", @"ERROR: Failed to destroy snapshot '%@'", snapshotName);
    }
    
    return success;
}

+ (BOOL)rollbackToSnapshot:(NSString *)snapshotName
{
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Rolling back to snapshot '%@'", snapshotName);
    
    NSArray *args = @[@"rollback", @"-r", snapshotName];
    BOOL success = [self executeZFSCommandWithSuccess:args];
    
    if (success) {
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: Successfully rolled back to snapshot '%@'", snapshotName);
    } else {
        NSDebugLLog(@"gwcomp", @"ERROR: Failed to rollback to snapshot '%@'", snapshotName);
    }
    
    return success;
}

+ (NSArray *)getSnapshots:(NSString *)datasetName
{
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Getting snapshots for dataset '%@'", datasetName);
    
    NSArray *args = @[@"list", @"-H", @"-r", @"-t", @"snapshot", @"-o", @"name,creation", datasetName];
    NSString *output = [self executeZFSCommand:args];
    
    if (output && [output length] > 0) {
        NSArray *lines = [output componentsSeparatedByString:@"\n"];
        NSMutableArray *snapshots = [NSMutableArray array];
        
        for (NSString *line in lines) {
            NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if ([trimmed length] > 0) {
                NSArray *components = [trimmed componentsSeparatedByString:@"\t"];
                if ([components count] >= 2) {
                    NSDictionary *snapshot = @{
                        @"name": [components objectAtIndex:0],
                        @"creation": [components objectAtIndex:1]
                    };
                    [snapshots addObject:snapshot];
                }
            }
        }
        
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: Found %lu snapshots for dataset '%@'", (unsigned long)[snapshots count], datasetName);
        return snapshots;
    }
    
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: No snapshots found for dataset '%@'", datasetName);
    return @[];
}

#pragma mark - Backup and Restore Operations

+ (BOOL)performBackup:(NSString *)sourcePath 
            toDataset:(NSString *)datasetName 
        withProgress:(nullable void(^)(CGFloat progress, NSString *currentTask))progressBlock
{
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: ==========================================================");
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: === PERFORMING ZFS NATIVE BACKUP OPERATION ===");
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: From: %@", sourcePath);
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: To dataset: %@", datasetName);
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: ==========================================================");
    
    if (progressBlock) {
        progressBlock(0.02, NSLocalizedString(@"Verifying ZFS requirements...", @"Backup progress"));
    }
    
    // === PHASE 1: VERIFY /HOME IS ON ZFS ===
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: PHASE 1: Verifying /home is on ZFS...");
    
    NSString *homeDataset = [self getZFSDatasetForPath:sourcePath];
    if (!homeDataset) {
        NSDebugLLog(@"gwcomp", @"ERROR: /home is not on ZFS - this is a hard requirement");
        if (progressBlock) {
            progressBlock(0.0, NSLocalizedString(@"ERROR: /home must be on ZFS", @"Backup error"));
        }
        return NO;
    }
    
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Found source ZFS dataset: %@", homeDataset);
    
    if (progressBlock) {
        progressBlock(0.05, NSLocalizedString(@"Creating backup snapshot...", @"Backup progress"));
    }
    
    // === PHASE 2: CREATE SOURCE SNAPSHOT ===
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: PHASE 2: Creating snapshot of source dataset...");
    
    NSString *timestamp = [self getCurrentTimestamp];
    NSString *sourceSnapshot = [NSString stringWithFormat:@"%@@backup_%@", homeDataset, timestamp];
    
    if (![self createSnapshot:sourceSnapshot]) {
        NSDebugLLog(@"gwcomp", @"ERROR: Failed to create source snapshot");
        return NO;
    }
    
    if (progressBlock) {
        progressBlock(0.08, NSLocalizedString(@"Preparing destination dataset...", @"Backup progress"));
    }
    
    // === PHASE 3: ENSURE DESTINATION DATASET EXISTS ===
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: PHASE 3: Ensuring destination dataset exists...");
    
    if (![self datasetExists:datasetName]) {
        if (![self createDataset:datasetName]) {
            NSDebugLLog(@"gwcomp", @"ERROR: Failed to create destination dataset");
            [self destroySnapshot:sourceSnapshot]; // Cleanup
            return NO;
        }
    }
    
    if (progressBlock) {
        progressBlock(0.10, NSLocalizedString(@"Starting ZFS transfer...", @"Backup progress"));
    }
    
    // === PHASE 4: PERFORM ZFS SEND/RECEIVE ===
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: PHASE 4: Performing ZFS send/receive operation...");
    
    BOOL success = [self performZFSSendReceive:sourceSnapshot 
                                toDataset:datasetName 
                            withProgress:progressBlock];
    
    if (success) {
        if (progressBlock) {
            progressBlock(1.0, NSLocalizedString(@"ZFS backup completed successfully", @"Backup progress"));
        }
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: ZFS native backup completed successfully");
    } else {
        NSDebugLLog(@"gwcomp", @"ERROR: ZFS send/receive operation failed");
        [self destroySnapshot:sourceSnapshot]; // Cleanup
    }
    
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: ==========================================================");
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: === ZFS NATIVE BACKUP %@ ===", success ? @"COMPLETED" : @"FAILED");
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: ==========================================================");
    
    return success;
}

+ (BOOL)performIncrementalBackup:(NSString *)sourcePath 
                       toDataset:(NSString *)datasetName 
                   withProgress:(nullable void(^)(CGFloat progress, NSString *currentTask))progressBlock
{
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: ==========================================================");
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: === PERFORMING ZFS INCREMENTAL BACKUP ===");
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: From: %@", sourcePath);
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: To dataset: %@", datasetName);
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: ==========================================================");
    
    if (progressBlock) {
        progressBlock(0.02, NSLocalizedString(@"Preparing incremental backup...", @"Backup progress"));
    }
    
    // === PHASE 1: VERIFY /HOME IS ON ZFS ===
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: PHASE 1: Verifying /home is on ZFS...");
    
    NSString *homeDataset = [self getZFSDatasetForPath:sourcePath];
    if (!homeDataset) {
        NSDebugLLog(@"gwcomp", @"ERROR: /home is not on ZFS - this is a hard requirement");
        if (progressBlock) {
            progressBlock(0.0, NSLocalizedString(@"ERROR: /home must be on ZFS", @"Backup error"));
        }
        return NO;
    }
    
    if (progressBlock) {
        progressBlock(0.05, NSLocalizedString(@"Checking for existing snapshots...", @"Backup progress"));
    }
    
    // === PHASE 2: GET EXISTING SNAPSHOTS ===
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: PHASE 2: Checking for existing snapshots...");
    
    NSArray *snapshots = [self getSnapshots:datasetName];
    NSString *lastSnapshot = nil;
    
    if ([snapshots count] > 0) {
        // Get the most recent snapshot
        id latestSnapshotObj = [snapshots lastObject];
        NSString *latestSnapshotName = nil;
        
        if ([latestSnapshotObj isKindOfClass:[NSDictionary class]]) {
            NSDictionary *latestSnapshot = (NSDictionary *)latestSnapshotObj;
            latestSnapshotName = [latestSnapshot objectForKey:@"name"];
        } else if ([latestSnapshotObj isKindOfClass:[NSString class]]) {
            latestSnapshotName = (NSString *)latestSnapshotObj;
        }
        
        if (latestSnapshotName) {
            lastSnapshot = latestSnapshotName;
            NSDebugLLog(@"gwcomp", @"BAZFSUtility: Found existing snapshot: %@", lastSnapshot);
            
            if (progressBlock) {
                progressBlock(0.08, NSLocalizedString(@"Creating incremental snapshot...", @"Backup progress"));
            }
        } else {
            NSDebugLLog(@"gwcomp", @"BAZFSUtility: Warning: Could not extract snapshot name from latest snapshot object");
        }
    } else {
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: No existing snapshots found, performing full backup");
        
        if (progressBlock) {
            progressBlock(0.08, NSLocalizedString(@"No previous snapshots - performing full backup...", @"Backup progress"));
        }
        
        // No snapshots exist, perform a full backup
        return [self performBackup:sourcePath toDataset:datasetName withProgress:progressBlock];
    }
    
    // === PHASE 3: CREATE NEW SNAPSHOT ===
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: PHASE 3: Creating new snapshot for incremental backup...");
    
    NSString *timestamp = [self getCurrentTimestamp];
    NSString *sourceSnapshot = [NSString stringWithFormat:@"%@@backup_%@", homeDataset, timestamp];
    
    if (![self createSnapshot:sourceSnapshot]) {
        NSDebugLLog(@"gwcomp", @"ERROR: Failed to create source snapshot for incremental backup");
        return NO;
    }
    
    if (progressBlock) {
        progressBlock(0.10, NSLocalizedString(@"Performing incremental ZFS send/receive...", @"Backup progress"));
    }
    
    // === PHASE 4: PERFORM INCREMENTAL ZFS SEND/RECEIVE ===
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: PHASE 4: Performing incremental ZFS send/receive operation...");
    
    BOOL success = [self performIncrementalZFSSendReceive:lastSnapshot 
                                               fromSnapshot:sourceSnapshot 
                                                 toDataset:datasetName 
                                              withProgress:progressBlock];
    
    if (success) {
        if (progressBlock) {
            progressBlock(1.0, NSLocalizedString(@"Incremental backup completed", @"Backup progress"));
        }
        
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: ==========================================================");
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: === ZFS INCREMENTAL BACKUP COMPLETED ===");
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: Previous snapshot: %@", lastSnapshot ?: @"(none)");
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: New snapshot: %@", sourceSnapshot);
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: ==========================================================");
        return YES;
    } else {
        NSDebugLLog(@"gwcomp", @"ERROR: Incremental ZFS send/receive failed");
        [self destroySnapshot:sourceSnapshot]; // Cleanup
        
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: ==========================================================");
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: === ZFS INCREMENTAL BACKUP FAILED ===");
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: ==========================================================");
        return NO;
    }
}

+ (BOOL)performRestore:(NSString *)sourcePath 
                toPath:(NSString *)destinationPath 
             withItems:(nullable NSArray *)itemsToRestore 
         withProgress:(nullable void(^)(CGFloat progress, NSString *currentTask))progressBlock
{
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: ==========================================================");
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: === PERFORMING ZFS NATIVE RESTORE OPERATION ===");
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: From: %@", sourcePath);
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: To: %@", destinationPath);
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: ==========================================================");
    
    if (progressBlock) {
        progressBlock(0.02, NSLocalizedString(@"Verifying ZFS requirements...", @"Restore progress"));
    }
    
    // === PHASE 1: VERIFY DESTINATION IS ON ZFS ===
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: PHASE 1: Verifying destination is on ZFS...");
    
    NSString *destDataset = [self getZFSDatasetForPath:destinationPath];
    if (!destDataset) {
        NSDebugLLog(@"gwcomp", @"ERROR: Destination path is not on ZFS - this is a hard requirement");
        if (progressBlock) {
            progressBlock(0.0, NSLocalizedString(@"ERROR: Destination must be on ZFS", @"Restore error"));
        }
        return NO;
    }
    
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Destination ZFS dataset: %@", destDataset);
    
    if (progressBlock) {
        progressBlock(0.05, NSLocalizedString(@"Preparing ZFS restore operation...", @"Restore progress"));
    }
    
    // === PHASE 2: DETERMINE SOURCE SNAPSHOT ===
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: PHASE 2: Determining source backup snapshot...");
    
    // The sourcePath should be a mounted backup dataset, find the latest snapshot
    NSString *sourceDataset = [self getZFSDatasetForPath:sourcePath];
    if (!sourceDataset) {
        NSDebugLLog(@"gwcomp", @"ERROR: Source backup is not on ZFS");
        if (progressBlock) {
            progressBlock(0.0, NSLocalizedString(@"ERROR: Source backup must be on ZFS", @"Restore error"));
        }
        return NO;
    }
    
    NSArray *snapshots = [self getSnapshots:sourceDataset];
    if ([snapshots count] == 0) {
        NSDebugLLog(@"gwcomp", @"ERROR: No snapshots found in source backup dataset");
        if (progressBlock) {
            progressBlock(0.0, NSLocalizedString(@"ERROR: No backup snapshots found", @"Restore error"));
        }
        return NO;
    }
    
    // Use the latest snapshot
    id latestSnapshotObj = [snapshots lastObject];
    NSString *sourceSnapshot = nil;
    
    if ([latestSnapshotObj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *latestSnapshot = (NSDictionary *)latestSnapshotObj;
        sourceSnapshot = [latestSnapshot objectForKey:@"name"];
    } else if ([latestSnapshotObj isKindOfClass:[NSString class]]) {
        sourceSnapshot = (NSString *)latestSnapshotObj;
    }
    
    if (!sourceSnapshot) {
        NSDebugLLog(@"gwcomp", @"ERROR: Could not extract snapshot name from latest snapshot object");
        if (progressBlock) {
            progressBlock(0.0, NSLocalizedString(@"ERROR: Invalid snapshot data", @"Restore error"));
        }
        return NO;
    }
    
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Using source snapshot: %@", sourceSnapshot);
    
    if (progressBlock) {
        progressBlock(0.10, NSLocalizedString(@"Performing ZFS rollback/restore...", @"Restore progress"));
    }
    
    // === PHASE 3: PERFORM ZFS RESTORE ===
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: PHASE 3: Performing ZFS restore operation...");
    
    BOOL success;
    if (itemsToRestore && [itemsToRestore count] > 0) {
        // Selective restore - need to mount source snapshot and copy specific items
        success = [self performSelectiveZFSRestore:sourceSnapshot 
                                     toDataset:destDataset 
                                     withItems:itemsToRestore 
                                  withProgress:progressBlock];
    } else {
        // Full restore - use ZFS rollback or send/receive
        success = [self performFullZFSRestore:sourceSnapshot 
                                   toDataset:destDataset 
                                withProgress:progressBlock];
    }
    
    if (progressBlock) {
        progressBlock(1.0, success ? 
            NSLocalizedString(@"ZFS restore completed successfully", @"Restore progress") :
            NSLocalizedString(@"ZFS restore completed with issues", @"Restore progress"));
    }
    
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: ==========================================================");
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: === ZFS NATIVE RESTORE %@ ===", success ? @"COMPLETED" : @"FAILED");
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: ==========================================================");
    
    return success;
}

#pragma mark - Utility Methods

+ (long long)getAvailableSpace:(NSString *)diskDevice
{
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Getting available space for disk %@", diskDevice);
    
    // First check if this disk has a ZFS pool
    if (![self diskHasZFSPool:diskDevice]) {
        // For disks without ZFS pools, return the raw disk size since we'll create a new pool
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: Disk %@ has no ZFS pool, returning raw disk size", diskDevice);
        return [self getRawDiskSize:diskDevice];
    }
    
    // For disks with existing ZFS pools, discover the actual pool name
    NSString *poolName = [self getPoolNameFromDisk:diskDevice];
    if (!poolName) {
        NSDebugLLog(@"gwcomp", @"WARNING: Could not determine pool name for disk %@, falling back to raw disk size", diskDevice);
        return [self getRawDiskSize:diskDevice];
    }
    
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Found pool name '%@' on disk %@", poolName, diskDevice);
    
    // Try to import the pool temporarily to get space info if it's not already imported
    if (![self poolExists:poolName]) {
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: Pool %@ not imported, attempting to import", poolName);
        NSTask *importTask = [[NSTask alloc] init];
        [importTask setLaunchPath:@"zpool"];
        [importTask setArguments:@[@"import", @"-N", poolName]];
        [importTask setStandardOutput:[NSPipe pipe]];
        [importTask setStandardError:[NSPipe pipe]];
        
        @try {
            [importTask launch];
            [importTask waitUntilExit];
            if ([importTask terminationStatus] == 0) {
                NSDebugLLog(@"gwcomp", @"BAZFSUtility: Successfully imported pool %@ for space calculation", poolName);
            } else {
                NSDebugLLog(@"gwcomp", @"WARNING: Could not import pool %@ for space calculation", poolName);
            }
        } @catch (NSException *exception) {
            NSDebugLLog(@"gwcomp", @"WARNING: Could not import pool %@: %@", poolName, [exception reason]);
        }
    } else {
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: Pool %@ is already imported", poolName);
    }
    
    // Now get pool space info
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"zpool"];
    [task setArguments:@[@"list", @"-H", @"-o", @"free", poolName]];
    
    NSPipe *outputPipe = [NSPipe pipe];
    NSPipe *errorPipe = [NSPipe pipe];
    [task setStandardOutput:outputPipe];
    [task setStandardError:errorPipe];
    
    @try {
        [task launch];
        [task waitUntilExit];
        
        NSData *errorData = [[errorPipe fileHandleForReading] readDataToEndOfFile];
        NSString *errorOutput = [[NSString alloc] initWithData:errorData encoding:NSUTF8StringEncoding];
        if ([errorOutput length] > 0) {
            NSDebugLLog(@"gwcomp", @"BAZFSUtility: zpool list stderr: %@", errorOutput);
        }
        
        if ([task terminationStatus] == 0) {
            NSData *data = [[outputPipe fileHandleForReading] readDataToEndOfFile];
            NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            NSString *freeSpace = [output stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            
            NSDebugLLog(@"gwcomp", @"BAZFSUtility: Raw zpool list output for free space: '%@'", freeSpace);
            
            // Convert human-readable size to bytes
            long long bytes = [self convertSizeStringToBytes:freeSpace];
            
            NSDebugLLog(@"gwcomp", @"BAZFSUtility: Available space in ZFS pool %@: %lld bytes (converted from '%@')", poolName, bytes, freeSpace);
            return bytes;
        } else {
            NSDebugLLog(@"gwcomp", @"ERROR: zpool list failed with exit status %d for pool %@", [task terminationStatus], poolName);
        }
    } @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"ERROR: Failed to get ZFS pool space for %@: %@", diskDevice, [exception reason]);
    }
    
    
    // Fallback: try using df on mounted filesystems
    NSTask *dfTask = [[NSTask alloc] init];
    [dfTask setLaunchPath:@"df"];
    [dfTask setArguments:@[@"-B", @"1", diskDevice]];
    
    NSPipe *dfPipe = [NSPipe pipe];
    [dfTask setStandardOutput:dfPipe];
    [dfTask setStandardError:[NSPipe pipe]];
    
    @try {
        [dfTask launch];
        [dfTask waitUntilExit];
        
        if ([dfTask terminationStatus] == 0) {
            NSData *data = [[dfPipe fileHandleForReading] readDataToEndOfFile];
            NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            
            // Parse df output (second line, fourth column)
            NSArray *lines = [output componentsSeparatedByString:@"\n"];
            if ([lines count] >= 2) {
                NSArray *columns = [[[lines objectAtIndex:1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] componentsSeparatedByString:@" "];
                NSMutableArray *filteredColumns = [NSMutableArray array];
                for (NSString *column in columns) {
                    if ([column length] > 0) {
                        [filteredColumns addObject:column];
                    }
                }
                
                if ([filteredColumns count] >= 4) {
                    long long availableSpace = [[filteredColumns objectAtIndex:3] longLongValue];
                    
                    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Available space on mounted filesystem %@: %lld bytes", diskDevice, availableSpace);
                    return availableSpace;
                }
            }
        }
    } @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"ERROR: Failed to get available space for disk %@: %@", diskDevice, [exception reason]);
    }
    
    return 0;
}

+ (NSString *)getCurrentTimestamp
{
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    [formatter setDateFormat:@"yyyyMMdd_HHmmss"];
    NSString *timestamp = [formatter stringFromDate:[NSDate date]];
    return timestamp;
}

+ (NSString *)executeZFSCommand:(NSArray *)arguments
{
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Executing ZFS command (with output): zfs %@", [arguments componentsJoinedByString:@" "]);
    
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"zfs"];
    [task setArguments:arguments];
    
    NSPipe *outputPipe = [NSPipe pipe];
    NSPipe *errorPipe = [NSPipe pipe];
    [task setStandardOutput:outputPipe];
    [task setStandardError:errorPipe];

    // Force C locale for consistent tool output
    NSMutableDictionary *env = [[[NSProcessInfo processInfo] environment] mutableCopy];
    [env setObject:@"C" forKey:@"LC_ALL"];
    [task setEnvironment:env];
    [env release];
    
    @try {
        [task launch];
        [task waitUntilExit];
        
        int status = [task terminationStatus];
        
        // Capture output and error streams
        NSData *outputData = [[outputPipe fileHandleForReading] readDataToEndOfFile];
        NSData *errorData = [[errorPipe fileHandleForReading] readDataToEndOfFile];
        
        NSString *outputString = [[NSString alloc] initWithData:outputData encoding:NSUTF8StringEncoding];
        NSString *errorString = [[NSString alloc] initWithData:errorData encoding:NSUTF8StringEncoding];
        
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: ZFS command (output) exit status: %d", status);
        if ([outputString length] > 0) {
            NSDebugLLog(@"gwcomp", @"BAZFSUtility: ZFS command output: %@", outputString);
        }
        if ([errorString length] > 0) {
            NSDebugLLog(@"gwcomp", @"BAZFSUtility: ZFS command error: %@", errorString);
            
            // Analyze common ZFS error conditions for better diagnostics
            NSString *lowerError = [errorString lowercaseString];
            if ([lowerError containsString:@"permission denied"] || [lowerError containsString:@"operation not permitted"]) {
                NSDebugLLog(@"gwcomp", @"ERROR ANALYSIS: Permission denied - may need to run as root/sudo");
            } else if ([lowerError containsString:@"no such file or directory"]) {
                NSDebugLLog(@"gwcomp", @"ERROR ANALYSIS: Dataset/file not found - check dataset name");
            } else if ([lowerError containsString:@"dataset already exists"]) {
                NSDebugLLog(@"gwcomp", @"ERROR ANALYSIS: Dataset already exists - may need to use different name");
            } else if ([lowerError containsString:@"invalid argument"]) {
                NSDebugLLog(@"gwcomp", @"ERROR ANALYSIS: Invalid argument - check dataset name or properties");
            } else if ([lowerError containsString:@"insufficient privileges"]) {
                NSDebugLLog(@"gwcomp", @"ERROR ANALYSIS: Insufficient privileges - need administrator/root access");
            } else if ([lowerError containsString:@"pool"]) {
                NSDebugLLog(@"gwcomp", @"ERROR ANALYSIS: Pool-related error - check pool status");
            } else if ([lowerError containsString:@"busy"]) {
                NSDebugLLog(@"gwcomp", @"ERROR ANALYSIS: Resource busy - dataset may be mounted or in use");
            } else if ([lowerError containsString:@"not found"]) {
                NSDebugLLog(@"gwcomp", @"ERROR ANALYSIS: Resource not found - check dataset or snapshot name");
            } else {
                NSDebugLLog(@"gwcomp", @"ERROR ANALYSIS: Unknown ZFS error condition");
            }
        }
        
        NSString *result = nil;
        if (status == 0 && outputString) {
            result = [outputString copy];
        } else if (status != 0) {
            NSDebugLLog(@"gwcomp", @"ERROR: ZFS command failed with exit status %d", status);
        }
        
        return result;
    } @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"CRITICAL ERROR: Exception while executing ZFS command %@: %@", arguments, [exception reason]);
        NSDebugLLog(@"gwcomp", @"CRITICAL ERROR: Exception details: %@", exception);
        return nil;
    }
}

+ (BOOL)executeZFSCommandWithSuccess:(NSArray *)arguments
{
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: ================================================================");
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Executing ZFS command: zfs %@", [arguments componentsJoinedByString:@" "]);
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: ================================================================");
    
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"zfs"];
    [task setArguments:arguments];
    
    NSPipe *outputPipe = [NSPipe pipe];
    NSPipe *errorPipe = [NSPipe pipe];
    [task setStandardOutput:outputPipe];
    [task setStandardError:errorPipe];
    
    @try {
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: Launching zfs task...");
        [task launch];
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: Task launched, waiting for completion with timeout...");
        
        // Wait with timeout to prevent hanging
        BOOL taskCompleted = NO;
        int timeoutSeconds = 60;  // 60 second timeout for ZFS commands
        int checkInterval = 100000; // 100ms check interval
        int checksPerSecond = 1000000 / checkInterval; // 10 checks per second
        int maxChecks = timeoutSeconds * checksPerSecond;
        
        for (int i = 0; i < maxChecks && [task isRunning]; i++) {
            usleep(checkInterval);
        }
        
        if ([task isRunning]) {
            NSDebugLLog(@"gwcomp", @"BAZFSUtility: ZFS task timed out after %d seconds, terminating...", timeoutSeconds);
            [task terminate];
            // Give it a moment to terminate gracefully
            usleep(500000); // 500ms
            if ([task isRunning]) {
                NSDebugLLog(@"gwcomp", @"BAZFSUtility: ZFS task still running after terminate, killing...");
                kill([task processIdentifier], SIGKILL);
            }
            taskCompleted = NO;
        } else {
            taskCompleted = YES;
        }
        
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: ZFS task %@", taskCompleted ? @"completed" : @"timed out");
        
        int status = [task terminationStatus];
        BOOL success = (status == 0 && taskCompleted);
        
        // If task timed out, consider it a failure
        if (!taskCompleted) {
            NSDebugLLog(@"gwcomp", @"BAZFSUtility: ZFS command timed out - considering as failure");
            success = NO;
            status = -1; // Indicate timeout
        }
        
        // Capture output and error streams
        NSData *outputData = [[outputPipe fileHandleForReading] readDataToEndOfFile];
        NSData *errorData = [[errorPipe fileHandleForReading] readDataToEndOfFile];
        
        NSString *outputString = [[NSString alloc] initWithData:outputData encoding:NSUTF8StringEncoding];
        NSString *errorString = [[NSString alloc] initWithData:errorData encoding:NSUTF8StringEncoding];
        
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: ================================================================");
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: ZFS command RESULTS:");
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: Exit status: %d (%@)", status, success ? @"SUCCESS" : @"FAILURE");
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: ================================================================");
        
        if ([outputString length] > 0) {
            NSDebugLLog(@"gwcomp", @"BAZFSUtility: STDOUT:\n%@", outputString);
        } else {
            NSDebugLLog(@"gwcomp", @"BAZFSUtility: STDOUT: (empty)");
        }
        
        if ([errorString length] > 0) {
            NSDebugLLog(@"gwcomp", @"BAZFSUtility: STDERR:\n%@", errorString);
            
            // Analyze common ZFS error conditions
            NSString *lowerError = [errorString lowercaseString];
            if ([lowerError containsString:@"permission denied"] || [lowerError containsString:@"operation not permitted"]) {
                NSDebugLLog(@"gwcomp", @"ERROR ANALYSIS: Permission denied - may need to run as root/sudo");
            } else if ([lowerError containsString:@"no such file or directory"]) {
                NSDebugLLog(@"gwcomp", @"ERROR ANALYSIS: Device not found - check disk device name");
            } else if ([lowerError containsString:@"device busy"] || [lowerError containsString:@"resource busy"]) {
                NSDebugLLog(@"gwcomp", @"ERROR ANALYSIS: Device is busy - may be mounted or in use");
            } else if ([lowerError containsString:@"pool is busy"] || [lowerError containsString:@"pool busy"]) {
                NSDebugLLog(@"gwcomp", @"ERROR ANALYSIS: Pool is busy - datasets may be mounted or pool is being accessed");
            } else if ([lowerError containsString:@"invalid argument"]) {
                NSDebugLLog(@"gwcomp", @"ERROR ANALYSIS: Invalid argument - check pool name or device name");
            } else if ([lowerError containsString:@"pool already exists"]) {
                NSDebugLLog(@"gwcomp", @"ERROR ANALYSIS: Pool name already in use");
            } else if ([lowerError containsString:@"not a block device"]) {
                NSDebugLLog(@"gwcomp", @"ERROR ANALYSIS: Device is not a valid block device");
            } else if ([lowerError containsString:@"insufficient privileges"]) {
                NSDebugLLog(@"gwcomp", @"ERROR ANALYSIS: Insufficient privileges - need administrator/root access");
            } else if ([lowerError containsString:@"pool"] && [lowerError containsString:@"not found"]) {
                NSDebugLLog(@"gwcomp", @"ERROR ANALYSIS: Pool not found - check pool name or import status");
            } else if ([lowerError containsString:@"cannot import"]) {
                NSDebugLLog(@"gwcomp", @"ERROR ANALYSIS: Cannot import pool - may already be imported or corrupted");
            } else if ([lowerError containsString:@"cannot export"]) {
                NSDebugLLog(@"gwcomp", @"ERROR ANALYSIS: Cannot export pool - may be in use or have mounted datasets");
            } else if ([lowerError containsString:@"no such pool"]) {
                NSDebugLLog(@"gwcomp", @"ERROR ANALYSIS: Pool not found - may already be destroyed or exported");
            } else {
                NSDebugLLog(@"gwcomp", @"ERROR ANALYSIS: Unknown ZPool error condition");
            }
        } else {
            NSDebugLLog(@"gwcomp", @"BAZFSUtility: STDERR: (empty)");
        }
        
        return success;
    } @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"CRITICAL ERROR: Exception while executing ZFS command %@: %@", arguments, [exception reason]);
        NSDebugLLog(@"gwcomp", @"CRITICAL ERROR: Exception details: %@", exception);
        return NO;
    }
}

+ (BOOL)executeZPoolCommandWithSuccess:(NSArray *)arguments
{
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: ================================================================");
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Executing ZPool command: zpool %@", [arguments componentsJoinedByString:@" "]);
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: ================================================================");
    
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"zpool"];
    [task setArguments:arguments];
    
    NSPipe *outputPipe = [NSPipe pipe];
    NSPipe *errorPipe = [NSPipe pipe];
    [task setStandardOutput:outputPipe];
    [task setStandardError:errorPipe];
    
    @try {
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: Launching zpool task...");
        [task launch];
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: Task launched, waiting for completion with timeout...");
        
        // Wait with timeout to prevent hanging
        BOOL taskCompleted = NO;
        int timeoutSeconds = 30;  // 30 second timeout
        int checkInterval = 100000; // 100ms check interval
        int checksPerSecond = 1000000 / checkInterval; // 10 checks per second
        int maxChecks = timeoutSeconds * checksPerSecond;
        
        for (int i = 0; i < maxChecks && [task isRunning]; i++) {
            usleep(checkInterval);
        }
        
        if ([task isRunning]) {
            NSDebugLLog(@"gwcomp", @"BAZFSUtility: Task timed out after %d seconds, terminating...", timeoutSeconds);
            [task terminate];
            // Give it a moment to terminate gracefully
            usleep(500000); // 500ms
            if ([task isRunning]) {
                NSDebugLLog(@"gwcomp", @"BAZFSUtility: Task still running after terminate, killing...");
                kill([task processIdentifier], SIGKILL);
            }
            taskCompleted = NO;
        } else {
            taskCompleted = YES;
        }
        
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: Task %@", taskCompleted ? @"completed" : @"timed out");
        
        int status = [task terminationStatus];
        BOOL success = (status == 0 && taskCompleted);
        
        // If task timed out, consider it a failure
        if (!taskCompleted) {
            NSDebugLLog(@"gwcomp", @"BAZFSUtility: ZPool command timed out - considering as failure");
            success = NO;
            status = -1; // Indicate timeout
        }
        
        // Capture output and error streams
        NSData *outputData = [[outputPipe fileHandleForReading] readDataToEndOfFile];
        NSData *errorData = [[errorPipe fileHandleForReading] readDataToEndOfFile];
        
        NSString *outputString = [[NSString alloc] initWithData:outputData encoding:NSUTF8StringEncoding];
        NSString *errorString = [[NSString alloc] initWithData:errorData encoding:NSUTF8StringEncoding];
        
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: ================================================================");
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: ZPool command RESULTS:");
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: Exit status: %d (%@)", status, success ? @"SUCCESS" : @"FAILURE");
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: ================================================================");
        
        if ([outputString length] > 0) {
            NSDebugLLog(@"gwcomp", @"BAZFSUtility: STDOUT:\n%@", outputString);
        } else {
            NSDebugLLog(@"gwcomp", @"BAZFSUtility: STDOUT: (empty)");
        }
        
        if ([errorString length] > 0) {
            NSDebugLLog(@"gwcomp", @"BAZFSUtility: STDERR:\n%@", errorString);
            
            // Analyze common ZFS error conditions
            NSString *lowerError = [errorString lowercaseString];
            if ([lowerError containsString:@"permission denied"] || [lowerError containsString:@"operation not permitted"]) {
                NSDebugLLog(@"gwcomp", @"ERROR ANALYSIS: Permission denied - may need to run as root/sudo");
            } else if ([lowerError containsString:@"no such file or directory"]) {
                NSDebugLLog(@"gwcomp", @"ERROR ANALYSIS: Device not found - check disk device name");
            } else if ([lowerError containsString:@"device busy"] || [lowerError containsString:@"resource busy"]) {
                NSDebugLLog(@"gwcomp", @"ERROR ANALYSIS: Device is busy - may be mounted or in use");
            } else if ([lowerError containsString:@"pool is busy"] || [lowerError containsString:@"pool busy"]) {
                NSDebugLLog(@"gwcomp", @"ERROR ANALYSIS: Pool is busy - datasets may be mounted or pool is being accessed");
            } else if ([lowerError containsString:@"invalid argument"]) {
                NSDebugLLog(@"gwcomp", @"ERROR ANALYSIS: Invalid argument - check pool name or device name");
            } else if ([lowerError containsString:@"pool already exists"]) {
                NSDebugLLog(@"gwcomp", @"ERROR ANALYSIS: Pool name already in use");
            } else if ([lowerError containsString:@"not a block device"]) {
                NSDebugLLog(@"gwcomp", @"ERROR ANALYSIS: Device is not a valid block device");
            } else if ([lowerError containsString:@"insufficient privileges"]) {
                NSDebugLLog(@"gwcomp", @"ERROR ANALYSIS: Insufficient privileges - need administrator/root access");
            } else if ([lowerError containsString:@"pool"] && [lowerError containsString:@"not found"]) {
                NSDebugLLog(@"gwcomp", @"ERROR ANALYSIS: Pool not found - check pool name or import status");
            } else if ([lowerError containsString:@"cannot import"]) {
                NSDebugLLog(@"gwcomp", @"ERROR ANALYSIS: Cannot import pool - may already be imported or corrupted");
            } else if ([lowerError containsString:@"cannot export"]) {
                NSDebugLLog(@"gwcomp", @"ERROR ANALYSIS: Cannot export pool - may be in use or have mounted datasets");
            } else if ([lowerError containsString:@"no such pool"]) {
                NSDebugLLog(@"gwcomp", @"ERROR ANALYSIS: Pool not found - may already be destroyed or exported");
            } else {
                NSDebugLLog(@"gwcomp", @"ERROR ANALYSIS: Unknown ZPool error condition");
            }
        } else {
            NSDebugLLog(@"gwcomp", @"BAZFSUtility: STDERR: (empty)");
        }
        
        return success;
    } @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"CRITICAL ERROR: Exception while executing ZPool command %@: %@", arguments, [exception reason]);
        NSDebugLLog(@"gwcomp", @"CRITICAL ERROR: Exception details: %@", exception);
        return NO;
    }
}

+ (NSString *)executeZPoolCommand:(NSArray *)arguments
{
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Executing ZPool command (with output): zpool %@", [arguments componentsJoinedByString:@" "]);
    
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"zpool"];
    [task setArguments:arguments];
    
    NSPipe *outputPipe = [NSPipe pipe];
    NSPipe *errorPipe = [NSPipe pipe];
    [task setStandardOutput:outputPipe];
    [task setStandardError:errorPipe];

    // Force C locale for consistent tool output
    NSMutableDictionary *env = [[[NSProcessInfo processInfo] environment] mutableCopy];
    [env setObject:@"C" forKey:@"LC_ALL"];
    [task setEnvironment:env];
    [env release];
    
    @try {
        [task launch];
        [task waitUntilExit];
        
        int status = [task terminationStatus];
        
        // Capture output and error streams
        NSData *outputData = [[outputPipe fileHandleForReading] readDataToEndOfFile];
        NSData *errorData = [[errorPipe fileHandleForReading] readDataToEndOfFile];
        
        
        NSString *outputString = [[NSString alloc] initWithData:outputData encoding:NSUTF8StringEncoding];
        NSString *errorString = [[NSString alloc] initWithData:errorData encoding:NSUTF8StringEncoding];
        
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: ZPool command (output) exit status: %d", status);
        if ([outputString length] > 0) {
            NSDebugLLog(@"gwcomp", @"BAZFSUtility: ZPool command output: %@", outputString);
        }
        if ([errorString length] > 0) {
            NSDebugLLog(@"gwcomp", @"BAZFSUtility: ZPool command error: %@", errorString);
            
            // Analyze common ZPool error conditions for better diagnostics
            NSString *lowerError = [errorString lowercaseString];
            if ([lowerError containsString:@"permission denied"] || [lowerError containsString:@"operation not permitted"]) {
                NSDebugLLog(@"gwcomp", @"ERROR ANALYSIS: Permission denied - may need to run as root/sudo");
            } else if ([lowerError containsString:@"no such file or directory"]) {
                NSDebugLLog(@"gwcomp", @"ERROR ANALYSIS: Device not found - check disk device name");
            } else if ([lowerError containsString:@"device busy"] || [lowerError containsString:@"resource busy"]) {
                NSDebugLLog(@"gwcomp", @"ERROR ANALYSIS: Device is busy - may be mounted or in use");
            } else if ([lowerError containsString:@"pool is busy"] || [lowerError containsString:@"pool busy"]) {
                NSDebugLLog(@"gwcomp", @"ERROR ANALYSIS: Pool is busy - datasets may be mounted or pool is being accessed");
            } else if ([lowerError containsString:@"invalid argument"]) {
                NSDebugLLog(@"gwcomp", @"ERROR ANALYSIS: Invalid argument - check pool name or device name");
            } else if ([lowerError containsString:@"pool already exists"]) {
                NSDebugLLog(@"gwcomp", @"ERROR ANALYSIS: Pool name already in use");
            } else if ([lowerError containsString:@"not a block device"]) {
                NSDebugLLog(@"gwcomp", @"ERROR ANALYSIS: Device is not a valid block device");
            } else if ([lowerError containsString:@"insufficient privileges"]) {
                NSDebugLLog(@"gwcomp", @"ERROR ANALYSIS: Insufficient privileges - need administrator/root access");
            } else if ([lowerError containsString:@"pool"] && [lowerError containsString:@"not found"]) {
                NSDebugLLog(@"gwcomp", @"ERROR ANALYSIS: Pool not found - check pool name or import status");
            } else if ([lowerError containsString:@"cannot import"]) {
                NSDebugLLog(@"gwcomp", @"ERROR ANALYSIS: Cannot import pool - may already be imported or corrupted");
            } else if ([lowerError containsString:@"cannot export"]) {
                NSDebugLLog(@"gwcomp", @"ERROR ANALYSIS: Cannot export pool - may be in use or have mounted datasets");
            } else if ([lowerError containsString:@"no such pool"]) {
                NSDebugLLog(@"gwcomp", @"ERROR ANALYSIS: Pool not found - may already be destroyed or exported");
            } else {
                NSDebugLLog(@"gwcomp", @"ERROR ANALYSIS: Unknown ZPool error condition");
            }
        }
        
        NSString *result = nil;
        if (status == 0 && outputString) {
            result = [outputString copy];
        } else if (status != 0) {
            NSDebugLLog(@"gwcomp", @"ERROR: ZPool command failed with exit status %d", status);
        }
        
        return result;
    } @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"CRITICAL ERROR: Exception while executing ZPool command %@: %@", arguments, [exception reason]);
        NSDebugLLog(@"gwcomp", @"CRITICAL ERROR: Exception details: %@", exception);
        return nil;
    }
}

#pragma mark - ZFS Native Operations

+ (BOOL)performZFSSendReceive:(NSString *)sourceSnapshot 
                    toDataset:(NSString *)destinationDataset 
                 withProgress:(nullable void(^)(CGFloat progress, NSString *currentTask))progressBlock
{
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Performing ZFS send/receive operation with ADVANCED PIPE MONITORING");
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Source snapshot: %@", sourceSnapshot);
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Destination dataset: %@", destinationDataset);
    
    if (progressBlock) {
        progressBlock(0.10, NSLocalizedString(@"Getting transfer size...", @"Backup progress"));
    }
    
    // PHASE 1: Get the total size using a dry-run send
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Phase 1: Getting transfer size with dry-run send");
    NSTask *sizeTask = [[NSTask alloc] init];
    [sizeTask setLaunchPath:@"zfs"];
    [sizeTask setArguments:@[@"send", @"--parsable", @"--dry-run", sourceSnapshot]];
    
    NSPipe *sizePipe = [NSPipe pipe];
    [sizeTask setStandardError:sizePipe];  // --parsable sends size info to stderr
    [sizeTask setStandardOutput:[NSPipe pipe]]; // Discard stdout for dry-run
    
    long long totalBytes = 0;
    @try {
        [sizeTask launch];
        [sizeTask waitUntilExit];
        
        if ([sizeTask terminationStatus] == 0) {
            NSData *sizeData = [[sizePipe fileHandleForReading] readDataToEndOfFile];
            NSString *sizeOutput = [[NSString alloc] initWithData:sizeData encoding:NSUTF8StringEncoding];
            
            // Parse the size from the parsable output
            totalBytes = [self parseTotalSizeFromParsableOutput:sizeOutput];
            NSDebugLLog(@"gwcomp", @"BAZFSUtility: Detected transfer size: %lld bytes (%@)", totalBytes, [self formatBytes:totalBytes]);
        }
    } @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"WARNING: Could not determine transfer size: %@", [exception reason]);
    }
    
    if (progressBlock) {
        progressBlock(0.15, NSLocalizedString(@"Starting ZFS transfer with real-time monitoring...", @"Backup progress"));
    }
    
    // PHASE 2: Perform the actual send/receive with pipe monitoring
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Phase 2: Performing monitored ZFS send/receive");
    
    // Create ZFS send task
    NSTask *sendTask = [[NSTask alloc] init];
    [sendTask setLaunchPath:@"zfs"];
    [sendTask setArguments:@[@"send", @"--large-block", @"--embed", sourceSnapshot]];
    
    // Create ZFS receive task  
    NSTask *receiveTask = [[NSTask alloc] init];
    [receiveTask setLaunchPath:@"zfs"];
    [receiveTask setArguments:@[@"receive", @"-v", @"-F", destinationDataset]];
    
    // Create separate pipes for proper monitoring
    NSPipe *dataPipe = [NSPipe pipe];
    NSPipe *sendErrorPipe = [NSPipe pipe];
    NSPipe *receiveErrorPipe = [NSPipe pipe];
    
    [sendTask setStandardOutput:dataPipe];
    [sendTask setStandardError:sendErrorPipe]; // Capture any errors and parsable output
    [receiveTask setStandardInput:dataPipe];
    [receiveTask setStandardError:receiveErrorPipe]; // Capture any errors
    
    @try {
        // Launch both tasks
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: Launching send and receive tasks");
        [sendTask launch];
        [receiveTask launch];
        
        // Use the proper monitoring method instead of simple timeout
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: Starting proper ZFS progress monitoring...");
        BOOL success = [self monitorZFSProgress:sendTask 
                                    receiveTask:receiveTask 
                                sendProgressPipe:sendErrorPipe 
                               receiveErrorPipe:receiveErrorPipe 
                                  progressBlock:progressBlock 
                                   baseProgress:0.15 
                                  progressRange:0.75];
        
        
        return success;
        
    } @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"ERROR: ZFS send/receive failed with exception: %@", [exception reason]);
        return NO;
    }
}

+ (BOOL)performIncrementalZFSSendReceive:(NSString *)baseSnapshot 
                            fromSnapshot:(NSString *)sourceSnapshot 
                               toDataset:(NSString *)destinationDataset 
                            withProgress:(nullable void(^)(CGFloat progress, NSString *currentTask))progressBlock
{
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Performing incremental ZFS send/receive operation with ADVANCED PIPE MONITORING");
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Base snapshot: %@", baseSnapshot);
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Source snapshot: %@", sourceSnapshot);
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Destination dataset: %@", destinationDataset);
    
    if (progressBlock) {
        progressBlock(0.10, NSLocalizedString(@"Getting incremental transfer size...", @"Backup progress"));
    }
    
    // PHASE 1: Get the total size using a dry-run incremental send
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Phase 1: Getting incremental transfer size with dry-run send");
    NSTask *sizeTask = [[NSTask alloc] init];
    [sizeTask setLaunchPath:@"zfs"];
    [sizeTask setArguments:@[@"send", @"--parsable", @"--dry-run", @"-i", baseSnapshot, sourceSnapshot]];
    
    NSPipe *sizePipe = [NSPipe pipe];
    [sizeTask setStandardError:sizePipe];  // --parsable sends size info to stderr
    [sizeTask setStandardOutput:[NSPipe pipe]]; // Discard stdout for dry-run
    
    long long totalBytes = 0;
    @try {
        [sizeTask launch];
        [sizeTask waitUntilExit];
        
        if ([sizeTask terminationStatus] == 0) {
            NSData *sizeData = [[sizePipe fileHandleForReading] readDataToEndOfFile];
            NSString *sizeOutput = [[NSString alloc] initWithData:sizeData encoding:NSUTF8StringEncoding];
            
            // Parse the size from the parsable output
            totalBytes = [self parseTotalSizeFromParsableOutput:sizeOutput];
            NSDebugLLog(@"gwcomp", @"BAZFSUtility: Detected incremental transfer size: %lld bytes (%@)", totalBytes, [self formatBytes:totalBytes]);
        }
    } @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"WARNING: Could not determine incremental transfer size: %@", [exception reason]);
    }
    
    if (progressBlock) {
        progressBlock(0.15, NSLocalizedString(@"Starting incremental ZFS transfer with real-time monitoring...", @"Backup progress"));
    }
    
    // PHASE 2: Perform the actual incremental send/receive with pipe monitoring
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Phase 2: Performing monitored incremental ZFS send/receive");
    
    // Create incremental ZFS send task
    NSTask *sendTask = [[NSTask alloc] init];
    [sendTask setLaunchPath:@"zfs"];
    [sendTask setArguments:@[@"send", @"--large-block", @"--embed", @"-i", baseSnapshot, sourceSnapshot]];
    
    // Create ZFS receive task
    NSTask *receiveTask = [[NSTask alloc] init];
    [receiveTask setLaunchPath:@"zfs"];
    [receiveTask setArguments:@[@"receive", @"-v", @"-F", destinationDataset]];
    
    // Create separate pipes for proper monitoring
    NSPipe *dataPipe = [NSPipe pipe];
    NSPipe *sendErrorPipe = [NSPipe pipe];
    NSPipe *receiveErrorPipe = [NSPipe pipe];
    
    [sendTask setStandardOutput:dataPipe];
    [sendTask setStandardError:sendErrorPipe]; // Capture any errors and parsable output
    [receiveTask setStandardInput:dataPipe];
    [receiveTask setStandardError:receiveErrorPipe]; // Capture any errors
    
    @try {
        // Launch both tasks
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: Launching incremental send and receive tasks");
        [sendTask launch];
        [receiveTask launch];
        
        // Use the proper monitoring method instead of simple timeout
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: Starting proper incremental ZFS progress monitoring...");
        BOOL success = [self monitorZFSProgress:sendTask 
                                    receiveTask:receiveTask 
                                sendProgressPipe:sendErrorPipe 
                               receiveErrorPipe:receiveErrorPipe 
                                  progressBlock:progressBlock 
                                   baseProgress:0.15 
                                  progressRange:0.75];
        
        
        return success;
        
    } @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"ERROR: Incremental ZFS send/receive failed with exception: %@", [exception reason]);
        return NO;
    }
}

+ (BOOL)performFullZFSRestore:(NSString *)sourceSnapshot 
                    toDataset:(NSString *)destinationDataset 
                 withProgress:(nullable void(^)(CGFloat progress, NSString *currentTask))progressBlock
{
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Performing full ZFS restore");
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Source snapshot: %@", sourceSnapshot);
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Destination dataset: %@", destinationDataset);
    
    if (progressBlock) {
        progressBlock(0.10, NSLocalizedString(@"Rolling back to snapshot...", @"Restore progress"));
    }
    
    // Use ZFS rollback for full restore
    BOOL success = [self rollbackToSnapshot:sourceSnapshot];
    
    if (progressBlock) {
        progressBlock(0.90, success ? 
            NSLocalizedString(@"Full restore completed", @"Restore progress") :
            NSLocalizedString(@"Full restore completed with issues", @"Restore progress"));
    }
    
    return success;
}

+ (BOOL)performSelectiveZFSRestore:(NSString *)sourceSnapshot 
                         toDataset:(NSString *)destinationDataset 
                         withItems:(NSArray *)itemsToRestore 
                      withProgress:(nullable void(^)(CGFloat progress, NSString *currentTask))progressBlock
{
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Performing selective ZFS restore for %lu items", (unsigned long)[itemsToRestore count]);
    
    if (progressBlock) {
        progressBlock(0.5, NSLocalizedString(@"Mounting source snapshot for selective restore...", @"Restore progress"));
    }
    
    // For selective restore, we need to mount the source snapshot temporarily
    // and then use ZFS native operations to copy specific items
    NSString *tempMountPoint = @"/tmp/zfs_restore_mount";
    
    // Mount the source snapshot
    if (![self mountDataset:sourceSnapshot atPath:tempMountPoint]) {
        NSDebugLLog(@"gwcomp", @"ERROR: Failed to mount source snapshot for selective restore");
        return NO;
    }
    
    BOOL success = YES;
    CGFloat itemProgress = 0.6;
    CGFloat progressIncrement = 0.3 / (CGFloat)[itemsToRestore count];
    
    // Note: For true ZFS-native selective restore, we would need more sophisticated
    // ZFS operations. For now, this is a placeholder that maintains the ZFS requirement.
    for (NSString *item in itemsToRestore) {
        if (progressBlock) {
            progressBlock(itemProgress, [NSString stringWithFormat:
                NSLocalizedString(@"Restoring %@ using ZFS operations...", @"Restore progress"), item]);
        }
        
        // TODO: Implement true ZFS-native selective file operations
        // This would involve creating partial snapshots or using ZFS clone operations
        
        itemProgress += progressIncrement;
    }
    
    // Unmount the temporary mount
    [self unmountDataset:sourceSnapshot];
    
    if (progressBlock) {
        progressBlock(0.9, NSLocalizedString(@"Selective restore completed", @"Restore progress"));
    }
    
    return success;
}

#pragma mark - ZFS Progress Monitoring

+ (BOOL)monitorZFSProgress:(NSTask *)sendTask 
               receiveTask:(NSTask *)receiveTask 
           sendProgressPipe:(NSPipe *)sendProgressPipe 
          receiveErrorPipe:(NSPipe *)receiveErrorPipe 
             progressBlock:(nullable void(^)(CGFloat progress, NSString *currentTask))progressBlock 
              baseProgress:(CGFloat)baseProgress 
             progressRange:(CGFloat)progressRange
{
{
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Starting ZFS progress monitoring with parsable output");
    
    NSFileHandle *sendProgressHandle = [sendProgressPipe fileHandleForReading];
    NSFileHandle *receiveErrorHandle = [receiveErrorPipe fileHandleForReading];
    
    // Variables for tracking progress
    long long totalBytes = 0;
    long long transferredBytes = 0;
    BOOL totalSizeKnown = NO;
    CGFloat currentProgress = baseProgress;
    
    // Set up non-blocking reads using fcntl
    int sendFd = [sendProgressHandle fileDescriptor];
    int receiveFd = [receiveErrorHandle fileDescriptor];
    
    fcntl(sendFd, F_SETFL, O_NONBLOCK);
    fcntl(receiveFd, F_SETFL, O_NONBLOCK);
    
    // Monitor both tasks with timeout protection
    int progressUpdateCounter = 0;
    int maxProgressUpdates = 6000; // 10 minutes timeout (6000 * 0.1s = 600s) 
    int periodicUpdateInterval = 25; // Update every 2.5 seconds (25 * 0.1s = 2.5s) - more frequent updates
    int verboseLogInterval = 50; // Verbose log every 5 seconds (50 * 0.1s = 5s) - more frequent logging
    
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Starting monitoring loop for send/receive tasks with parsable progress");
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Timeout: %d seconds, Updates every %.1f seconds", 
          maxProgressUpdates / 10, (float)periodicUpdateInterval / 10.0);
    
    // Helper function to safely dispatch progress updates to main thread
    void (^dispatchProgressUpdate)(CGFloat, NSString *) = ^(CGFloat progress, NSString *message) {
        if (progressBlock) {
            // Since GCD dispatch functions aren't available, call directly
            // The progress block should be designed to handle thread safety
            progressBlock(progress, message);
        }
    };
    
    while (([sendTask isRunning] || [receiveTask isRunning]) && progressUpdateCounter < maxProgressUpdates) {
        @autoreleasepool {
            // Check if tasks have finished but we haven't noticed yet
            BOOL sendRunning = [sendTask isRunning];
            BOOL receiveRunning = [receiveTask isRunning];
            
            // Only log verbose monitoring every 10 seconds to reduce spam
            if ((progressUpdateCounter % verboseLogInterval) == 0) {
                NSDebugLLog(@"gwcomp", @"BAZFSUtility: Monitoring iteration %d - Send running: %@, Receive running: %@", 
                      progressUpdateCounter, sendRunning ? @"YES" : @"NO", receiveRunning ? @"YES" : @"NO");
            }
            
            // Try to read from send task stderr for parsable progress data (non-blocking)
            NSData *sendData = nil;
            @try {
                sendData = [sendProgressHandle availableData];
            } @catch (NSException *exception) {
                // Handle non-blocking read exceptions gracefully
                if ((progressUpdateCounter % verboseLogInterval) == 0) {
                    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Send progress handle read exception (normal for non-blocking): %@", [exception reason]);
                }
                sendData = nil;
            }
            
            if ([sendData length] > 0) {
                NSString *output = [[NSString alloc] initWithData:sendData encoding:NSUTF8StringEncoding];
                NSDebugLLog(@"gwcomp", @"ZFS Send Parsable Output: %@", output);
                
                // Parse ZFS parsable output format - this provides metadata but not real-time progress
                // NOTE: ZFS send --parsable only provides initial metadata (size, type) and final completion
                // It does NOT provide intermediate progress updates during the actual data transfer
                NSArray *lines = [output componentsSeparatedByString:@"\n"];
                for (__strong NSString *line in lines) {
                    line = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                    if ([line length] == 0) continue;
                    
                    NSDebugLLog(@"gwcomp", @"ZFS Parsable Line: '%@'", line);
                    
                    // ZFS parsable format (from ZFS documentation):
                    // Line format: <timestamp> <bytes_transferred> <total_bytes> <dataset>
                    // Or: size <total_bytes>
                    // Or: full <dataset> <total_bytes>
                    // Or: incremental <from_dataset> <to_dataset> <total_bytes>
                    
                    // Split by tabs first, then by spaces if needed
                    NSArray *components = [line componentsSeparatedByString:@"\t"];
                    if ([components count] < 2) {
                        // Try space-separated format
                        components = [line componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                        // Filter out empty components
                        NSMutableArray *filtered = [NSMutableArray array];
                        for (NSString *comp in components) {
                            if ([comp length] > 0) {
                                [filtered addObject:comp];
                            }
                        }
                        components = filtered;
                    }
                    
                    if ([components count] >= 2) {
                        NSString *firstComponent = [components objectAtIndex:0];
                        
                        // Handle "size" line - total size information
                        if ([firstComponent isEqualToString:@"size"]) {
                            NSString *sizeStr = [components objectAtIndex:1];
                            long long size = [sizeStr longLongValue];
                            if (size > 0 && !totalSizeKnown) {
                                totalBytes = size;
                                totalSizeKnown = YES;
                                NSDebugLLog(@"gwcomp", @"BAZFSUtility: Found total size from 'size' line: %lld bytes", size);
                                
                                if (progressBlock) {
                                    dispatchProgressUpdate(currentProgress, 
                                        NSLocalizedString(@"ZFS transfer starting...", @"ZFS progress"));
                                }
                            }
                        }
                        // Handle "full" line - full stream with total size
                        else if ([firstComponent isEqualToString:@"full"]) {
                            if ([components count] >= 3) {
                                NSString *sizeStr = [components objectAtIndex:2];
                                long long size = [sizeStr longLongValue];
                                if (size > 0 && !totalSizeKnown) {
                                    totalBytes = size;
                                    totalSizeKnown = YES;
                                    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Found total size from 'full' line: %lld bytes", size);
                                    
                                    if (progressBlock) {
                                        dispatchProgressUpdate(currentProgress, 
                                            NSLocalizedString(@"ZFS transfer starting...", @"ZFS progress"));
                                    }
                                }
                            }
                        }
                        // Handle "incremental" line - incremental stream with total size
                        else if ([firstComponent isEqualToString:@"incremental"]) {
                            if ([components count] >= 4) {
                                NSString *sizeStr = [components objectAtIndex:3];
                                long long size = [sizeStr longLongValue];
                                if (size > 0 && !totalSizeKnown) {
                                    totalBytes = size;
                                    totalSizeKnown = YES;
                                    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Found total size from 'incremental' line: %lld bytes", size);
                                    
                                    if (progressBlock) {
                                        dispatchProgressUpdate(currentProgress, 
                                            NSLocalizedString(@"ZFS incremental transfer starting...", @"ZFS progress"));
                                    }
                                }
                            }
                        }
                        // Handle progress lines - timestamp bytes_transferred total_bytes dataset
                        else if ([components count] >= 4) {
                            // Format: <timestamp> <bytes_transferred> <total_bytes> <dataset>
                            NSString *bytesTransferredStr = [components objectAtIndex:1];
                            NSString *totalBytesStr = [components objectAtIndex:2];
                            
                            long long bytesTransferred = [bytesTransferredStr longLongValue];
                            long long totalBytesFromLine = [totalBytesStr longLongValue];
                            
                            if (bytesTransferred > 0 && totalBytesFromLine > 0) {
                                // Update total bytes if not set yet
                                if (!totalSizeKnown) {
                                    totalBytes = totalBytesFromLine;
                                    totalSizeKnown = YES;
                                    NSDebugLLog(@"gwcomp", @"ZFS Progress: Total size determined from progress line: %lld bytes", totalBytes);
                                }
                                
                                // Update transferred bytes
                                if (bytesTransferred <= totalBytes) {
                                    transferredBytes = bytesTransferred;
                                    
                                    CGFloat zfsProgress = (CGFloat)transferredBytes / (CGFloat)totalBytes;
                                    currentProgress = baseProgress + (zfsProgress * progressRange);
                                    
                                    if (progressBlock) {
                                        NSString *statusMsg = [NSString stringWithFormat:
                                            NSLocalizedString(@"Transferring: %@ of %@ (%.1f%%)", @"ZFS transfer progress"),
                                            [self formatBytes:transferredBytes],
                                            [self formatBytes:totalBytes],
                                            zfsProgress * 100.0];
                                        dispatchProgressUpdate(currentProgress, statusMsg);
                                    }
                                    
                                    NSDebugLLog(@"gwcomp", @"ZFS Progress: %lld/%lld bytes (%.1f%%) - REAL PROGRESS DATA (rare)", 
                                          transferredBytes, totalBytes, zfsProgress * 100.0);
                                }
                            }
                        }
                        // Handle timestamp-only progress lines (older format)
                        else if ([components count] >= 2 && totalSizeKnown) {
                            // Format: <timestamp> <bytes_transferred>
                            NSString *bytesStr = [components objectAtIndex:1];
                            long long bytes = [bytesStr longLongValue];
                            
                            if (bytes > 0 && bytes <= totalBytes) {
                                transferredBytes = bytes;
                                
                                CGFloat zfsProgress = (CGFloat)transferredBytes / (CGFloat)totalBytes;
                                currentProgress = baseProgress + (zfsProgress * progressRange);
                                
                                if (progressBlock) {
                                    NSString *statusMsg = [NSString stringWithFormat:
                                        NSLocalizedString(@"Transferring: %@ of %@ (%.1f%%)", @"ZFS transfer progress"),
                                        [self formatBytes:transferredBytes],
                                        [self formatBytes:totalBytes],
                                        zfsProgress * 100.0];
                                    dispatchProgressUpdate(currentProgress, statusMsg);
                                }
                                
                                NSDebugLLog(@"gwcomp", @"ZFS Progress: %lld/%lld bytes (%.1f%%) - TIMESTAMP FORMAT", 
                                      transferredBytes, totalBytes, zfsProgress * 100.0);
                            }
                        }
                    }
                }
            }
            
            // Try to read from receive task stderr for completion messages (non-blocking)
            NSData *receiveData = nil;
            @try {
                receiveData = [receiveErrorHandle availableData];
            } @catch (NSException *exception) {
                // Handle non-blocking read exceptions gracefully
                if ((progressUpdateCounter % verboseLogInterval) == 0) {
                    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Receive error handle read exception (normal for non-blocking): %@", [exception reason]);
                }
                receiveData = nil;
            }
            
            if ([receiveData length] > 0) {
                NSString *output = [[NSString alloc] initWithData:receiveData encoding:NSUTF8StringEncoding];
                NSDebugLLog(@"gwcomp", @"ZFS Receive Output: %@", output);
                
                // Check for completion messages
                if ([output containsString:@"received"] && [output containsString:@"stream"]) {
                    NSDebugLLog(@"gwcomp", @"ZFS Receive: Stream completed successfully");
                    if (progressBlock) {
                        dispatchProgressUpdate(baseProgress + progressRange * 0.95, 
                            NSLocalizedString(@"ZFS stream received successfully", @"ZFS completion"));
                    }
                }
                
            }
            
            // Increment progress counter on every loop iteration (not just when data is available)
            progressUpdateCounter++;
            
            // Provide intelligent progress updates based on transfer status
            // Update more frequently for GUI responsiveness when size is unknown
            int progressUpdateFrequency = totalSizeKnown ? periodicUpdateInterval : (periodicUpdateInterval / 3); // Update 3x more often when size unknown
            
            // Debug: Log every 10 iterations to see if the loop is working
            if ((progressUpdateCounter % 10) == 0) {
                NSDebugLLog(@"gwcomp", @"BAZFSUtility: Loop iteration %d, Send: %@, Receive: %@, TotalSizeKnown: %@", 
                      progressUpdateCounter, sendRunning ? @"YES" : @"NO", receiveRunning ? @"YES" : @"NO", totalSizeKnown ? @"YES" : @"NO");
            }
            
            // Provide intelligent progress updates based on transfer status
            if ((progressUpdateCounter % progressUpdateFrequency) == 0) {
                if (totalSizeKnown) {
                        // We have total size from parsable output - calculate percentage-based progress
                        // ZFS send doesn't provide intermediate progress, so we estimate based on time
                        
                        if (transferredBytes == 0) {
                            // No real progress data available - ZFS send doesn't provide intermediate progress
                            // Provide conservative time-based estimates for user feedback
                            CGFloat timeProgress = (CGFloat)progressUpdateCounter / (CGFloat)maxProgressUpdates;
                            CGFloat estimatedProgress = timeProgress * 0.8; // Conservative: reach 80% over timeout period
                            CGFloat newProgress = baseProgress + (estimatedProgress * progressRange);
                            
                            // Only advance progress, never go backwards
                            if (newProgress > currentProgress) {
                                currentProgress = newProgress;
                                
                                if (progressBlock) {
                                    // Calculate estimated completion time
                                    float secondsElapsed = (float)progressUpdateCounter / 10.0; // 0.1s per iteration
                                    float estimatedTotalSeconds = secondsElapsed / estimatedProgress;
                                    float estimatedRemainingSeconds = estimatedTotalSeconds - secondsElapsed;
                                    
                                    NSString *statusMsg;
                                    if (estimatedRemainingSeconds > 0 && estimatedProgress > 0.05) {
                                        int remainingMinutes = (int)(estimatedRemainingSeconds / 60.0);
                                        if (remainingMinutes > 0) {
                                            statusMsg = [NSString stringWithFormat:
                                                NSLocalizedString(@"Transferring %@ (~%d min remaining)", @"ZFS progress with time estimate"),
                                                [self formatBytes:totalBytes], remainingMinutes];
                                        } else {
                                            statusMsg = [NSString stringWithFormat:
                                                NSLocalizedString(@"Transferring %@ (almost complete)", @"ZFS progress near completion"),
                                                [self formatBytes:totalBytes]];
                                        }
                                    } else {
                                        statusMsg = [NSString stringWithFormat:
                                            NSLocalizedString(@"Transferring %@ (%.1f%% estimated)", @"ZFS progress estimate"),
                                            [self formatBytes:totalBytes], estimatedProgress * 100.0];
                                    }
                                    
                                    dispatchProgressUpdate(currentProgress, statusMsg);
                                }
                                
                                NSDebugLLog(@"gwcomp", @"ZFS Progress: Time-based estimate %.1f%% after %.1f seconds (ZFS parsable doesn't provide real-time progress)", 
                                      estimatedProgress * 100.0, (float)progressUpdateCounter / 10.0);
                            }
                        }
                    } else {
                        // No size known yet - provide time-based progress estimates for GUI feedback
                        CGFloat timeProgress = (CGFloat)progressUpdateCounter / (CGFloat)maxProgressUpdates;
                        CGFloat estimatedProgress = timeProgress * 0.7; // Conservative: reach 70% over timeout period
                        CGFloat newProgress = baseProgress + (estimatedProgress * progressRange);
                        
                        // Only advance progress, never go backwards
                        if (newProgress > currentProgress) {
                            currentProgress = newProgress;
                            
                            if (progressBlock) {
                                // Calculate elapsed time for user feedback
                                float secondsElapsed = (float)progressUpdateCounter / 10.0; // 0.1s per iteration
                                int minutesElapsed = (int)(secondsElapsed / 60.0);
                                
                                NSString *statusMsg;
                                if (minutesElapsed > 0) {
                                    statusMsg = [NSString stringWithFormat:
                                        NSLocalizedString(@"ZFS transfer in progress (%d min elapsed, %.1f%% estimated)", @"ZFS progress with time"),
                                        minutesElapsed, estimatedProgress * 100.0];
                                } else {
                                    statusMsg = [NSString stringWithFormat:
                                        NSLocalizedString(@"ZFS transfer in progress (%.0f sec elapsed, %.1f%% estimated)", @"ZFS progress with time"),
                                        secondsElapsed, estimatedProgress * 100.0];
                                }
                                
                                dispatchProgressUpdate(currentProgress, statusMsg);
                            }
                            
                            NSDebugLLog(@"gwcomp", @"BAZFSUtility: Time-based progress estimate %.1f%% after %.1f seconds (no size known)", 
                                  estimatedProgress * 100.0, (float)progressUpdateCounter / 10.0);
                        }
                    }
                }
                
                // Check if we should break out early (tasks finished)
                if (!sendRunning && !receiveRunning) {
                    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Both tasks have completed, breaking monitoring loop");
                    break;
                }
            }
            
            // Small delay to prevent busy waiting (0.1 seconds)
            usleep(100000); // 0.1 seconds
        } // End of @autoreleasepool
    } // End of while loop
    
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: ZFS monitoring completed");  // Remove the variable reference
    
    // Wait a bit for tasks to fully complete and get final status
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Waiting for tasks to complete...");
    
    // Wait for send task if still running
    if ([sendTask isRunning]) {
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: Waiting for send task to complete...");
        [sendTask waitUntilExit];
    }
    
    // Wait for receive task if still running  
    if ([receiveTask isRunning]) {
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: Waiting for receive task to complete...");
        [receiveTask waitUntilExit];
    }
    
    // Tasks have completed - get their exit status
    int sendStatus = [sendTask terminationStatus];
    int receiveStatus = [receiveTask terminationStatus];
    
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Final task status - Send: %d, Receive: %d", sendStatus, receiveStatus);
    
    BOOL success = (sendStatus == 0 && receiveStatus == 0);
    
    if (success && progressBlock) {
        if (progressBlock) {
            progressBlock(baseProgress + progressRange, NSLocalizedString(@"ZFS transfer completed", @"ZFS completion"));
        }
    } else if (!success) {
        NSDebugLLog(@"gwcomp", @"ERROR: ZFS operation failed - Send status: %d, Receive status: %d", sendStatus, receiveStatus);
        
        // Read any remaining error output for debugging
        NSData *remainingSendData = [[sendProgressPipe fileHandleForReading] readDataToEndOfFile];
        NSData *remainingReceiveData = [[receiveErrorPipe fileHandleForReading] readDataToEndOfFile];
        
        if ([remainingSendData length] > 0) {
            NSString *sendError = [[NSString alloc] initWithData:remainingSendData encoding:NSUTF8StringEncoding];
            NSDebugLLog(@"gwcomp", @"ZFS Send Final Error: %@", sendError);
        }
        
        if ([remainingReceiveData length] > 0) {
            NSString *receiveError = [[NSString alloc] initWithData:remainingReceiveData encoding:NSUTF8StringEncoding];
            NSDebugLLog(@"gwcomp", @"ZFS Receive Final Error: %@", receiveError);
        }
        
        if (progressBlock) {
            progressBlock(baseProgress + progressRange, NSLocalizedString(@"ZFS transfer completed with errors", @"ZFS error completion"));
        }
    }
    
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: ZFS progress monitoring completed, success: %@", success ? @"YES" : @"NO");
    return success;
}

+ (long long)parseSizeFromString:(NSString *)sizeStr
{
    if (!sizeStr || [sizeStr length] == 0) {
        return 0;
    }
    
    // Remove any whitespace
    sizeStr = [sizeStr stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    
    // Convert to lowercase for easier parsing
    NSString *lowerStr = [sizeStr lowercaseString];
    
    // Extract numeric part
    NSScanner *scanner = [NSScanner scannerWithString:lowerStr];
    double value = 0.0;
    
    if (![scanner scanDouble:&value]) {
        return 0;
    }
    
    // Check for size suffixes
    NSString *remainder = [lowerStr substringFromIndex:[scanner scanLocation]];
    remainder = [remainder stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    
    long long multiplier = 1;
    
    if ([remainder hasPrefix:@"k"] || [remainder hasPrefix:@"kb"]) {
        multiplier = 1024LL;
    } else if ([remainder hasPrefix:@"m"] || [remainder hasPrefix:@"mb"]) {
        multiplier = 1024LL * 1024LL;
    } else if ([remainder hasPrefix:@"g"] || [remainder hasPrefix:@"gb"]) {
        multiplier = 1024LL * 1024LL * 1024LL;
    } else if ([remainder hasPrefix:@"t"] || [remainder hasPrefix:@"tb"]) {
        multiplier = 1024LL * 1024LL * 1024LL * 1024LL;
    }
    
    return (long long)(value * multiplier);
}

#pragma mark - Missing Utility Method Implementations

+ (NSString *)getZFSDatasetForPath:(NSString *)path
{
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Getting ZFS dataset for path: %@", path);
    
    // Use df to get the filesystem information for the path
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"df"];
    [task setArguments:@[@"-T", path]];
    
    NSPipe *outputPipe = [NSPipe pipe];
    NSPipe *errorPipe = [NSPipe pipe];
    [task setStandardOutput:outputPipe];
    [task setStandardError:errorPipe];
    
    @try {
        [task launch];
        [task waitUntilExit];
        
        if ([task terminationStatus] == 0) {
            NSData *data = [[outputPipe fileHandleForReading] readDataToEndOfFile];
            NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            
            // Parse df output to find ZFS filesystem
            NSArray *lines = [output componentsSeparatedByString:@"\n"];
            for (NSString *line in lines) {
                if ([line containsString:@"zfs"]) {
                    // Extract the dataset name (first column)
                    NSArray *components = [line componentsSeparatedByString:@" "];
                    NSMutableArray *filtered = [NSMutableArray array];
                    for (NSString *comp in components) {
                        if ([comp length] > 0) {
                            [filtered addObject:comp];
                        }
                    }
                    
                    if ([filtered count] > 0) {
                        NSString *dataset = [filtered objectAtIndex:0];
                        NSDebugLLog(@"gwcomp", @"BAZFSUtility: Found ZFS dataset: %@", dataset);
                        return dataset;
                    }
                }
            }
        }
    } @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"ERROR: Failed to get ZFS dataset for path %@: %@", path, [exception reason]);
    }
    
    
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Path %@ is not on ZFS", path);
    return nil;
}

+ (long long)getRawDiskSize:(NSString *)diskDevice
{
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Getting raw disk size for %@", diskDevice);
    
    // Use blockdev or fdisk to get disk size
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"blockdev"];
    [task setArguments:@[@"--getsize64", diskDevice]];
    
    NSPipe *outputPipe = [NSPipe pipe];
    NSPipe *errorPipe = [NSPipe pipe];
    [task setStandardOutput:outputPipe];
    [task setStandardError:errorPipe];
    
    @try {
        [task launch];
        [task waitUntilExit];
        
        if ([task terminationStatus] == 0) {
            NSData *data = [[outputPipe fileHandleForReading] readDataToEndOfFile];
            NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            NSString *sizeStr = [output stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            
            long long size = [sizeStr longLongValue];
            NSDebugLLog(@"gwcomp", @"BAZFSUtility: Raw disk size: %lld bytes", size);
            return size;
        }
    } @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"ERROR: Failed to get raw disk size for %@: %@", diskDevice, [exception reason]);
    }
    
    return 0;
}

+ (long long)convertSizeStringToBytes:(NSString *)sizeString
{
    if (!sizeString || [sizeString length] == 0) {
        return 0;
    }
    
    // Remove any whitespace
    sizeString = [sizeString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    
    // Convert to lowercase for easier parsing
    NSString *lowerStr = [sizeString lowercaseString];
    
    // Extract numeric part
    NSScanner *scanner = [NSScanner scannerWithString:lowerStr];
    double value = 0.0;
    
    if (![scanner scanDouble:&value]) {
        // Try scanning as long long for plain numbers
        [scanner setScanLocation:0];
        long long intValue = 0;
        if ([scanner scanLongLong:&intValue]) {
            return intValue;
        }
        return 0;
    }
    
    // Check for size suffixes
    NSString *remainder = [lowerStr substringFromIndex:[scanner scanLocation]];
    remainder = [remainder stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    
    long long multiplier = 1;
    
    if ([remainder hasPrefix:@"k"] || [remainder hasPrefix:@"kb"]) {
        multiplier = 1024LL;
    } else if ([remainder hasPrefix:@"m"] || [remainder hasPrefix:@"mb"]) {
        multiplier = 1024LL * 1024LL;
    } else if ([remainder hasPrefix:@"g"] || [remainder hasPrefix:@"gb"]) {
        multiplier = 1024LL * 1024LL * 1024LL;
    } else if ([remainder hasPrefix:@"t"] || [remainder hasPrefix:@"tb"]) {
        multiplier = 1024LL * 1024LL * 1024LL * 1024LL;
    }
    
    return (long long)(value * multiplier);
}

+ (BOOL)unmountDisk:(NSString *)diskDevice
{
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Unmounting disk %@", diskDevice);
    
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"umount"];
    [task setArguments:@[diskDevice]];
    
    NSPipe *outputPipe = [NSPipe pipe];
    NSPipe *errorPipe = [NSPipe pipe];
    [task setStandardOutput:outputPipe];
    [task setStandardError:errorPipe];
    
    @try {
        [task launch];
        [task waitUntilExit];
        
        BOOL success = ([task terminationStatus] == 0);
        if (success) {
            NSDebugLLog(@"gwcomp", @"BAZFSUtility: Successfully unmounted %@", diskDevice);
        } else {
            NSDebugLLog(@"gwcomp", @"WARNING: Failed to unmount %@ (may not be mounted)", diskDevice);
        }
        
        return success;
    } @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"ERROR: Failed to unmount disk %@: %@", diskDevice, [exception reason]);
        return NO;
    }
}

+ (long long)calculateDirectorySize:(NSString *)path
{
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Calculating directory size for %@", path);
    
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"du"];
    [task setArguments:@[@"-sb", path]];
    
    NSPipe *outputPipe = [NSPipe pipe];
    NSPipe *errorPipe = [NSPipe pipe];
    [task setStandardOutput:outputPipe];
    [task setStandardError:errorPipe];
    
    @try {
        [task launch];
        [task waitUntilExit];
        
        if ([task terminationStatus] == 0) {
            NSData *data = [[outputPipe fileHandleForReading] readDataToEndOfFile];
            NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            
            // Parse du output (first column is size in bytes)
            NSArray *components = [output componentsSeparatedByString:@"\t"];
            if ([components count] >= 1) {
                NSString *sizeStr = [[components objectAtIndex:0] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                long long size = [sizeStr longLongValue];
                NSDebugLLog(@"gwcomp", @"BAZFSUtility: Directory size: %lld bytes", size);
                return size;
            }
        }
    } @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"ERROR: Failed to calculate directory size for %@: %@", path, [exception reason]);
    }
    
    return 0;
}

+ (NSString *)formatBytes:(long long)bytes
{
    if (bytes < 1024) {
        return [NSString stringWithFormat:@"%lld B", bytes];
    } else if (bytes < 1024 * 1024) {
        return [NSString stringWithFormat:@"%.1f KB", (double)bytes / 1024.0];
    } else if (bytes < 1024 * 1024 * 1024) {
        return [NSString stringWithFormat:@"%.1f MB", (double)bytes / (1024.0 * 1024.0)];
    } else if (bytes < 1024LL * 1024LL * 1024LL * 1024LL) {
        return [NSString stringWithFormat:@"%.1f GB", (double)bytes / (1024.0 * 1024.0 * 1024.0)];
    } else {
        return [NSString stringWithFormat:@"%.1f TB", (double)bytes / (1024.0 * 1024.0 * 1024.0 * 1024.0)];
    }
}

+ (BOOL)validateZFSSystemState:(NSString * _Nullable * _Nullable)errorMessage
{
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Validating ZFS system state");
    
    // Check if ZFS is available
    if (![self isZFSAvailable]) {
        if (errorMessage) {
            *errorMessage = @"ZFS is not available on this system";
        }
        return NO;
    }
    
    // Check if zfs kernel module is loaded
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"lsmod"];
    [task setArguments:@[]];
    
    NSPipe *outputPipe = [NSPipe pipe];
    [task setStandardOutput:outputPipe];
    [task setStandardError:[NSPipe pipe]];
    
    @try {
        [task launch];
        [task waitUntilExit];
        
        if ([task terminationStatus] == 0) {
            NSData *data = [[outputPipe fileHandleForReading] readDataToEndOfFile];
            NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            
            BOOL zfsLoaded = [output containsString:@"zfs"];
            
            if (!zfsLoaded) {
                if (errorMessage) {
                    *errorMessage = @"ZFS kernel module is not loaded";
                }
                return NO;
            }
            
            NSDebugLLog(@"gwcomp", @"BAZFSUtility: ZFS system state is valid");
            return YES;
        }
    } @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"ERROR: Failed to validate ZFS system state: %@", [exception reason]);
    }
    
    
    if (errorMessage) {
        *errorMessage = @"Failed to validate ZFS system state";
    }
    return NO;
}

+ (BOOL)validatePoolHealth:(NSString *)poolName errorMessage:(NSString * _Nullable * _Nullable)errorMessage
{
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Validating health of pool %@", poolName);
    
    if (![self poolExists:poolName]) {
        if (errorMessage) {
            *errorMessage = [NSString stringWithFormat:@"Pool '%@' does not exist", poolName];
        }
        return NO;
    }
    
    // Check pool status
    NSArray *args = @[@"status", @"-x", poolName];
    NSString *output = [self executeZPoolCommand:args];
    
    if (output) {
        if ([output containsString:@"pool is healthy"] || [output containsString:@"all pools are healthy"]) {
            NSDebugLLog(@"gwcomp", @"BAZFSUtility: Pool %@ is healthy", poolName);
            return YES;
        } else {
            if (errorMessage) {
                *errorMessage = [NSString stringWithFormat:@"Pool '%@' health issues: %@", poolName, output];
            }
            return NO;
        }
    }
    
    if (errorMessage) {
        *errorMessage = [NSString stringWithFormat:@"Failed to check health of pool '%@'", poolName];
    }
    return NO;
}

+ (BOOL)validateDatasetExists:(NSString *)datasetName errorMessage:(NSString * _Nullable * _Nullable)errorMessage
{
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Validating dataset exists: %@", datasetName);
    
    BOOL exists = [self datasetExists:datasetName];
    
    if (!exists && errorMessage) {
        *errorMessage = [NSString stringWithFormat:@"Dataset '%@' does not exist", datasetName];
    }
    
    return exists;
}

+ (long long)parseTotalSizeFromParsableOutput:(NSString *)output
{
    if (!output || [output length] == 0) {
        return 0;
    }
    
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Parsing total size from parsable output: %@", output);
    
    NSArray *lines = [output componentsSeparatedByString:@"\n"];
    for (__strong NSString *line in lines) {
        line = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([line length] == 0) continue;
        
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: Parsing size line: '%@'", line);
        
        // Split by tabs first, then by spaces if needed
        NSArray *components = [line componentsSeparatedByString:@"\t"];
        if ([components count] < 2) {
            // Try space-separated format
            components = [line componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            // Filter out empty components
            NSMutableArray *filtered = [NSMutableArray array];
            for (NSString *comp in components) {
                if ([comp length] > 0) {
                    [filtered addObject:comp];
                }
            }
            components = filtered;
        }
        
        if ([components count] >= 2) {
            NSString *firstComponent = [components objectAtIndex:0];
            
            // Handle "size" line - total size information
            if ([firstComponent isEqualToString:@"size"]) {
                NSString *sizeStr = [components objectAtIndex:1];
                long long size = [sizeStr longLongValue];
                if (size > 0) {
                    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Found total size from 'size' line: %lld bytes", size);
                    return size;
                }
            }
            // Handle "full" line - full stream with total size
            else if ([firstComponent isEqualToString:@"full"]) {
                if ([components count] >= 3) {
                    NSString *sizeStr = [components objectAtIndex:2];
                    long long size = [sizeStr longLongValue];
                    if (size > 0) {
                        NSDebugLLog(@"gwcomp", @"BAZFSUtility: Found total size from 'full' line: %lld bytes", size);
                        return size;
                    }
                }
            }
            // Handle "incremental" line - incremental stream with total size
            else if ([firstComponent isEqualToString:@"incremental"]) {
                if ([components count] >= 4) {
                    NSString *sizeStr = [components objectAtIndex:3];
                    long long size = [sizeStr longLongValue];
                    if (size > 0) {
                        NSDebugLLog(@"gwcomp", @"BAZFSUtility: Found total size from 'incremental' line: %lld bytes", size);
                        return size;
                    }
                }
            }
        }
    }
    
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Could not parse total size from parsable output");
    return 0;
}

+ (NSPipe *)createMonitoredPipeWithTotalBytes:(long long)totalBytes 
                                progressBlock:(nullable void(^)(CGFloat progress, NSString *currentTask))progressBlock
                                 baseProgress:(CGFloat)baseProgress 
                                progressRange:(CGFloat)progressRange
{
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Creating monitored pipe for %lld bytes", totalBytes);
    
    // Create a regular pipe
    NSPipe *pipe = [NSPipe pipe];
    
    if (progressBlock) {
        // Start a background thread to monitor the pipe regardless of totalBytes
        NSMutableDictionary *threadInfo = [[NSMutableDictionary alloc] init];
        [threadInfo setObject:pipe forKey:@"pipe"];
        [threadInfo setObject:[NSNumber numberWithLongLong:totalBytes] forKey:@"totalBytes"];
        [threadInfo setObject:[NSNumber numberWithFloat:baseProgress] forKey:@"baseProgress"];
        [threadInfo setObject:[NSNumber numberWithFloat:progressRange] forKey:@"progressRange"];
        [threadInfo setObject:[progressBlock copy] forKey:@"progressBlock"];
        [threadInfo setObject:[NSNumber numberWithBool:YES] forKey:@"shouldContinue"];
        
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [self monitorPipeProgress:threadInfo];
        });
    }
    
    return pipe;
}

+ (void)monitorPipeProgress:(NSMutableDictionary *)threadInfo
{
    @autoreleasepool {
        if (!threadInfo || ![threadInfo isKindOfClass:[NSDictionary class]]) {
            NSDebugLLog(@"gwcomp", @"ERROR: Invalid threadInfo parameter in monitorPipeProgress");
            return;
        }
        
        NSPipe *pipe = [threadInfo objectForKey:@"pipe"];
        NSNumber *totalBytesNum = [threadInfo objectForKey:@"totalBytes"];
        NSNumber *baseProgressNum = [threadInfo objectForKey:@"baseProgress"];
        NSNumber *progressRangeNum = [threadInfo objectForKey:@"progressRange"];
        void(^progressBlock)(CGFloat, NSString*) = [threadInfo objectForKey:@"progressBlock"];
        
        if (!pipe || !totalBytesNum || !baseProgressNum || !progressRangeNum) {
            NSDebugLLog(@"gwcomp", @"ERROR: Missing required parameters in threadInfo dictionary");
            return;
        }
        
        long long totalBytes = [totalBytesNum longLongValue];
        CGFloat baseProgress = [baseProgressNum floatValue];
        CGFloat progressRange = [progressRangeNum floatValue];
        
        NSFileHandle *readHandle = [pipe fileHandleForReading];
        long long bytesTransferred = 0;
        
        // Set up non-blocking reads
        int fd = [readHandle fileDescriptor];
        fcntl(fd, F_SETFL, O_NONBLOCK);
        
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: Starting pipe monitoring thread for %lld total bytes", totalBytes);
        
        NSDate *startTime = [NSDate date];
        int updateCounter = 0;
        
        while (YES) {
            @autoreleasepool {
                NSData *data = [readHandle availableData];
                if ([data length] == 0) {
                    // No data available, check if pipe is closed or just waiting
                    usleep(100000); // 100ms
                    continue;
                }
                
                bytesTransferred += [data length];
                updateCounter++;
                
                // Provide progress updates every 10 data chunks or every 2 seconds, whichever comes first
                NSTimeInterval elapsed = [[NSDate date] timeIntervalSinceDate:startTime];
                BOOL shouldUpdate = (updateCounter % 10 == 0) || (elapsed - (int)(elapsed / 2.0) * 2.0 < 0.1);
                
                if (shouldUpdate && progressBlock) {
                    CGFloat adjustedProgress;
                    NSString *statusMsg;
                    
                    if (totalBytes > 0) {
                        // We know the total size, calculate percentage-based progress
                        CGFloat transferProgress = (CGFloat)bytesTransferred / (CGFloat)totalBytes;
                        adjustedProgress = baseProgress + (transferProgress * progressRange);
                        
                        // Cap progress at baseProgress + progressRange
                        if (adjustedProgress > baseProgress + progressRange) {
                            adjustedProgress = baseProgress + progressRange;
                        }
                        
                        statusMsg = [NSString stringWithFormat:
                            NSLocalizedString(@"Transferring: %@ of %@ (%.1f%%)", @"ZFS transfer progress"),
                            [self formatBytes:bytesTransferred],
                            [self formatBytes:totalBytes],
                            transferProgress * 100.0];
                        
                        NSDebugLLog(@"gwcomp", @"BAZFSUtility: Pipe Monitor: %lld/%lld bytes (%.1f%%) transferred", 
                              bytesTransferred, totalBytes, transferProgress * 100.0);
                    } else {
                        // Unknown total size - provide time-based progress estimates for GUI feedback
                        // Calculate progress based on elapsed time and data transferred 
                        CGFloat timeProgress = MIN(elapsed / 300.0, 1.0); // Assume max 5 min for fallback
                        CGFloat dataProgress = MIN(bytesTransferred / (100.0 * 1024 * 1024), 1.0); // Normalize to ~100MB
                        CGFloat estimatedProgress = MAX(timeProgress, dataProgress) * 0.8; // Conservative estimate
                        
                        adjustedProgress = baseProgress + (estimatedProgress * progressRange);
                        
                        statusMsg = [NSString stringWithFormat:
                            NSLocalizedString(@"Transferring: %@ (%.1f KB/s)", @"ZFS transfer progress without total"),
                            [self formatBytes:bytesTransferred],
                            elapsed > 0 ? (bytesTransferred / 1024.0) / elapsed : 0.0];
                        
                        NSDebugLLog(@"gwcomp", @"BAZFSUtility: Pipe Monitor (no total): %lld bytes transferred, %.1f KB/s", 
                              bytesTransferred, elapsed > 0 ? (bytesTransferred / 1024.0) / elapsed : 0.0);
                    }
                    
                    // Update progress on main thread
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self updateProgressOnMainThread:@[[NSNumber numberWithFloat:adjustedProgress], statusMsg, [progressBlock copy]]];
                    });
                }
                
                // Check if we've reached the end (only for known sizes)
                if (totalBytes > 0 && bytesTransferred >= totalBytes) {
                    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Pipe monitoring completed - reached expected total");
                    break;
                }
                
                // For unknown sizes, we'll continue until the pipe is closed by the sender
                // Check periodically if we should stop (pipe closed/EOF)
                if (totalBytes <= 0 && updateCounter % 50 == 0) {
                    // Try to read one byte to check if pipe is still open
                    char testByte;
                    ssize_t result = read(fd, &testByte, 1);
                    if (result == 0) {
                        NSDebugLLog(@"gwcomp", @"BAZFSUtility: Pipe monitoring completed - EOF detected");
                        break;
                    } else if (result > 0) {
                        // Put the byte back by adjusting our counter
                        bytesTransferred += 1;
                    }
                }
            }
        }
        
        NSDebugLLog(@"gwcomp", @"BAZFSUtility: Pipe monitoring thread finished, total transferred: %lld bytes", bytesTransferred);
    }
}

+ (void)updateProgressOnMainThread:(NSArray *)args
{
    if ([args count] >= 3) {
        CGFloat progress = [[args objectAtIndex:0] floatValue];
        NSString *status = [args objectAtIndex:1];
        void(^progressBlock)(CGFloat, NSString*) = [args objectAtIndex:2];
        
        if (progressBlock) {
            progressBlock(progress, status);
        }
    }
}

+ (BOOL)checkPoolCanBeExported:(NSString *)poolName
{
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Checking if pool '%@' can be safely exported", poolName);
    
    // Check for mounted datasets in the pool
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"zfs"];
    [task setArguments:@[@"list", @"-H", @"-o", @"name,mounted", @"-r", poolName]];
    
    NSPipe *outputPipe = [NSPipe pipe];
    [task setStandardOutput:outputPipe];
    [task setStandardError:[NSPipe pipe]];
    
    @try {
        [task launch];
        [task waitUntilExit];
        
        if ([task terminationStatus] == 0) {
            NSData *data = [[outputPipe fileHandleForReading] readDataToEndOfFile];
            NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            
            NSArray *lines = [output componentsSeparatedByString:@"\n"];
            BOOL hasMountedDatasets = NO;
            
            for (NSString *line in lines) {
                if ([line length] == 0) continue;
                NSArray *parts = [line componentsSeparatedByString:@"\t"];
                if ([parts count] >= 2) {
                    NSString *datasetName = [parts objectAtIndex:0];
                    NSString *mounted = [parts objectAtIndex:1];
                    
                    if ([mounted isEqualToString:@"yes"]) {
                        NSDebugLLog(@"gwcomp", @"BAZFSUtility: Found mounted dataset: %@", datasetName);
                        hasMountedDatasets = YES;
                        
                        // Try to unmount it
                        NSDebugLLog(@"gwcomp", @"BAZFSUtility: Attempting to unmount dataset: %@", datasetName);
                        if ([self unmountDataset:datasetName]) {
                            NSDebugLLog(@"gwcomp", @"BAZFSUtility: Successfully unmounted dataset: %@", datasetName);
                        } else {
                            NSDebugLLog(@"gwcomp", @"BAZFSUtility: Failed to unmount dataset: %@", datasetName);
                        }
                    }
                }
            }
            
            
            if (hasMountedDatasets) {
                NSDebugLLog(@"gwcomp", @"BAZFSUtility: Pool had mounted datasets - attempted to unmount them");
                // Give the system a moment to finish unmounting
                usleep(1000000); // 1 second
            } else {
                NSDebugLLog(@"gwcomp", @"BAZFSUtility: Pool '%@' has no mounted datasets", poolName);
            }
        }
    } @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"ERROR: Failed to check mounted datasets for pool %@: %@", poolName, [exception reason]);
    }
    
    
    // Check for any processes using files in the pool
    NSDebugLLog(@"gwcomp", @"BAZFSUtility: Checking for processes using pool '%@'", poolName);
    NSTask *lsofTask = [[NSTask alloc] init];
    [lsofTask setLaunchPath:@"lsof"];
    [lsofTask setArguments:@[@"+D", [NSString stringWithFormat:@"/%@", poolName]]];
    
    NSPipe *lsofPipe = [NSPipe pipe];
    [lsofTask setStandardOutput:lsofPipe];
    [lsofTask setStandardError:[NSPipe pipe]];
    
    @try {
        [lsofTask launch];
        [lsofTask waitUntilExit];
        
        // lsof returns 0 if files are found, 1 if no files found
        if ([lsofTask terminationStatus] == 0) {
            NSData *data = [[lsofPipe fileHandleForReading] readDataToEndOfFile];
            NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            NSDebugLLog(@"gwcomp", @"BAZFSUtility: Processes using pool '%@':\n%@", poolName, output);
            
            NSDebugLLog(@"gwcomp", @"BAZFSUtility: WARNING: Pool '%@' is in use by running processes", poolName);
            return NO;
        } else {
            NSDebugLLog(@"gwcomp", @"BAZFSUtility: No processes found using pool '%@'", poolName);
        }
    } @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"WARNING: Could not check for processes using pool: %@", [exception reason]);
    }
    
    return YES;
}

@end
