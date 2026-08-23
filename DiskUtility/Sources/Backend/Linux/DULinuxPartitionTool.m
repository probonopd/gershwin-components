/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#if defined(__linux__)

#import "DULinuxPartitionTool.h"

#import <sys/wait.h>
#import <unistd.h>

#import "DUErrors.h"
#import "DULinuxFilesystemTool.h"
#import "DUPartition.h"
#import "DUPartitionPlan.h"
#import "DUParsing.h"
#import "DUProcessRunner.h"
#import "DUAuthorizationManager.h"

// First partition starts at 1 MiB when the plan carries no explicit offsets;
// 0 would collide with the protective MBR / GPT header area and parted
// rejects it outright.
static const unsigned long long kFirstUsableByte = 1024ull * 1024;

@implementation DULinuxPartitionTool

+ (BOOL)partitioningAvailable
{
    return [DUProcessRunner executablePathForName:@"parted"] != nil ||
        [DUProcessRunner executablePathForName:@"sfdisk"] != nil;
}

+ (NSString *)tableLabelForScheme:(NSString *)scheme
{
    NSString *normalized = [[DUParsing trimmedString:scheme] lowercaseString];
    if ([normalized isEqualToString:@"gpt"]) {
        return @"gpt";
    }
    if ([normalized isEqualToString:@"mbr"] ||
        [normalized isEqualToString:@"dos"] ||
        [normalized isEqualToString:@"msdos"]) {
        return @"msdos";
    }
    return nil;
}

+ (NSString *)sfdiskScriptForPlan:(DUPartitionPlan *)plan
{
    NSMutableString *script =
        [NSMutableString stringWithFormat:
             @"label: %@\n",
             [self tableLabelForScheme:plan.scheme] ?: @"dos"];

    for (DUPartition *entry in plan.entries) {
        NSMutableArray<NSString *> *fields = [NSMutableArray array];
        if (entry.offsetBytes > 0) {
            // sfdisk works in 512-byte sectors; round the start down so a
            // byte-granular offset stays inside its own sector.
            unsigned long long startSector = entry.offsetBytes / 512ull;
            [fields addObject:[NSString stringWithFormat:
                                    @"start=%llu", startSector]];
        }
        if (entry.sizeBytes > 0) {
            unsigned long long sizeSectors =
                (entry.sizeBytes + 511ull) / 512ull;
            [fields addObject:[NSString stringWithFormat:
                                    @"size=%llu", sizeSectors]];
        }
        NSString *typeToken = [self sfdiskTypeToken:entry.partitionType];
        if (typeToken != nil) {
            [fields addObject:[NSString stringWithFormat:
                                    @"type=%@", typeToken]];
        }
        if (entry.name.length > 0) {
            // Quotes inside names would break the script grammar; strip
            // them instead of inventing an escaping dialect per tool.
            NSString *safeName =
                [entry.name stringByReplacingOccurrencesOfString:@"\""
                                                       withString:@""];
            [fields addObject:[NSString stringWithFormat:
                                    @"name=\"%@\"", safeName]];
        }
        if (entry.bootable) {
            [fields addObject:@"bootable"];
        }
        [script appendFormat:@"%@\n",
             [fields componentsJoinedByString:@", "]];
    }
    return script;
}

// Passes through hex type codes and GUIDs verbatim; drops prose tokens that
// only make sense to other backends ("Apple HFS+" etc.) so sfdisk never has
// to guess what they mean.
+ (NSString *)sfdiskTypeToken:(NSString *)rawType
{
    NSString *trimmed = [DUParsing trimmedString:rawType];
    if (trimmed.length == 0) {
        return nil;
    }
    NSCharacterSet *allowed =
        [NSCharacterSet characterSetWithCharactersInString:
                            @"0123456789abcdefABCDEF-"];
    NSRange invalid =
        [trimmed rangeOfCharacterFromSet:[allowed invertedSet]];
    return invalid.location == NSNotFound ? trimmed : nil;
}

- (NSError *)applyPlan:(DUPartitionPlan *)plan
          toDevicePath:(NSString *)devicePath
              progress:(void (^)(double, NSString *))progress
{
    if (plan == nil || devicePath.length == 0) {
        return DUErrorMake(DUErrorInvalidArgument,
                           NSLocalizedString(@"No partitioning target "
                                              @"specified.",
                                             nil));
    }
    NSString *tableLabel = [[self class] tableLabelForScheme:plan.scheme];
    if (tableLabel == nil) {
        return DUErrorMake(DUErrorInvalidArgument,
                           [NSString stringWithFormat:
                                NSLocalizedString(
                                    @"Unsupported partition table scheme "
                                    @"\"%@\".",
                                    nil), plan.scheme]);
    }

    NSError *error = nil;
    if ([DUProcessRunner executablePathForName:@"parted"] != nil) {
        // parted executes everything through argument vectors; sfdisk wants
        // a stdin script, which our process policy never provides, so it
        // only runs when parted is absent (script via temporary file).
        error = [self applyViaParted:plan
                        toDevicePath:devicePath
                          tableLabel:tableLabel
                            progress:progress];
    } else {
        error = [self applyViaSfdiskScript:[[self class]
                                               sfdiskScriptForPlan:plan]
                              toDevicePath:devicePath
                                  progress:progress];
    }
    if (error != nil) {
        return error;
    }

    if (progress != NULL) {
        progress(0.9,
                 NSLocalizedString(@"Rereading the partition table...",
                                   nil));
    }
    // partprobe failure is non-fatal: the kernel may already have picked up
    // the change, or the next discovery pass sees the on-disk state anyway.
    // It pokes the kernel about the rewritten table, so it runs elevated
    // like the writers before it.
    NSString *partprobe = [DUProcessRunner executablePathForName:@"partprobe"];
    if (partprobe != nil) {
        [[DUAuthorizationManager sharedManager]
            runPrivileged:partprobe
                     args:@[ devicePath ]
                  timeout:300.0
                    error:NULL];
    }
    if (progress != NULL) {
        progress(1.0,
                 NSLocalizedString(@"Partitioning complete.", nil));
    }
    return nil;
}

#pragma mark - parted execution

// Filesystem hint tokens parted understands inside mkpart; unknown or empty
// types simply omit the operand.
+ (NSArray<NSString *> *)partedKnownFilesystemTokens
{
    static NSArray<NSString *> *tokens;
    @synchronized (self) {
        if (tokens == nil) {
            tokens = @[ @"ext2", @"ext3", @"ext4", @"fat16", @"fat32",
                        @"ntfs", @"xfs", @"btrfs", @"hfs+", @"swap" ];
        }
        return tokens;
    }
}

+ (NSString *)partedFilesystemToken:(NSString *)filesystemType
{
    if (filesystemType.length == 0) {
        return nil;
    }
    NSDictionary<NSString *, NSString *> *aliases =
        @{ @"vfat" : @"fat32", @"msdos" : @"fat16" };
    NSString *token = aliases[filesystemType] ?: filesystemType;
    NSArray<NSString *> *known =
        [self partedKnownFilesystemTokens];
    return [known containsObject:token] ? token : nil;
}

- (NSError *)applyViaParted:(DUPartitionPlan *)plan
               toDevicePath:(NSString *)devicePath
                 tableLabel:(NSString *)tableLabel
                   progress:(void (^)(double, NSString *))progress
{
    NSString *parted = [DUProcessRunner executablePathForName:@"parted"];
    if (parted == nil) {
        return DUErrorMake(DUErrorUnsupportedOperation,
                           NSLocalizedString(@"The required tool parted is "
                                              @"not installed.",
                                             nil));
    }

    if (progress != NULL) {
        progress(0.1,
                 NSLocalizedString(@"Writing the partition table...", nil));
    }
    NSError *error = [self runParted:parted
                           arguments:@[ @"-s", devicePath, @"mklabel",
                                        tableLabel ]];
    if (error != nil) {
        return error;
    }

    NSArray<DUPartition *> *entries = plan.entries;
    unsigned long long cursor = kFirstUsableByte;
    BOOL isMsdos = [tableLabel isEqualToString:@"msdos"];

    for (NSUInteger i = 0; i < entries.count; i++) {
        DUPartition *entry = entries[i];

        // Plans built from scratch carry offset 0 ("unknown"); derive the
        // position from the running cursor instead of stacking every
        // partition at the same address. Explicit offsets are honored as-is.
        unsigned long long start = cursor;
        unsigned long long end = start + entry.sizeBytes;
        cursor = end;

        NSMutableArray<NSString *> *arguments =
            [NSMutableArray arrayWithObjects:@"-s", devicePath, @"mkpart",
                                             nil];
        // parted's first mkpart operand is a free name under GPT but the
        // slot kind (primary/logical/extended) under msdos.
        if (isMsdos) {
            [arguments addObject:@"primary"];
        } else if (entry.name.length > 0) {
            [arguments addObject:entry.name];
        } else {
            [arguments addObject:
                 [NSString stringWithFormat:@"partition%lu",
                     (unsigned long)(i + 1)]];
        }
        NSString *fsToken =
            [[self class] partedFilesystemToken:entry.filesystemType];
        if (fsToken != nil) {
            [arguments addObject:fsToken];
        }
        [arguments addObjectsFromArray:@[
            [NSString stringWithFormat:@"%llub", start],
            [NSString stringWithFormat:@"%llub", end],
        ]];

        double fraction =
            0.1 + 0.7 * ((double)(i + 1) /
                         (double)(entries.count > 0 ? entries.count : 1));
        if (progress != NULL) {
            progress(fraction,
                     [NSString stringWithFormat:
                          NSLocalizedString(
                              @"Creating partition %lu of %lu...", nil),
                          (unsigned long)(i + 1),
                          (unsigned long)entries.count]);
        }
        error = [self runParted:parted arguments:arguments];
        if (error != nil) {
            return error;
        }

        if (isMsdos && entry.bootable) {
            error = [self runParted:parted
                          arguments:@[ @"-s", devicePath, @"set",
                                       [NSString stringWithFormat:@"%lu",
                                           (unsigned long)(i + 1)],
                                       @"boot", @"on" ]];
            if (error != nil) {
                return error;
            }
        }
    }
    return nil;
}

- (NSError *)runParted:(NSString *)parted
             arguments:(NSArray<NSString *> *)arguments
{
    // parted rewrites the partition table; needs root.
    NSError *launchError = nil;
    DUProcessResult *result = [[DUAuthorizationManager sharedManager]
        runPrivileged:parted
                 args:arguments
              timeout:300.0
                error:&launchError];
    if (launchError != nil) {
        return launchError;
    }
    int status = WEXITSTATUS(result.terminationStatus);
    if (!result.exitedNormally || status != 0) {
        return [NSError errorWithDomain:DUStorageErrorDomain
                                   code:DUErrorPartitionError
                               userInfo:@{
            NSLocalizedDescriptionKey :
                NSLocalizedString(@"The partition table could not be "
                                  @"written.",
                                  nil),
            kDUBackendDetailKey :
                [DUParsing trimmedString:result.standardError],
        }];
    }
    return nil;
}

#pragma mark - sfdisk execution

// sfdisk reads its script from stdin by design. Our process runner never
// provides stdin (argument vectors only, no shell), so when only sfdisk is
// installed the rendered script travels through a temporary file passed as
// the trailing operand.
- (NSError *)applyViaSfdiskScript:(NSString *)script
                     toDevicePath:(NSString *)devicePath
                         progress:(void (^)(double, NSString *))progress
{
    NSString *sfdisk = [DUProcessRunner executablePathForName:@"sfdisk"];
    if (sfdisk == nil) {
        return DUErrorMake(DUErrorUnsupportedOperation,
                           NSLocalizedString(@"Neither parted nor sfdisk is "
                                              @"available for partitioning.",
                                             nil));
    }

    NSString *directory = NSTemporaryDirectory();
    NSString *path = directory.length > 0
        ? [directory stringByAppendingPathComponent:[NSUUID UUID].UUIDString]
        : nil;
    if (path == nil ||
        ![script writeToFile:path
                  atomically:YES
                    encoding:NSUTF8StringEncoding
                       error:NULL]) {
        return DUErrorMake(DUErrorUnknown,
                           NSLocalizedString(@"Could not create the "
                                              @"temporary script file.",
                                             nil));
    }

    @try {
        if (progress != NULL) {
            progress(0.3,
                     NSLocalizedString(@"Writing the partition table...",
                                       nil));
        }
        NSError *launchError = nil;
        // sfdisk rewrites the partition table; needs root.
        DUProcessResult *result =
            [[DUAuthorizationManager sharedManager]
                runPrivileged:sfdisk
                         args:@[ @"--no-reread", @"--force",
                                 devicePath, path ]
                      timeout:300.0
                        error:&launchError];
        if (launchError != nil) {
            return launchError;
        }
        int status = WEXITSTATUS(result.terminationStatus);
        if (!result.exitedNormally || status != 0) {
            return [NSError errorWithDomain:DUStorageErrorDomain
                                       code:DUErrorPartitionError
                                   userInfo:@{
                NSLocalizedDescriptionKey :
                    NSLocalizedString(@"The partition table could not be "
                                      @"written.",
                                      nil),
                kDUBackendDetailKey :
                    [DUParsing trimmedString:result.standardError],
            }];
        }
    } @finally {
        // Temporary files must vanish on success and failure alike
        // (ARCHITECTURE.md section 85).
        [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
    }
    return nil;
}

@end

#endif /* defined(__linux__) */
