/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#if defined(__OpenBSD__)

#import "DUOpenBSDStorageBackend.h"

#import <sys/statvfs.h>
#import <sys/wait.h>
#import <stdlib.h>
#import <unistd.h>

#import "DUErrors.h"
#import "DUAuthorizationManager.h"
#import "DUOpenBSDDeviceDiscovery.h"
#import "DUOpenBSDDisklabelParser.h"
#import "DUOpticalMedia.h"
#import "DUOpenBSDDeviceDiscovery.h"
#import "DUParsing.h"
#import "DUPartition.h"
#import "DUPartitionPlan.h"
#import "DUPartitionTableParser.h"
#import "DUProcessRunner.h"
#import "DUStorageCapabilities.h"
#import "DUStorageDevice.h"
#import "DUStorageVolume.h"

NSString *const DUOpenBSDBackendDetailKey = @"DUBackendDetail";

// UFS labels are capped by the FFS on-disk name field (15 characters);
// newfs_msdos FAT labels by the classic 11-character limit. Truncate before
// the tools reject them.
static const NSUInteger kMaxUFSLabelLength = 15;
static const NSUInteger kMaxFATLabelLength = 11;

// OpenBSD reserves partition letter c for the whole disk; templates and
// child assignments must skip it.
static NSString * const kWholeDiskLetter = @"c";

// Privileged tool runs get a bounded lifetime so a wedged device cannot pin
// a worker thread forever.
static const NSTimeInterval kToolTimeoutSeconds = 300.0;

@implementation DUOpenBSDStorageBackend

#pragma mark - Discovery

- (NSArray *)discoverStorageObjects:(NSError **)error
{
    return [[DUOpenBSDDeviceDiscovery new] discoverObjects:error];
}

- (NSDictionary *)capabilitiesReport
{
    // Flags reflect installed tools so the diagnostics page shows honest
    // answers instead of a flat "everything works" on minimal systems.
    return @{
        @"Platform" : @"OpenBSD",
        @"Device discovery" : @"yes",
        @"Mount management" :
            ([DUOpenBSDToolCache haveTool:@"mount"] &&
             [DUOpenBSDToolCache haveTool:@"umount"]) ? @"yes" : @"no",
        @"Partitioning" :
            ([DUOpenBSDToolCache haveTool:@"disklabel"]) ? @"partial" : @"no",
        @"Filesystem formatting" :
            ([DUOpenBSDToolCache haveTool:@"newfs"] ||
             [DUOpenBSDToolCache haveTool:@"newfs_msdos"]) ? @"yes" : @"no",
        @"Filesystem repair" :
            ([DUOpenBSDToolCache haveTool:@"fsck_ffs"] ||
             [DUOpenBSDToolCache haveTool:@"fsck_msdos"]) ? @"yes" : @"no",
        @"Secure erase" :
            [DUOpenBSDToolCache haveTool:@"dd"] ? @"partial" : @"no",
        @"RAID management" : @"no",
        @"Disk image mounting" : @"no",
        @"Disk image conversion" : @"no",
    };
}

#pragma mark - Format descriptors

- (NSArray<NSDictionary *> *)supportedFormatsForObject:(DUStorageObject *)object
{
    if (object == nil || object.capabilities.canErase == NO) {
        return @[];
    }
    BOOL ufsPossible = [DUOpenBSDToolCache haveTool:@"newfs"];
    BOOL fatPossible = [DUOpenBSDToolCache haveTool:@"newfs_msdos"];

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
            kDUFormatIdentifierKey : @"vfat",
            kDUFormatDisplayNameKey :
                [DUPartitionTableParser filesystemDisplayName:@"vfat"],
            kDUFormatCanFormatKey : @YES,
        }];
    }
    // Swap partitions are marked in the label, not formatted by a tool, so
    // the entry exists for planning but honestly reports cannot-format.
    [formats addObject:@{
        kDUFormatIdentifierKey : @"swap",
        kDUFormatDisplayNameKey :
            [DUPartitionTableParser filesystemDisplayName:@"swap"],
        kDUFormatCanFormatKey : @NO,
    }];
    return formats;
}

#pragma mark - Capability queries

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
    NSThread *worker = [[NSThread alloc]
        initWithBlock:^{
            @autoreleasepool {
                work();
            }
        }];
    worker.name = @"DU OpenBSD op";
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
        [DUParsing trimmedString:result.standardError] ?: @"";
    if (detail.length == 0) {
        detail = [DUParsing trimmedString:result.standardOutput] ?: @"";
    }
    NSUInteger tailStart = detail.length > 400 ? detail.length - 400 : 0;
    NSString *tail = [detail substringFromIndex:tailStart];

    return [NSError errorWithDomain:DUStorageErrorDomain
                               code:code
                           userInfo:@{
        NSLocalizedDescriptionKey : message,
        DUOpenBSDBackendDetailKey : tail,
    }];
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
        NSString *text =
            [DUParsing trimmedString:
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

#pragma mark - Object classification

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

// Filesystem tools insist on character devices; block nodes are converted
// with the classic "r" convention ("/dev/sd0a" -> "/dev/rsd0a"). A bare disk
// name has no raw alias of its own: the whole-disk letter completes it
// ("/dev/sd0" -> "/dev/rsd0c").
- (NSString *)rawNodeForPath:(NSString *)blockPath
{
    if (![blockPath hasPrefix:@"/dev/"]) {
        return blockPath;
    }
    NSString *base = [blockPath substringFromIndex:(NSUInteger)5];
    if ([base hasPrefix:@"r"] || base.length == 0) {
        return blockPath;
    }
    NSCharacterSet *digits = [NSCharacterSet decimalDigitCharacterSet];
    NSUInteger index = 0;
    while (index < base.length &&
           ![digits characterIsMember:[base characterAtIndex:index]]) {
        index++;
    }
    while (index < base.length &&
           [digits characterIsMember:[base characterAtIndex:index]]) {
        index++;
    }
    if (index < base.length) {
        // Letter suffix present: this is already a partition node.
        return [@"/dev/r" stringByAppendingString:base];
    }
    NSString *wholeDisk =
        [base stringByAppendingString:kWholeDiskLetter];
    return [@"/dev/r" stringByAppendingString:wholeDisk];
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
    if ([normalized isEqualToString:@"vfat"] ||
        [normalized isEqualToString:@"fat"] ||
        [normalized isEqualToString:@"fat16"] ||
        [normalized isEqualToString:@"fat32"] ||
        [normalized isEqualToString:@"msdos"]) {
        return @"fsck_msdos";
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
        @"ufs" : @"ffs",
        @"vfat" : @"msdos",
        @"fat16" : @"msdos",
        @"fat32" : @"msdos",
        @"cd9660" : @"cd9660",
        @"iso9660" : @"cd9660",
        @"ntfs" : @"ntfs",
        @"ext2" : @"ext2",
    };
    NSString *mapped = table[fstype.lowercaseString];
    return mapped ?: fstype;
}

// Formatter binary plus the label-length cap that applies to it; nil when
// no honest mapping exists (callers reject rather than guess).
- (NSString *)formatterNameForFormatIdentifier:(NSString *)identifier
                                 labelCapacity:(NSUInteger *)outLabelLimit
                                  ufsTakesLabel:(BOOL *)outUFSTakesLabel
{
    NSString *normalized = identifier.lowercaseString;
    if ([normalized isEqualToString:@"ufs"]) {
        if (outLabelLimit != NULL) {
            *outLabelLimit = kMaxUFSLabelLength;
        }
        if (outUFSTakesLabel != NULL) {
            // Only some newfs builds accept an FFS volume label; the caller
            // decides per platform whether "-L" may be passed.
            *outUFSTakesLabel = NO;
        }
        return @"newfs";
    }
    if ([normalized isEqualToString:@"vfat"] ||
        [normalized isEqualToString:@"fat"] ||
        [normalized isEqualToString:@"fat16"] ||
        [normalized isEqualToString:@"fat32"] ||
        [normalized isEqualToString:@"msdos"]) {
        if (outLabelLimit != NULL) {
            *outLabelLimit = kMaxFATLabelLength;
        }
        if (outUFSTakesLabel != NULL) {
            *outUFSTakesLabel = YES;
        }
        return @"newfs_msdos";
    }
    return nil;
}

// Canonical filesystem identifier back to the disklabel row spelling used
// in disklabel -R templates; nil when unmappable.
- (NSString *)labelFstypeForFormatIdentifier:(NSString *)identifier
{
    NSDictionary<NSString *, NSString *> *table = @{
        @"ufs" : @"4.2BSD",
        @"vfat" : @"MSDOS",
        @"fat" : @"MSDOS",
        @"fat16" : @"MSDOS",
        @"fat32" : @"MSDOS",
        @"swap" : @"swap",
        @"ntfs" : @"NTFS",
        @"ext2" : @"ext2fs",
        @"ext3" : @"ext2fs",
        @"ext4" : @"ext2fs",
    };
    return table[identifier.lowercaseString];
}

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
        label = [NSMutableString
            stringWithString:[label substringToIndex:limit]];
    }
    return label;
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
        [DUOpenBSDDeviceDiscovery currentMountTable];
    for (NSString *node in nodes) {
        if (table[node] != nil || table[node.lastPathComponent] != nil) {
            return node;
        }
    }
    // Whole-disk work must also catch mounted partitions whose names extend
    // the disk node ("sd0" vs mounted "sd0a"); letter suffixes are exactly
    // that pattern here.
    for (NSString *node in nodes) {
        NSString *base = node.lastPathComponent;
        if (base.length == 0) {
            continue;
        }
        NSRange lastLetter =
            [base rangeOfCharacterFromSet:
                       [NSCharacterSet lowercaseLetterCharacterSet]
                       options:NSBackwardsSearch];
        if (lastLetter.location == NSNotFound ||
            lastLetter.location != base.length - 1) {
            continue;
        }
        NSString *stem = [base substringToIndex:lastLetter.location];
        if (stem.length == 0) {
            continue;
        }
        for (NSString *mountedNode in table) {
            if ([mountedNode.lastPathComponent hasPrefix:stem] &&
                ![mountedNode.lastPathComponent isEqualToString:base]) {
                // Report the concrete mounted child ("/dev/sd0a"), not the
                // whole-disk alias, so the busy message names the volume.
                return table[mountedNode] != nil &&
                       [mountedNode hasPrefix:@"/dev/"]
                    ? mountedNode
                    : node;
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
    NSString *fstype =
        gate == nil ? [self filesystemTypeOfObject:object] : nil;
    if (gate == nil && (fstype.length == 0 ||
                        [fstype isEqualToString:@"swap"])) {
        gate = DUErrorMake(
            DUErrorUnsupportedOperation,
            NSLocalizedString(@"The selected item cannot be verified.", nil));
    }
    NSArray<NSString *> *readonlyArgs = nil;
    NSString *checker =
        gate == nil ? [self checkerNameForFilesystem:fstype] : nil;
    readonlyArgs =
        checker == nil ? nil : [self readonlyArgumentsForChecker:checker];
    NSString *checkerPath = checker == nil
        ? nil
        : [DUOpenBSDToolCache pathForTool:checker];
    if (gate == nil && checkerPath == nil) {
        gate = DUErrorMake(
            DUErrorUnsupportedOperation,
            [NSString stringWithFormat:
                 NSLocalizedString(@"No filesystem checker for %@ is "
                                   @"installed.",
                                   nil),
             fstype]);
    }
    if (gate != nil) {
        if (completion != NULL) {
            completion(gate);
        }
        return;
    }

    NSString *rawNode = [self rawNodeForPath:object.backendPath];
    [self spawnWork:^{
        if (progress != NULL) {
            progress(0.0,
                     NSLocalizedString(@"Checking filesystem...", nil));
        }
        NSMutableArray<NSString *> *arguments =
            [NSMutableArray arrayWithArray:readonlyArgs];
        [arguments addObject:rawNode];

        __block NSUInteger lineCount = 0;
        DUProcessResult *result = [self
            blockingStreamedRun:checkerPath
                      arguments:arguments
                    lineHandler:^(NSString *line) {
                NSString *text = [DUParsing trimmedString:line];
                if (text.length == 0) {
                    return;
                }
                lineCount++;
                if (progress != NULL) {
                    // fsck gives no machine-readable progress; advance a
                    // capped fraction per output line so the bar keeps
                    // moving honestly.
                    double fraction = 1.0 - 1.0 / (double)(lineCount + 1);
                    progress(fraction * 0.95, text);
                }
            }];

        if (![self runSucceeded:result]) {
            NSError *error = [self
                toolFailure:DUErrorVerificationFailed
                    message:NSLocalizedString(
                                @"The filesystem was found to be damaged.",
                                nil)
                     result:result];
            if (completion != NULL) {
                completion(error);
            }
            return;
        }
        if (progress != NULL) {
            progress(1.0, NSLocalizedString(@"Volume verified.", nil));
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
    NSString *busyNode =
        gate == nil ? [self mountedNodeAmong:[self nodesOfSubtree:object]]
                    : nil;
    if (gate == nil && busyNode != nil) {
        gate = DUErrorMake(DUErrorDeviceBusy,
                           [NSString stringWithFormat:
                                NSLocalizedString(
                                    @"%@ is mounted and must be unmounted "
                                    @"before repair.",
                                    nil),
                            busyNode]);
    }

    NSString *fstype =
        gate == nil ? [self filesystemTypeOfObject:object] : nil;
    NSString *checker =
        gate == nil ? [self checkerNameForFilesystem:fstype] : nil;
    NSString *checkerPath = checker == nil
        ? nil
        : [DUOpenBSDToolCache pathForTool:checker];
    if (gate == nil && checkerPath == nil) {
        gate = DUErrorMake(
            DUErrorUnsupportedOperation,
            [NSString stringWithFormat:
                 NSLocalizedString(@"No filesystem repair tool for %@ is "
                                   @"installed.",
                                   nil),
             fstype]);
    }
    if (gate != nil) {
        if (completion != NULL) {
            completion(gate);
        }
        return;
    }

    NSString *rawNode = [self rawNodeForPath:object.backendPath];
    BOOL forceFullScan = [checker isEqualToString:@"fsck_ffs"];
    [self spawnWork:^{
        if (progress != NULL) {
            progress(0.0, NSLocalizedString(@"Repairing filesystem...", nil));
        }
        NSMutableArray<NSString *> *arguments =
            [NSMutableArray arrayWithObject:@"-y"];
        if (forceFullScan) {
            [arguments addObject:@"-f"];
        }
        [arguments addObject:rawNode];

        __block NSUInteger lineCount = 0;
        DUProcessResult *result = [self
            blockingStreamedRun:checkerPath
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
            NSError *error =
                [self toolFailure:DUErrorRepairFailed
                          message:NSLocalizedString(
                                      @"The filesystem could not be repaired.",
                                      nil)
                           result:result];
            if (completion != NULL) {
                completion(error);
            }
            return;
        }
        if (progress != NULL) {
            progress(1.0, NSLocalizedString(@"Volume repaired.", nil));
        }
        if (completion != NULL) {
            completion(nil);
        }
    }];
}

#pragma mark - Erase

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
    NSString *busyNode =
        gate == nil ? [self mountedNodeAmong:[self nodesOfSubtree:object]]
                    : nil;
    if (gate == nil && busyNode != nil) {
        gate = DUErrorMake(DUErrorDeviceBusy,
                           [NSString stringWithFormat:
                                NSLocalizedString(
                                    @"%@ is mounted and must be unmounted "
                                    @"before erasing.",
                                    nil),
                            busyNode]);
    }

    NSString *formatIdentifier =
        [DUParsing trimmedString:options[kDUFormatIdentifierKey]];
    if (gate == nil && formatIdentifier.length == 0) {
        gate = DUErrorMake(
            DUErrorInvalidArgument,
            NSLocalizedString(@"No filesystem was chosen for the erased "
                              @"volume.",
                              nil));
    }
    NSUInteger labelLimit = 0;
    BOOL ufsTakesLabel = NO;
    NSString *formatter = gate == nil
        ? [self formatterNameForFormatIdentifier:formatIdentifier
                                   labelCapacity:&labelLimit
                                    ufsTakesLabel:&ufsTakesLabel]
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
        : [DUOpenBSDToolCache pathForTool:formatter];
    if (gate == nil && formatterPath == nil) {
        gate = DUErrorMake(
            DUErrorUnsupportedOperation,
            [NSString stringWithFormat:
                 NSLocalizedString(@"The %@ formatting tool is not "
                                   @"installed.",
                                   nil),
             formatter]);
    }

    NSString *securityMethod =
        [DUParsing trimmedString:options[kDUEraseSecurityMethodKey]];
    BOOL wipeWithZeros =
        [securityMethod isEqualToString:kDUEraseMethodZerosKey];
    NSString *ddPath = nil;
    if (gate == nil && wipeWithZeros) {
        ddPath = [DUOpenBSDToolCache pathForTool:@"dd"];
        if (ddPath == nil) {
            gate = DUErrorMake(
                DUErrorUnsupportedOperation,
                NSLocalizedString(@"Secure zeroing requires dd, which is "
                                  @"not installed.",
                                  nil));
        }
    }

    if (gate != nil) {
        if (completion != NULL) {
            completion(gate);
        }
        return;
    }

    NSString *rawNode = [self rawNodeForPath:object.backendPath];
    NSString *volumeName =
        [DUParsing trimmedString:options[@"name"]] ?: @"";
    NSString *label = [self sanitizedLabel:volumeName limit:labelLimit];
    unsigned long long totalBytes = [self sizeOfObject:object];

    [self spawnWork:^{
        double fraction = 0.0;

        if (wipeWithZeros) {
            if (progress != NULL) {
                progress(0.02,
                         NSLocalizedString(@"Writing zeroes over the "
                                           @"device...",
                                           nil));
            }
            NSMutableArray<NSString *> *ddArguments =
                [NSMutableArray arrayWithArray:@[
                    @"if=/dev/zero",
                    [NSString stringWithFormat:@"of=%@", rawNode],
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
                    double ratio = (double)written / (double)totalBytes;
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
                    completion([self
                        toolFailure:DUErrorEraseFailed
                            message:NSLocalizedString(
                                        @"Zeroing the device failed.", nil)
                             result:wipe]);
                }
                return;
            }
            fraction = 0.75;
        }

        // No signature-wipe pass: newfs rewrites the superblock area itself
        // and stale label remnants past the filesystem are harmless here,
        // so inventing extra writes would only add failure modes.
        if (progress != NULL) {
            progress(fraction + 0.1,
                     NSLocalizedString(@"Creating filesystem...", nil));
        }
        NSMutableArray<NSString *> *formatArguments =
            [NSMutableArray array];
        if (label.length > 0 && ufsTakesLabel) {
            [formatArguments addObjectsFromArray:@[ @"-L", label ]];
        }
        [formatArguments addObject:rawNode];
        DUProcessResult *created = [DUAuthorizationManager.sharedManager
            runPrivileged:formatterPath
                     args:formatArguments
                  timeout:kToolTimeoutSeconds
                    error:NULL];
        if (![self runSucceeded:created]) {
            if (completion != NULL) {
                completion([self
                    toolFailure:DUErrorEraseFailed
                        message:NSLocalizedString(
                                    @"Creating the filesystem failed.", nil)
                         result:created]);
            }
            return;
        }

        if (progress != NULL) {
            progress(1.0, NSLocalizedString(@"Erase completed.", nil));
        }
        if (completion != NULL) {
            completion(nil);
        }
    }];
}

#pragma mark - Partitioning

// Writes text securely (mkstemp, 0600, private directory) because the
// template carries the full intended layout before any tool sees it.
// Returns nil + fills error when creation or the write fails.
- (NSString *)secureTemporaryFileWithContents:(NSString *)contents
                                        error:(NSError **)error
{
    NSString *directory = NSTemporaryDirectory();
    if (directory.length == 0) {
        if (error != NULL) {
            *error = DUErrorMake(
                DUErrorUnknown,
                NSLocalizedString(@"No temporary directory available.", nil));
        }
        return nil;
    }
    NSString *candidate =
        [directory stringByAppendingPathComponent:@"DUdisklabelXXXXXX"];
    char *pathBuffer = strdup(candidate.fileSystemRepresentation);
    if (pathBuffer == NULL) {
        if (error != NULL) {
            *error = DUErrorMake(DUErrorUnknown,
                                 NSLocalizedString(@"Out of memory.", nil));
        }
        return nil;
    }
    int descriptor = mkstemp(pathBuffer);
    if (descriptor < 0) {
        free(pathBuffer);
        if (error != NULL) {
            *error = DUErrorMake(
                DUErrorUnknown,
                NSLocalizedString(@"The temporary layout file could not be "
                                  @"created.",
                                  nil));
        }
        return nil;
    }
    NSData *data = [contents dataUsingEncoding:NSUTF8StringEncoding];
    NSUInteger written = 0;
    BOOL failed = NO;
    while (written < data.length) {
        ssize_t chunk = write(descriptor, (const char *)data.bytes + written,
                              data.length - written);
        if (chunk <= 0) {
            failed = YES;
            break;
        }
        written += (NSUInteger)chunk;
    }
    if (close(descriptor) != 0) {
        failed = YES;
    }
    NSString *path = [NSString stringWithUTF8String:pathBuffer];
    free(pathBuffer);
    if (failed || path == nil) {
        if (path != nil) {
            unlink(path.fileSystemRepresentation);
        }
        if (error != NULL) {
            *error = DUErrorMake(
                DUErrorUnknown,
                NSLocalizedString(@"The temporary layout file could not be "
                                  @"written.",
                                  nil));
        }
        return nil;
    }
    return path;
}

- (void)partitionDevice:(DUStorageObject *)device
                 withPlan:(DUPartitionPlan *)plan
                progress:(void (^)(double progress, NSString *message))progress
              completion:(void (^)(NSError *error))completion
{
    NSError *gate = [self gateForOperation:kDUOperationPartition
                                 onObject:device];
    if (gate == nil && plan == nil) {
        gate = DUErrorMake(DUErrorInvalidArgument,
                           NSLocalizedString(@"No partition plan was given.",
                                             nil));
    }
    if (gate == nil && device.backendPath.length == 0) {
        gate = DUErrorMake(DUErrorInvalidArgument,
                           NSLocalizedString(@"The device has no device "
                                             @"node.",
                                             nil));
    }

    // Rewriting the label under mounted filesystems loses their contents.
    NSString *busyNode =
        gate == nil ? [self mountedNodeAmong:[self nodesOfSubtree:device]]
                    : nil;
    if (gate == nil && busyNode != nil) {
        gate = DUErrorMake(DUErrorDeviceBusy,
                           [NSString stringWithFormat:
                                NSLocalizedString(
                                    @"%@ is mounted and must be unmounted "
                                    @"before partitioning.",
                                    nil),
                            busyNode]);
    }

    NSString *scheme = gate == nil
        ? [DUPartitionTableParser normalizeSchemeToken:plan.scheme]
        : nil;
    if (gate == nil && ![scheme isEqualToString:@"bsd"]) {
        // Scripted MBR editing would need stdin control of `fdisk -e`,
        // which the process runner deliberately does not provide. Refusing
        // beats half-writing an MBR and dropping planned partitions.
        gate = DUErrorMake(
            DUErrorUnsupportedOperation,
            [NSString stringWithFormat:
                 NSLocalizedString(@"Partition scheme %@ is not supported "
                                   @"here; only BSD disklabel layouts can "
                                   @"be applied.",
                                   nil),
             plan.scheme ?: @""]);
    }

    NSString *disklabelPath = nil;
    if (gate == nil) {
        disklabelPath = [DUOpenBSDToolCache pathForTool:@"disklabel"];
        if (disklabelPath == nil) {
            gate = DUErrorMake(
                DUErrorUnsupportedOperation,
                NSLocalizedString(@"Partitioning requires disklabel, which "
                                  @"is not installed.",
                                  nil));
        }
    }

    // Sector geometry comes from the live label, not from the discovery
    // snapshot, so plans stay correct across re-plugs. A disk without an
    // existing label cannot take a -R rewrite either, so failing here is
    // honest rather than premature.
    NSDictionary<NSString *, id> *currentLabel = nil;
    unsigned long long sectorSize = 0;
    if (gate == nil) {
        DUProcessResult *probe = [DUProcessRunner
            runExecutable:disklabelPath
                arguments:@[ device.backendPath.lastPathComponent ]
                    error:NULL];
        currentLabel = probe != nil && probe.exitedNormally &&
                               WEXITSTATUS(probe.terminationStatus) == 0
            ? [DUOpenBSDDisklabelParser parseDisklabelOutput:
                                            probe.standardOutput]
            : nil;
        sectorSize = currentLabel != nil
            ? [currentLabel[kDisklabelKeySectorSize] unsignedLongLongValue]
            : 0;
        if (sectorSize == 0) {
            gate = DUErrorMake(
                DUErrorPartitionError,
                NSLocalizedString(@"The disk has no readable disklabel, so "
                                  @"a new one cannot be installed from a "
                                  @"template.",
                                  nil));
        }
    }

    // Resolve every entry up front so a bad plan fails synchronously
    // instead of after the label was already rewritten. The template
    // grammar demands explicit sizes and offsets in sectors.
    NSArray<DUPartition *> *entries = gate == nil ? plan.entries : nil;
    NSMutableArray<NSString *> *letters =
        [NSMutableArray arrayWithCapacity:entries.count];
    NSMutableArray<NSString *> *sizes =
        [NSMutableArray arrayWithCapacity:entries.count];
    NSMutableArray<NSString *> *offsets =
        [NSMutableArray arrayWithCapacity:entries.count];
    if (gate == nil) {
        for (NSUInteger i = 0; i < entries.count; i++) {
            DUPartition *entry = entries[i];
            if (entry.sizeBytes == 0) {
                gate = DUErrorMake(
                    DUErrorInvalidArgument,
                    [NSString stringWithFormat:
                         NSLocalizedString(@"Partition %lu has no size.",
                                           nil),
                     (unsigned long)(i + 1)]);
                break;
            }
            if (entry.offsetBytes == 0) {
                gate = DUErrorMake(
                    DUErrorInvalidArgument,
                    [NSString stringWithFormat:
                         NSLocalizedString(@"Partition %lu has no start "
                                           @"offset; explicit positions are "
                                           @"required.",
                                           nil),
                     (unsigned long)(i + 1)]);
                break;
            }
            if (entry.offsetBytes % sectorSize != 0) {
                gate = DUErrorMake(
                    DUErrorInvalidArgument,
                    [NSString stringWithFormat:
                         NSLocalizedString(@"Partition %lu does not start "
                                           @"on a sector boundary.",
                                           nil),
                     (unsigned long)(i + 1)]);
                break;
            }
            NSString *labelFstype = [self
                labelFstypeForFormatIdentifier:
                    [DUParsing trimmedString:entry.filesystemType] ?: @""];
            if (labelFstype == nil) {
                gate = DUErrorMake(
                    DUErrorInvalidArgument,
                    [NSString stringWithFormat:
                         NSLocalizedString(@"No disklabel filesystem type "
                                           @"mapping exists for %@.",
                                           nil),
                     entry.filesystemType ?: @""]);
                break;
            }
            // Letters run a..p skipping the reserved whole-disk letter:
            // every index at or past the reserved slot shifts up by one.
            NSUInteger letterIndex = i;
            if ((char)('a' + letterIndex) >=
                [kWholeDiskLetter characterAtIndex:0]) {
                letterIndex++;
            }
            if ((char)('a' + letterIndex) > 'p') {
                gate = DUErrorMake(
                    DUErrorInvalidArgument,
                    NSLocalizedString(@"Too many partitions for one "
                                      @"disklabel.",
                                      nil));
                break;
            }
            [letters addObject:[NSString stringWithFormat:@"%c",
                                                          (char)('a' +
                                                                 letterIndex)]];
            unsigned long long sizeSectors =
                (entry.sizeBytes + sectorSize - 1) / sectorSize;
            [sizes addObject:[NSString stringWithFormat:@"%llu",
                                                        sizeSectors]];
            [offsets addObject:[NSString stringWithFormat:@"%llu",
                                                          (unsigned long long)(
                                                              entry.offsetBytes /
                                                              sectorSize)]];
        }
    }
    if (gate == nil && entries.count == 0) {
        gate = DUErrorMake(DUErrorInvalidArgument,
                           NSLocalizedString(@"The plan contains no "
                                             @"partitions.",
                                             nil));
    }

    if (gate != nil) {
        if (completion != NULL) {
            completion(gate);
        }
        return;
    }

    NSMutableString *template = [NSMutableString string];
    for (NSUInteger i = 0; i < letters.count; i++) {
        [template appendFormat:@"%@: %@ %@ %@\n", letters[i], sizes[i],
                               offsets[i],
                               [self labelFstypeForFormatIdentifier:
                                         [DUParsing trimmedString:
                                                       entries[i]
                                                           .filesystemType]]];
    }

    NSString *rawDiskNode = [self rawNodeForPath:device.backendPath];
    NSError *templateError = nil;
    NSString *templatePath =
        [self secureTemporaryFileWithContents:template error:&templateError];
    if (templatePath == nil) {
        if (completion != NULL) {
            completion(templateError);
        }
        return;
    }

    [self spawnWork:^{
        if (progress != NULL) {
            progress(0.2,
                     NSLocalizedString(@"Writing the disklabel...", nil));
        }
        DUProcessResult *result =
            [DUAuthorizationManager.sharedManager
                runPrivileged:disklabelPath
                         args:@[ @"-R", rawDiskNode, templatePath ]
                      timeout:kToolTimeoutSeconds
                        error:NULL];
        // The template must vanish regardless of how the tool run ends; it
        // describes the layout and outliving the operation serves nobody.
        unlink(templatePath.fileSystemRepresentation);

        if (![self runSucceeded:result]) {
            if (completion != NULL) {
                completion([self
                    toolFailure:DUErrorPartitionError
                        message:NSLocalizedString(
                                    @"Writing the disklabel failed.", nil)
                         result:result]);
            }
            return;
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
    NSError *gate = [self gateForOperation:kDUOperationMount onObject:object];
    if (gate == nil && object.backendPath.length == 0) {
        gate = DUErrorMake(DUErrorInvalidArgument,
                           NSLocalizedString(@"The item has no device node.",
                                             nil));
    }

    if (gate == nil) {
        NSDictionary *existing =
            [DUOpenBSDDeviceDiscovery currentMountTable][object.backendPath];
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
    NSString *mountType =
        gate == nil && fstype.length > 0
            ? [self mountTypeForFilesystem:fstype]
            : nil;
    if (gate == nil && mountType.length == 0) {
        gate = DUErrorMake(
            DUErrorUnsupportedOperation,
            NSLocalizedString(@"The filesystem type of this item is unknown, "
                              @"so it cannot be mounted.",
                              nil));
    }
    NSString *mountPath = gate == nil
        ? [DUOpenBSDToolCache pathForTool:@"mount"]
        : nil;
    if (gate == nil && mountPath == nil) {
        gate = DUErrorMake(DUErrorUnsupportedOperation,
                           NSLocalizedString(@"The mount tool is not "
                                             @"installed.",
                                             nil));
    }

    if (gate != nil) {
        if (completion != NULL) {
            completion(gate, nil);
        }
        return;
    }

    NSString *node = object.backendPath;
    NSString *directory =
        [@"/media/" stringByAppendingString:node.lastPathComponent];
    NSError *directoryError = nil;
    if ([[NSFileManager defaultManager] createDirectoryAtPath:directory
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:&directoryError]
            == NO &&
        directoryError != nil) {
        if (completion != NULL) {
            completion(DUErrorMake(
                           DUErrorMountError,
                           [NSString stringWithFormat:
                                NSLocalizedString(
                                    @"The mount point %@ could not be "
                                    @"created.",
                                    nil),
                                directory]),
                       nil);
        }
        return;
    }

    [self spawnWork:^{
        NSError *runError = nil;
        DUProcessResult *result =
            [DUAuthorizationManager.sharedManager
                runPrivileged:mountPath
                         args:@[ @"-t", mountType, node, directory ]
                      timeout:kToolTimeoutSeconds
                        error:&runError];
        if (![self runSucceeded:result]) {
            NSString *detail =
                result.standardError.length > 0 ? result.standardError
                                                : runError.localizedDescription;
            BOOL busy =
                [detail rangeOfString:@"busy"].location != NSNotFound ||
                [detail rangeOfString:@"already mounted"].location !=
                    NSNotFound;
            if (completion != NULL) {
                completion([NSError
                               errorWithDomain:DUStorageErrorDomain
                                          code:busy ? DUErrorDeviceBusy
                                                    : DUErrorMountError
                                      userInfo:@{
                    NSLocalizedDescriptionKey :
                        NSLocalizedString(@"Mounting failed.", nil),
                    DUOpenBSDBackendDetailKey :
                        [DUParsing trimmedString:detail] ?: @"",
                }],
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

    NSString *umountPath = gate == nil
        ? [DUOpenBSDToolCache pathForTool:@"umount"]
        : nil;
    if (gate == nil && umountPath == nil) {
        gate = DUErrorMake(DUErrorUnsupportedOperation,
                           NSLocalizedString(@"The umount tool is not "
                                             @"installed.",
                                             nil));
    }

    NSString *target = nil;
    if (gate == nil) {
        if ([object isKindOfClass:[DUStorageVolume class]] &&
            ((DUStorageVolume *)object).mountPoint.length > 0) {
            target = ((DUStorageVolume *)object).mountPoint;
        } else {
            target = [DUOpenBSDDeviceDiscovery
                         currentMountTable][object.backendPath][@"mountPoint"];
        }
        if (target.length == 0) {
            gate = DUErrorMake(DUErrorUnmountError,
                               NSLocalizedString(@"This item is not "
                                                 @"mounted.",
                                                 nil));
        }
    }

    if (gate != nil) {
        if (completion != NULL) {
            completion(gate);
        }
        return;
    }

    [self spawnWork:^{
        NSError *runError = nil;
        DUProcessResult *result = [DUAuthorizationManager.sharedManager
            runPrivileged:umountPath
                     args:@[ target ]
                  timeout:kToolTimeoutSeconds
                    error:&runError];
        if (![self runSucceeded:result]) {
            NSString *detail =
                result.standardError.length > 0 ? result.standardError
                                                : runError.localizedDescription;
            BOOL busy =
                [detail rangeOfString:@"busy"].location != NSNotFound ||
                [detail rangeOfString:@"in use"].location != NSNotFound;
            DUStorageErrorCode code =
                busy ? DUErrorDeviceBusy : DUErrorUnmountError;
            NSString *message = busy
                ? NSLocalizedString(@"The volume is still in use.", nil)
                : NSLocalizedString(@"Unmounting failed.", nil);
            if (completion != NULL) {
                completion([NSError errorWithDomain:DUStorageErrorDomain
                                               code:code
                                           userInfo:@{
                    NSLocalizedDescriptionKey : message,
                    DUOpenBSDBackendDetailKey :
                        [DUParsing trimmedString:detail] ?: @"",
                }]);
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
    NSError *gate = [self gateForOperation:kDUOperationEject onObject:object];
    if (gate == nil && object.backendPath.length == 0) {
        gate = DUErrorMake(DUErrorInvalidArgument,
                           NSLocalizedString(@"The item has no device node.",
                                             nil));
    }
    NSString *ejectPath = gate == nil
        ? [DUOpenBSDToolCache pathForTool:@"eject"]
        : nil;
    if (gate == nil && ejectPath == nil) {
        gate = DUErrorMake(DUErrorUnsupportedOperation,
                           NSLocalizedString(@"The eject tool is not "
                                             @"installed.",
                                             nil));
    }

    // Eject the containing drive, not a partition on the media.
    NSString *devicePath = nil;
    if (gate == nil) {
        DUStorageObject *root = object;
        while (root.parent != nil) {
            root = root.parent;
        }
        devicePath = root.backendPath ?: object.backendPath;
    }

    if (gate != nil) {
        if (completion != NULL) {
            completion(gate);
        }
        return;
    }

    [self spawnWork:^{
        // Unmount first so the tray does not pop with open files.
        for (NSString *node in [self nodesOfSubtree:object]) {
            NSDictionary *entry =
                [DUOpenBSDDeviceDiscovery currentMountTable][node];
            NSString *mountPoint =
                [DUParsing trimmedString:entry[@"mountPoint"]];
            if (mountPoint.length == 0) {
                continue;
            }
            NSString *umountPath =
                [DUOpenBSDToolCache pathForTool:@"umount"];
            if (umountPath == nil) {
                if (completion != NULL) {
                    completion(DUErrorMake(
                        DUErrorDeviceBusy,
                        NSLocalizedString(@"A volume on this media is "
                                          @"mounted and umount is not "
                                          @"installed.",
                                          nil)));
                }
                return;
            }
            [DUAuthorizationManager.sharedManager
                runPrivileged:umountPath
                         args:@[ mountPoint ]
                      timeout:kToolTimeoutSeconds
                        error:NULL];
        }

        NSError *runError = nil;
        DUProcessResult *result = [DUAuthorizationManager.sharedManager
            runPrivileged:ejectPath
                     args:@[ devicePath ]
                  timeout:kToolTimeoutSeconds
                    error:&runError];
        if (![self runSucceeded:result]) {
            if (completion != NULL) {
                NSString *detail =
                    result.standardError.length > 0
                        ? result.standardError
                        : runError.localizedDescription;
                completion([NSError
                    errorWithDomain:DUStorageErrorDomain
                               code:DUErrorUnknown
                           userInfo:@{
                    NSLocalizedDescriptionKey :
                        NSLocalizedString(@"The media could not be ejected.",
                                          nil),
                    DUOpenBSDBackendDetailKey :
                        [DUParsing trimmedString:detail] ?: @"",
                }]);
            }
            return;
        }
        if (completion != NULL) {
            completion(nil);
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
                                             @"need device nodes.",
                                             nil));
    }
    if (gate == nil &&
        [source.backendPath isEqualToString:destination.backendPath]) {
        gate = DUErrorMake(DUErrorInvalidArgument,
                           NSLocalizedString(@"Source and destination are "
                                             @"the same device.",
                                             nil));
    }
    unsigned long long totalBytes =
        gate == nil ? [self sizeOfObject:destination] : 0;
    if (gate == nil && totalBytes == 0) {
        gate = DUErrorMake(
            DUErrorUnsupportedOperation,
            NSLocalizedString(@"The destination size is unknown, so restore "
                              @"cannot proceed safely.",
                              nil));
    }

    NSString *busyNode =
        gate == nil
            ? [self mountedNodeAmong:[self nodesOfSubtree:destination]]
            : nil;
    if (gate == nil && busyNode != nil) {
        gate = DUErrorMake(DUErrorDeviceBusy,
                           [NSString stringWithFormat:
                                NSLocalizedString(
                                    @"%@ is mounted and must be unmounted "
                                    @"before restoring.",
                                    nil),
                            busyNode]);
    }

    NSString *ddPath = gate == nil
        ? [DUOpenBSDToolCache pathForTool:@"dd"]
        : nil;
    if (gate == nil && ddPath == nil) {
        gate = DUErrorMake(DUErrorUnsupportedOperation,
                           NSLocalizedString(@"Restoring requires dd, which "
                                             @"is not installed.",
                                             nil));
    }
    if (gate != nil) {
        if (completion != NULL) {
            completion(gate);
        }
        return;
    }

    // Image options are reserved; raw device copy is the only mode here.
    (void)options;
    NSString *sourceNode = [self rawNodeForPath:source.backendPath];
    NSString *destinationNode =
        [self rawNodeForPath:destination.backendPath];

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
        DUProcessResult *result =
            [self blockingStreamedRun:ddPath
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
                                           NSLocalizedString(@"Copying...",
                                                             nil));
                              }
                          }];

        if (![self runSucceeded:result]) {
            if (result != nil && result.wasCancelled) {
                if (completion != NULL) {
                    completion(DUErrorMake(
                        DUErrorCancelled,
                        NSLocalizedString(@"Restore was cancelled.", nil)));
                }
                return;
            }
            if (completion != NULL) {
                completion([self
                    toolFailure:DUErrorRestoreFailed
                        message:NSLocalizedString(
                                    @"Restoring the image failed.", nil)
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

@end

#endif /* defined(__OpenBSD__) */
