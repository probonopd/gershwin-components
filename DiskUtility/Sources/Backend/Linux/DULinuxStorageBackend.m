/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#if defined(__linux__)

#import "DULinuxStorageBackend.h"

#import <sys/statvfs.h>

#import "DUDiskImage.h"
#import "DUOpticalMedia.h"
#import "DUErrors.h"
#import "DULinuxDeviceDiscovery.h"
#import "DULinuxFilesystemTool.h"
#import "DULinuxImageTool.h"
#import "DULinuxPartitionTool.h"
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

- (void)verifyObject:(DUStorageObject *)object
            progress:(void (^)(double, NSString *))progress
          completion:(void (^)(NSError *))completion
{
    dispatch_worker(^{
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

        NSString *udisksctl =
            [DUProcessRunner executablePathForName:@"udisksctl"];
        NSString *fstype = @"";
        if ([object isKindOfClass:[DUStorageVolume class]]) {
            fstype = ((DUStorageVolume *)object).filesystemType ?: @"";
        } else if ([object isKindOfClass:[DUPartition class]]) {
            fstype = ((DUPartition *)object).filesystemType ?: @"";
        }

        NSError *runError = nil;
        DUProcessResult *result = nil;
        if (udisksctl != nil) {
            // udisks talks to the system service and needs no elevation.
            result = [DUProcessRunner runExecutable:udisksctl
                                          arguments:@[ @"mount", @"-b", devicePath ]
                                              error:&runError];
        } else {
            result = [[DUAuthorizationManager sharedManager]
                runPrivileged:[DUProcessRunner executablePathForName:@"mount"]
                         args:(fstype.length > 0
                                   ? @[ @"-t", fstype, devicePath, directory ]
                                   : @[ devicePath, directory ])
                      timeout:300.0
                        error:&runError];
        }
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

        // Prefer the location reported by the tool output over our guess.
        NSString *reportedMount = nil;
        NSRange mountedRange =
            [result.standardOutput rangeOfString:@"mounted at "];
        if (mountedRange.location != NSNotFound) {
            reportedMount =
                [[result.standardOutput substringFromIndex:NSMaxRange(mountedRange)]
                    stringByTrimmingCharactersInSet:
                        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            // udisksctl quotes the path when it contains spaces.
            reportedMount = [reportedMount
                stringByReplacingOccurrencesOfString:@"'"
                                  withString:@""];
        }
        completion(nil, reportedMount.length > 0 ? reportedMount : directory);
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
        NSString *udisksctl =
            [DUProcessRunner executablePathForName:@"udisksctl"];
        NSError *runError = nil;
        DUProcessResult *result = nil;
        if (udisksctl != nil) {
            result = [DUProcessRunner runExecutable:udisksctl
                                          arguments:@[ @"unmount", @"-b", target ]
                                              error:&runError];
        } else {
            result = [[DUAuthorizationManager sharedManager]
                runPrivileged:[DUProcessRunner executablePathForName:@"umount"]
                           args:@[ target ]
                        timeout:300.0
                          error:&runError];
        }
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
