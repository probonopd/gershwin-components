//
// BAController.h
// Backup Assistant - Main Controller
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <GSAssistantFramework.h>

typedef NS_ENUM(NSInteger, BAOperationType) {
    BAOperationTypeNone,
    BAOperationTypeNewBackup,
    BAOperationTypeUpdateBackup,
    BAOperationTypeRestoreBackup,
    BAOperationTypeMountBackup,
    BAOperationTypeDestroyAndRecreate
};

typedef NS_ENUM(NSInteger, BADiskAnalysisResult) {
    BADiskAnalysisResultEmpty,
    BADiskAnalysisResultHasBackup,
    BADiskAnalysisResultCorrupted,
    BADiskAnalysisResultIncompatible
};

@interface BAController : NSObject <GSAssistantWindowDelegate>
{
    GSAssistantWindow *_assistantWindow;
    NSString *_selectedDiskDevice;
    NSString *_homeDirectory;
    BAOperationType _selectedOperation;
    BADiskAnalysisResult _diskAnalysisResult;
    NSArray *_availableSnapshots;
    NSString *_selectedSnapshot;
    NSMutableArray *_backupItems;
    NSMutableArray *_restoreItems;
    BOOL _operationSuccessful;
    NSString *_zfsPoolName;
    long long _requiredSpace;
    long long _availableSpace;
    BOOL _userConfirmedWipe;
}

@property (nonatomic, retain) NSString *selectedDiskDevice;
@property (nonatomic, retain) NSString *homeDirectory;
@property (nonatomic, assign) BAOperationType selectedOperation;
@property (nonatomic, assign) BADiskAnalysisResult diskAnalysisResult;
@property (nonatomic, retain) NSArray *availableSnapshots;
@property (nonatomic, retain) NSString *selectedSnapshot;
@property (nonatomic, retain) NSMutableArray *backupItems;
@property (nonatomic, retain) NSMutableArray *restoreItems;
@property (nonatomic, assign) BOOL operationSuccessful;
@property (nonatomic, retain) NSString *zfsPoolName;
@property (nonatomic, assign) long long requiredSpace;
@property (nonatomic, assign) long long availableSpace;
@property (nonatomic, assign) BOOL userConfirmedWipe;

- (void)showAssistant;

// Disk and ZFS operations
- (BADiskAnalysisResult)analyzeDisk:(NSString *)diskDevice;
- (BOOL)createZFSPool:(NSString *)diskDevice;
- (BOOL)importZFSPool:(NSString *)diskDevice;
- (BOOL)destroyExistingZFSPool:(NSString *)diskDevice;
- (NSArray *)getZFSSnapshots;
- (long long)calculateBackupSize;
- (long long)getDiskAvailableSpace:(NSString *)diskDevice;

// Backup operations
- (BOOL)performBackupWithProgress:(void(^)(CGFloat progress, NSString *currentTask))progressBlock;
- (BOOL)performIncrementalBackupWithProgress:(void(^)(CGFloat progress, NSString *currentTask))progressBlock;
- (BOOL)performRestoreWithProgress:(void(^)(CGFloat progress, NSString *currentTask))progressBlock;
- (BOOL)performMountBackupWithProgress:(void(^)(CGFloat progress, NSString *currentTask))progressBlock;

// Success and error handling
- (void)showOperationSuccess:(NSString *)message;
- (void)showOperationError:(NSString *)message;

// Helper methods
- (BOOL)checkZFSAvailability;
- (BOOL)checkHomeDirectoryOnZFS;
- (NSString *)formatDiskSize:(long long)sizeInBytes;
- (BOOL)isValidZFSPool:(NSString *)poolName;
- (void)cleanupOnError;
- (void)stopDiskRefreshTimers; // Stop any active disk refresh timers

@end
