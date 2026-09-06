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

// Disc (optical) operation keys. Blanking a rewritable disc (CD-RW,
// DVD-RW, DVD+RW, DVD-RAM, BD-RE) prepares it for reuse; the method picks
// the wipe depth.
extern NSString *const kDUDiscBlankMethodKey; // value is one of the two below
extern NSString *const kDUDiscBlankFastKey;   // e.g. "fast" (quick blank)
extern NSString *const kDUDiscBlankAllKey;    // e.g. "all" (full blank)

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

// Create an empty disk image file of the requested format and size.
// "raw" truncates a sparse file; other formats go through qemu-img create.
// Absent method => the backend cannot create blank images; the menu gates
// the item on respondsToSelector.
- (void)createBlankImageAtPath:(NSString *)path
                           size:(unsigned long long)bytes
                         format:(NSString *)format
                       progress:(void (^)(double progress,
                                          NSString *message))progress
                     completion:(void (^)(NSError *error))completion;

// Build a disk image whose filesystem carries the contents of a folder: the
// backend creates a blank image, formats and mounts it, copies the folder
// tree in and unmounts. Absent method => the backend cannot image folders;
// the menu gates the item on respondsToSelector.
- (void)createImageFromFolder:(NSString *)folderPath
                  destination:(NSString *)path
                  filesystem:(NSString *)filesystem
                    progress:(void (^)(double progress,
                                       NSString *message))progress
                  completion:(void (^)(NSError *error))completion;

// Convert a disk-image file into another format (LIBRARIES.md section 3:
// qemu-img out of process). Options:
//   @"path"   destination file; must not exist yet
//   @"format" target identifier from -imageCreationFormats
// Absent method => the backend cannot convert; UI gates on
// canConvertImage which backends set only when they implement this.
- (void)convertImage:(DUStorageObject *)image
             options:(NSDictionary *)options
            progress:(void (^)(double progress, NSString *message))progress
          completion:(void (^)(NSError *error))completion;

// Resize a disk-image file by a signed byte delta. Options:
//   @"deltaBytes" NSNumber (long long, may be negative)
// Absent method => cannot resize; UI gates on canResizeImage.
- (void)resizeImage:(DUStorageObject *)image
             options:(NSDictionary *)options
            progress:(void (^)(double progress, NSString *message))progress
          completion:(void (^)(NSError *error))completion;

// Burn an image file onto the optical disc in drive. Absent method =>
// cannot burn; UI gates on canBurn which backends set only when a burning
// tool is installed and the drive has writable media.
- (void)burnImage:(DUStorageObject *)image
          toObject:(DUStorageObject *)opticalDrive
          progress:(void (^)(double progress, NSString *message))progress
         completion:(void (^)(NSError *error))completion;

// Blank (erase) a rewritable optical disc in the drive so it can be
// reused. options carries the method under kDUDiscBlankMethodKey; when
// absent backends use the fast blank. Absent method => cannot blank; UI
// gates on canBlankDisc which backends set only for optical drives with a
// burning tool installed and media present.
- (void)blankOpticalDisc:(DUStorageObject *)opticalDrive
                 options:(NSDictionary *)options
                progress:(void (^)(double progress, NSString *message))progress
              completion:(void (^)(NSError *error))completion;

// Verify a burned optical disc by reading its data back and comparing it
// against the source image file. Absent method => cannot verify discs; UI
// gates on canVerifyDisc which backends set only for optical drives with
// media present.
- (void)verifyDisc:(DUStorageObject *)opticalDrive
       againstImage:(DUStorageObject *)image
           progress:(void (^)(double progress, NSString *message))progress
         completion:(void (^)(NSError *error))completion;

// Repair permissions of every user's home directory so all files there
// belong to the owning user (chown -R + chmod -R). Absent method => the
// backend has no repair-permissions verb; the UI gates the button on
// canRepairPermissions which backends set only when they implement this.
- (void)repairHomePermissionsWithProgress:(void (^)(double progress,
                                                    NSString *message))progress
                                completion:(void (^)(NSError *error))completion;

// Mount a disk-image file the user opened from disk (File > Open Disk Image),
// attaching it through the platform's loop/vnode device and returning the
// mount point. Absent method => the backend cannot open image files; the menu
// gates the item on respondsToSelector.
- (void)mountFileImageAtPath:(NSString *)path
                  completion:(void (^)(NSError *error,
                                       NSString *mountPoint))completion;

// The command-line tools this backend relies on, used by the startup
// availability check (DUApplicationDelegate) to warn the user about missing
// helpers before the app runs with reduced functionality. Absent method =>
// no tool check for this backend.
- (NSArray<NSString *> *)expectedToolNames;

@end
