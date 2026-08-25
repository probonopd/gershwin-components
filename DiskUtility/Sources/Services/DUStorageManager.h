/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

#import "DUStorageBackend.h"
#import "DUStorageCapabilities.h"

@class DUOperation;
@class DUOperationManager;

// Central storage-domain service (ARCHITECTURE.md section 36): owns the
// backend, keeps the current object snapshot, publishes topology changes and
// hands operation starters to the DUOperationManager while enforcing the
// application-level busy locks of section 33.
@interface DUStorageManager : NSObject

@property (nonatomic, strong, readonly) id<DUStorageBackend> backend;
@property (nonatomic, strong, readonly) DUOperationManager *operationManager;

// Snapshot of the last successful discovery; empty before the first refresh.
@property (nonatomic, copy, readonly) NSArray<DUStorageObject *> *currentObjects;

- (instancetype)initWithBackend:(id<DUStorageBackend>)backend
                operationManager:(DUOperationManager *)operationManager
    NS_DESIGNATED_INITIALIZER;

// Synchronous discovery + reconcile against the snapshot. Returns YES when
// the model was updated; NO with *error set on discovery failure, in which
// case the previous snapshot is kept. Call from a background thread.
- (BOOL)refreshWithError:(NSError **)error;

- (DUStorageObject *)objectForIdentifier:(NSString *)identifier;
- (DUStorageCapabilities *)capabilitiesForObject:(DUStorageObject *)object;

// Backend-wide feature report for diagnostics/degradation UI.
- (NSDictionary *)backendCapabilitiesReport;

// Application-level per-identifier locks (ARCHITECTURE.md section 33).
- (BOOL)isBusyIdentifier:(NSString *)identifier;
- (BOOL)acquireLock:(NSString *)identifier error:(NSError **)error;
- (void)releaseLock:(NSString *)identifier;

// Convenience starter: acquires the lock for object.identifier, builds a
// verify operation and starts it through the operation manager. Returns nil
// (with *error set) when the object is busy or unsupported; the completion
// block always fires exactly once, on any thread.
// Same contract as verifyObject: but drives the repair backend call.
- (DUOperation *)repairObject:(DUStorageObject *)object
                   onProgress:(void (^)(double progress, NSString *message))progress
                 onCompletion:(void (^)(NSError *error))completion
                        error:(NSError **)error;

- (DUOperation *)verifyObject:(DUStorageObject *)object
                   onProgress:(void (^)(double progress, NSString *message))progress
                 onCompletion:(void (^)(NSError *error))completion
                        error:(NSError **)error;

// Convenience starter for disk-image creation (optional backend verb).
// Acquires the object lock, runs the imaging on a worker thread and
// releases the lock on completion. Returns nil with *error when busy or
// unsupported.
- (DUOperation *)createImageFromObject:(DUStorageObject *)object
                               options:(NSDictionary *)options
                            onProgress:(void (^)(double progress, NSString *message))progress
                          onCompletion:(void (^)(NSError *error))completion
                                 error:(NSError **)error;

- (NSArray<NSDictionary *> *)imageCreationFormats;

// Convenience starters for image conversion, resizing and burning
// (optional backend verbs). Same lock-and-run contract as image creation.
- (DUOperation *)convertImage:(DUStorageObject *)image
                       options:(NSDictionary *)options
                    onProgress:(void (^)(double progress, NSString *message))progress
                  onCompletion:(void (^)(NSError *error))completion
                         error:(NSError **)error;

- (DUOperation *)resizeImage:(DUStorageObject *)image
                      options:(NSDictionary *)options
                   onProgress:(void (^)(double progress, NSString *message))progress
                 onCompletion:(void (^)(NSError *error))completion
                        error:(NSError **)error;

- (DUOperation *)burnImage:(DUStorageObject *)image
                 toObject:(DUStorageObject *)opticalDrive
               onProgress:(void (^)(double progress, NSString *message))progress
             onCompletion:(void (^)(NSError *error))completion
                    error:(NSError **)error;

// Format descriptors for the erase popup; passthrough to the optional
// backend method, empty array when the backend does not implement it.
- (NSArray<NSDictionary *> *)supportedFormatsForObject:(DUStorageObject *)object;

// Security-method choices for the erase dialog, built from the canonical
// kDUErase* constants.
- (NSArray<NSDictionary *> *)eraseSecurityOptions;

@end
