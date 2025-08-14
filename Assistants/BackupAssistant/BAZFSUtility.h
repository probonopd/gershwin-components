//
// BAZFSUtility.h
// Backup Assistant - ZFS Operations Utility
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface BAZFSUtility : NSObject

// ZFS System Checks
+ (BOOL)isZFSAvailable;
+ (BOOL)isValidPoolName:(NSString *)poolName;

// Pool Management
+ (BOOL)createPool:(NSString *)poolName onDisk:(NSString *)diskDevice;
+ (BOOL)importPoolFromDisk:(NSString *)diskDevice poolName:(NSString *)poolName;
+ (BOOL)exportPool:(NSString *)poolName;
+ (BOOL)destroyPool:(NSString *)poolName;
+ (BOOL)poolExists:(NSString *)poolName;
+ (BOOL)diskHasZFSPool:(NSString *)diskDevice;
+ (NSString *)getPoolNameFromDisk:(NSString *)diskDevice;

// Dataset Management
+ (BOOL)createDataset:(NSString *)datasetName;
+ (BOOL)destroyDataset:(NSString *)datasetName;
+ (BOOL)datasetExists:(NSString *)datasetName;
+ (BOOL)mountDataset:(NSString *)datasetName atPath:(NSString *)mountPath;
+ (BOOL)unmountDataset:(NSString *)datasetName;
+ (NSArray *)getDatasets:(NSString *)poolName;

// Snapshot Management
+ (BOOL)createSnapshot:(NSString *)snapshotName;
+ (BOOL)destroySnapshot:(NSString *)snapshotName;
+ (BOOL)rollbackToSnapshot:(NSString *)snapshotName;
+ (NSArray *)getSnapshots:(NSString *)datasetName;

// Backup and Restore Operations
+ (BOOL)performBackup:(NSString *)sourcePath 
            toDataset:(NSString *)datasetName 
        withProgress:(nullable void(^)(CGFloat progress, NSString *currentTask))progressBlock;

+ (BOOL)performIncrementalBackup:(NSString *)sourcePath 
                       toDataset:(NSString *)datasetName 
                   withProgress:(nullable void(^)(CGFloat progress, NSString *currentTask))progressBlock;

+ (BOOL)performRestore:(NSString *)sourcePath 
                toPath:(NSString *)destinationPath 
             withItems:(nullable NSArray *)itemsToRestore 
         withProgress:(nullable void(^)(CGFloat progress, NSString *currentTask))progressBlock;

// Utility Methods
+ (long long)getAvailableSpace:(NSString *)diskDevice;
+ (long long)getRawDiskSize:(NSString *)diskDevice;
+ (long long)convertSizeStringToBytes:(NSString *)sizeString;
+ (NSString *)getCurrentTimestamp;
+ (NSString *)executeZFSCommand:(NSArray *)arguments;
+ (BOOL)executeZFSCommandWithSuccess:(NSArray *)arguments;
+ (NSString *)executeZPoolCommand:(NSArray *)arguments;
+ (BOOL)executeZPoolCommandWithSuccess:(NSArray *)arguments;

// ZFS Native Operations
+ (NSString *)getZFSDatasetForPath:(NSString *)path;
+ (BOOL)performZFSSendReceive:(NSString *)sourceSnapshot 
                    toDataset:(NSString *)destinationDataset 
                 withProgress:(nullable void(^)(CGFloat progress, NSString *currentTask))progressBlock;
+ (BOOL)performIncrementalZFSSendReceive:(NSString *)baseSnapshot 
                            fromSnapshot:(NSString *)sourceSnapshot 
                               toDataset:(NSString *)destinationDataset 
                            withProgress:(nullable void(^)(CGFloat progress, NSString *currentTask))progressBlock;
+ (BOOL)performFullZFSRestore:(NSString *)sourceSnapshot 
                    toDataset:(NSString *)destinationDataset 
                 withProgress:(nullable void(^)(CGFloat progress, NSString *currentTask))progressBlock;
+ (BOOL)performSelectiveZFSRestore:(NSString *)sourceSnapshot 
                         toDataset:(NSString *)destinationDataset 
                         withItems:(NSArray *)itemsToRestore 
                      withProgress:(nullable void(^)(CGFloat progress, NSString *currentTask))progressBlock;

// Progress monitoring for ZFS operations
+ (BOOL)monitorZFSProgress:(NSTask *)sendTask 
               receiveTask:(NSTask *)receiveTask 
           sendProgressPipe:(NSPipe *)sendProgressPipe 
          receiveErrorPipe:(NSPipe *)receiveErrorPipe 
             progressBlock:(nullable void(^)(CGFloat progress, NSString *currentTask))progressBlock 
              baseProgress:(CGFloat)baseProgress 
             progressRange:(CGFloat)progressRange;

// Private Helper Methods  
+ (BOOL)unmountDisk:(NSString *)diskDevice;
+ (long long)calculateDirectorySize:(NSString *)path;
+ (NSString *)formatBytes:(long long)bytes;

// Enhanced error handling and validation
+ (BOOL)validateZFSSystemState:(NSString * _Nullable * _Nullable)errorMessage;
+ (BOOL)validatePoolHealth:(NSString *)poolName errorMessage:(NSString * _Nullable * _Nullable)errorMessage;
+ (BOOL)validateDatasetExists:(NSString *)datasetName errorMessage:(NSString * _Nullable * _Nullable)errorMessage;

@end

NS_ASSUME_NONNULL_END
