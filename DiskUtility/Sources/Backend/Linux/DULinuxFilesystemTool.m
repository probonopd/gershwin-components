/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#if defined(__linux__)

#import "DULinuxFilesystemTool.h"

#import <stdlib.h>

#import <sys/wait.h>
#import <unistd.h>

#import "DUErrors.h"
#import "DUParsing.h"
#import "DUProcessRunner.h"
#import "DUAuthorizationManager.h"

NSString * const kDUBackendDetailKey = @"DUBackendDetail";

// streamExecutable delivers its finish callback from a watcher thread; the
// calling thread polls this flag exactly like DUProcessRunner joins its
// pipe-reader threads. No GCD anywhere.
@interface DUStreamWait : NSObject
@property (nonatomic, strong) NSLock *lock;
@property (nonatomic) BOOL finished;
@end

@implementation DUStreamWait
- (instancetype)init
{
    if ((self = [super init]) == nil) {
        return nil;
    }
    _lock = [NSLock new];
    _finished = NO;
    return self;
}
- (void)markFinished
{
    [self.lock lock];
    self.finished = YES;
    [self.lock unlock];
}
- (BOOL)isFinished
{
    [self.lock lock];
    BOOL value = self.finished;
    [self.lock unlock];
    return value;
}
@end

// Last chunk of stderr kept under kDUBackendDetailKey; full transcripts
// belong to the operation log, not to error dictionaries.
static NSString *StderrTail(NSString *text)
{
    NSString *trimmed = [DUParsing trimmedString:text] ?: @"";
    static const NSUInteger kTailLimit = 800;
    if (trimmed.length > kTailLimit) {
        trimmed = [trimmed substringFromIndex:trimmed.length - kTailLimit];
    }
    return trimmed;
}

// Byte count from a dd "123456789 bytes (1.2 GB, 1.1 GiB) copied" progress
// or summary line; 0 when the line carries none.
static unsigned long long DdByteCountFromLine(NSString *line)
{
    if (line.length == 0) {
        return 0;
    }
    NSRange bytesRange = [line rangeOfString:@" bytes"];
    if (bytesRange.location == NSNotFound || bytesRange.location == 0) {
        return 0;
    }
    NSString *head = [line substringToIndex:bytesRange.location];
    // strtoull skips whitespace and stops at the first non-digit, so a
    // "\r1234567 bytes..." remnant still parses correctly.
    return strtoull(head.UTF8String, NULL, 10);
}

// Human-readable size for progress messages ("1.4 GiB"); binary units
// match what capacity displays elsewhere in the app show.
static NSString *HumanBytes(unsigned long long bytes)
{
    static const char *units[] = { "B", "KiB", "MiB", "GiB", "TiB", "PiB" };
    double value = (double)bytes;
    NSUInteger unit = 0;
    while (value >= 1024.0 && unit < sizeof(units) / sizeof(units[0]) - 1) {
        value /= 1024.0;
        unit++;
    }
    if (unit == 0) {
        return [NSString stringWithFormat:@"%llu %@", bytes,
                                          @(units[0])];
    }
    return [NSString stringWithFormat:@"%.2f %@",
                                      value, @(units[unit])];
}

// Maps one tool output line to a coarse stage fraction so the progress bar
// moves through real work instead of sitting indeterminate. e2fsck prints
// "Pass 1:".."Pass 5:", mke2fs announces inode tables/superblocks/journal
// stages. Only ever raises the fraction (monotonic per ARCHITECTURE.md 30).
static double StageFractionForLine(NSString *line, double current)
{
    if (line.length == 0) {
        return current;
    }
    NSString *lower = [line lowercaseString];
    double candidate = current;

    // fsck family: five passes.
    for (NSUInteger pass = 1; pass <= 5; pass++) {
        if ([lower hasPrefix:[NSString stringWithFormat:@"pass %lu:",
                                                       (unsigned long)pass]] ||
            [lower hasPrefix:[NSString stringWithFormat:@"pass %lu ",
                                                        (unsigned long)pass]]) {
            candidate = MAX(candidate, ((double)pass - 0.5) / 5.0);
        }
    }

    // mkfs.ext2/3/4 stages.
    NSRange ratio = [lower rangeOfString:@"/"];
    if (ratio.location != NSNotFound && ratio.location > 0 &&
        ratio.location + 1 < lower.length) {
        unichar before = [lower characterAtIndex:ratio.location - 1];
        unichar after = [lower characterAtIndex:ratio.location + 1];
        BOOL digits = isdigit(before) && isdigit(after);
        if (digits && [lower containsString:@"inode tables"]) {
            // "Writing inode tables: 34/1280" -> fraction within the phase.
            NSScanner *scanner = [NSScanner scannerWithString:lower];
            [scanner setScanLocation:0];
            double written = -1.0;
            while (!scanner.isAtEnd) {
                NSString *word = nil;
                [scanner scanUpToCharactersFromSet:
                             [[NSCharacterSet whitespaceCharacterSet]
                                 invertedSet]
                                      intoString:&word];
                NSScanner *wordScanner = [NSScanner scannerWithString:word ?: @""];
                double n = 0;
                double m = 0;
                if ([wordScanner scanDouble:&n] && [wordScanner scanString:@"/" intoString:NULL] &&
                    [wordScanner scanDouble:&m] && m > 0) {
                    written = n / m;
                    break;
                }
            }
            if (written >= 0) {
                candidate = MAX(candidate, 0.15 + 0.6 * written);
            } else {
                candidate = MAX(candidate, 0.35);
            }
        }
    }
    if ([lower containsString:@"creating journal"]) {
        candidate = MAX(candidate, 0.8);
    }
    if ([lower containsString:@"writing superblocks"] ||
        [lower containsString:@"writing filesystem state"]) {
        candidate = MAX(candidate, 0.92);
    }
    if ([lower containsString:@"creating filesystem"]) {
        candidate = MAX(candidate, 0.1);
    }
    return candidate;
}

// Runs a tool with its merged output streamed line-by-line to progressBlock
// and blocks until exit. okExitMask is a bitmask of acceptable WEXITSTATUS
// values; anything else maps to failCode with the output tail under
// kDUBackendDetailKey.
static NSError *RunStreamedTool(NSString *toolName,
                                NSArray<NSString *> *aliasNames,
                                NSArray<NSString *> *arguments,
                                void (^progress)(double fraction,
                                                 NSString *line),
                                unsigned okExitMask,
                                DUStorageErrorCode failCode,
                                NSString *failMessage)
{
    NSString *path = nil;
    for (NSString *candidate in aliasNames ?: @[ toolName ]) {
        path = [DUProcessRunner executablePathForName:candidate];
        if (path != nil) {
            break;
        }
    }
    if (path == nil) {
        return DUErrorMake(DUErrorUnsupportedOperation,
                           [NSString stringWithFormat:
                                NSLocalizedString(
                                    @"The required tool %@ is not installed.",
                                    nil), toolName]);
    }

    DUStreamWait *wait = [[DUStreamWait alloc] init];
    __block NSError *result = nil;
    __block double stage = 0.05;
    __block NSMutableString *transcript = [NSMutableString string];
    NSError *streamError = nil;

    // mkfs/fsck write or read raw device nodes, so the tool runs elevated
    // (sudo -A askpass when not root); long-running filesystem work is
    // unbounded by design and cancellable via handle.
    // No timeout parameter exists on the streaming runner.
    [[DUAuthorizationManager sharedManager]
        streamPrivileged:path
                    args:arguments
           stdoutHandler:^(NSString *line) {
               [transcript appendFormat:@"%@\n", line];
               if (progress == NULL) {
                   return;
               }
               stage = StageFractionForLine(line, stage);
               progress(stage, line);
           }
            finishHandler:^(DUProcessResult *processResult) {
                int status = 0;
                if (processResult.exitedNormally) {
                    status = WEXITSTATUS(processResult
                                             .terminationStatus);
                }
                if (!processResult.exitedNormally ||
                    (okExitMask & (1u << status)) == 0) {
                    // Output is merged into standardOutput by the streaming
                    // runner; keep the tail as backend detail either way.
                    NSString *detail = processResult.standardError.length > 0
                        ? processResult.standardError
                        : processResult.standardOutput;
                    result = [NSError
                        errorWithDomain:DUStorageErrorDomain
                                   code:failCode
                               userInfo:@{
                     NSLocalizedDescriptionKey :
                         failMessage ?: @"",
                     kDUBackendDetailKey :
                         StderrTail(detail),
                               }];
                }
                [wait markFinished];
            }
                      error:&streamError];
    if (streamError != nil) {
        return streamError;
    }

    while (!wait.isFinished) {
        usleep(20000);
    }
    return result;
}

@implementation DULinuxFilesystemTool

+ (NSArray<NSString *> *)formattableFilesystemTypes
{
    return @[ @"ext2", @"ext3", @"ext4", @"vfat", @"exfat", @"ntfs",
              @"xfs", @"btrfs", @"f2fs", @"swap" ];
}

// The -F/-f/-I/-Q flags keep mkfs non-interactive: our process runner never
// attaches a stdin, so any "are you sure?" prompt would read EOF and abort.
+ (NSArray<NSString *> *)formatArgumentsForFilesystemType:(NSString *)fstype
                                                    label:(NSString *)label
{
    NSDictionary<NSString *, NSArray<NSString *> *> *table =
        @{ @"ext2" : @[ @"mkfs.ext2", @"-F" ],
           @"ext3" : @[ @"mkfs.ext3", @"-F" ],
           @"ext4" : @[ @"mkfs.ext4", @"-F" ],
           @"vfat" : @[ @"mkfs.vfat", @"-I" ],
           @"exfat" : @[ @"mkfs.exfat" ],
           @"ntfs" : @[ @"mkfs.ntfs", @"-Q" ],
           @"xfs" : @[ @"mkfs.xfs", @"-f" ],
           @"btrfs" : @[ @"mkfs.btrfs", @"-f" ],
           @"f2fs" : @[ @"mkfs.f2fs" ],
           @"swap" : @[ @"mkswap" ] };
    NSArray<NSString *> *base = table[fstype];
    if (base == nil || label.length == 0) {
        return base;
    }

    // Label flag spelling differs per mkfs implementation.
    NSDictionary<NSString *, NSString *> *flagTable =
        @{ @"ext2" : @"-L",
           @"ext3" : @"-L",
           @"ext4" : @"-L",
           @"vfat" : @"-n",
           @"exfat" : @"-n",
           @"ntfs" : @"--label",
           @"xfs" : @"-L",
           @"btrfs" : @"-L",
           @"f2fs" : @"-l",
           @"swap" : @"-L" };
    NSMutableArray<NSString *> *arguments = [base mutableCopy];
    [arguments addObjectsFromArray:@[ flagTable[fstype], label ]];
    return arguments;
}

+ (NSString *)checkToolNameForFilesystemType:(NSString *)fstype
{
    // Swap has no checker; iso9660/udf media is verified by reading it.
    NSDictionary<NSString *, NSString *> *table =
        @{ @"ext2" : @"fsck.ext2",
           @"ext3" : @"fsck.ext3",
           @"ext4" : @"fsck.ext4",
           @"vfat" : @"fsck.vfat",
           @"msdos" : @"fsck.fat",
           @"exfat" : @"fsck.exfat",
           @"ntfs" : @"fsck.ntfs",
           @"xfs" : @"fsck.xfs",
           @"btrfs" : @"fsck.btrfs",
           @"f2fs" : @"fsck.f2fs" };
    return table[fstype];
}

+ (NSArray<NSString *> *)checkToolAliasesForFilesystemType:(NSString *)fstype
{
    // vfat checkers ship under both names depending on the distribution.
    NSDictionary<NSString *, NSArray<NSString *> *> *aliases =
        @{ @"vfat" : @[ @"fsck.vfat", @"fsck.fat" ],
           @"msdos" : @[ @"fsck.msdos", @"fsck.fat" ],
           @"ext2" : @[ @"fsck.ext2", @"e2fsck" ],
           @"ext3" : @[ @"fsck.ext3", @"e2fsck" ],
           @"ext4" : @[ @"fsck.ext4", @"e2fsck" ] };
    NSArray<NSString *> *list = aliases[fstype];
    NSString *single = [self checkToolNameForFilesystemType:fstype];
    if (list != nil) {
        return list;
    }
    return single != nil ? @[ single ] : nil;
}

+ (NSString *)resizeToolNameForFilesystemType:(NSString *)fstype
{
    NSDictionary<NSString *, NSString *> *table =
        @{ @"ext2" : @"resize2fs",
           @"ext3" : @"resize2fs",
           @"ext4" : @"resize2fs",
           @"xfs" : @"xfs_growfs",
           @"ntfs" : @"ntfsresize",
           @"btrfs" : @"btrfs",
           @"f2fs" : @"resize.f2fs" };
    return table[fstype];
}

+ (BOOL)journalingToggleAvailable
{
    return [DUProcessRunner executablePathForName:@"tune2fs"] != nil;
}

+ (NSError *)verifyVolumeAtDevicePath:(NSString *)devicePath
                       filesystemType:(NSString *)fstype
                             progress:(void (^)(double, NSString *))progress
{
    // fsck exit bits (e2fsprogs): 0 clean, 1 corrected, 2 reboot needed,
    // 4 uncorrected errors, 8 operational error, 16 usage, 32 canceled.
    // A read-only verify only counts as success when nothing was wrong at
    // all; even auto-corrections mean the volume was damaged.
    return RunStreamedTool([self checkToolNameForFilesystemType:fstype],
                           [self checkToolAliasesForFilesystemType:fstype],
                           @[ @"-n", devicePath ],
                           progress,
                           1u << 0,
                           DUErrorVerificationFailed,
                           NSLocalizedString(@"The filesystem was found to "
                                               @"be damaged.",
                                              nil));
}

+ (NSError *)repairVolumeAtDevicePath:(NSString *)devicePath
                       filesystemType:(NSString *)fstype
                             progress:(void (^)(double, NSString *))progress
{
    // Repair accepts "clean" and "errors corrected"; everything else means
    // damage remains or fsck could not run.
    return RunStreamedTool([self checkToolNameForFilesystemType:fstype],
                           [self checkToolAliasesForFilesystemType:fstype],
                           @[ @"-y", devicePath ],
                           progress,
                           (1u << 0) | (1u << 1),
                           DUErrorRepairFailed,
                           NSLocalizedString(@"The filesystem could not be "
                                              @"repaired.",
                                             nil));
}

+ (NSError *)wipeSignaturesAtDevicePath:(NSString *)devicePath
{
    NSString *wipefs = [DUProcessRunner executablePathForName:@"wipefs"];
    if (wipefs == nil) {
        // Absent wipefs degrades to plain formatting instead of failing the
        // whole erase; mkfs overwrites the primary signatures itself.
        return nil;
    }

    // wipefs rewrites the device signature area; needs root.
    NSError *launchError = nil;
    DUProcessResult *result = [[DUAuthorizationManager sharedManager]
        runPrivileged:wipefs
                 args:@[ @"-a", devicePath ]
              timeout:300.0
                error:&launchError];
    if (launchError != nil) {
        return launchError;
    }
    if (!result.exitedNormally || WEXITSTATUS(result.terminationStatus) != 0) {
        return [NSError errorWithDomain:DUStorageErrorDomain
                                   code:DUErrorEraseFailed
                               userInfo:@{
            NSLocalizedDescriptionKey :
                NSLocalizedString(@"Existing signatures could not be "
                                  @"removed.",
                                  nil),
            kDUBackendDetailKey : StderrTail(result.standardError),
        }];
    }
    return nil;
}

+ (NSError *)zeroFillDevicePath:(NSString *)devicePath
                      sizeBytes:(unsigned long long)sizeBytes
                       progress:(void (^)(double, NSString *))progress
{
    NSString *dd = [DUProcessRunner executablePathForName:@"dd"];
    if (dd == nil) {
        return DUErrorMake(DUErrorUnsupportedOperation,
                           NSLocalizedString(@"The required tool dd is not "
                                              @"installed.",
                                             nil));
    }
    if (progress != NULL) {
        progress(0.0,
                 NSLocalizedString(@"Writing zeros to the device...", nil));
    }

    // Zeroing overwrites every byte of the device; needs root. Streaming
    // keeps dd's status=progress lines feeding both the fraction and the
    // operation log instead of a frozen indeterminate bar.
    DUStreamWait *wait = [[DUStreamWait alloc] init];
    __block NSError *result = nil;
    NSError *streamError = nil;

    [[DUAuthorizationManager sharedManager]
        streamPrivileged:dd
                    args:@[ @"if=/dev/zero",
                            [@"of=" stringByAppendingString:devicePath],
                            @"bs=1M",
                            @"status=progress" ]
           stdoutHandler:^(NSString *line) {
               if (progress == NULL) {
                   return;
               }
               unsigned long long copied = DdByteCountFromLine(line);
               double fraction = copied > 0 && sizeBytes > 0
                   ? MIN(1.0, (double)copied / (double)sizeBytes)
                   : 0.0;
               progress(fraction,
                        fraction > 0
                            ? [NSString stringWithFormat:
                                  NSLocalizedString(@"Written %@ of %@...",
                                                    nil),
                                  HumanBytes(copied),
                                  HumanBytes(sizeBytes)]
                            : line);
           }
            finishHandler:^(DUProcessResult *processResult) {
                if (!processResult.exitedNormally ||
                    WEXITSTATUS(processResult.terminationStatus) != 0) {
                    // Merged streaming puts the tool transcript (progress,
                    // summary, errors) in standardOutput.
                    result = [NSError errorWithDomain:DUStorageErrorDomain
                                                 code:DUErrorEraseFailed
                                             userInfo:@{
                        NSLocalizedDescriptionKey :
                            NSLocalizedString(@"Writing zeros to the device failed.", nil),
                        kDUBackendDetailKey :
                            StderrTail(processResult.standardOutput.length > 0
                                           ? processResult.standardOutput
                                           : processResult.standardError),
                    }];
                }
                [wait markFinished];
            }
                      error:&streamError];
    if (streamError != nil) {
        return streamError;
    }

    while (!wait.isFinished) {
        usleep(20000);
    }
    if (result == nil && progress != NULL) {
        progress(1.0,
                 NSLocalizedString(@"Zero overwrite complete.", nil));
    }
    return result;
}

+ (NSError *)formatVolumeAtDevicePath:(NSString *)devicePath
                       filesystemType:(NSString *)fstype
                                label:(NSString *)label
                             progress:(void (^)(double, NSString *))progress
{
    NSArray<NSString *> *prefix =
        [self formatArgumentsForFilesystemType:fstype label:label];
    if (prefix == nil) {
        return DUErrorMake(DUErrorInvalidArgument,
                           [NSString stringWithFormat:
                                NSLocalizedString(
                                    @"\"%@\" cannot be created here.", nil),
                                fstype]);
    }

    NSMutableArray<NSString *> *arguments = [prefix mutableCopy];
    [arguments addObject:devicePath];

    return RunStreamedTool(prefix.firstObject,
                           @[ prefix.firstObject ],
                           arguments,
                           progress,
                           1u << 0,
                           DUErrorEraseFailed,
                           [NSString stringWithFormat:
                                NSLocalizedString(
                                    @"Creating the %@ filesystem failed.",
                                    nil), fstype]);
}

+ (NSError *)toggleJournalingOnDevicePath:(NSString *)devicePath
                           filesystemType:(NSString *)fstype
                                     enable:(BOOL)enable
{
    BOOL isExtFamily = [fstype isEqualToString:@"ext2"] ||
        [fstype isEqualToString:@"ext3"] || [fstype isEqualToString:@"ext4"];
    if (!isExtFamily || ![self journalingToggleAvailable]) {
        return DUErrorMake(DUErrorUnsupportedOperation,
                           NSLocalizedString(@"Journaling can only be toggled "
                                              @"for ext2/ext3/ext4 volumes "
                                              @"when tune2fs is installed.",
                                             nil));
    }

    NSString *mode = enable ? @"has_journal" : @"^has_journal";
    NSString *tune2fs = [DUProcessRunner executablePathForName:@"tune2fs"];
    if (tune2fs == nil) {
        return DUErrorMake(DUErrorUnsupportedOperation,
                           NSLocalizedString(@"The required tool tune2fs is "
                                              @"not installed.",
                                             nil));
    }
    NSError *launchError = nil;
    // tune2fs rewrites superblock metadata; needs root.
    DUProcessResult *result =
        [[DUAuthorizationManager sharedManager]
            runPrivileged:tune2fs
                     args:@[ @"-O", mode, devicePath ]
                  timeout:300.0
                    error:&launchError];
    if (launchError != nil) {
        return launchError;
    }
    if (!result.exitedNormally ||
        WEXITSTATUS(result.terminationStatus) != 0) {
        return [NSError errorWithDomain:DUStorageErrorDomain
                                   code:DUErrorFilesystemError
                               userInfo:@{
            NSLocalizedDescriptionKey :
                NSLocalizedString(@"Changing journaling failed.", nil),
            kDUBackendDetailKey : StderrTail(result.standardError),
        }];
    }
    return nil;
}

@end

#endif /* defined(__linux__) */
