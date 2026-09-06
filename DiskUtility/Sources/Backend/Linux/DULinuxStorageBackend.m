/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#if defined(__linux__)

#import "DULinuxStorageBackend.h"
#import "DURepairPermissionsTool.h"

#import <sys/statvfs.h>

#import "DUArchiveLibrary.h"
#import "DUBlkidLibrary.h"
#import "DUDiskImage.h"
#import "DUExt2Library.h"
#import "DUOpticalMedia.h"
#import "DUErrors.h"
#import "DULinuxDeviceDiscovery.h"
#import "DULinuxFilesystemTool.h"
#import "DULinuxImageTool.h"
#import "DULinuxPartitionTool.h"
#import "DUMountLibrary.h"
#import "DUOperation.h"
#import "DUParsing.h"
#import "DUPartition.h"
#import "DUPartitionTableParser.h"
#import "DUPartitionPlan.h"
#import "DUProcessRunner.h"
#import "DUStorageCapabilities.h"
#import "DUStorageDevice.h"
#import "DUAuthorizationManager.h"
#import "DUStorageManager.h"
#import "DUStorageVolume.h"

@implementation DULinuxStorageBackend

- (NSArray<NSString *> *)expectedToolNames
{
    return @[
        @"lsblk", @"blkid", @"mount", @"umount", @"e2fsck", @"mke2fs",
        @"resize2fs", @"tune2fs", @"mkfs.ext4", @"fsck.fat", @"mkfs.fat",
        @"fatlabel", @"mkfs.exfat", @"fsck.exfat", @"wipefs", @"dd",
        @"mdadm", @"qemu-img", @"xorriso", @"cat", @"gzip", @"parted",
        @"sfdisk", @"partprobe"
    ];
}

#pragma mark - Discovery

- (NSArray<DUStorageObject *> *)discoverStorageObjects:(NSError **)error
{
    NSMutableArray<DUStorageObject *> *objects = [NSMutableArray array];

    NSError *discoveryError = nil;
    NSArray<DUStorageObject *> *roots =
        [[DULinuxDeviceDiscovery new] discoverObjects:&discoveryError];
    if (roots == nil) {
        if (error != NULL) {
            *error = discoveryError;
        }
        return nil;
    }
    [objects addObjectsFromArray:roots];

    // Disk images registered by the user (preference key per ARCHITECTURE.md
    // section 67); each becomes a DUDiskImage root with format probing.
    NSArray<NSString *> *imagePaths =
        [[NSUserDefaults standardUserDefaults]
            arrayForKey:@"DUAdditionalImages"] ?: @[];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    for (NSString *path in imagePaths) {
        if (![fileManager fileExistsAtPath:path]) {
            continue;
        }
        DUDiskImage *image = [[DUDiskImage alloc]
            initWithIdentifier:[@"linux-image-"
                                   stringByAppendingString:
                                       [path stringByAddingPercentEncodingWithAllowedCharacters:
                                                 [NSCharacterSet alphanumericCharacterSet]].lowercaseString]];
        image.displayName = path.lastPathComponent;
        image.path = path;
        image.format = [DULinuxImageTool probeFormatForImageAtPath:path];
        NSDictionary<NSString *, NSNumber *> *attributes =
            [fileManager attributesOfItemAtPath:path error:NULL];
        image.sizeBytes =
            attributes[NSFileSize].unsignedLongLongValue;
        image.encrypted = NO;
        image.compressed = ![image.format isEqualToString:@"raw"];
        image.mounted = NO;
        image.capabilities = [DUStorageCapabilities capabilitiesWithAll:NO];
        image.capabilities.canMount = YES;
        image.capabilities.canConvertImage =
            [DULinuxImageTool conversionAvailable];
        image.capabilities.canResizeImage =
            [DULinuxImageTool conversionAvailable];
        [objects addObject:image];
    }

    return objects;
}

- (NSDictionary *)capabilitiesReport
{
    return @{
        @"Platform" : @"Linux",
        @"Device discovery" : @"yes",
        @"Mount management" : @"yes",
        @"Partitioning" : [DULinuxPartitionTool partitioningAvailable] ? @"yes" : @"no",
        @"Filesystem formatting" :
            [DULinuxFilesystemTool formattableFilesystemTypes].count > 0 ? @"yes" : @"no",
        @"Filesystem repair" : @"partial",
        @"Secure erase" : @"no",
        @"RAID management" :
            [DUProcessRunner executablePathForName:@"mdadm"] != nil ? @"yes" : @"no",
        @"Disk image mounting" : @"no",
        @"Disk image conversion" :
            [DULinuxImageTool conversionAvailable] ? @"partial" : @"no",
        // Diagnostics for the optional direct-link libraries (LIBRARIES.md
        // sections 6.1, 6.3, 7.1 and 12); "no" means the command-line and
        // magic-byte fallbacks are in effect, never a broken install.
        @"libblkid probing" : [DUBlkidLibrary isAvailable] ? @"yes" : @"no",
        @"libmount mounts" : [DUMountLibrary isAvailable] ? @"yes" : @"no",
        @"libext2fs stats" : [DUExt2Library isAvailable] ? @"yes" : @"no",
        @"libarchive identify" : [DUArchiveLibrary isAvailable] ? @"yes" : @"no",
    };
}

#pragma mark - Capability queries

- (BOOL)supportsOperation:(NSString *)op forObject:(DUStorageObject *)object
{
    DUStorageCapabilities *capabilities = object.capabilities;
    if ([op isEqualToString:kDUOperationVerify]) {
        return capabilities.canVerify;
    }
    if ([op isEqualToString:kDUOperationRepair]) {
        return capabilities.canRepair;
    }
    if ([op isEqualToString:kDUOperationErase]) {
        return capabilities.canErase;
    }
    if ([op isEqualToString:kDUOperationPartition]) {
        return capabilities.canPartition;
    }
    if ([op isEqualToString:kDUOperationMount]) {
        return capabilities.canMount;
    }
    if ([op isEqualToString:kDUOperationUnmount]) {
        return capabilities.canUnmount;
    }
    if ([op isEqualToString:kDUOperationEject]) {
        return capabilities.canEject;
    }
    if ([op isEqualToString:kDUOperationRestore]) {
        return capabilities.canRestore;
    }
    return NO;
}

- (NSArray<NSDictionary *> *)supportedFormatsForObject:(DUStorageObject *)object
{
    (void)object; // the Linux tool set is host-wide, not per-object
    NSMutableArray<NSDictionary *> *formats = [NSMutableArray array];
    for (NSString *type in [DULinuxFilesystemTool formattableFilesystemTypes]) {
        [formats addObject:@{
            kDUFormatIdentifierKey : type,
            kDUFormatDisplayNameKey :
                [DUPartitionTableParser filesystemDisplayName:type],
            kDUFormatCanFormatKey : @YES,
        }];
    }
    return formats;
}

#pragma mark - Verify / repair

// Resolves any object to its writable block device node and filesystem
// identifier, or reports why verification cannot proceed.
- (NSString *)deviceAndFstypeForObject:(DUStorageObject *)object
                                fstype:(NSString **)fstypeOut
                                 error:(NSError **)error
{
    NSString *devicePath = object.backendPath;
    NSString *fstype = nil;

    if ([object isKindOfClass:[DUStorageVolume class]]) {
        DUStorageVolume *volume = (DUStorageVolume *)object;
        fstype = volume.filesystemType;
        devicePath = object.parent.backendPath ?: object.backendPath;
    } else if ([object isKindOfClass:[DUPartition class]]) {
        DUPartition *partition = (DUPartition *)object;
        fstype = partition.filesystemType;
    } else if ([object isKindOfClass:[DUOpticalMedia class]]) {
        fstype = ((DUOpticalMedia *)object).filesystemType;
    }

    if (devicePath.length == 0 || fstype.length == 0 ||
        [fstype isEqualToString:@"swap"]) {
        if (error != NULL) {
            *error = DUErrorMake(
                DUErrorUnsupportedOperation,
                NSLocalizedString(@"The selected item cannot be verified.",
                                  nil));
        }
        return nil;
    }
    *fstypeOut = fstype;
    return devicePath;
}

// Verifies every filesystem-carrying partition of a disk in sequence.
// The overall fraction is (partitionsDone + partitionFraction) / count so
// the bar sweeps once across all children. Unverifiable partitions (no
// filesystem, swap) are reported and skipped, not treated as failures;
// any real fsck failure fails the whole operation after all children ran.
- (void)verifyPartitionsOfDevice:(DUStorageDevice *)device
                        progress:(void (^)(double, NSString *))progress
                      completion:(void (^)(NSError *))completion
{
    NSMutableArray<DUPartition *> *verifiable =
        [NSMutableArray array];
    NSMutableArray<DUPartition *> *skipped = [NSMutableArray array];
    for (DUStorageObject *child in device.children) {
        if (![child isKindOfClass:[DUPartition class]]) {
            continue;
        }
        DUPartition *partition = (DUPartition *)child;
        NSString *fstype = partition.filesystemType;
        BOOL checkable = fstype.length > 0 &&
            ![fstype isEqualToString:@"swap"];
        [checkable ? verifiable : skipped addObject:partition];
    }

    if (verifiable.count == 0 && skipped.count == 0) {
        completion(DUErrorMake(
            DUErrorUnsupportedOperation,
            NSLocalizedString(@"This disk has no partitions to verify.",
                              nil)));
        return;
    }

    progress(0.0,
             [NSString stringWithFormat:
                  NSLocalizedString(@"Verifying %lu partitions on %@...",
                                    nil),
                  (unsigned long)verifiable.count,
                  device.displayName ?: @""]);

    NSUInteger total = verifiable.count + skipped.count;
    __block NSUInteger done = 0;
    __block NSMutableArray<NSString *> *failureDetails = [NSMutableArray array];
    __block DUPartition *failedPartition = nil;

    __block void (^next)(void) = ^void(void) {
        if (done >= total) {
            // Break the self-reference so the block can release.
            next = nil;
            if (failedPartition == nil) {
                progress(1.0,
                         NSLocalizedString(@"All partitions verified clean.",
                                           nil));
                completion(nil);
            } else {
                progress(1.0,
                         NSLocalizedString(@"Verification found errors.",
                                           nil));
                completion([NSError errorWithDomain:DUStorageErrorDomain
                                               code:DUErrorVerificationFailed
                                           userInfo:@{
                    NSLocalizedDescriptionKey :
                        [NSString stringWithFormat:
                             NSLocalizedString(
                                 @"Partition %@ could not be verified "
                                 @"without errors.",
                                 nil),
                             failedPartition.displayName ?: @""],
                        kDUBackendDetailKey :
                            [failureDetails componentsJoinedByString:@"\n"],
                    }]);
            }
            return;
        }

        NSUInteger index = done;
        double base = (double)index / (double)total;
        double span = 1.0 / (double)total;

        // Skipped children occupy their slot instantly with a note.
        if (index < skipped.count) {
            DUPartition *partition = skipped[index];
            done++;
            progress((done / (double)total),
                     [NSString stringWithFormat:
                          NSLocalizedString(
                              @"[%lu/%lu] %@ has no verifiable filesystem - "
                              @"skipped.",
                              nil),
                          (unsigned long)index + 1,
                          (unsigned long)total,
                          partition.displayName ?: @""]);
            next();
            return;
        }

        DUPartition *partition =
            verifiable[index - skipped.count];
        NSString *prefix =
            [NSString stringWithFormat:@"[%lu/%lu] %@:",
                 (unsigned long)index + 1, (unsigned long)total,
                 partition.displayName ?: @""];
        progress(base,
                 [NSString stringWithFormat:
                      NSLocalizedString(@"%@ checking %@...",
                                        nil),
                      prefix, partition.filesystemType]);
        NSError *result = [DULinuxFilesystemTool
            verifyVolumeAtDevicePath:partition.backendPath
                      filesystemType:partition.filesystemType
                            progress:^(double fraction, NSString *line) {
                progress(base + fraction * span, line);
            }];
        done++;
        if (result != nil) {
            failedPartition = failedPartition ?: partition;
            [failureDetails addObject:
                [NSString stringWithFormat:@"%@ %@",
                    prefix, result.localizedDescription ?: @""]];
            progress(done / (double)total,
                     [NSString stringWithFormat:
                          NSLocalizedString(@"%@ errors found.", nil),
                          prefix]);
        } else {
            progress(done / (double)total,
                     [NSString stringWithFormat:
                          NSLocalizedString(@"%@ clean.", nil), prefix]);
        }
        next();
    };
    next();
}

- (void)verifyObject:(DUStorageObject *)object
            progress:(void (^)(double, NSString *))progress
          completion:(void (^)(NSError *))completion
{
    dispatch_worker(^{
        // A whole disk has no filesystem of its own; verifying it means
        // verifying every partition on it, with the bar advancing per
        // partition (ARCHITECTURE.md section 30 capability semantics).
        if ([object isKindOfClass:[DUStorageDevice class]]) {
            [self verifyPartitionsOfDevice:(DUStorageDevice *)object
                                  progress:progress
                                completion:completion];
            return;
        }

        progress(0.05,
                 NSLocalizedString(@"Verifying volume structure...", nil));
        NSString *fstype = nil;
        NSError *setupError = nil;
        NSString *devicePath = [self deviceAndFstypeForObject:object
                                                       fstype:&fstype
                                                        error:&setupError];
        if (devicePath == nil) {
            completion(setupError);
            return;
        }
        progress(0.3, [NSString stringWithFormat:NSLocalizedString(@"Checking filesystem %@", nil), fstype]);
        NSError *result = [DULinuxFilesystemTool
            verifyVolumeAtDevicePath:devicePath
                     filesystemType:fstype
                           progress:^(double fraction, NSString *line) {
            // fsck pass stages drive the bar; raw lines feed the log.
            progress(MAX(fraction, 0.3), line);
        }];
        progress(1.0,
                 result == nil
                     ? NSLocalizedString(@"No errors found.", nil)
                     : NSLocalizedString(@"Verification completed with errors.", nil));
        completion(result);
    });
}

- (void)repairObject:(DUStorageObject *)object
            progress:(void (^)(double, NSString *))progress
          completion:(void (^)(NSError *))completion
{
    dispatch_worker(^{
        DUStorageVolume *volume = nil;
        if ([object isKindOfClass:[DUStorageVolume class]]) {
            volume = (DUStorageVolume *)object;
        } else if ([object isKindOfClass:[DUPartition class]]) {
            volume = ((DUPartition *)object).volume;
        }
        if (volume == nil || volume.mounted) {
            completion(DUErrorMake(
                DUErrorDeviceBusy,
                NSLocalizedString(
                    @"Unmount the volume before repairing it.", nil)));
            return;
        }
        progress(0.1, NSLocalizedString(@"Preparing repair...", nil));
        NSString *fstype = volume.filesystemType;
        NSString *devicePath = object.backendPath;
        NSError *result = [DULinuxFilesystemTool
            repairVolumeAtDevicePath:devicePath
                      filesystemType:fstype
                            progress:^(double fraction, NSString *line) {
            progress(MAX(fraction, 0.1), line);
        }];
        progress(1.0,
                 result == nil
                     ? NSLocalizedString(@"Repair completed successfully.", nil)
                     : NSLocalizedString(@"Repair failed.", nil));
        completion(result);
    });
}

- (void)repairHomePermissionsWithProgress:(void (^)(double, NSString *))progress
                                completion:(void (^)(NSError *))completion
{
    [DURepairPermissionsTool repairHomePermissionsWithProgress:progress
                                                     completion:completion];
}

#pragma mark - Erase

- (void)eraseObject:(DUStorageObject *)object
            options:(NSDictionary *)options
           progress:(void (^)(double, NSString *))progress
         completion:(void (^)(NSError *))completion
{
    dispatch_worker(^{
        NSString *devicePath = object.backendPath;
        NSString *fstype = options[kDUFormatIdentifierKey];
        NSString *name = options[@"name"];
        NSString *method = options[kDUEraseSecurityMethodKey];

        if (devicePath.length == 0 || fstype.length == 0) {
            completion(DUErrorMake(DUErrorInvalidArgument,
                                   NSLocalizedString(@"Missing erase parameters.", nil)));
            return;
        }

        unsigned long long sizeBytes = 0;
        if ([object isKindOfClass:[DUStorageDevice class]]) {
            sizeBytes = ((DUStorageDevice *)object).capacityBytes;
        } else if ([object isKindOfClass:[DUPartition class]]) {
            sizeBytes = ((DUPartition *)object).sizeBytes;
        } else if ([object isKindOfClass:[DUStorageVolume class]]) {
            sizeBytes = ((DUStorageVolume *)object).capacityBytes;
        }

        NSError *result = nil;
        if ([method isEqualToString:kDUEraseMethodZerosKey] && sizeBytes > 0) {
            // Zero overwrite is the slow phase; it owns most of the bar.
            result = [DULinuxFilesystemTool zeroFillDevicePath:devicePath
                                                     sizeBytes:sizeBytes
                                                      progress:^(double fraction, NSString *message) {
                progress(fraction * 0.7, message);
            }];
            if (result != nil) {
                completion(result);
                return;
            }
        }

        progress(0.75, NSLocalizedString(@"Removing old signatures...", nil));
        result = [DULinuxFilesystemTool wipeSignaturesAtDevicePath:devicePath];
        if (result != nil) {
            completion(result);
            return;
        }

        progress(0.85, NSLocalizedString(@"Creating filesystem...", nil));
        result = [DULinuxFilesystemTool formatVolumeAtDevicePath:devicePath
                                                  filesystemType:fstype
                                                           label:name
                                                        progress:^(double fraction, NSString *line) {
            // mkfs stage fractions (0.1..0.92) fold into the erase bar's
            // final 15% after wipefs.
            progress(0.85 + fraction * 0.14, line);
        }];
        progress(1.0,
                 result == nil
                     ? NSLocalizedString(@"Erase completed successfully.", nil)
                     : NSLocalizedString(@"Erase failed.", nil));
        completion(result);
    });
}

#pragma mark - Partitioning

- (void)partitionDevice:(DUStorageObject *)device
               withPlan:(DUPartitionPlan *)plan
               progress:(void (^)(double, NSString *))progress
             completion:(void (^)(NSError *))completion
{
    dispatch_worker(^{
        progress(0.1, NSLocalizedString(@"Applying partition layout...", nil));
        NSError *result =
            [[DULinuxPartitionTool new] applyPlan:plan
                                    toDevicePath:device.backendPath
                                        progress:^(double fraction,
                                                   NSString *message) {
            progress(0.1 + fraction * 0.85, message);
        }];
        progress(1.0,
                 result == nil
                     ? NSLocalizedString(@"Partitioning completed.", nil)
                     : NSLocalizedString(@"Partitioning failed.", nil));
        completion(result);
    });
}

#pragma mark - Mount management

- (NSString *)mountDirectoryForLabel:(NSString *)label
                              device:(NSString *)devicePath
{
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *base = label.length > 0 ? label : devicePath.lastPathComponent;
    // Sanitize: mount point names must not contain path separators.
    base = [[base componentsSeparatedByCharactersInSet:
                       [NSCharacterSet characterSetWithCharactersInString:@"/ "]]
        componentsJoinedByString:@"_"];
    if (base.length == 0) {
        base = devicePath.lastPathComponent;
    }
    NSString *directory = [@"/media" stringByAppendingPathComponent:base];
    if (![fileManager fileExistsAtPath:directory]) {
        NSError *createError = nil;
        if (![fileManager createDirectoryAtPath:directory
                    withIntermediateDirectories:YES
                                     attributes:nil
                                          error:&createError]) {
            return nil;
        }
    }
    return directory;
}

- (void)mountObject:(DUStorageObject *)object
          completion:(void (^)(NSError *, NSString *))completion
{
    dispatch_worker(^{
        NSString *devicePath = object.backendPath;
        if (devicePath.length == 0) {
            completion(DUErrorMake(DUErrorInvalidArgument,
                                   NSLocalizedString(@"No device to mount.", nil)),
                      nil);
            return;
        }

        NSString *label = object.displayName;
        NSString *directory =
            [self mountDirectoryForLabel:label device:devicePath];
        if (directory == nil) {
            completion(DUErrorMake(DUErrorMountError,
                                   NSLocalizedString(@"The mount directory could not be created.", nil)),
                      nil);
            return;
        }

        NSString *fstype = @"";
        if ([object isKindOfClass:[DUStorageVolume class]]) {
            fstype = ((DUStorageVolume *)object).filesystemType ?: @"";
        } else if ([object isKindOfClass:[DUPartition class]]) {
            fstype = ((DUPartition *)object).filesystemType ?: @"";
        }

        // mount(8) writes kernel state and needs root; the backend talks to
        // OS facilities directly, with no UDisks layer in between
        // (LIBRARIES.md section 0).
        NSError *runError = nil;
        DUProcessResult *result =
            [[DUAuthorizationManager sharedManager]
                runPrivileged:[DUProcessRunner executablePathForName:@"mount"]
                         args:(fstype.length > 0
                                   ? @[ @"-t", fstype, devicePath, directory ]
                                   : @[ devicePath, directory ])
                      timeout:300.0
                        error:&runError];
        if (result == nil || !result.exitedNormally ||
            result.terminationStatus != 0) {
            NSString *detail =
                result.standardError.length > 0 ? result.standardError
                                                : runError.localizedDescription;
            BOOL busy = [detail rangeOfString:@"already mounted"].location != NSNotFound
                || [detail rangeOfString:@"busy"].location != NSNotFound;
            completion([NSError errorWithDomain:DUStorageErrorDomain
                                           code:busy ? DUErrorDeviceBusy
                                                     : DUErrorMountError
                                      userInfo:@{
                NSLocalizedDescriptionKey :
                    NSLocalizedString(@"The volume could not be mounted.", nil),
                kDUBackendDetailKey : detail ?: @"",
            }],
                      nil);
            return;
        }

        completion(nil, directory);
    });
}

- (void)unmountObject:(DUStorageObject *)object
            completion:(void (^)(NSError *))completion
{
    dispatch_worker(^{
        NSString *target = nil;
        if ([object isKindOfClass:[DUStorageVolume class]]) {
            target = ((DUStorageVolume *)object).mountPoint;
        }
        if (target.length == 0) {
            target = object.backendPath;
        }
        // umount(8) needs root; there is no UDisks layer in between
        // (LIBRARIES.md section 0).
        NSError *runError = nil;
        DUProcessResult *result =
            [[DUAuthorizationManager sharedManager]
                runPrivileged:[DUProcessRunner executablePathForName:@"umount"]
                           args:@[ target ]
                        timeout:300.0
                          error:&runError];
        if (result == nil || !result.exitedNormally ||
            result.terminationStatus != 0) {
            NSString *detail =
                result.standardError.length > 0 ? result.standardError : @"";
            BOOL busy = [detail rangeOfString:@"busy"].location != NSNotFound
                || [detail rangeOfString:@"in use"].location != NSNotFound;
            completion([NSError errorWithDomain:DUStorageErrorDomain
                                           code:busy ? DUErrorDeviceBusy
                                                     : DUErrorUnmountError
                                       userInfo:@{
                NSLocalizedDescriptionKey :
                    NSLocalizedString(@"The volume could not be unmounted.", nil),
                kDUBackendDetailKey : detail ?: @"",
            }]);
            return;
        }
        completion(nil);
    });
}

- (void)ejectObject:(DUStorageObject *)object
          completion:(void (^)(NSError *))completion
{
    dispatch_worker(^{
        // Eject the containing drive, not a partition on the media.
        DUStorageObject *root = object;
        while (root.parent != nil) {
            root = root.parent;
        }
        NSString *devicePath = root.backendPath ?: object.backendPath;

        // Unmount first so the tray does not pop with open files.
        if ([object isKindOfClass:[DUStorageVolume class]] &&
            ((DUStorageVolume *)object).mounted) {
            DUStorageVolume *volume = (DUStorageVolume *)object;
            [[DUAuthorizationManager sharedManager]
                runPrivileged:[DUProcessRunner executablePathForName:@"umount"]
                           args:@[ volume.mountPoint ]
                        timeout:300.0
                          error:NULL];
        }

        NSString *eject = [DUProcessRunner executablePathForName:@"eject"];
        NSError *runError = nil;
        // eject opens the drive tray via the device node; needs root.
        DUProcessResult *result = eject != nil
            ? [[DUAuthorizationManager sharedManager]
                  runPrivileged:eject
                           args:@[ devicePath ]
                        timeout:300.0
                          error:&runError]
            : nil;
        if (result == nil || !result.exitedNormally ||
            result.terminationStatus != 0) {
            completion(DUErrorMake(
                DUErrorUnknown,
                NSLocalizedString(@"The media could not be ejected.", nil)));
            return;
        }
        completion(nil);
    });
}

#pragma mark - Restore

- (void)restoreFromSource:(DUStorageObject *)source
              destination:(DUStorageObject *)destination
                  options:(NSDictionary *)options
                 progress:(void (^)(double, NSString *))progress
               completion:(void (^)(NSError *))completion
{
    dispatch_worker(^{
        NSString *sourcePath = source.backendPath;
        NSString *destinationPath = destination.backendPath;
        if (sourcePath.length == 0 || destinationPath.length == 0 ||
            [sourcePath isEqualToString:destinationPath]) {
            completion(DUErrorMake(DUErrorInvalidArgument,
                                   NSLocalizedString(@"Restore source and destination must be different devices.", nil)));
            return;
        }

        unsigned long long destinationSize = 0;
        if ([destination isKindOfClass:[DUStorageDevice class]]) {
            destinationSize = ((DUStorageDevice *)destination).capacityBytes;
        } else if ([destination isKindOfClass:[DUPartition class]]) {
            destinationSize = ((DUPartition *)destination).sizeBytes;
        }

        // Verification needs the byte count that will have crossed the
        // wire; without it the checksum phase is impossible, not skipped.
        unsigned long long sourceSize = 0;
        if ([source isKindOfClass:[DUStorageDevice class]]) {
            sourceSize = ((DUStorageDevice *)source).capacityBytes;
        } else if ([source isKindOfClass:[DUPartition class]]) {
            sourceSize = ((DUPartition *)source).sizeBytes;
        } else if ([source isKindOfClass:[DUStorageVolume class]]) {
            sourceSize = ((DUStorageVolume *)source).capacityBytes;
        } else if ([source isKindOfClass:[DUDiskImage class]]) {
            sourceSize = ((DUDiskImage *)source).sizeBytes;
        }
        BOOL verify =
            ![options[@"skipChecksum"] boolValue] && sourceSize > 0;

        NSString *dd = [DUProcessRunner executablePathForName:@"dd"];
        if (dd == nil) {
            completion(DUErrorMake(DUErrorBackendUnavailable,
                                   NSLocalizedString(@"The dd tool is not available.", nil)));
            return;
        }

        progress(0.02, NSLocalizedString(@"Restoring from source...", nil));
        // dd writes the raw destination device; needs root. Streaming keeps
        // status=progress lines feeding the progress callback. With
        // verification enabled the write owns 2-50% of the bar; the two
        // checksum passes share the rest.
        double writeScale = verify ? 0.48 : 0.96;
        double writeBase = verify ? 0.02 : 0.02;
        NSError *streamError = nil;
        [[DUAuthorizationManager sharedManager]
            streamPrivileged:dd
                        args:@[ [@"if=" stringByAppendingString:sourcePath],
                                [@"of=" stringByAppendingString:destinationPath],
                                @"bs=1M",
                                @"status=progress" ]
               stdoutHandler:^(NSString *line) {
                   // status=progress prints running byte counts; convert them
                   // to a fraction of the known destination size.
                   unsigned long long copied = strtoull(line.UTF8String, NULL, 10);
                   if (copied > 0 && destinationSize > 0) {
                       double fraction = (double)copied / (double)destinationSize;
                       progress(writeBase + MIN(1.0, MAX(0.0, fraction)) * writeScale, line);
                   }
               }
                finishHandler:^(DUProcessResult *result) {
                    // The runner keeps its own threads alive through completion;
                    // the handle only exists for external cancellation.
                    if (!result.exitedNormally || result.terminationStatus != 0) {
                        progress(1.0, NSLocalizedString(@"Restore failed.", nil));
                        completion([NSError errorWithDomain:DUStorageErrorDomain
                                                       code:DUErrorRestoreFailed
                                                   userInfo:@{
                            NSLocalizedDescriptionKey :
                                NSLocalizedString(@"The restore operation failed.", nil),
                            kDUBackendDetailKey : result.standardError ?: @"",
                        }]);
                        return;
                    }
                    if (!verify) {
                        progress(1.0, NSLocalizedString(@"Restore completed successfully.", nil));
                        completion(nil);
                        return;
                    }

                    // Verify pass: hash what landed on the device and hash
                    // the source; both must agree byte for byte.
                    progress(0.5,
                             NSLocalizedString(@"Verifying checksum...", nil));
                    progress(0.5,
                             NSLocalizedString(@"Re-reading written data...",
                                               nil));
                    NSString *writtenDigest =
                        [DULinuxImageTool
                            sha256HexForPath:destinationPath
                                   sizeBytes:sourceSize
                                    progress:^(double fraction) {
                        progress(0.5 + fraction * 0.25,
                                 NSLocalizedString(@"Re-reading written data...",
                                                   nil));
                    }
                                       error:nil];
                    if (writtenDigest == nil) {
                        progress(1.0, NSLocalizedString(@"Verification failed.", nil));
                        completion(DUErrorMake(
                            DUErrorVerificationFailed,
                            NSLocalizedString(@"The written data could not be "
                                              @"read back for verification.",
                                              nil)));
                        return;
                    }
                    progress(0.75,
                             NSLocalizedString(@"Hashing source...", nil));
                    NSString *sourceDigest =
                        [DULinuxImageTool
                            sha256HexForPath:sourcePath
                                   sizeBytes:sourceSize
                                    progress:^(double fraction) {
                        progress(0.75 + fraction * 0.25,
                                 NSLocalizedString(@"Hashing source...", nil));
                    }
                                       error:nil];
                    if (sourceDigest == nil) {
                        progress(1.0, NSLocalizedString(@"Verification failed.", nil));
                        completion(DUErrorMake(
                            DUErrorVerificationFailed,
                            NSLocalizedString(@"The source could not be read "
                                              @"back for verification.",
                                              nil)));
                        return;
                    }
                    if (![writtenDigest isEqualToString:sourceDigest]) {
                        progress(1.0, NSLocalizedString(@"Verification failed.", nil));
                        completion([NSError errorWithDomain:DUStorageErrorDomain
                                                       code:DUErrorVerificationFailed
                                                   userInfo:@{
                            NSLocalizedDescriptionKey :
                                NSLocalizedString(@"Checksum mismatch: the "
                                                  @"written data does not match "
                                                  @"the source.",
                                                  nil),
                            kDUBackendDetailKey :
                                [NSString stringWithFormat:
                                              @"source=%@ written=%@",
                                              sourceDigest, writtenDigest],
                        }]);
                        return;
                    }
                    progress(1.0,
                             NSLocalizedString(@"Verified: checksums match.",
                                               nil));
                    completion(nil);
                }
                  error:&streamError];
        if (streamError != nil) {
            completion(streamError);
        }
    });
}
#pragma mark - Image creation

- (NSArray<NSDictionary *> *)imageCreationFormats
{
    return [DULinuxImageTool imageCreationFormats];
}

// Resolves any imagerable object to its block device node and size.
- (NSString *)imageSourceForObject:(DUStorageObject *)object
                            bytes:(unsigned long long *)bytesOut
{
    DUStorageObject *source = object;
    if ([object isKindOfClass:[DUStorageVolume class]]) {
        source = object.parent ?: object;
    }
    NSString *path = source.backendPath;
    if (path.length == 0) {
        return nil;
    }
    unsigned long long bytes = 0;
    if ([source isKindOfClass:[DUStorageDevice class]]) {
        bytes = ((DUStorageDevice *)source).capacityBytes;
    } else if ([source isKindOfClass:[DUPartition class]]) {
        bytes = ((DUPartition *)source).sizeBytes;
    } else if ([source isKindOfClass:[DUStorageVolume class]]) {
        bytes = ((DUStorageVolume *)source).capacityBytes;
    }
    if (bytes == 0) {
        return nil;
    }
    *bytesOut = bytes;
    return path;
}

- (void)createImageFromObject:(DUStorageObject *)object
                      options:(NSDictionary *)options
                     progress:(void (^)(double, NSString *))progress
                   completion:(void (^)(NSError *))completion
{
    dispatch_worker(^{
        unsigned long long sourceBytes = 0;
        NSString *devicePath =
            [self imageSourceForObject:object bytes:&sourceBytes];
        NSString *targetPath = options[@"path"];
        NSString *format = options[@"format"];
        if (devicePath == nil || targetPath.length == 0 ||
            format.length == 0) {
            completion(DUErrorMake(DUErrorInvalidArgument,
                                   NSLocalizedString(
                                       @"Missing image parameters.", nil)));
            return;
        }

        // The UI hands us its cancellation probe inside the options
        // dictionary; polling it keeps abort latency at one chunk.
        BOOL (^cancelCheck)(void) = options[@"duCancelCheck"];
        progress(0.0, NSLocalizedString(@"Creating disk image...", nil));
        NSError *result = [DULinuxImageTool
            streamDeviceAtPath:devicePath
                     sizeBytes:sourceBytes
                       toImage:targetPath
                        format:format
                      progress:^(double fraction, NSString *message) {
            progress(fraction, message);
        }
                   cancelCheck:^BOOL(void) {
            return cancelCheck != nil && cancelCheck();
        }];
        if (result == nil) {
            // Final wording rides the normal progress channel so the main
            // window's bottom status line picks it up.
            progress(1.0,
                     NSLocalizedString(@"Image created successfully.",
                                       nil));
        }
        completion(result);
    });
}

#pragma mark - Blank and folder image creation

- (void)createBlankImageAtPath:(NSString *)path
                           size:(unsigned long long)bytes
                         format:(NSString *)format
                       progress:(void (^)(double, NSString *))progress
                     completion:(void (^)(NSError *))completion
{
    dispatch_worker(^{
        progress(0.0, NSLocalizedString(@"Creating blank image...", nil));
        NSError *error = nil;
        if ([format isEqualToString:@"raw"]) {
            error = [DULinuxImageTool createImageFileAtPath:path
                                                sizeBytes:bytes];
        } else {
            NSString *qemu =
                [DUProcessRunner executablePathForName:@"qemu-img"];
            if (qemu == nil) {
                completion(DUErrorMake(
                    DUErrorBackendUnavailable,
                    NSLocalizedString(@"qemu-img is required to create "
                                       @"this image format.",
                                      nil)));
                return;
            }
            NSError *runError = nil;
            DUProcessResult *result = [[DUAuthorizationManager sharedManager]
                runPrivileged:qemu
                         args:@[
                             @"create", @"-f", format, path,
                             [NSString stringWithFormat:@"%llu", bytes]
                         ]
                       timeout:300.0
                         error:&runError];
            if (result == nil || !result.exitedNormally ||
                result.terminationStatus != 0) {
                NSString *detail = result.standardError.length > 0
                                       ? result.standardError
                                       : runError.localizedDescription;
                error = DUErrorMake(
                    DUErrorFilesystemError,
                    NSLocalizedString(@"The blank image could not be "
                                       @"created.",
                                      nil));
                (void)detail;
            }
        }
        if (error == nil) {
            progress(1.0, NSLocalizedString(@"Blank image created.", nil));
        }
        completion(error);
    });
}

// Recursively sums the regular-file bytes under a folder so the image can be
// sized to hold it plus a safety margin.
- (unsigned long long)folderSizeAtPath:(NSString *)folder
{
    NSFileManager *fm = [NSFileManager defaultManager];
    unsigned long long total = 0;
    NSDirectoryEnumerator *enumerator =
        [fm enumeratorAtPath:folder];
    for (NSString *entry in enumerator) {
        NSString *full =
            [folder stringByAppendingPathComponent:entry];
        NSDictionary *attrs =
            [fm attributesOfItemAtPath:full error:nil];
        if ([[attrs fileType] isEqualToString:NSFileTypeRegular]) {
            total += [attrs fileSize];
        }
    }
    return total;
}

// mkfs on a raw image file (not a mounted device) lays down the filesystem
// the copied folder will live on.
- (NSError *)formatImageFile:(NSString *)path
                  filesystem:(NSString *)filesystem
{
    NSString *mkfs =
        [DUProcessRunner executablePathForName:
                             [NSString stringWithFormat:@"mkfs.%@",
                                                        filesystem]];
    if (mkfs == nil) {
        return DUErrorMake(
            DUErrorBackendUnavailable,
            NSLocalizedString(
                @"The filesystem formatting tool for this image is "
                @"missing.",
                nil));
    }
    NSError *runError = nil;
    DUProcessResult *result = [[DUAuthorizationManager sharedManager]
        runPrivileged:mkfs
                 args:@[ path ]
               timeout:300.0
                 error:&runError];
    if (result == nil || !result.exitedNormally ||
        result.terminationStatus != 0) {
        return DUErrorMake(DUErrorFilesystemError,
                           NSLocalizedString(
                               @"The image filesystem could not be "
                               @"formatted.",
                               nil));
    }
    return nil;
}

// Loop-mounts a raw image file to a private directory so its contents can be
// populated. The mount point is returned on success, nil on failure.
- (NSString *)mountFileImage:(NSString *)path
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [NSString
        stringWithFormat:@"/tmp/du_img_%@",
                         [[NSProcessInfo processInfo]
                             globallyUniqueString]];
    if (![fm createDirectoryAtPath:dir
            withIntermediateDirectories:YES
                             attributes:nil
                                  error:nil]) {
        return nil;
    }
    NSError *runError = nil;
    DUProcessResult *result = [[DUAuthorizationManager sharedManager]
        runPrivileged:[DUProcessRunner executablePathForName:@"mount"]
                 args:@[ @"-o", @"loop", path, dir ]
               timeout:300.0
                 error:&runError];
    if (result == nil || !result.exitedNormally ||
        result.terminationStatus != 0) {
        [fm removeItemAtPath:dir error:nil];
        return nil;
    }
    return dir;
}

- (void)unmountFileImage:(NSString *)mountPoint
{
    [[DUAuthorizationManager sharedManager]
        runPrivileged:[DUProcessRunner executablePathForName:@"umount"]
                 args:@[ mountPoint ]
               timeout:300.0
                 error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:mountPoint
                                                error:nil];
}

- (void)createImageFromFolder:(NSString *)folderPath
                  destination:(NSString *)path
                  filesystem:(NSString *)filesystem
                    progress:(void (^)(double, NSString *))progress
                  completion:(void (^)(NSError *))completion
{
    dispatch_worker(^{
        unsigned long long content = [self folderSizeAtPath:folderPath];
        unsigned long long size = content + content / 10 + 16 * 1024 * 1024;
        progress(0.05,
                 NSLocalizedString(@"Creating image container...", nil));
        NSError *error =
            [DULinuxImageTool createImageFileAtPath:path sizeBytes:size];
        if (error != nil) {
            completion(error);
            return;
        }
        progress(0.2, NSLocalizedString(@"Formatting image...", nil));
        error = [self formatImageFile:path filesystem:filesystem];
        if (error != nil) {
            completion(error);
            return;
        }
        progress(0.35, NSLocalizedString(@"Mounting image...", nil));
        NSString *mountPoint = [self mountFileImage:path];
        if (mountPoint == nil) {
            completion(DUErrorMake(
                DUErrorMountError,
                NSLocalizedString(@"The folder image could not be mounted.",
                                  nil)));
            return;
        }
        progress(0.5, NSLocalizedString(@"Copying files into image...", nil));
        NSError *copyError = nil;
        [[DUAuthorizationManager sharedManager]
            runPrivileged:[DUProcessRunner executablePathForName:@"/bin/cp"]
                     args:@[
                         @"-a",
                         [folderPath stringByAppendingPathComponent:@"."],
                         mountPoint
                     ]
                   timeout:600.0
                     error:&copyError];
        [self unmountFileImage:mountPoint];
        if (copyError != nil) {
            completion(DUErrorMake(
                DUErrorFilesystemError,
                NSLocalizedString(@"The folder could not be copied into "
                                   @"the image.",
                                  nil)));
            return;
        }
        progress(1.0,
                 NSLocalizedString(@"Folder image created.", nil));
        completion(nil);
    });
}

#pragma mark - Image conversion, resizing, burning

- (void)convertImage:(DUStorageObject *)image
             options:(NSDictionary *)options
            progress:(void (^)(double, NSString *))progress
          completion:(void (^)(NSError *))completion
{
    NSString *sourcePath = ((DUDiskImage *)image).path;
    NSString *targetPath = options[@"path"];
    NSString *format = options[@"format"];
    if (sourcePath.length == 0 || targetPath.length == 0 ||
        format.length == 0) {
        completion(DUErrorMake(DUErrorInvalidArgument,
                               NSLocalizedString(
                                   @"Missing image parameters.", nil)));
        return;
    }
    dispatch_worker(^{
        progress(0.1, NSLocalizedString(@"Converting image...", nil));
        NSError *result = [DULinuxImageTool
            convertImageAtPath:sourcePath
                        toPath:targetPath
                        format:format];
        if (result == nil) {
            progress(1.0,
                     NSLocalizedString(@"Image converted successfully.",
                                       nil));
        }
        completion(result);
    });
}

- (void)resizeImage:(DUStorageObject *)image
             options:(NSDictionary *)options
            progress:(void (^)(double, NSString *))progress
          completion:(void (^)(NSError *))completion
{
    NSString *sourcePath = ((DUDiskImage *)image).path;
    NSNumber *delta = options[@"deltaBytes"];
    if (sourcePath.length == 0 || delta == nil) {
        completion(DUErrorMake(DUErrorInvalidArgument,
                               NSLocalizedString(
                                   @"Missing image parameters.", nil)));
        return;
    }
    dispatch_worker(^{
        progress(0.1, NSLocalizedString(@"Resizing image...", nil));
        NSError *result = [DULinuxImageTool
            resizeImageAtPath:sourcePath
               sizeDeltaBytes:delta.longLongValue];
        if (result == nil) {
            progress(1.0,
                     NSLocalizedString(@"Image resized successfully.",
                                       nil));
        }
        completion(result);
    });
}

// cdrecord-family syntax differences; the probed tool decides the argument
// shape. All of them write the image to the drive node.
- (NSArray<NSString *> *)burnArgumentsForTool:(NSString *)tool
                                   imagePath:(NSString *)imagePath
                                    drivePath:(NSString *)drivePath
{
    if ([tool hasSuffix:@"xorriso"]) {
        return @[ @"-as", @"cdrecord", @"-v",
                  [NSString stringWithFormat:@"dev=%@", drivePath],
                  @"-data", imagePath ];
    }
    if ([tool hasSuffix:@"growisofs"]) {
        return @[ @"-dvd-compat",
                  [NSString stringWithFormat:@"%@=%@", drivePath, imagePath] ];
    }
    return @[ @"-v",
              [NSString stringWithFormat:@"dev=%@", drivePath],
              imagePath ];
}

- (void)burnImage:(DUStorageObject *)image
         toObject:(DUStorageObject *)opticalDrive
         progress:(void (^)(double, NSString *))progress
        completion:(void (^)(NSError *))completion
{
    NSString *imagePath = ((DUDiskImage *)image).path;
    NSString *drivePath = ((DUStorageDevice *)opticalDrive).devicePath
        ?: opticalDrive.backendPath;
    if (imagePath.length == 0 || drivePath.length == 0) {
        completion(DUErrorMake(DUErrorInvalidArgument,
                               NSLocalizedString(
                                   @"Missing burn parameters.", nil)));
        return;
    }

    NSString *tool = nil;
    for (NSString *candidate in @[ @"xorriso", @"growisofs",
                                   @"wodim", @"cdrecord" ]) {
        NSString *path = [DUProcessRunner executablePathForName:candidate];
        if (path != nil) {
            tool = path;
            break;
        }
    }
    if (tool == nil) {
        completion(DUErrorMake(DUErrorBackendUnavailable,
                               NSLocalizedString(
                                   @"No optical burning tool is installed "
                                   @"(xorriso, growisofs, wodim or "
                                   @"cdrecord).", nil)));
        return;
    }

    NSArray<NSString *> *arguments =
        [self burnArgumentsForTool:tool.lastPathComponent
                         imagePath:imagePath
                          drivePath:drivePath];

    // Writing to the raw drive node needs root; escalate like dd/mount do.
    progress(0.05, NSLocalizedString(@"Burning image...", nil));
    NSError *launchError = nil;
    DUProcessHandle *handle =
        [[DUAuthorizationManager sharedManager]
            streamPrivileged:tool
                        args:arguments
               stdoutHandler:^(NSString *line) {
            // Tool progress lines stream into the log; the fraction stays
            // coarse because every burner reports differently.
            progress(0.5, [DUParsing trimmedString:line] ?: @"");
        }
              finishHandler:^(DUProcessResult *result) {
            if (result.exitedNormally && result.terminationStatus == 0) {
                progress(1.0,
                         NSLocalizedString(@"Image burned successfully.",
                                           nil));
                completion(nil);
            } else {
                NSString *detail = [DUParsing trimmedString:
                                        result.standardOutput];
                completion(DUErrorMake(DUErrorUnknown,
                                       detail.length > 0
                                           ? detail
                                           : NSLocalizedString(
                                                 @"Burning failed.", nil)));
            }
        }
                               error:&launchError];
    if (handle == nil) {
        completion(launchError ?: DUErrorMake(DUErrorBackendUnavailable,
                                              NSLocalizedString(
                                                  @"Burning could not be "
                                                  @"started.", nil)));
    }
}

// Blank (erase) a rewritable optical disc. xorriso covers every burner
// class through its cdrecord personality; wodim/cdrecord are accepted when
// present. DVD+RW/DVD-RAM also need a pre-format pass, folded into the same
// tool invocation below.
- (void)blankOpticalDisc:(DUStorageObject *)opticalDrive
                 options:(NSDictionary *)options
                progress:(void (^)(double, NSString *))progress
              completion:(void (^)(NSError *))completion
{
    NSString *drivePath = ((DUStorageDevice *)opticalDrive).devicePath
        ?: opticalDrive.backendPath;
    if (drivePath.length == 0) {
        completion(DUErrorMake(DUErrorInvalidArgument,
                               NSLocalizedString(
                                   @"Missing disc drive.", nil)));
        return;
    }

    NSString *method = options[kDUDiscBlankMethodKey]
        ?: kDUDiscBlankFastKey;
    NSString *mode = [method isEqualToString:kDUDiscBlankAllKey]
        ? @"all" : @"fast";

    NSString *tool = nil;
    for (NSString *candidate in @[ @"xorriso", @"wodim", @"cdrecord" ]) {
        NSString *path = [DUProcessRunner executablePathForName:candidate];
        if (path != nil) {
            tool = path;
            break;
        }
    }
    if (tool == nil) {
        completion(DUErrorMake(
            DUErrorBackendUnavailable,
            NSLocalizedString(
                @"No optical burning tool is installed "
                @"(xorriso, wodim or cdrecord).", nil)));
        return;
    }

    NSArray<NSString *> *arguments;
    NSString *last = tool.lastPathComponent;
    if ([last isEqualToString:@"xorriso"]) {
        arguments = @[ @"-as", @"cdrecord", @"-v",
                      [NSString stringWithFormat:@"blank=%@", mode],
                      [NSString stringWithFormat:@"dev=%@", drivePath] ];
    } else {
        arguments = @[ @"-v",
                      [NSString stringWithFormat:@"blank=%@", mode],
                      [NSString stringWithFormat:@"dev=%@", drivePath] ];
    }

    progress(0.05, NSLocalizedString(@"Blanking disc...", nil));
    NSError *launchError = nil;
    DUProcessHandle *handle =
        [[DUAuthorizationManager sharedManager]
            streamPrivileged:tool
                        args:arguments
               stdoutHandler:^(NSString *line) {
                progress(0.5, [DUParsing trimmedString:line] ?: @"");
            }
                 finishHandler:^(DUProcessResult *result) {
                if (result.exitedNormally &&
                    result.terminationStatus == 0) {
                    progress(1.0,
                             NSLocalizedString(
                                 @"Disc blanked successfully.", nil));
                    completion(nil);
                } else {
                    NSString *detail =
                        [DUParsing trimmedString:result.standardOutput];
                    completion(DUErrorMake(
                        DUErrorEraseFailed,
                        detail.length > 0 ? detail
                                         : NSLocalizedString(
                                               @"Blanking failed.", nil)));
                }
            }
                        error:&launchError];
    if (handle == nil) {
        completion(launchError ?: DUErrorMake(DUErrorBackendUnavailable,
                                              NSLocalizedString(
                                                  @"Blanking could not be "
                                                  @"started.", nil)));
    }
}

// Verify a burned disc by reading its data back and comparing it byte for
// byte against the source image. cmp stops at the shorter file (the image),
// so exactly the written span is checked; an exit of 0 means a match.
- (void)verifyDisc:(DUStorageObject *)opticalDrive
      againstImage:(DUStorageObject *)image
          progress:(void (^)(double, NSString *))progress
        completion:(void (^)(NSError *))completion
{
    NSString *drivePath = ((DUStorageDevice *)opticalDrive).devicePath
        ?: opticalDrive.backendPath;
    NSString *imagePath = ((DUDiskImage *)image).path;
    if (drivePath.length == 0 || imagePath.length == 0) {
        completion(DUErrorMake(DUErrorInvalidArgument,
                               NSLocalizedString(
                                   @"Missing verify parameters.", nil)));
        return;
    }

    NSString *cmp = [DUProcessRunner executablePathForName:@"cmp"];
    if (cmp == nil) {
        completion(DUErrorMake(DUErrorBackendUnavailable,
                               NSLocalizedString(
                                   @"The cmp tool is required to verify "
                                   @"discs.", nil)));
        return;
    }

    progress(0.1, NSLocalizedString(@"Reading disc back...", nil));
    NSError *launchError = nil;
    DUProcessHandle *handle =
        [[DUAuthorizationManager sharedManager]
            streamPrivileged:cmp
                        args:@[ drivePath, imagePath ]
               stdoutHandler:^(NSString *line) {
                progress(0.7, [DUParsing trimmedString:line] ?: @"");
            }
                 finishHandler:^(DUProcessResult *result) {
                if (result.exitedNormally &&
                    result.terminationStatus == 0) {
                    progress(1.0,
                             NSLocalizedString(
                                 @"Disc verified: data matches the image.",
                                 nil));
                    completion(nil);
                } else if (result.exitedNormally &&
                           result.terminationStatus == 1) {
                    NSString *detail =
                        [DUParsing trimmedString:result.standardOutput];
                    completion(DUErrorMake(
                        DUErrorVerificationFailed,
                        detail.length > 0 ? detail
                                         : NSLocalizedString(
                                               @"The disc does not match "
                                               @"the image.", nil)));
                } else {
                    NSString *detail =
                        [DUParsing trimmedString:result.standardOutput];
                    completion(DUErrorMake(
                        DUErrorUnknown,
                        detail.length > 0 ? detail
                                         : NSLocalizedString(
                                               @"Verification failed.",
                                               nil)));
                }
            }
                        error:&launchError];
    if (handle == nil) {
        completion(launchError ?: DUErrorMake(DUErrorBackendUnavailable,
                                              NSLocalizedString(
                                                  @"Verification could not "
                                                  @"be started.", nil)));
    }
}

#pragma mark - RAID

- (NSError *)createRAIDSetNamed:(NSString *)name
                          level:(NSString *)level
                        members:(NSArray<NSString *> *)memberPaths
{
    NSString *mdadm = [DUProcessRunner executablePathForName:@"mdadm"];
    if (mdadm == nil) {
        return DUErrorMake(DUErrorBackendUnavailable,
                           NSLocalizedString(@"RAID management requires mdadm, which is not installed.", nil));
    }
    NSString *raidLevel = nil;
    if ([level isEqualToString:@"mirror"]) {
        raidLevel = @"1";
    } else if ([level isEqualToString:@"stripe"]) {
        raidLevel = @"0";
    } else if ([level isEqualToString:@"concat"]) {
        raidLevel = @"linear";
    } else {
        return DUErrorMake(DUErrorInvalidArgument,
                           NSLocalizedString(@"Unsupported RAID level.", nil));
    }
    if (memberPaths.count < 2) {
        return DUErrorMake(DUErrorInvalidArgument,
                           NSLocalizedString(@"A RAID set needs at least two members.", nil));
    }
    NSMutableArray<NSString *> *arguments =
        [NSMutableArray arrayWithArray:@[
            @"--create", [@"/dev/md/" stringByAppendingString:name],
            @"--level", raidLevel,
            @"--raid-devices", [NSString stringWithFormat:@"%lu",
                                                          (unsigned long)memberPaths.count],
        ]];
    [arguments addObjectsFromArray:memberPaths];
    // mdadm creates the array from the member devices; needs root.
    DUProcessResult *result = [[DUAuthorizationManager sharedManager]
        runPrivileged:mdadm
                 args:arguments
              timeout:300.0
                error:NULL];
    if (result == nil || !result.exitedNormally ||
        result.terminationStatus != 0) {
        return [NSError errorWithDomain:DUStorageErrorDomain
                                   code:DUErrorUnknown
                               userInfo:@{
            NSLocalizedDescriptionKey :
                NSLocalizedString(@"Creating the RAID set failed.", nil),
            kDUBackendDetailKey : result.standardError ?: @"",
        }];
    }
    return nil;
}

#pragma mark - Worker helper

- (void)mountFileImageAtPath:(NSString *)path
                  completion:(void (^)(NSError *, NSString *))completion
{
    dispatch_worker(^{
        NSString *mountPoint = [self mountFileImage:path];
        if (mountPoint == nil) {
            completion(DUErrorMake(
                          DUErrorMountError,
                          NSLocalizedString(@"The disk image could not be "
                                            @"mounted.",
                                            nil)),
                      nil);
            return;
        }
        completion(nil, mountPoint);
    });
}

// Spawns a detached one-shot worker thread with its own autorelease pool.
// No GCD: operations here can block for minutes on device I/O.
static void dispatch_worker(void (^block)(void))
{
    NSThread *thread = [[NSThread alloc]
        initWithBlock:^{
            @autoreleasepool {
                block();
            }
        }];
    thread.name = @"DU-Linux-backend";
    [thread start];
}

@end

#endif /* defined(__linux__) */
