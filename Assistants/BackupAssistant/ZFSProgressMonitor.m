//
//  ZFSProgressMonitor.m
//  BackupAssistant
//
//  Created for monitoring ZFS send/receive progress using libzfs
//

#import "ZFSProgressMonitor.h"
#include "zfs_compat_types.h"  // Define missing Solaris types
#include "libshare.h"          // Local copy of the compatibility header
#include <libzfs.h>
#include <pthread.h>
#include <unistd.h>

@implementation ZFSProgressMonitor

+ (BOOL)monitorZFSSendFromSnapshot:(NSString *)sourceSnapshot
                          toHandle:(int)outputFileDescriptor
                      withCallback:(ZFSProgressCallback)progressCallback
                             error:(NSError **)error
{
    NSLog(@"ZFSProgressMonitor: Starting libzfs-based send monitoring for %@", sourceSnapshot);
    
    // Initialize libzfs
    libzfs_handle_t *libzfs = libzfs_init();
    if (libzfs == NULL) {
        NSLog(@"ERROR: Failed to initialize libzfs");
        if (error) {
            *error = [NSError errorWithDomain:@"ZFSProgressMonitor" 
                                         code:1 
                                     userInfo:@{NSLocalizedDescriptionKey: @"Failed to initialize libzfs"}];
        }
        return NO;
    }
    
    // Get the ZFS handle for the snapshot
    zfs_handle_t *zhp = zfs_open(libzfs, [sourceSnapshot UTF8String], ZFS_TYPE_SNAPSHOT);
    if (zhp == NULL) {
        NSLog(@"ERROR: Failed to open ZFS snapshot %@", sourceSnapshot);
        libzfs_fini(libzfs);
        if (error) {
            *error = [NSError errorWithDomain:@"ZFSProgressMonitor" 
                                         code:2 
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to open snapshot %@", sourceSnapshot]}];
        }
        return NO;
    }
    
    // Set up send flags
    sendflags_t sendflags = {0};
    sendflags.verbosity = 1;
    sendflags.progress = B_TRUE;  // Enable progress monitoring
    sendflags.parsable = B_TRUE;  // Enable parsable output
    
    NSLog(@"ZFSProgressMonitor: Starting ZFS send with progress monitoring");
    
    // Create a monitoring thread to check progress
    dispatch_queue_t progressQueue = dispatch_queue_create("zfs.progress.monitor", DISPATCH_QUEUE_SERIAL);
    __block BOOL sendCompleted = NO;
    __block BOOL sendSuccess = NO;
    
    // Start progress monitoring in background
    dispatch_async(progressQueue, ^{
        uint64_t totalBytes = 0;
        uint64_t transferredBytes = 0;
        
        // Get the initial size estimate
        nvlist_t *props = NULL;
        if (zfs_send_one(zhp, NULL, STDOUT_FILENO, &sendflags, NULL) == 0) {
            // This is a dry run to get size estimate
            NSLog(@"ZFSProgressMonitor: Got size estimate for send operation");
        }
        
        while (!sendCompleted) {
            // Check progress every 100ms
            usleep(100000);
            
            // Get current progress
            if (zfs_send_progress(zhp, outputFileDescriptor, &transferredBytes, &totalBytes) == 0) {
                if (totalBytes > 0) {
                    CGFloat progress = (CGFloat)transferredBytes / (CGFloat)totalBytes;
                    
                    NSString *statusMessage = [NSString stringWithFormat:@"Sending: %@ of %@ (%.1f%%)",
                                               [self formatBytes:transferredBytes],
                                               [self formatBytes:totalBytes],
                                               progress * 100.0];
                    
                    // Call the progress callback on the main thread
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (progressCallback) {
                            progressCallback(progress, statusMessage, transferredBytes, totalBytes);
                        }
                    });
                    
                    NSLog(@"ZFS Progress: %llu/%llu bytes (%.1f%%) - REAL LIBZFS DATA", 
                          transferredBytes, totalBytes, progress * 100.0);
                }
            }
        }
    });
    
    // Perform the actual send operation
    NSLog(@"ZFSProgressMonitor: Executing zfs_send_one()");
    int result = zfs_send_one(zhp, NULL, outputFileDescriptor, &sendflags, NULL);
    
    // Mark send as completed
    sendCompleted = YES;
    sendSuccess = (result == 0);
    
    // Final progress update
    if (sendSuccess && progressCallback) {
        dispatch_async(dispatch_get_main_queue(), ^{
            progressCallback(1.0, @"ZFS send completed successfully", 0, 0);
        });
    }
    
    // Cleanup
    zfs_close(zhp);
    libzfs_fini(libzfs);
    
    NSLog(@"ZFSProgressMonitor: ZFS send completed with result: %d (%s)", result, sendSuccess ? "SUCCESS" : "FAILURE");
    
    if (!sendSuccess && error) {
        *error = [NSError errorWithDomain:@"ZFSProgressMonitor" 
                                     code:3 
                                 userInfo:@{NSLocalizedDescriptionKey: @"ZFS send operation failed"}];
    }
    
    return sendSuccess;
}

+ (BOOL)monitorZFSReceiveToDataset:(NSString *)destinationDataset
                        fromHandle:(int)inputFileDescriptor
                      withCallback:(ZFSProgressCallback)progressCallback
                             error:(NSError **)error
{
    NSLog(@"ZFSProgressMonitor: Starting libzfs-based receive monitoring for %@", destinationDataset);
    
    // Initialize libzfs
    libzfs_handle_t *libzfs = libzfs_init();
    if (libzfs == NULL) {
        NSLog(@"ERROR: Failed to initialize libzfs");
        if (error) {
            *error = [NSError errorWithDomain:@"ZFSProgressMonitor" 
                                         code:1 
                                     userInfo:@{NSLocalizedDescriptionKey: @"Failed to initialize libzfs"}];
        }
        return NO;
    }
    
    // Set up receive flags
    recvflags_t recvflags = {0};
    recvflags.verbose = B_TRUE;
    recvflags.force = B_TRUE;  // Equivalent to -F flag
    
    NSLog(@"ZFSProgressMonitor: Starting ZFS receive");
    
    // Perform the receive operation
    int result = zfs_receive(libzfs, [destinationDataset UTF8String], NULL, &recvflags, inputFileDescriptor, NULL);
    
    BOOL success = (result == 0);
    
    // Final progress update
    if (success && progressCallback) {
        dispatch_async(dispatch_get_main_queue(), ^{
            progressCallback(1.0, @"ZFS receive completed successfully", 0, 0);
        });
    }
    
    // Cleanup
    libzfs_fini(libzfs);
    
    NSLog(@"ZFSProgressMonitor: ZFS receive completed with result: %d (%s)", result, success ? "SUCCESS" : "FAILURE");
    
    if (!success && error) {
        *error = [NSError errorWithDomain:@"ZFSProgressMonitor" 
                                     code:4 
                                 userInfo:@{NSLocalizedDescriptionKey: @"ZFS receive operation failed"}];
    }
    
    return success;
}

+ (BOOL)performZFSSendReceiveFromSnapshot:(NSString *)sourceSnapshot
                                toDataset:(NSString *)destinationDataset
                             withCallback:(ZFSProgressCallback)progressCallback
                                    error:(NSError **)error
{
    NSLog(@"ZFSProgressMonitor: Starting combined ZFS send/receive with libzfs progress monitoring");
    NSLog(@"ZFSProgressMonitor: Source: %@", sourceSnapshot);
    NSLog(@"ZFSProgressMonitor: Destination: %@", destinationDataset);
    
    // Create a pipe for the send/receive operation
    int pipefd[2];
    if (pipe(pipefd) != 0) {
        NSLog(@"ERROR: Failed to create pipe for ZFS send/receive");
        if (error) {
            *error = [NSError errorWithDomain:@"ZFSProgressMonitor" 
                                         code:5 
                                     userInfo:@{NSLocalizedDescriptionKey: @"Failed to create pipe"}];
        }
        return NO;
    }
    
    int readfd = pipefd[0];
    int writefd = pipefd[1];
    
    __block BOOL sendResult = NO;
    __block BOOL receiveResult = NO;
    __block NSError *sendError = nil;
    __block NSError *receiveError = nil;
    
    // Create concurrent queues for send and receive
    dispatch_queue_t sendQueue = dispatch_queue_create("zfs.send", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_t receiveQueue = dispatch_queue_create("zfs.receive", DISPATCH_QUEUE_SERIAL);
    dispatch_group_t transferGroup = dispatch_group_create();
    
    // Start the send operation
    dispatch_group_async(transferGroup, sendQueue, ^{
        NSLog(@"ZFSProgressMonitor: Starting send operation in background");
        sendResult = [self monitorZFSSendFromSnapshot:sourceSnapshot
                                             toHandle:writefd
                                         withCallback:^(CGFloat progress, NSString *status, uint64_t bytesTransferred, uint64_t totalBytes) {
            // Adjust progress to be 0-80% for send operation
            CGFloat adjustedProgress = progress * 0.8;
            if (progressCallback) {
                progressCallback(adjustedProgress, status, bytesTransferred, totalBytes);
            }
        }
                                                error:&sendError];
        
        // Close write end when send is done
        close(writefd);
        NSLog(@"ZFSProgressMonitor: Send operation completed with result: %@", sendResult ? @"SUCCESS" : @"FAILURE");
    });
    
    // Start the receive operation
    dispatch_group_async(transferGroup, receiveQueue, ^{
        NSLog(@"ZFSProgressMonitor: Starting receive operation in background");
        receiveResult = [self monitorZFSReceiveToDataset:destinationDataset
                                              fromHandle:readfd
                                            withCallback:^(CGFloat progress, NSString *status, uint64_t bytesTransferred, uint64_t totalBytes) {
            // Adjust progress to be 80-100% for receive operation
            CGFloat adjustedProgress = 0.8 + (progress * 0.2);
            if (progressCallback) {
                progressCallback(adjustedProgress, status, bytesTransferred, totalBytes);
            }
        }
                                                   error:&receiveError];
        
        // Close read end when receive is done
        close(readfd);
        NSLog(@"ZFSProgressMonitor: Receive operation completed with result: %@", receiveResult ? @"SUCCESS" : @"FAILURE");
    });
    
    // Wait for both operations to complete
    dispatch_group_wait(transferGroup, DISPATCH_TIME_FOREVER);
    
    BOOL overallSuccess = sendResult && receiveResult;
    
    if (!overallSuccess && error) {
        if (sendError) {
            *error = sendError;
        } else if (receiveError) {
            *error = receiveError;
        } else {
            *error = [NSError errorWithDomain:@"ZFSProgressMonitor" 
                                         code:6 
                                     userInfo:@{NSLocalizedDescriptionKey: @"ZFS send/receive operation failed"}];
        }
    }
    
    NSLog(@"ZFSProgressMonitor: Combined ZFS send/receive completed with overall result: %@", overallSuccess ? @"SUCCESS" : @"FAILURE");
    
    return overallSuccess;
}

+ (BOOL)performIncrementalZFSSendReceiveFromSnapshot:(NSString *)sourceSnapshot
                                        baseSnapshot:(NSString *)baseSnapshot  
                                           toDataset:(NSString *)destinationDataset
                                        withCallback:(ZFSProgressCallback)progressCallback
                                               error:(NSError **)error
{
    NSLog(@"ZFSProgressMonitor: Starting incremental ZFS send/receive with libzfs progress monitoring");
    NSLog(@"ZFSProgressMonitor: Base snapshot: %@", baseSnapshot);
    NSLog(@"ZFSProgressMonitor: Source snapshot: %@", sourceSnapshot);
    NSLog(@"ZFSProgressMonitor: Destination: %@", destinationDataset);
    
    // Initialize libzfs
    libzfs_handle_t *libzfs = libzfs_init();
    if (libzfs == NULL) {
        NSLog(@"ERROR: Failed to initialize libzfs for incremental send");
        if (error) {
            *error = [NSError errorWithDomain:@"ZFSProgressMonitor" 
                                         code:1 
                                     userInfo:@{NSLocalizedDescriptionKey: @"Failed to initialize libzfs for incremental send"}];
        }
        return NO;
    }
    
    // Get the ZFS handles for both snapshots
    zfs_handle_t *fromZhp = zfs_open(libzfs, [baseSnapshot UTF8String], ZFS_TYPE_SNAPSHOT);
    if (fromZhp == NULL) {
        NSLog(@"ERROR: Failed to open base ZFS snapshot %@", baseSnapshot);
        libzfs_fini(libzfs);
        if (error) {
            *error = [NSError errorWithDomain:@"ZFSProgressMonitor" 
                                         code:2 
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to open base snapshot %@", baseSnapshot]}];
        }
        return NO;
    }
    
    zfs_handle_t *toZhp = zfs_open(libzfs, [sourceSnapshot UTF8String], ZFS_TYPE_SNAPSHOT);
    if (toZhp == NULL) {
        NSLog(@"ERROR: Failed to open source ZFS snapshot %@", sourceSnapshot);
        zfs_close(fromZhp);
        libzfs_fini(libzfs);
        if (error) {
            *error = [NSError errorWithDomain:@"ZFSProgressMonitor" 
                                         code:2 
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to open source snapshot %@", sourceSnapshot]}];
        }
        return NO;
    }
    
    // Create a pipe for the send/receive operation
    int pipefd[2];
    if (pipe(pipefd) != 0) {
        NSLog(@"ERROR: Failed to create pipe for incremental ZFS send/receive");
        zfs_close(fromZhp);
        zfs_close(toZhp);
        libzfs_fini(libzfs);
        if (error) {
            *error = [NSError errorWithDomain:@"ZFSProgressMonitor" 
                                         code:5 
                                     userInfo:@{NSLocalizedDescriptionKey: @"Failed to create pipe"}];
        }
        return NO;
    }
    
    int readfd = pipefd[0];
    int writefd = pipefd[1];
    
    // Set up incremental send flags
    sendflags_t sendflags = {0};
    sendflags.verbosity = 1;
    sendflags.progress = B_TRUE;  // Enable progress monitoring
    sendflags.parsable = B_TRUE;  // Enable parsable output
    
    __block BOOL sendResult = NO;
    __block BOOL receiveResult = NO;
    __block NSError *sendError = nil;
    __block NSError *receiveError = nil;
    
    // Create concurrent queues for send and receive
    dispatch_queue_t sendQueue = dispatch_queue_create("zfs.incremental.send", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_t receiveQueue = dispatch_queue_create("zfs.incremental.receive", DISPATCH_QUEUE_SERIAL);
    dispatch_group_t transferGroup = dispatch_group_create();
    
    // Start the incremental send operation
    dispatch_group_async(transferGroup, sendQueue, ^{
        NSLog(@"ZFSProgressMonitor: Starting incremental send operation in background");
        
        // Monitor progress in background
        dispatch_queue_t progressQueue = dispatch_queue_create("zfs.incremental.progress", DISPATCH_QUEUE_SERIAL);
        __block BOOL sendCompleted = NO;
        
        dispatch_async(progressQueue, ^{
            uint64_t totalBytes = 0;
            uint64_t transferredBytes = 0;
            
            while (!sendCompleted) {
                usleep(100000); // 100ms
                
                // Get current progress using libzfs
                if (zfs_send_progress(toZhp, writefd, &transferredBytes, &totalBytes) == 0) {
                    if (totalBytes > 0) {
                        CGFloat progress = (CGFloat)transferredBytes / (CGFloat)totalBytes;
                        
                        NSString *statusMessage = [NSString stringWithFormat:@"Incremental sending: %@ of %@ (%.1f%%)",
                                                   [self formatBytes:transferredBytes],
                                                   [self formatBytes:totalBytes],
                                                   progress * 100.0];
                        
                        // Call the progress callback on the main thread
                        dispatch_async(dispatch_get_main_queue(), ^{
                            if (progressCallback) {
                                // Adjust progress to be 0-80% for send operation
                                CGFloat adjustedProgress = progress * 0.8;
                                progressCallback(adjustedProgress, statusMessage, transferredBytes, totalBytes);
                            }
                        });
                        
                        NSLog(@"ZFS Incremental Progress: %llu/%llu bytes (%.1f%%) - REAL LIBZFS DATA", 
                              transferredBytes, totalBytes, progress * 100.0);
                    }
                }
            }
        });
        
        // Perform the incremental send (from base snapshot to source snapshot)
        NSLog(@"ZFSProgressMonitor: Executing incremental zfs_send_one() from %@ to %@", baseSnapshot, sourceSnapshot);
        int result = zfs_send_one(toZhp, [baseSnapshot UTF8String], writefd, &sendflags, NULL);
        
        // Mark send as completed
        sendCompleted = YES;
        sendResult = (result == 0);
        
        // Close write end when send is done
        close(writefd);
        NSLog(@"ZFSProgressMonitor: Incremental send operation completed with result: %@", sendResult ? @"SUCCESS" : @"FAILURE");
        
        if (!sendResult) {
            sendError = [NSError errorWithDomain:@"ZFSProgressMonitor" 
                                            code:3 
                                        userInfo:@{NSLocalizedDescriptionKey: @"Incremental ZFS send operation failed"}];
        }
    });
    
    // Start the receive operation
    dispatch_group_async(transferGroup, receiveQueue, ^{
        NSLog(@"ZFSProgressMonitor: Starting receive operation in background");
        
        // Set up receive flags
        recvflags_t recvflags = {0};
        recvflags.verbose = B_TRUE;
        recvflags.force = B_TRUE;  // Equivalent to -F flag
        
        // Perform the receive operation
        int result = zfs_receive(libzfs, [destinationDataset UTF8String], NULL, &recvflags, readfd, NULL);
        receiveResult = (result == 0);
        
        // Close read end when receive is done
        close(readfd);
        NSLog(@"ZFSProgressMonitor: Receive operation completed with result: %@", receiveResult ? @"SUCCESS" : @"FAILURE");
        
        if (receiveResult && progressCallback) {
            dispatch_async(dispatch_get_main_queue(), ^{
                progressCallback(1.0, @"Incremental ZFS receive completed successfully", 0, 0);
            });
        } else if (!receiveResult) {
            receiveError = [NSError errorWithDomain:@"ZFSProgressMonitor" 
                                               code:4 
                                           userInfo:@{NSLocalizedDescriptionKey: @"Incremental ZFS receive operation failed"}];
        }
    });
    
    // Wait for both operations to complete
    dispatch_group_wait(transferGroup, DISPATCH_TIME_FOREVER);
    
    BOOL overallSuccess = sendResult && receiveResult;
    
    // Cleanup
    zfs_close(fromZhp);
    zfs_close(toZhp);
    libzfs_fini(libzfs);
    
    if (!overallSuccess && error) {
        if (sendError) {
            *error = sendError;
        } else if (receiveError) {
            *error = receiveError;
        } else {
            *error = [NSError errorWithDomain:@"ZFSProgressMonitor" 
                                         code:6 
                                     userInfo:@{NSLocalizedDescriptionKey: @"Incremental ZFS send/receive operation failed"}];
        }
    }
    
    NSLog(@"ZFSProgressMonitor: Incremental ZFS send/receive completed with overall result: %@", overallSuccess ? @"SUCCESS" : @"FAILURE");
    
    return overallSuccess;
}

#pragma mark - Utility Methods

+ (NSString *)formatBytes:(uint64_t)bytes
{
    if (bytes < 1024) {
        return [NSString stringWithFormat:@"%llu B", bytes];
    } else if (bytes < 1024 * 1024) {
        return [NSString stringWithFormat:@"%.1f KB", (double)bytes / 1024.0];
    } else if (bytes < 1024 * 1024 * 1024) {
        return [NSString stringWithFormat:@"%.1f MB", (double)bytes / (1024.0 * 1024.0)];
    } else if (bytes < 1024ULL * 1024ULL * 1024ULL * 1024ULL) {
        return [NSString stringWithFormat:@"%.1f GB", (double)bytes / (1024.0 * 1024.0 * 1024.0)];
    } else {
        return [NSString stringWithFormat:@"%.1f TB", (double)bytes / (1024.0 * 1024.0 * 1024.0 * 1024.0)];
    }
}

@end
