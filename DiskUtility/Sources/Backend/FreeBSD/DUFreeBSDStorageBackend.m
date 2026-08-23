/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#if defined(__FreeBSD__)

#import "DUFreeBSDStorageBackend.h"

#import <sys/statvfs.h>
#import <sys/wait.h>

#import "DUBackendCapabilities.h"
#import "DUErrors.h"
#import "DUFreeBSDDeviceDiscovery.h"
#import "DUFreeBSDGEOMAdapter.h"
#import "DUOpticalMedia.h"
#import "DUPartition.h"
#import "DUPartitionPlan.h"
#import "DUPartitionTableParser.h"
#import "DUParsing.h"
#import "DUProcessRunner.h"
#import "DUAuthorizationManager.h"
#import "DUStorageCapabilities.h"
#import "DUStorageDevice.h"
#import "DUStorageObject.h"
#import "DUStorageVolume.h"

// UFS volume labels are capped by newfs itself (MAXLABELLEN 15); FAT has
// the classic 11-character limit. Truncate before the tool rejects them.
static const NSUInteger kMaxUFSLabelLength = 15;
static const NSUInteger kMaxFATLabelLength = 11;

@implementation DUFreeBSDStorageBackend

#pragma mark - Discovery and capability reporting

- (NSArray *)discoverStorageObjects:(NSError **)error
{
    return [[DUFreeBSDDeviceDiscovery alloc] discoverObjects:error];
}

- (NSDictionary *)capabilitiesReport
{
    // Flags reflect installed tools so the diagnostics page shows honest
    // answers instead of a flat "everything works" on minimal systems.
    DUBackendReport *report = [[DUBackendReport alloc] init];
    report.discovery = [DUFreeBSDToolCache haveTool:@"geom"];
    report.mountManagement =
        [DUFreeBSDToolCache haveTool:@"mount"] &&
        [DUFreeBSDToolCache haveTool:@"umount"];
    report.partitioning = [DUFreeBSDToolCache haveTool:@"gpart"];
    report.filesystemFormat =
        [DUFreeBSDToolCache haveTool:@"newfs"] ||
        [DUFreeBSDToolCache haveTool:@"newfs_msdos"];
    report.filesystemRepair =
        [DUFreeBSDToolCache haveTool:@"fsck_ffs"] ||
        [DUFreeBSDToolCache haveTool:@"fsck_msdosfs"];
    report.secureErase = [DUFreeBSDToolCache haveTool:@"dd"];
    report.raidManagement =
        [DUFreeBSDToolCache haveTool:@"gmirror"] ||
        [DUFreeBSDToolCache haveTool:@"gstripe"] ||
        [DUFreeBSDToolCache haveTool:@"gconcat"];
    report.imageCreate = [DUFreeBSDToolCache haveTool:@"dd"];
    report.imageConvert = NO;
    report.imageResize = NO;
    report.burn = NO;
    return [report reportDictionary];
}

#pragma mark - Format descriptors

- (NSArray<NSDictionary *> *)supportedFormatsForObject:(DUStorageObject *)object
{
    if (object == nil || object.capabilities.canErase == NO) {
        return @[];
    }
    BOOL ufsPossible = [DUFreeBSDToolCache haveTool:@"newfs"];
    BOOL fatPossible = [DUFreeBSDToolCache haveTool:@"newfs_msdos"];

    NSMutableArray<NSDictionary *> *formats = [NSMutableArray array];
    if (ufsPossible) {
        [formats addObject:@{
            kDUFormatIdentifierKey : @"ufs",
            kDUFormatDisplayNameKey :
                [DUPartitionTableParser filesystemDisplayName:@"ufs"],
            kDUFormatCanFormatKey : @YES,
        }];
    }
    if (fatPossible) {
        [formats addObject:@{
            kDUFormatIdentifierKey : @"fat32",
            kDUFormatDisplayNameKey :
                [DUPartitionTableParser filesystemDisplayName:@"vfat"],
            kDUFormatCanFormatKey : @YES,
        }];
    }
    // Swap partitions are marked in the table, not formatted by a tool, so
    // the entry exists for planning but honestly reports cannot-format.
    [formats addObject:@{
        kDUFormatIdentifierKey : @"swap",
        kDUFormatDisplayNameKey :
            [DUPartitionTableParser filesystemDisplayName:@"swap"],
        kDUFormatCanFormatKey : @NO,
    }];
    return formats;
}

#pragma mark - Operation gating

- (BOOL)supportsOperation:(NSString *)op forObject:(DUStorageObject *)object
{
    if (op == nil || object == nil || object.capabilities == nil) {
        return NO;
    }
    DUStorageCapabilities *caps = object.capabilities;

    if ([op isEqualToString:kDUOperationVerify]) return caps.canVerify;
    if ([op isEqualToString:kDUOperationRepair]) return caps.canRepair;
    if ([op isEqualToString:kDUOperationErase]) return caps.canErase;
    if ([op isEqualToString:kDUOperationPartition]) return caps.canPartition;
    if ([op isEqualToString:kDUOperationMount]) return caps.canMount;
    if ([op isEqualToString:kDUOperationUnmount]) return caps.canUnmount;
    if ([op isEqualToString:kDUOperationEject]) return caps.canEject;
    if ([op isEqualToString:kDUOperationRestore]) return caps.canRestore;
    if ([op isEqualToString:kDUOperationBurn]) return caps.canBurn;
    if ([op isEqualToString:kDUOperationCreateImage]) return caps.canCreateImage;
    if ([op isEqualToString:kDUOperationConvertImage]) return caps.canConvertImage;
    if ([op isEqualToString:kDUOperationResizeImage]) return caps.canResizeImage;
    if ([op isEqualToString:kDUOperationToggleJournaling]) return caps.canToggleJournaling;
    return NO;
}

- (NSError *)gateForOperation:(NSString *)op onObject:(DUStorageObject *)object
{
    if (object == nil) {
        return DUErrorMake(DUErrorInvalidArgument,
                           NSLocalizedString(@"No object selected.", nil));
    }
    if (![self supportsOperation:op forObject:object]) {
        return DUErrorMake(
            DUErrorUnsupportedOperation,
            [NSString stringWithFormat:
                 NSLocalizedString(@"\"%@\" cannot be performed on %@.", nil),
             op,
             object.displayName ?: NSLocalizedString(@"this item", nil)]);
    }
    return nil;
}

#pragma mark - Worker plumbing

// Documented async contract: work runs on a private thread with an
// autorelease pool; progress and completion fire there or on reader threads
// spawned below, and callers marshal to main themselves.
- (void)spawnWork:(void (^)(void))work
{
    NSThread *worker = [[NSThread alloc] initWithBlock:^{
        @autoreleasepool {
            work();
        }
    }];
    worker.name = @"DU FreeBSD op";
    [worker start];
}

// Streams a tool run while the calling worker blocks until completion, so
// the operation's completion callback fires on that worker as promised.
// The tool runs elevated (sudo -A askpass when not root) because every
// caller here reads or writes raw device nodes.
- (DUProcessResult *)blockingStreamedRun:(NSString *)path
                               arguments:(NSArray<NSString *> *)arguments
                             lineHandler:(void (^)(NSString *line))lineHandler
{
    NSCondition *condition = [[NSCondition alloc] init];
    __block DUProcessResult *result = nil;
    __block BOOL finished = NO;
    NSError *streamError = nil;

    [[DUAuthorizationManager sharedManager]
        streamPrivileged:path
                    args:arguments
           stdoutHandler:lineHandler
            finishHandler:^(DUProcessResult *runResult) {
                [condition lock];
                result = runResult;
                finished = YES;
                [condition signal];
                [condition unlock];
            }
                    error:&streamError];
    if (streamError != nil) {
        return nil;
    }

    [condition lock];
    while (!finished) {
        [condition wait];
    }
    [condition unlock];
    return result;
}

// Error sheets show why a tool failed without dumping full transcripts.
- (NSError *)toolFailure:(DUStorageErrorCode)code
                 message:(NSString *)message
                  result:(DUProcessResult *)result
{
    NSString *detail =
        [DUParsing trimmedString:result.standardError]
        ?: @"";
    if (detail.length == 0) {
        detail = [DUParsing trimmedString:result.standardOutput] ?: @"";
    }
    NSUInteger tailStart = detail.length > 400 ? detail.length - 400 : 0;
    NSString *tail = [detail substringFromIndex:tailStart];

    NSError *error = [NSError errorWithDomain:DUStorageErrorDomain
                                         code:code
                                     userInfo:@{
        NSLocalizedDescriptionKey : message,
        DUFreeBSDBackendDetailKey : tail,
    }];
    return error;
}

- (BOOL)runSucceeded:(DUProcessResult *)result
{
    return result != nil && result.exitedNormally &&
        WEXITSTATUS(result.terminationStatus) == 0 && !result.timedOut;
}

// dd progress lines ("123456789 bytes transferred ..." / GNU-style copies)
// carry the authoritative byte count; \r-separated updates arrive inside a
// single buffered line and are split here.
- (unsigned long long)byteCountFromProgressLine:(NSString *)line
{
    for (NSString *chunk in [line componentsSeparatedByString:@"\r"]) {
        NSString *text = [DUParsing trimmedString:
                                   [chunk stringByReplacingOccurrencesOfString:@"\r"
                                                                    withString:@""]];
        if (text.length == 0) {
            continue;
        }
        NSRange suffix = [text rangeOfString:@" bytes"];
        if (suffix.location != 0) {
            continue;
        }
        unsigned long long bytes =
            [DUParsing unsignedLongLongFromString:text];
        if (bytes > 0) {
            return bytes;
        }
    }
    return 0;
}

#pragma mark - Filesystem classification

// Checker binary for a filesystem identifier; nil when this backend cannot
// inspect it. Verify passes read-only flags, repair gets -y.
- (NSString *)checkerNameForFilesystem:(NSString *)fstype
{
    NSString *normalized = fstype.lowercaseString;
    if ([normalized isEqualToString:@"ufs"]) {
        return @"fsck_ffs";
    }
    if ([normalized isEqualToString:@"msdosfs"] ||
        [normalized isEqualToString:@"fat32"] ||
        [normalized isEqualToString:@"fat16"] ||
        [normalized isEqualToString:@"vfat"] ||
        [normalized isEqualToString:@"fat"]) {
        return @"fsck_msdosfs";
    }
    return nil;
}

- (NSArray<NSString *> *)readonlyArgumentsForChecker:(NSString *)checker
{
    return [checker isEqualToString:@"fsck_ffs"] ? @[ @"-n", @"-f" ]
                                                 : @[ @"-n" ];
}

// mount(8) -t spellings differ from our canonical identifiers.
- (NSString *)mountTypeForFilesystem:(NSString *)fstype
{
    NSDictionary<NSString *, NSString *> *table = @{
        @"ufs" : @"ufs",
        @"msdosfs" : @"msdosfs",
        @"fat32" : @"msdosfs",
        @"vfat" : @"msdosfs",
        @"cd9660" : @"cd9660",
        @"iso9660" : @"cd9660",
        @"ntfs" : @"ntfs",
        @"ext2" : @"ext2fs",
        @"ext3" : @"ext2fs",
        @"ext4" : @"ext2fs",
        @"exfat" : @"exfat",
    };
    NSString *mapped = table[fstype.lowercaseString];
    return mapped ?: fstype;
}

- (NSString *)formatterNameForFormatIdentifier:(NSString *)identifier
                                 labelCapacity:(NSUInteger *)outLabelLimit
{
    NSString *normalized = identifier.lowercaseString;
    if ([normalized isEqualToString:@"ufs"]) {
        if (outLabelLimit != NULL) {
            *outLabelLimit = kMaxUFSLabelLength;
        }
        return @"newfs";
    }
    if ([normalized isEqualToString:@"fat32"] ||
        [normalized isEqualToString:@"fat16"] ||
        [normalized isEqualToString:@"vfat"] ||
        [normalized isEqualToString:@"fat"] ||
        [normalized isEqualToString:@"msdosfs"]) {
        if (outLabelLimit != NULL) {
            *outLabelLimit = kMaxFATLabelLength;
        }
        return @"newfs_msdos";
    }
    return nil;
}

// gpart add -t payload for a requested filesystem identifier; nil when no
// honest mapping exists (callers reject rather than guess).
- (NSString *)gpartTypeForFilesystem:(NSString *)fstype
{
    NSDictionary<NSString *, NSString *> *table = @{
        @"ext2" : @"linux-data",
        @"ext3" : @"linux-data",
        @"ext4" : @"linux-data",
        @"linux" : @"linux-data",
        @"linux-data" : @"linux-data",
        @"ufs" : @"freebsd-ufs",
        @"freebsd-ufs" : @"freebsd-ufs",
        @"vfat" : @"!fat32",
        @"fat" : @"!fat32",
        @"fat16" : @"!fat32",
        @"fat32" : @"!fat32",
        @"msdosfs" : @"!fat32",
        @"efi" : @"efi",
        @"swap" : @"freebsd-swap",
    };
    return table[fstype.lowercaseString];
}

// Filesystem relevant to verify/repair/erase for any object kind.
- (NSString *)filesystemTypeOfObject:(DUStorageObject *)object
{
    if ([object isKindOfClass:[DUStorageVolume class]]) {
        return ((DUStorageVolume *)object).filesystemType;
    }
    if ([object isKindOfClass:[DUPartition class]]) {
        DUPartition *partition = (DUPartition *)object;
        return partition.volume.filesystemType ?: partition.filesystemType;
    }
    if ([object isKindOfClass:[DUOpticalMedia class]]) {
        return ((DUOpticalMedia *)object).filesystemType;
    }
    return nil;
}

- (unsigned long long)sizeOfObject:(DUStorageObject *)object
{
    if ([object isKindOfClass:[DUStorageDevice class]]) {
        return ((DUStorageDevice *)object).capacityBytes;
    }
    if ([object isKindOfClass:[DUPartition class]]) {
        DUPartition *partition = (DUPartition *)object;
        return partition.sizeBytes ?: partition.volume.capacityBytes;
    }
    if ([object isKindOfClass:[DUStorageVolume class]]) {
        return ((DUStorageVolume *)object).capacityBytes;
    }
    if ([object isKindOfClass:[DUOpticalMedia class]]) {
        return ((DUOpticalMedia *)object).capacityBytes;
    }
    return 0;
}

#pragma mark - Mount-state guards

// The node of this object plus every descendant node, used to refuse
// destructive work while anything above is mounted.
- (NSArray<NSString *> *)nodesOfSubtree:(DUStorageObject *)object
{
    NSMutableArray<NSString *> *nodes = [NSMutableArray array];
    if (object.backendPath.length > 0) {
        [nodes addObject:object.backendPath];
    }
    for (DUStorageObject *child in object.children) {
        [nodes addObjectsFromArray:[self nodesOfSubtree:child]];
    }
    return nodes;
}

- (NSString *)mountedNodeAmong:(NSArray<NSString *> *)nodes
{
    NSDictionary<NSString *, NSDictionary *> *table =
        [DUFreeBSDGEOMAdapter currentMountTable];
    for (NSString *node in nodes) {
        if (table[node] != nil) {
            return node;
        }
    }
    // Whole-disk work must also catch mounted slices like /dev/ada0p2 whose
    // names extend the disk node; partition nodes are matched exactly above.
    for (NSString *node in nodes) {
        NSString *base = node.lastPathComponent;
        if (base.length == 0) {
            continue;
        }
        NSRange firstDigit =
            [base rangeOfCharacterFromSet:
                       [NSCharacterSet decimalDigitCharacterSet]];
        if (firstDigit.location != NSNotFound) {
            continue;
        }
        for (NSString *mountedNode in table) {
            if ([mountedNode.lastPathComponent hasPrefix:base] &&
                ![mountedNode.lastPathComponent isEqualToString:base]) {
                return mountedNode;
            }
        }
    }
    return nil;
}

#pragma mark - Verify

- (void)verifyObject:(DUStorageObject *)object
              progress:(void (^)(double progress, NSString *message))progress
            completion:(void (^)(NSError *error))completion
{
    NSError *gate = [self gateForOperation:kDUOperationVerify
                                 onObject:object];
    if (gate == nil && object.backendPath.length == 0) {
        gate = DUErrorMake(DUErrorInvalidArgument,
                           NSLocalizedString(@"The item has no device node.",
                                             nil));
    }
    NSString *fstype = gate == nil ? [self filesystemTypeOfObject:object] : nil;
    NSArray<NSString *> *readonlyArgs = nil;
    NSString *checker = gate == nil
        ? [self checkerNameForFilesystem:fstype]
        : nil;
    readonlyArgs =
        checker == nil ? nil : [self readonlyArgumentsForChecker:checker];
    NSString *checkerPath = checker == nil
        ? nil
        : [DUFreeBSDToolCache pathForTool:checker];
    if (gate == nil && checkerPath == nil) {
        gate = DUErrorMake(
            DUErrorUnsupportedOperation,
            [NSString stringWithFormat:
                 NSLocalizedString(@"No filesystem checker for %@ is "
                                   @"installed.", nil),
             fstype]);
    }
    if (gate != nil) {
        if (completion != NULL) {
            completion(gate);
        }
        return;
    }

    NSString *node = object.backendPath;
    [self spawnWork:^{
        if (progress != NULL) {
            progress(0.0, NSLocalizedString(@"Checking filesystem...", nil));
        }
        NSMutableArray<NSString *> *arguments =
            [NSMutableArray arrayWithArray:readonlyArgs];
        [arguments addObject:node];

        __block NSUInteger lineCount = 0;
        DUProcessResult *result = [self blockingStreamedRun:checkerPath
                                                  arguments:arguments
                                                lineHandler:^(NSString *line) {
            NSString *text = [DUParsing trimmedString:line];
            if (text.length == 0) {
                return;
            }
            lineCount++;
            if (progress != NULL) {
                // fsck gives no machine-readable progress; advance a capped
                // fraction per output line so the bar keeps moving honestly.
                double fraction = 1.0 - 1.0 / (double)(lineCount + 1);
                progress(fraction * 0.95, text);
            }
        }];

        if (![self runSucceeded:result]) {
            NSError *error = [self toolFailure:DUErrorVerificationFailed
                                       message:NSLocalizedString(
                                                    @"The filesystem was "
                                                    @"found to be damaged.",
                                                    nil)
                                        result:result];
            if (completion != NULL) {
                completion(error);
            }
            return;
        }
        if (progress != NULL) {
            progress(1.0,
                     NSLocalizedString(@"Volume verified.", nil));
        }
        if (completion != NULL) {
            completion(nil);
        }
    }];
}

#pragma mark - Repair

- (void)repairObject:(DUStorageObject *)object
              progress:(void (^)(double progress, NSString *message))progress
            completion:(void (^)(NSError *error))completion
{
    NSError *gate = [self gateForOperation:kDUOperationRepair
                                 onObject:object];
    if (gate == nil && object.backendPath.length == 0) {
        gate = DUErrorMake(DUErrorInvalidArgument,
                           NSLocalizedString(@"The item has no device node.",
                                             nil));
    }

    // fsck -y on a live filesystem corrupts it; refuse before spawning.
    NSString *busyNode = gate == nil
        ? [self mountedNodeAmong:[self nodesOfSubtree:object]]
        : nil;
    if (gate == nil && busyNode != nil) {
        gate = DUErrorMake(DUErrorDeviceBusy,
                           [NSString stringWithFormat:
                                NSLocalizedString(
                                    @"%@ is mounted and must be unmounted "
                                    @"before repair.", nil),
                            busyNode]);
    }

    NSString *fstype = gate == nil ? [self filesystemTypeOfObject:object] : nil;
    NSString *checker = gate == nil
        ? [self checkerNameForFilesystem:fstype]
        : nil;
    NSString *checkerPath = checker == nil
        ? nil
        : [DUFreeBSDToolCache pathForTool:checker];
    if (gate == nil && checkerPath == nil) {
        gate = DUErrorMake(
            DUErrorUnsupportedOperation,
            [NSString stringWithFormat:
                 NSLocalizedString(@"No filesystem repair tool for %@ is "
                                   @"installed.", nil),
             fstype]);
    }
    if (gate != nil) {
        if (completion != NULL) {
            completion(gate);
        }
        return;
    }

    NSString *node = object.backendPath;
    [self spawnWork:^{
        if (progress != NULL) {
            progress(0.0, NSLocalizedString(@"Repairing filesystem...", nil));
        }
        NSMutableArray<NSString *> *arguments =
            [NSMutableArray arrayWithObject:@"-y"];
        [arguments addObject:node];

        __block NSUInteger lineCount = 0;
        DUProcessResult *result = [self blockingStreamedRun:checkerPath
                                                  arguments:arguments
                                                lineHandler:^(NSString *line) {
            NSString *text = [DUParsing trimmedString:line];
            if (text.length == 0) {
                return;
            }
            lineCount++;
            if (progress != NULL) {
                double fraction = 1.0 - 1.0 / (double)(lineCount + 1);
                progress(fraction * 0.95, text);
            }
        }];

        if (![self runSucceeded:result]) {
            NSError *error = [self toolFailure:DUErrorRepairFailed
                                       message:NSLocalizedString(
                                                    @"The filesystem could "
                                                    @"not be repaired.", nil)
                                        result:result];
            if (completion != NULL) {
                completion(error);
            }
            return;
        }
        if (progress != NULL) {
            progress(1.0,
                     NSLocalizedString(@"Volume repaired.", nil));
        }
        if (completion != NULL) {
            completion(nil);
        }
    }];
}

#pragma mark - Erase

// Labels feed tool argv directly, so option-leading characters must go and
// whitespace would split nothing but still confuse tools that echo labels.
- (NSString *)sanitizedLabel:(NSString *)rawLabel limit:(NSUInteger)limit
{
    NSMutableString *label =
        [[DUParsing trimmedString:rawLabel] mutableCopy];
    while (label.length > 0 && [label characterAtIndex:0] == '-') {
        [label deleteCharactersInRange:NSMakeRange(0, 1)];
    }
    [label replaceOccurrencesOfString:@" "
                           withString:@"_"
                              options:0
                                range:NSMakeRange(0, label.length)];
    if (label.length > limit) {
        label = [NSMutableString stringWithString:
                            [label substringToIndex:limit]];
    }
    return label;
}

- (void)eraseObject:(DUStorageObject *)object
             options:(NSDictionary *)options
            progress:(void (^)(double progress, NSString *message))progress
          completion:(void (^)(NSError *error))completion
{
    NSError *gate = [self gateForOperation:kDUOperationErase
                                 onObject:object];
    if (gate == nil && object.backendPath.length == 0) {
        gate = DUErrorMake(DUErrorInvalidArgument,
                           NSLocalizedString(@"The item has no device node.",
                                             nil));
    }
    NSString *busyNode = gate == nil
        ? [self mountedNodeAmong:[self nodesOfSubtree:object]]
        : nil;
    if (gate == nil && busyNode != nil) {
        gate = DUErrorMake(DUErrorDeviceBusy,
                           [NSString stringWithFormat:
                                NSLocalizedString(
                                    @"%@ is mounted and must be unmounted "
                                    @"before erasing.", nil),
                            busyNode]);
    }

    NSString *formatIdentifier =
        [DUParsing trimmedString:options[kDUFormatIdentifierKey]];
    if (gate == nil && formatIdentifier.length == 0) {
        gate = DUErrorMake(DUErrorInvalidArgument,
                           NSLocalizedString(@"No filesystem was chosen for "
                                             @"the erased volume.", nil));
    }
    NSUInteger labelLimit = 0;
    NSString *formatter = gate == nil
        ? [self formatterNameForFormatIdentifier:formatIdentifier
                                   labelCapacity:&labelLimit]
        : nil;
    if (gate == nil && formatter == nil) {
        gate = DUErrorMake(
            DUErrorUnsupportedOperation,
            [NSString stringWithFormat:
                 NSLocalizedString(@"Formatting as %@ is not supported.",
                                   nil),
             formatIdentifier]);
    }
    NSString *formatterPath = formatter == nil
        ? nil
        : [DUFreeBSDToolCache pathForTool:formatter];
    if (gate == nil && formatterPath == nil) {
        gate = DUErrorMake(
            DUErrorUnsupportedOperation,
            [NSString stringWithFormat:
                 NSLocalizedString(@"The %@ formatting tool is not "
                                   @"installed.", nil),
             formatter]);
    }

    NSString *securityMethod =
        [DUParsing trimmedString:options[kDUEraseSecurityMethodKey]];
    BOOL wipeWithZeros =
        [securityMethod isEqualToString:kDUEraseMethodZerosKey];
    NSString *ddPath = nil;
    if (gate == nil && wipeWithZeros) {
        ddPath = [DUFreeBSDToolCache pathForTool:@"dd"];
        if (ddPath == nil) {
            gate = DUErrorMake(
                DUErrorUnsupportedOperation,
                NSLocalizedString(@"Secure zeroing requires dd, which is "
                                  @"not installed.", nil));
        }
    }

    BOOL wholeDisk = gate == nil && object.type == DUStorageObjectTypeDevice;
    NSString *gpartPath = nil;
    if (gate == nil && wholeDisk) {
        gpartPath = [DUFreeBSDToolCache pathForTool:@"gpart"];
        if (gpartPath == nil) {
            gate = DUErrorMake(
                DUErrorUnsupportedOperation,
                NSLocalizedString(@"Erasing a whole disk requires gpart, "
                                  @"which is not installed.", nil));
        }
    }

    if (gate != nil) {
        if (completion != NULL) {
            completion(gate);
        }
        return;
    }

    NSString *node = object.backendPath;
    NSString *volumeName =
        [DUParsing trimmedString:options[@"name"]] ?: @"";
    NSString *label = [self sanitizedLabel:volumeName limit:labelLimit];

    [self spawnWork:^{
        double fraction = 0.0;

        if (wipeWithZeros) {
            if (progress != NULL) {
                progress(0.02,
                         NSLocalizedString(@"Writing zeroes over the "
                                           @"device...", nil));
            }
            unsigned long long totalBytes = [self sizeOfObject:object];
            NSMutableArray<NSString *> *ddArguments = [NSMutableArray array];
            [ddArguments addObjectsFromArray:@[
                @"if=/dev/zero",
                [NSString stringWithFormat:@"of=%@", node],
                @"bs=1M",
                @"status=progress",
            ]];
            DUProcessResult *wipe = [self
                blockingStreamedRun:ddPath
                          arguments:ddArguments
                        lineHandler:^(NSString *line) {
                    unsigned long long written =
                        [self byteCountFromProgressLine:line];
                    if (written == 0 || totalBytes == 0) {
                        return;
                    }
                    double ratio =
                        (double)written / (double)totalBytes;
                    if (ratio > 1.0) {
                        ratio = 1.0;
                    }
                    if (progress != NULL) {
                        progress(0.02 + ratio * 0.73,
                                 NSLocalizedString(@"Writing zeroes...",
                                                   nil));
                    }
                }];
            if (![self runSucceeded:wipe]) {
                if (completion != NULL) {
                    completion([self toolFailure:DUErrorEraseFailed
                                         message:NSLocalizedString(
                                                      @"Zeroing the device "
                                                      @"failed.", nil)
                                          result:wipe]);
                }
                return;
            }
            fraction = 0.75;
        }

        if (wholeDisk) {
            fraction = fraction > 0 ? fraction : 0.2;
            if (progress != NULL) {
                progress(fraction,
                         NSLocalizedString(@"Removing the partition "
                                           @"table...", nil));
            }
            // gpart destroy rewrites the table; needs root.
            DUProcessResult *destroy =
                [[DUAuthorizationManager sharedManager]
                    runPrivileged:gpartPath
                             args:@[ @"destroy", @"-F", node ]
                          timeout:300.0
                            error:NULL];
            BOOL tableWasAbsent =
                [destroy.standardError localizedCaseInsensitiveContainsString:
                                           @"no such geom"] ||
                [destroy.standardOutput localizedCaseInsensitiveContainsString:
                                            @"no such geom"];
            if (![self runSucceeded:destroy] && !tableWasAbsent) {
                if (completion != NULL) {
                    completion([self toolFailure:DUErrorEraseFailed
                                         message:NSLocalizedString(
                                                      @"Removing the old "
                                                      @"partition table "
                                                      @"failed.", nil)
                                          result:destroy]);
                }
                return;
            }
            fraction += 0.05;
        }

        if (progress != NULL) {
            progress(fraction + 0.1,
                     NSLocalizedString(@"Creating filesystem...", nil));
        }
        NSMutableArray<NSString *> *formatArguments =
            [NSMutableArray array];
        if (label.length > 0) {
            [formatArguments addObjectsFromArray:@[ @"-L", label ]];
        }
        [formatArguments addObject:node];
        // newfs writes the raw device; needs root.
        DUProcessResult *created =
            [[DUAuthorizationManager sharedManager]
                runPrivileged:formatterPath
                         args:formatArguments
                      timeout:300.0
                        error:NULL];
        if (![self runSucceeded:created]) {
            if (completion != NULL) {
                completion([self toolFailure:DUErrorEraseFailed
                                     message:NSLocalizedString(
                                                  @"Creating the filesystem "
                                                  @"failed.", nil)
                                      result:created]);
            }
            return;
        }

        if (progress != NULL) {
            progress(1.0,
                     NSLocalizedString(@"Erase completed.", nil));
        }
        if (completion != NULL) {
            completion(nil);
        }
    }];
}

#pragma mark - Partitioning

- (void)partitionDevice:(DUStorageObject *)device
                withPlan:(DUPartitionPlan *)plan
               progress:(void (^)(double progress, NSString *message))progress
             completion:(void (^)(NSError *error))completion
{
    NSError *gate =
        [self gateForOperation:kDUOperationPartition onObject:device];
    if (gate == nil && plan == nil) {
        gate = DUErrorMake(DUErrorInvalidArgument,
                           NSLocalizedString(@"No partition plan was given.",
                                             nil));
    }
    if (gate == nil && device.backendPath.length == 0) {
        gate = DUErrorMake(DUErrorInvalidArgument,
                           NSLocalizedString(@"The device has no device "
                                             @"node.", nil));
    }

    // Rewriting the table under mounted filesystems loses their contents.
    NSString *busyNode = gate == nil
        ? [self mountedNodeAmong:[self nodesOfSubtree:device]]
        : nil;
    if (gate == nil && busyNode != nil) {
        gate = DUErrorMake(DUErrorDeviceBusy,
                           [NSString stringWithFormat:
                                NSLocalizedString(
                                    @"%@ is mounted and must be unmounted "
                                    @"before partitioning.", nil),
                            busyNode]);
    }

    NSString *scheme = gate == nil
        ? [DUPartitionTableParser normalizeSchemeToken:plan.scheme]
        : nil;
    if (gate == nil &&
        !([scheme isEqualToString:@"gpt"] ||
          [scheme isEqualToString:@"mbr"] ||
          [scheme isEqualToString:@"bsd"])) {
        gate = DUErrorMake(
            DUErrorUnsupportedOperation,
            [NSString stringWithFormat:
                 NSLocalizedString(@"Partition scheme %@ is not supported.",
                                   nil),
             plan.scheme ?: @""]);
    }

    // Resolve every entry type up front so an unmappable filesystem fails
    // synchronously instead of after the table was already destroyed.
    NSArray<DUPartition *> *entries = gate == nil ? plan.entries : nil;
    NSMutableArray<NSString *> *types =
        [NSMutableArray arrayWithCapacity:entries.count];
    if (gate == nil) {
        for (DUPartition *entry in entries) {
            NSString *requested =
                [DUParsing trimmedString:entry.filesystemType]
                ?: @"";
            if (requested.length == 0) {
                requested =
                    [DUFreeBSDGEOMAdapter filesystemTokenForPartitionType:
                                              entry.partitionType] ?: @"";
            }
            NSString *type = [self gpartTypeForFilesystem:requested];
            if (type == nil) {
                gate = DUErrorMake(
                    DUErrorInvalidArgument,
                    [NSString stringWithFormat:
                         NSLocalizedString(@"No partition type mapping "
                                           @"exists for %@.", nil),
                     requested]);
                break;
            }
            [types addObject:type];
        }
    }

    NSString *gpartPath = nil;
    if (gate == nil) {
        gpartPath = [DUFreeBSDToolCache pathForTool:@"gpart"];
        if (gpartPath == nil) {
            gate = DUErrorMake(
                DUErrorUnsupportedOperation,
                NSLocalizedString(@"Partitioning requires gpart, which is "
                                  @"not installed.", nil));
        }
    }

    if (gate != nil) {
        if (completion != NULL) {
            completion(gate);
        }
        return;
    }

    // Sector geometry comes from the live provider data, not from the
    // discovery snapshot, so plans stay correct across re-plugs.
    NSString *nodeName = device.backendPath.lastPathComponent;
    unsigned long long sectorSize = 512;
    NSArray<NSDictionary<NSString *, id> *> *geometry =
        [DUFreeBSDGEOMAdapter listClass:@"part" name:nodeName error:NULL];
    for (NSDictionary *provider in geometry) {
        unsigned long long reported = [DUParsing
            unsignedLongLongFromString:[DUParsing trimmedString:
                                                   provider[@"sectorsize"]]];
        if (reported > 0) {
            sectorSize = reported;
            break;
        }
    }

    [self spawnWork:^{
        if (progress != NULL) {
            progress(0.02,
                     NSLocalizedString(@"Creating partition table...",
                                       nil));
        }
        // gpart create rewrites the table; needs root.
        DUProcessResult *created =
            [[DUAuthorizationManager sharedManager]
                runPrivileged:gpartPath
                         args:@[ @"create", @"-s", scheme, nodeName ]
                      timeout:300.0
                        error:NULL];
        if (![self runSucceeded:created]) {
            if (completion != NULL) {
                completion([self toolFailure:DUErrorPartitionError
                                     message:NSLocalizedString(
                                                  @"Creating the partition "
                                                  @"table failed.", nil)
                                      result:created]);
            }
            return;
        }

        NSUInteger count = entries.count;
        for (NSUInteger i = 0; i < count; i++) {
            DUPartition *entry = entries[i];
            NSMutableArray<NSString *> *arguments =
                [NSMutableArray arrayWithObject:@"add"];
            [arguments addObjectsFromArray:@[ @"-t", types[i] ]];

            if (entry.sizeBytes > 0) {
                // Round up so rounding can never swallow part of the last
                // partition into unallocated space.
                unsigned long long sectors =
                    (entry.sizeBytes + sectorSize - 1) / sectorSize;
                [arguments addObjectsFromArray:
                                @[ @"-s",
                                   [NSString stringWithFormat:@"%llu",
                                                              sectors] ]];
            }
            if ([scheme isEqualToString:@"gpt"] && entry.index >= 1) {
                [arguments addObjectsFromArray:
                                @[ @"-i",
                                   [NSString stringWithFormat:@"%ld",
                                                              (long)entry.index] ]];
            }
            if ([scheme isEqualToString:@"gpt"] &&
                entry.name.length > 0) {
                NSString *label =
                    [self sanitizedLabel:entry.name limit:kMaxUFSLabelLength];
                if (label.length > 0) {
                    [arguments addObjectsFromArray:@[ @"-l", label ]];
                }
            }
            [arguments addObject:nodeName];

            if (progress != NULL) {
                progress(0.1 + 0.85 * (double)(i + 1) / (double)count,
                         [NSString stringWithFormat:
                              NSLocalizedString(@"Adding partition %lu of %lu...",
                                                nil),
                              (unsigned long)(i + 1), (unsigned long)count]);
            }
            // gpart add rewrites the table; needs root.
            DUProcessResult *added =
                [[DUAuthorizationManager sharedManager]
                    runPrivileged:gpartPath
                             args:arguments
                          timeout:300.0
                            error:NULL];
            if (![self runSucceeded:added]) {
                if (completion != NULL) {
                    completion([self toolFailure:DUErrorPartitionError
                                         message:NSLocalizedString(
                                                      @"Adding a partition "
                                                      @"failed.", nil)
                                          result:added]);
                }
                return;
            }
        }

        if (progress != NULL) {
            progress(1.0,
                     NSLocalizedString(@"Partitions created.", nil));
        }
        if (completion != NULL) {
            completion(nil);
        }
    }];
}

#pragma mark - Mount management

- (void)mountObject:(DUStorageObject *)object
          completion:(void (^)(NSError *error, NSString *mountPoint))completion
{
    NSError *gate =
        [self gateForOperation:kDUOperationMount onObject:object];
    if (gate == nil && object.backendPath.length == 0) {
        gate = DUErrorMake(DUErrorInvalidArgument,
                           NSLocalizedString(@"The item has no device node.",
                                             nil));
    }

    NSString *mountPath = gate == nil
        ? [DUFreeBSDToolCache pathForTool:@"mount"]
        : nil;
    if (gate == nil && mountPath == nil) {
        gate = DUErrorMake(DUErrorUnsupportedOperation,
                           NSLocalizedString(@"The mount tool is not "
                                             @"installed.", nil));
    }

    NSString *node = gate == nil ? object.backendPath : nil;
    if (gate == nil) {
        NSDictionary *existing =
            [DUFreeBSDGEOMAdapter currentMountTable][node];
        if (existing != nil) {
            // Already up: surface the existing state instead of stacking a
            // second mount.
            if (completion != NULL) {
                completion(nil, existing[@"mountPoint"]);
            }
            return;
        }
    }

    NSString *fstype = gate == nil ? [self filesystemTypeOfObject:object] : nil;
    NSString *mountType = gate == nil && fstype.length > 0
        ? [self mountTypeForFilesystem:fstype]
        : nil;
    if (gate == nil && mountType.length == 0) {
        gate = DUErrorMake(
            DUErrorUnsupportedOperation,
            NSLocalizedString(@"The filesystem type of this item is "
                              @"unknown, so it cannot be mounted.", nil));
    }

    if (gate != nil) {
        if (completion != NULL) {
            completion(gate, nil);
        }
        return;
    }

    NSString *directory =
        [@"/media/" stringByAppendingString:node.lastPathComponent];
    NSError *directoryError = nil;
    if ([[NSFileManager defaultManager] createDirectoryAtPath:directory
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:&directoryError] == NO &&
        directoryError != nil) {
        if (completion != NULL) {
            completion(DUErrorMake(DUErrorMountError,
                                   [NSString stringWithFormat:
                                        NSLocalizedString(
                                            @"The mount point %@ could not "
                                            @"be created.", nil),
                                        directory]),
                      nil);
        }
        return;
    }

    [self spawnWork:^{
        // mount(8) attaches a filesystem for the whole session; needs root.
        DUProcessResult *result =
            [[DUAuthorizationManager sharedManager]
                runPrivileged:mountPath
                         args:@[ @"-t", mountType, node, directory ]
                      timeout:300.0
                        error:NULL];
        if (![self runSucceeded:result]) {
            if (completion != NULL) {
                completion([self toolFailure:DUErrorMountError
                                     message:NSLocalizedString(
                                                  @"Mounting failed.", nil)
                                      result:result],
                           nil);
            }
            return;
        }
        if (completion != NULL) {
            completion(nil, directory);
        }
    }];
}

- (void)unmountObject:(DUStorageObject *)object
            completion:(void (^)(NSError *error))completion
{
    NSError *gate =
        [self gateForOperation:kDUOperationUnmount onObject:object];
    if (gate == nil && object.backendPath.length == 0) {
        gate = DUErrorMake(DUErrorInvalidArgument,
                           NSLocalizedString(@"The item has no device node.",
                                             nil));
    }

    NSString *umountPath = gate == nil
        ? [DUFreeBSDToolCache pathForTool:@"umount"]
        : nil;
    if (gate == nil && umountPath == nil) {
        gate = DUErrorMake(DUErrorUnsupportedOperation,
                           NSLocalizedString(@"The umount tool is not "
                                             @"installed.", nil));
    }

    NSString *target = nil;
    if (gate == nil) {
        if ([object isKindOfClass:[DUStorageVolume class]] &&
            ((DUStorageVolume *)object).mountPoint.length > 0) {
            target = ((DUStorageVolume *)object).mountPoint;
        } else {
            target =
                [DUFreeBSDGEOMAdapter currentMountTable][object.backendPath][@"mountPoint"];
        }
        if (target.length == 0) {
            gate = DUErrorMake(DUErrorUnmountError,
                               NSLocalizedString(@"This item is not "
                                                 @"mounted.", nil));
        }
    }

    if (gate != nil) {
        if (completion != NULL) {
            completion(gate);
        }
        return;
    }

    [self spawnWork:^{
        // umount detaches a filesystem for the whole session; needs root.
        DUProcessResult *result =
            [[DUAuthorizationManager sharedManager]
                runPrivileged:umountPath
                         args:@[ target ]
                      timeout:300.0
                        error:NULL];
        if (![self runSucceeded:result]) {
            BOOL busy = [result.standardError
                localizedCaseInsensitiveContainsString:@"busy"];
            NSString *message = busy
                ? NSLocalizedString(@"The volume is still in use.", nil)
                : NSLocalizedString(@"Unmounting failed.", nil);
            DUStorageErrorCode code =
                busy ? DUErrorDeviceBusy : DUErrorUnmountError;
            if (completion != NULL) {
                completion([self toolFailure:code
                                     message:message
                                      result:result]);
            }
            return;
        }
        if (completion != NULL) {
            completion(nil);
        }
    }];
}

- (void)ejectObject:(DUStorageObject *)object
          completion:(void (^)(NSError *error))completion
{
    NSError *gate =
        [self gateForOperation:kDUOperationEject onObject:object];
    if (gate == nil && object.backendPath.length == 0) {
        gate = DUErrorMake(DUErrorInvalidArgument,
                           NSLocalizedString(@"The item has no device node.",
                                             nil));
    }

    NSString *cdcontrolPath = [DUFreeBSDToolCache pathForTool:@"cdcontrol"];
    NSString *camcontrolPath = [DUFreeBSDToolCache pathForTool:@"camcontrol"];
    BOOL optical = NO;
    if (gate == nil) {
        if ([object isKindOfClass:[DUStorageDevice class]]) {
            optical = ((DUStorageDevice *)object).optical;
        } else {
            DUStorageObject *ancestor = object.parent;
            while (ancestor != nil) {
                if ([ancestor isKindOfClass:[DUStorageDevice class]]) {
                    optical = ((DUStorageDevice *)ancestor).optical;
                    break;
                }
                ancestor = ancestor.parent;
            }
        }
    }
    if (gate == nil && cdcontrolPath == nil && camcontrolPath == nil) {
        gate = DUErrorMake(DUErrorUnsupportedOperation,
                           NSLocalizedString(@"Neither cdcontrol nor "
                                             @"camcontrol is installed.",
                                             nil));
    }
    if (gate != nil) {
        if (completion != NULL) {
            completion(gate);
        }
        return;
    }

    NSString *node = object.backendPath;

    [self spawnWork:^{
        DUProcessResult *failure = nil;

        // Optical media leaves via cdcontrol first; tray semantics live
        // there, not in CAM. Anything else goes straight to camcontrol.
        // Both commands drive the drive hardware; needs root.
        if (optical && cdcontrolPath != nil) {
            DUProcessResult *result =
                [[DUAuthorizationManager sharedManager]
                    runPrivileged:cdcontrolPath
                             args:@[ @"-f", node, @"eject" ]
                          timeout:300.0
                            error:NULL];
            if ([self runSucceeded:result]) {
                if (completion != NULL) {
                    completion(nil);
                }
                return;
            }
            failure = result;
        }

        if (camcontrolPath != nil) {
            DUProcessResult *result =
                [[DUAuthorizationManager sharedManager]
                    runPrivileged:camcontrolPath
                             args:@[ @"eject",
                                     node.lastPathComponent ]
                          timeout:300.0
                            error:NULL];
            if ([self runSucceeded:result]) {
                if (completion != NULL) {
                    completion(nil);
                }
                return;
            }
            failure = failure ?: result;
        }

        if (completion != NULL) {
            completion([self toolFailure:DUErrorUnknown
                                 message:NSLocalizedString(
                                              @"Ejecting failed.", nil)
                                  result:failure]);
        }
    }];
}

#pragma mark - Restore

- (void)restoreFromSource:(DUStorageObject *)source
               destination:(DUStorageObject *)destination
                   options:(NSDictionary *)options
                  progress:(void (^)(double progress, NSString *message))progress
                completion:(void (^)(NSError *error))completion
{
    NSError *gate =
        [self gateForOperation:kDUOperationRestore onObject:destination];
    if (gate == nil && source == nil) {
        gate = DUErrorMake(DUErrorInvalidArgument,
                           NSLocalizedString(@"No restore source was chosen.",
                                             nil));
    }
    if (gate == nil &&
        (source.backendPath.length == 0 ||
         destination.backendPath.length == 0)) {
        gate = DUErrorMake(DUErrorInvalidArgument,
                           NSLocalizedString(@"Both source and destination "
                                             @"need device nodes.", nil));
    }
    if (gate == nil &&
        [source.backendPath isEqualToString:destination.backendPath]) {
        gate = DUErrorMake(DUErrorInvalidArgument,
                           NSLocalizedString(@"Source and destination are "
                                             @"the same device.", nil));
    }
    unsigned long long totalBytes =
        gate == nil ? [self sizeOfObject:destination] : 0;
    if (gate == nil && totalBytes == 0) {
        gate = DUErrorMake(
            DUErrorUnsupportedOperation,
            NSLocalizedString(@"The destination size is unknown, so restore "
                              @"cannot proceed safely.", nil));
    }

    NSString *busyNode = gate == nil
        ? [self mountedNodeAmong:[self nodesOfSubtree:destination]]
        : nil;
    if (gate == nil && busyNode != nil) {
        gate = DUErrorMake(DUErrorDeviceBusy,
                           [NSString stringWithFormat:
                                NSLocalizedString(
                                    @"%@ is mounted and must be unmounted "
                                    @"before restoring.", nil),
                            busyNode]);
    }

    NSString *ddPath = gate == nil
        ? [DUFreeBSDToolCache pathForTool:@"dd"]
        : nil;
    if (gate == nil && ddPath == nil) {
        gate = DUErrorMake(DUErrorUnsupportedOperation,
                           NSLocalizedString(@"Restoring requires dd, which "
                                             @"is not installed.", nil));
    }
    if (gate != nil) {
        if (completion != NULL) {
            completion(gate);
        }
        return;
    }

    // Image options are reserved; raw device copy is the only mode here.
    (void)options;
    NSString *sourceNode = source.backendPath;
    NSString *destinationNode = destination.backendPath;

    [self spawnWork:^{
        if (progress != NULL) {
            progress(0.0, NSLocalizedString(@"Copying...", nil));
        }
        NSMutableArray<NSString *> *arguments =
            [NSMutableArray arrayWithArray:@[
                [NSString stringWithFormat:@"if=%@", sourceNode],
                [NSString stringWithFormat:@"of=%@", destinationNode],
                @"bs=1M",
                @"status=progress",
            ]];

        // The streamed lines carry running byte counts; compare them with
        // the destination size for the fraction.
        DUProcessResult *result = [self
            blockingStreamedRun:ddPath
                      arguments:arguments
                    lineHandler:^(NSString *line) {
                        unsigned long long copied =
                            [self byteCountFromProgressLine:line];
                        if (copied == 0) {
                            return;
                        }
                        double ratio =
                            (double)copied / (double)totalBytes;
                        if (ratio > 1.0) {
                            ratio = 1.0;
                        }
                        if (progress != NULL) {
                            progress(ratio * 0.98,
                                     NSLocalizedString(@"Copying...", nil));
                        }
                    }];

        if (![self runSucceeded:result]) {
            if (result != nil && result.wasCancelled) {
                if (completion != NULL) {
                    completion(DUErrorMake(DUErrorCancelled,
                                           NSLocalizedString(
                                               @"Restore was cancelled.",
                                               nil)));
                }
                return;
            }
            if (completion != NULL) {
                completion([self toolFailure:DUErrorRestoreFailed
                                     message:NSLocalizedString(
                                                  @"Restoring the image "
                                                  @"failed.", nil)
                                      result:result]);
            }
            return;
        }
        if (progress != NULL) {
            progress(1.0,
                     NSLocalizedString(@"Restore completed.", nil));
        }
        if (completion != NULL) {
            completion(nil);
        }
    }];
}

#pragma mark - RAID

- (NSError *)createRAIDWithName:(NSString *)name
                          level:(NSString *)level
                        members:(NSArray<DUStorageObject *> *)members
{
    if (name.length == 0 || members.count < 2) {
        return DUErrorMake(DUErrorInvalidArgument,
                           NSLocalizedString(@"A RAID set needs a name and "
                                             @"at least two members.", nil));
    }

    NSDictionary<NSString *, NSString *> *tools = @{
        @"mirror" : @"gmirror",
        @"1" : @"gmirror",
        @"stripe" : @"gstripe",
        @"0" : @"gstripe",
        @"concat" : @"gconcat",
        @"linear" : @"gconcat",
    };
    NSString *tool = tools[level.lowercaseString];
    if (tool == nil) {
        return DUErrorMake(
            DUErrorUnsupportedOperation,
            [NSString stringWithFormat:
                 NSLocalizedString(@"RAID level %@ is not supported here.",
                                   nil),
             level]);
    }
    NSString *toolPath = [DUFreeBSDToolCache pathForTool:tool];
    if (toolPath == nil) {
        return DUErrorMake(
            DUErrorUnsupportedOperation,
            [NSString stringWithFormat:
                 NSLocalizedString(@"%@ is not installed.", nil),
             tool]);
    }

    NSMutableArray<NSString *> *memberNodes =
        [NSMutableArray arrayWithCapacity:members.count];
    for (DUStorageObject *member in members) {
        if (member.backendPath.length == 0) {
            return DUErrorMake(DUErrorInvalidArgument,
                               NSLocalizedString(@"A RAID member has no "
                                                 @"device node.", nil));
        }
        [memberNodes addObject:member.backendPath];
    }

    NSString *setName = [self sanitizedLabel:name limit:31];
    NSMutableArray<NSString *> *arguments =
        [NSMutableArray arrayWithObject:@"label"];
    [arguments addObject:@"-h"];
    [arguments addObject:setName];
    [arguments addObjectsFromArray:memberNodes];

    // glabel labels the member devices; needs root.
    DUProcessResult *result =
        [[DUAuthorizationManager sharedManager]
            runPrivileged:toolPath
                     args:arguments
                  timeout:300.0
                    error:NULL];
    if (![self runSucceeded:result]) {
        return [self toolFailure:DUErrorUnknown
                         message:NSLocalizedString(@"Creating the RAID set "
                                                   @"failed.", nil)
                          result:result];
    }
    return nil;
}

@end

#endif /* defined(__FreeBSD__) */
