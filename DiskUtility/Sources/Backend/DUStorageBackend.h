/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

@class DUStorageObject;
@class DUPartitionPlan;

// Canonical operation tokens passed to supportsOperation:forObject:.
// UI and backends share these constants so nothing hardcodes raw strings.
extern NSString *const kDUOperationVerify;
extern NSString *const kDUOperationRepair;
extern NSString *const kDUOperationErase;
extern NSString *const kDUOperationPartition;
extern NSString *const kDUOperationMount;
extern NSString *const kDUOperationUnmount;
extern NSString *const kDUOperationEject;
extern NSString *const kDUOperationRestore;
extern NSString *const kDUOperationBurn;
extern NSString *const kDUOperationCreateImage;
extern NSString *const kDUOperationConvertImage;
extern NSString *const kDUOperationResizeImage;
extern NSString *const kDUOperationToggleJournaling;

// Keys of the format-descriptor dictionaries returned by
// supportedFormatsForObject:. One dictionary per formattable filesystem.
extern NSString *const kDUFormatIdentifierKey;    // e.g. "ext4"
extern NSString *const kDUFormatDisplayNameKey;   // e.g. "Extended filesystem"
extern NSString *const kDUFormatCanFormatKey;     // NSNumber bool

// Security-option values for eraseObject:options:. The options dictionary
// carries the chosen method under kDUEraseSecurityMethodKey; when absent
// backends use the fastest safe method (standard).
extern NSString *const kDUEraseSecurityMethodKey; // value is one of the two below
extern NSString *const kDUEraseMethodStandardKey; // e.g. "standard"
extern NSString *const kDUEraseMethodZerosKey;    // e.g. "zeros"

// Storage abstraction every platform backend implements. All async methods
// validate their arguments synchronously and then run on a private worker
// thread. Progress and completion callbacks are delivered on an arbitrary
// thread; callers must marshal to the main thread themselves. Operations
// rejected before they start deliver their completion error synchronously
// on the calling thread.
@protocol DUStorageBackend <NSObject>

- (NSArray *)discoverStorageObjects:(NSError **)error;
- (NSDictionary *)capabilitiesReport;

- (BOOL)supportsOperation:(NSString *)op forObject:(DUStorageObject *)object;

- (void)verifyObject:(DUStorageObject *)object
             progress:(void (^)(double progress, NSString *message))progress
           completion:(void (^)(NSError *error))completion;

- (void)repairObject:(DUStorageObject *)object
             progress:(void (^)(double progress, NSString *message))progress
           completion:(void (^)(NSError *error))completion;

- (void)eraseObject:(DUStorageObject *)object
            options:(NSDictionary *)options
           progress:(void (^)(double progress, NSString *message))progress
         completion:(void (^)(NSError *error))completion;

- (void)partitionDevice:(DUStorageObject *)device
                withPlan:(DUPartitionPlan *)plan
               progress:(void (^)(double progress, NSString *message))progress
             completion:(void (^)(NSError *error))completion;

- (void)mountObject:(DUStorageObject *)object
          completion:(void (^)(NSError *error, NSString *mountPoint))completion;

- (void)unmountObject:(DUStorageObject *)object
            completion:(void (^)(NSError *error))completion;

- (void)ejectObject:(DUStorageObject *)object
          completion:(void (^)(NSError *error))completion;

- (void)restoreFromSource:(DUStorageObject *)source
              destination:(DUStorageObject *)destination
                  options:(NSDictionary *)options
                 progress:(void (^)(double progress, NSString *message))progress
               completion:(void (^)(NSError *error))completion;

@optional

// Format descriptors offered for this object, empty array when none. Callers
// must treat absence of the method as an empty result.
- (NSArray<NSDictionary *> *)supportedFormatsForObject:(DUStorageObject *)object;

// Disk-image creation from a whole device (partition table included) or a
// single volume. Options keys:
//   @"path"   destination file the user picked
//   @"format" one of the identifiers reported by -imageCreationFormats
// Absent method => the backend cannot image devices; UI gates on
// canCreateImage which backends set only when they implement this.
- (void)createImageFromObject:(DUStorageObject *)object
                      options:(NSDictionary *)options
                     progress:(void (^)(double progress, NSString *message))progress
                   completion:(void (^)(NSError *error))completion;

// Image-creation target descriptors ({kDUFormatIdentifierKey,
// kDUFormatDisplayNameKey}), e.g. raw, gzip-compressed raw, and any
// qemu-img formats when that tool is installed. Absent => none.
- (NSArray<NSDictionary *> *)imageCreationFormats;

@end
