//
// BAController.m
// Backup Assistant - Main Controller Implementation
//

#import "BAController.h"
#import "BAIntroStep.h"
#import "BADiskSelectionStep.h"
#import "BAOperationSelectionStep.h"
#import "BAConfigurationStep.h"
#import "BAProgressStep.h"
#import "BACompletionStep.h"
#import "BAZFSUtility.h"

@implementation BAController

@synthesize selectedDiskDevice = _selectedDiskDevice;
@synthesize homeDirectory = _homeDirectory;
@synthesize selectedOperation = _selectedOperation;
@synthesize diskAnalysisResult = _diskAnalysisResult;
@synthesize availableSnapshots = _availableSnapshots;
@synthesize selectedSnapshot = _selectedSnapshot;
@synthesize backupItems = _backupItems;
@synthesize restoreItems = _restoreItems;
@synthesize operationSuccessful = _operationSuccessful;
@synthesize zfsPoolName = _zfsPoolName;
@synthesize requiredSpace = _requiredSpace;
@synthesize availableSpace = _availableSpace;
@synthesize userConfirmedWipe = _userConfirmedWipe;

- (id)init
{
    self = [super init];
    if (self) {
        _homeDirectory = [@"/home" retain];  // Backup all user home directories
        _selectedOperation = BAOperationTypeNone;
        _diskAnalysisResult = BADiskAnalysisResultEmpty;
        _backupItems = [[NSMutableArray alloc] init];
        _restoreItems = [[NSMutableArray alloc] init];
        _operationSuccessful = NO;
        _zfsPoolName = [@"backup_pool" retain];
        _requiredSpace = 0;
        _availableSpace = 0;
        _userConfirmedWipe = NO;
        
        NSLog(@"BackupAssistant: Controller initialized for home directories: %@", _homeDirectory);
    }
    return self;
}

- (void)dealloc
{
    [_selectedDiskDevice release];
    [_homeDirectory release];
    [_availableSnapshots release];
    [_selectedSnapshot release];
    [_backupItems release];
    [_restoreItems release];
    [_zfsPoolName release];
    [_assistantWindow release];
    [super dealloc];
}

- (void)showAssistant
{
    NSLog(@"BackupAssistant: Creating assistant window");
    
    // Check ZFS availability first
    if (![self checkZFSAvailability]) {
        [self showOperationError:NSLocalizedString(@"ZFS is not available on this system. Please ensure ZFS support is properly installed.", @"ZFS not available error")];
        return;
    }
    
    // HARD REQUIREMENT: /home must be on ZFS
    if (![self checkHomeDirectoryOnZFS]) {
        [self showOperationError:NSLocalizedString(@"The /home directory must be on a ZFS filesystem to use this Backup Assistant. This tool only works with ZFS-native operations for maximum data integrity and efficiency.", @"ZFS required for /home error")];
        return;
    }
    
    // Create the steps
    NSMutableArray *steps = [NSMutableArray array];
    
    // Introduction step
    BAIntroStep *introStep = [[BAIntroStep alloc] init];
    [steps addObject:introStep];
    [introStep release];
    
    // Disk selection step
    BADiskSelectionStep *diskStep = [[BADiskSelectionStep alloc] initWithController:self];
    [steps addObject:diskStep];
    [diskStep release];
    
    // Operation selection step  
    BAOperationSelectionStep *operationStep = [[BAOperationSelectionStep alloc] initWithController:self];
    [steps addObject:operationStep];
    [operationStep release];
    
    // Configuration step
    BAConfigurationStep *configStep = [[BAConfigurationStep alloc] initWithController:self];
    [steps addObject:configStep];
    [configStep release];
    
    // Progress step
    BAProgressStep *progressStep = [[BAProgressStep alloc] initWithController:self];
    [steps addObject:progressStep];
    [progressStep release];
    
    // Completion step
    BACompletionStep *completionStep = [[BACompletionStep alloc] initWithController:self];
    [steps addObject:completionStep];
    [completionStep release];
    
    // Create the assistant window
    NSImage *icon = [NSImage imageNamed:@"backup_icon"];
    _assistantWindow = [[GSAssistantWindow alloc] initWithLayoutStyle:GSAssistantLayoutStyleInstaller
                                                                title:NSLocalizedString(@"Backup Assistant", @"Assistant window title")
                                                                 icon:icon
                                                                steps:steps];
    
    [_assistantWindow setDelegate:self];
    [_assistantWindow setShowsSidebar:YES];
    [_assistantWindow setShowsStepIndicators:YES];
    [_assistantWindow setAllowsCancel:YES];
    
    [_assistantWindow showWindow:nil];
    
    NSLog(@"BackupAssistant: Assistant window shown");
}

#pragma mark - GSAssistantWindowDelegate

- (void)assistantWindowWillClose:(GSAssistantWindow *)window
{
    NSLog(@"BackupAssistant: Assistant window will close");
    [self cleanupOnError];
}

- (void)assistantWindowDidCancel:(GSAssistantWindow *)window
{
    NSLog(@"BackupAssistant: Assistant cancelled by user");
    [self cleanupOnError];
    [NSApp terminate:nil];
}

- (void)assistantWindowDidFinish:(GSAssistantWindow *)window
{
    NSLog(@"BackupAssistant: Assistant completed successfully");
    NSLog(@"BackupAssistant: Window remains open for user to review results");
    // Don't terminate - let user close the window manually
}

#pragma mark - Disk and ZFS Operations

- (BADiskAnalysisResult)analyzeDisk:(NSString *)diskDevice
{
    NSLog(@"BackupAssistant: Analyzing disk %@", diskDevice);
    
    if (!diskDevice || [diskDevice length] == 0) {
        return BADiskAnalysisResultEmpty;
    }
    
    // Check if disk has existing ZFS pool
    if ([BAZFSUtility diskHasZFSPool:diskDevice]) {
        NSLog(@"BackupAssistant: Disk has existing ZFS pool");
        
        // First check if the pool is already imported and available
        BOOL poolAlreadyExists = [BAZFSUtility poolExists:_zfsPoolName];
        NSLog(@"BackupAssistant: Pool '%@' already exists/imported: %@", _zfsPoolName, poolAlreadyExists ? @"YES" : @"NO");
        
        if (poolAlreadyExists) {
            // Pool is already available, check if it has backup datasets
            NSArray *datasets = [BAZFSUtility getDatasets:_zfsPoolName];
            if (datasets && [datasets count] > 0) {
                NSLog(@"BackupAssistant: Valid backup found on existing pool");
                return BADiskAnalysisResultHasBackup;
            } else {
                NSLog(@"BackupAssistant: Pool exists but no backup datasets found");
                return BADiskAnalysisResultIncompatible;
            }
        } else {
            // Pool is not imported, try to import it
            NSLog(@"BackupAssistant: Attempting to import pool '%@'", _zfsPoolName);
            if ([BAZFSUtility importPoolFromDisk:diskDevice poolName:_zfsPoolName]) {
                NSArray *datasets = [BAZFSUtility getDatasets:_zfsPoolName];
                if (datasets && [datasets count] > 0) {
                    NSLog(@"BackupAssistant: Valid backup found after import");
                    return BADiskAnalysisResultHasBackup;
                } else {
                    NSLog(@"BackupAssistant: ZFS pool imported but no backup datasets found");
                    return BADiskAnalysisResultIncompatible;
                }
            } else {
                NSLog(@"BackupAssistant: ZFS pool corrupted or incompatible");
                return BADiskAnalysisResultCorrupted;
            }
        }
    }
    
    NSLog(@"BackupAssistant: Disk appears to be empty or non-ZFS");
    return BADiskAnalysisResultEmpty;
}

- (BOOL)createZFSPool:(NSString *)diskDevice
{
    NSLog(@"BackupAssistant: Creating ZFS pool on %@", diskDevice);
    
    if (![BAZFSUtility createPool:_zfsPoolName onDisk:diskDevice]) {
        NSLog(@"ERROR: Failed to create ZFS pool on %@", diskDevice);
        return NO;
    }
    
    // Create backup dataset
    NSString *datasetName = [NSString stringWithFormat:@"%@/home_backup", _zfsPoolName];
    if (![BAZFSUtility createDataset:datasetName]) {
        NSLog(@"ERROR: Failed to create backup dataset %@", datasetName);
        [BAZFSUtility destroyPool:_zfsPoolName];
        return NO;
    }
    
    NSLog(@"BackupAssistant: Successfully created ZFS pool and backup dataset");
    return YES;
}

- (BOOL)importZFSPool:(NSString *)diskDevice
{
    NSLog(@"BackupAssistant: Importing ZFS pool from %@", diskDevice);
    return [BAZFSUtility importPoolFromDisk:diskDevice poolName:_zfsPoolName];
}

- (BOOL)destroyExistingZFSPool:(NSString *)diskDevice
{
    NSLog(@"BackupAssistant: Destroying existing ZFS pool on %@", diskDevice);
    
    // First, try to get the pool name from the disk
    NSString *poolName = [BAZFSUtility getPoolNameFromDisk:diskDevice];
    if (!poolName) {
        NSLog(@"WARNING: Could not determine pool name from disk %@, using default name", diskDevice);
        poolName = _zfsPoolName;
    }
    
    NSLog(@"BackupAssistant: Attempting to destroy pool '%@'", poolName);
    
    // First try to export the pool (graceful)
    if ([BAZFSUtility poolExists:poolName]) {
        NSLog(@"BackupAssistant: Pool '%@' exists, attempting graceful export first", poolName);
        if ([BAZFSUtility exportPool:poolName]) {
            NSLog(@"BackupAssistant: Successfully exported pool '%@'", poolName);
        } else {
            NSLog(@"WARNING: Failed to export pool '%@', will try to destroy directly", poolName);
        }
    }
    
    // Now destroy the pool
    BOOL success = [BAZFSUtility destroyPool:poolName];
    if (success) {
        NSLog(@"BackupAssistant: Successfully destroyed pool '%@'", poolName);
    } else {
        NSLog(@"ERROR: Failed to destroy pool '%@'", poolName);
    }
    
    return success;
}

- (NSArray *)getZFSSnapshots
{
    NSString *datasetName = [NSString stringWithFormat:@"%@/home_backup", _zfsPoolName];
    return [BAZFSUtility getSnapshots:datasetName];
}

- (long long)calculateBackupSize
{
    NSLog(@"BackupAssistant: Calculating backup size for %@", _homeDirectory);
    
    // Use du command to calculate directory size
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"du"];
    [task setArguments:@[@"-s", @"-B", @"1", _homeDirectory]];
    
    NSPipe *pipe = [NSPipe pipe];
    [task setStandardOutput:pipe];
    [task setStandardError:[NSPipe pipe]];
    
    @try {
        [task launch];
        [task waitUntilExit];
        
        if ([task terminationStatus] == 0) {
            NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
            NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            
            // Parse the size from du output
            NSArray *components = [output componentsSeparatedByString:@"\t"];
            if ([components count] > 0) {
                long long size = [[components objectAtIndex:0] longLongValue];
                [output release];
                [task release];
                
                NSLog(@"BackupAssistant: Calculated backup size: %lld bytes", size);
                return size;
            }
            [output release];
        }
    } @catch (NSException *exception) {
        NSLog(@"ERROR: Failed to calculate backup size: %@", [exception reason]);
    }
    
    [task release];
    return 0;
}

- (long long)getDiskAvailableSpace:(NSString *)diskDevice
{
    return [BAZFSUtility getAvailableSpace:diskDevice];
}

#pragma mark - Backup Operations

- (BOOL)performBackupWithProgress:(void(^)(CGFloat progress, NSString *currentTask))progressBlock
{
    NSLog(@"BackupAssistant: Starting full backup operation");
    
    if (progressBlock) {
        progressBlock(0.1, NSLocalizedString(@"Preparing backup...", @"Backup progress message"));
    }
    
    NSString *datasetName = [NSString stringWithFormat:@"%@/home_backup", _zfsPoolName];
    NSString *mountPoint = [NSString stringWithFormat:@"/mnt/%@", _zfsPoolName];
    
    // Ensure the dataset exists - create it if it doesn't exist
    if (![BAZFSUtility datasetExists:datasetName]) {
        NSLog(@"BackupAssistant: Dataset does not exist, creating it");
        if (![BAZFSUtility createDataset:datasetName]) {
            NSLog(@"ERROR: Failed to create dataset for backup");
            return NO;
        }
    } else {
        NSLog(@"BackupAssistant: Dataset already exists, proceeding with mount");
    }
    
    // Mount the dataset
    if (![BAZFSUtility mountDataset:datasetName atPath:mountPoint]) {
        NSLog(@"ERROR: Failed to mount dataset for backup");
        return NO;
    }
    
    if (progressBlock) {
        progressBlock(0.2, NSLocalizedString(@"Performing ZFS backup...", @"Backup progress message"));
    }
    
    // Perform ZFS native backup operation
    BOOL success = [BAZFSUtility performBackup:_homeDirectory 
                                   toDataset:datasetName 
                               withProgress:progressBlock];
    
    if (success) {
        if (progressBlock) {
            progressBlock(0.9, NSLocalizedString(@"Creating snapshot...", @"Backup progress message"));
        }
        
        // Create a snapshot
        NSString *timestamp = [BAZFSUtility getCurrentTimestamp];
        NSString *snapshotName = [NSString stringWithFormat:@"%@@backup_%@", datasetName, timestamp];
        success = [BAZFSUtility createSnapshot:snapshotName];
        
        if (progressBlock) {
            progressBlock(1.0, NSLocalizedString(@"Backup completed", @"Backup progress message"));
        }
    }
    
    // Unmount the dataset
    [BAZFSUtility unmountDataset:datasetName];
    
    NSLog(@"BackupAssistant: Backup operation %@", success ? @"completed successfully" : @"failed");
    return success;
}

- (BOOL)performIncrementalBackupWithProgress:(void(^)(CGFloat progress, NSString *currentTask))progressBlock
{
    NSLog(@"BackupAssistant: Starting incremental backup operation");
    
    if (progressBlock) {
        progressBlock(0.1, NSLocalizedString(@"Preparing incremental backup...", @"Backup progress message"));
    }
    
    NSString *datasetName = [NSString stringWithFormat:@"%@/home_backup", _zfsPoolName];
    NSString *mountPoint = [NSString stringWithFormat:@"/mnt/%@", _zfsPoolName];
    
    // Ensure the dataset exists - create it if it doesn't exist
    if (![BAZFSUtility datasetExists:datasetName]) {
        NSLog(@"BackupAssistant: Dataset does not exist, creating it");
        if (![BAZFSUtility createDataset:datasetName]) {
            NSLog(@"ERROR: Failed to create dataset for incremental backup");
            return NO;
        }
    } else {
        NSLog(@"BackupAssistant: Dataset already exists, proceeding with mount");
    }
    
    // Mount the dataset
    if (![BAZFSUtility mountDataset:datasetName atPath:mountPoint]) {
        NSLog(@"ERROR: Failed to mount dataset for incremental backup");
        return NO;
    }
    
    if (progressBlock) {
        progressBlock(0.3, NSLocalizedString(@"Performing incremental ZFS backup...", @"Backup progress message"));
    }
    
    // Perform incremental backup using ZFS native operations
    BOOL success = [BAZFSUtility performIncrementalBackup:_homeDirectory 
                                              toDataset:datasetName 
                                          withProgress:progressBlock];
    
    if (success) {
        if (progressBlock) {
            progressBlock(0.9, NSLocalizedString(@"Creating snapshot...", @"Backup progress message"));
        }
        
        // Create a new snapshot
        NSString *timestamp = [BAZFSUtility getCurrentTimestamp];
        NSString *snapshotName = [NSString stringWithFormat:@"%@@backup_%@", datasetName, timestamp];
        success = [BAZFSUtility createSnapshot:snapshotName];
        
        if (progressBlock) {
            progressBlock(1.0, NSLocalizedString(@"Incremental backup completed", @"Backup progress message"));
        }
    }
    
    // Unmount the dataset
    [BAZFSUtility unmountDataset:datasetName];
    
    NSLog(@"BackupAssistant: Incremental backup operation %@", success ? @"completed successfully" : @"failed");
    return success;
}

- (BOOL)performRestoreWithProgress:(void(^)(CGFloat progress, NSString *currentTask))progressBlock
{
    NSLog(@"BackupAssistant: Starting restore operation");
    
    if (progressBlock) {
        progressBlock(0.1, NSLocalizedString(@"Preparing restore...", @"Restore progress message"));
    }
    
    NSString *datasetName = [NSString stringWithFormat:@"%@/home_backup", _zfsPoolName];
    NSString *mountPoint = [NSString stringWithFormat:@"/mnt/%@", _zfsPoolName];
    
    // If a specific snapshot is selected, roll back to it first
    if (_selectedSnapshot) {
        if (progressBlock) {
            progressBlock(0.2, NSLocalizedString(@"Rolling back to snapshot...", @"Restore progress message"));
        }
        
        if (![BAZFSUtility rollbackToSnapshot:_selectedSnapshot]) {
            NSLog(@"ERROR: Failed to rollback to snapshot %@", _selectedSnapshot);
            return NO;
        }
    }
    
    // Ensure the dataset exists - it should exist for restore operations
    if (![BAZFSUtility datasetExists:datasetName]) {
        NSLog(@"ERROR: Dataset does not exist for restore operation");
        return NO;
    }
    
    // Mount the dataset
    if (![BAZFSUtility mountDataset:datasetName atPath:mountPoint]) {
        NSLog(@"ERROR: Failed to mount dataset for restore");
        return NO;
    }
    
    if (progressBlock) {
        progressBlock(0.4, NSLocalizedString(@"Restoring files...", @"Restore progress message"));
    }
    
    // Perform the restore
    BOOL success = [BAZFSUtility performRestore:mountPoint 
                                      toPath:_homeDirectory 
                                   withItems:_restoreItems 
                                withProgress:progressBlock];
    
    if (progressBlock) {
        progressBlock(1.0, NSLocalizedString(@"Restore completed", @"Restore progress message"));
    }
    
    // Unmount the dataset
    [BAZFSUtility unmountDataset:datasetName];
    
    NSLog(@"BackupAssistant: Restore operation %@", success ? @"completed successfully" : @"failed");
    return success;
}

- (BOOL)performMountBackupWithProgress:(void(^)(CGFloat progress, NSString *currentTask))progressBlock
{
    NSLog(@"BackupAssistant: Starting mount backup operation");
    
    if (progressBlock) {
        progressBlock(0.1, NSLocalizedString(@"Preparing to mount backup...", @"Mount progress message"));
    }
    
    NSString *datasetName = [NSString stringWithFormat:@"%@/home_backup", _zfsPoolName];
    NSString *mountPoint = [NSString stringWithFormat:@"/mnt/%@", _zfsPoolName];
    
    // Ensure the dataset exists
    if (![BAZFSUtility datasetExists:datasetName]) {
        NSLog(@"ERROR: Dataset does not exist for mount operation");
        return NO;
    }
    
    if (progressBlock) {
        progressBlock(0.3, NSLocalizedString(@"Mounting backup dataset...", @"Mount progress message"));
    }
    
    // Mount the dataset
    if (![BAZFSUtility mountDataset:datasetName atPath:mountPoint]) {
        NSLog(@"ERROR: Failed to mount dataset");
        return NO;
    }
    
    if (progressBlock) {
        progressBlock(0.8, NSLocalizedString(@"Verifying mount...", @"Mount progress message"));
    }
    
    // Verify the mount was successful
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager fileExistsAtPath:mountPoint]) {
        NSLog(@"ERROR: Mount point does not exist after mount operation");
        return NO;
    }
    
    if (progressBlock) {
        progressBlock(1.0, NSLocalizedString(@"Backup mounted successfully", @"Mount progress message"));
    }
    
    NSLog(@"BackupAssistant: Mount backup operation completed successfully");
    NSLog(@"BackupAssistant: Backup is now accessible at: %@", mountPoint);
    return YES;
}

#pragma mark - Success and Error Handling

- (void)showOperationSuccess:(NSString *)message
{
    NSLog(@"BackupAssistant: Showing success message: %@", message);
    _operationSuccessful = YES;
    
    if (_assistantWindow) {
        // Use the auto-complete method which hides navigation buttons
        [_assistantWindow autoCompleteWithSuccessMessage:message];
    }
}

- (void)showOperationError:(NSString *)message
{
    NSLog(@"BackupAssistant: Showing error message: %@", message);
    _operationSuccessful = NO;
    
    if (_assistantWindow) {
        [_assistantWindow showErrorPageWithTitle:NSLocalizedString(@"Operation Failed", @"Error title")
                                         message:message];
    }
}

#pragma mark - Helper Methods

- (BOOL)checkZFSAvailability
{
    NSLog(@"BackupAssistant: Checking ZFS availability");
    return [BAZFSUtility isZFSAvailable];
}

- (BOOL)checkHomeDirectoryOnZFS
{
    NSLog(@"BackupAssistant: Checking if /home is on ZFS filesystem...");
    
    NSString *homeDataset = [BAZFSUtility getZFSDatasetForPath:_homeDirectory];
    if (!homeDataset) {
        NSLog(@"ERROR: /home directory is not on ZFS - this is a hard requirement");
        return NO;
    }
    
    NSLog(@"BackupAssistant: /home is on ZFS dataset: %@", homeDataset);
    return YES;
}

- (NSString *)formatDiskSize:(long long)sizeInBytes
{
    if (sizeInBytes < 1024) {
        return [NSString stringWithFormat:@"%lld B", sizeInBytes];
    } else if (sizeInBytes < 1024 * 1024) {
        return [NSString stringWithFormat:@"%.1f KB", (double)sizeInBytes / 1024.0];
    } else if (sizeInBytes < 1024 * 1024 * 1024) {
        return [NSString stringWithFormat:@"%.1f MB", (double)sizeInBytes / (1024.0 * 1024.0)];
    } else {
        return [NSString stringWithFormat:@"%.1f GB", (double)sizeInBytes / (1024.0 * 1024.0 * 1024.0)];
    }
}

- (BOOL)isValidZFSPool:(NSString *)poolName
{
    return [BAZFSUtility isValidPoolName:poolName];
}

- (void)cleanupOnError
{
    NSLog(@"BackupAssistant: Performing cleanup on error");
    
    // Export any imported pools to clean up
    if (_zfsPoolName && [BAZFSUtility poolExists:_zfsPoolName]) {
        [BAZFSUtility exportPool:_zfsPoolName];
    }
}

- (void)stopDiskRefreshTimers
{
    NSLog(@"BAController: Requesting all disk refresh timers to stop");
    // This will be called from BADiskSelectionStep when needed
    // Send notification to disk selection steps to stop their timers
    [[NSNotificationCenter defaultCenter] postNotificationName:@"BAStopDiskRefreshTimers" 
                                                        object:self];
}

@end
