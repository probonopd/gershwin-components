//
//  ZFSProgressMonitor.h
//  BackupAssistant
//
//  Created for monitoring ZFS send/receive progress using libzfs
//

#ifndef ZFSProgressMonitor_h
#define ZFSProgressMonitor_h

#include <Foundation/Foundation.h>

// Progress callback block
typedef void (^ZFSProgressCallback)(CGFloat progress, NSString *status, uint64_t bytesTransferred, uint64_t totalBytes);

@interface ZFSProgressMonitor : NSObject

// Monitor a ZFS send operation using libzfs
+ (BOOL)monitorZFSSendFromSnapshot:(NSString *)sourceSnapshot
                          toHandle:(int)outputFileDescriptor
                      withCallback:(ZFSProgressCallback)progressCallback
                             error:(NSError **)error;

// Monitor a ZFS receive operation 
+ (BOOL)monitorZFSReceiveToDataset:(NSString *)destinationDataset
                        fromHandle:(int)inputFileDescriptor
                      withCallback:(ZFSProgressCallback)progressCallback
                             error:(NSError **)error;

// Perform ZFS send/receive with real progress monitoring using libzfs
+ (BOOL)performZFSSendReceiveFromSnapshot:(NSString *)sourceSnapshot
                                toDataset:(NSString *)destinationDataset
                             withCallback:(ZFSProgressCallback)progressCallback
                                    error:(NSError **)error;

// Perform incremental ZFS send/receive with real progress monitoring using libzfs
+ (BOOL)performIncrementalZFSSendReceiveFromSnapshot:(NSString *)sourceSnapshot
                                        baseSnapshot:(NSString *)baseSnapshot  
                                           toDataset:(NSString *)destinationDataset
                                        withCallback:(ZFSProgressCallback)progressCallback
                                               error:(NSError **)error;

@end

#endif /* ZFSProgressMonitor_h */
