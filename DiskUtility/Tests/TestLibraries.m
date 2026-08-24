/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// Coverage for the optional direct-link library wrappers in
// Sources/Backend/Libraries. Every assertion holds in BOTH build
// configurations: when a HAVE_LIB* compile guard is off the wrappers are
// explicit stubs (nil/NO) and the tests pin exactly that stub behavior;
// when it is on they additionally exercise the real probing against
// scratch fixtures built under the system temporary directory. No block
// devices, no filesystem creation - the fixtures are plain files.

#import <Foundation/Foundation.h>
#import "Testing.h"

#import "DUArchiveLibrary.h"
#import "DUBlkidLibrary.h"
#import "DUExt2Library.h"
#import "DUFdiskLibrary.h"
#import "DUMountLibrary.h"

#import <stdlib.h>
#import <stdio.h>
#import <string.h>

static const NSUInteger OneMegabyte = 1024u * 1024u;

// Unique scratch directory via mkdtemp under NSTemporaryDirectory(); the
// whole tree is the tool's own creation and removed again at the end.
static NSString *MakeScratchDirectory(void)
{
    NSString *base = NSTemporaryDirectory() ?: @"/tmp/";
    if (![base hasSuffix:@"/"]) {
        base = [base stringByAppendingString:@"/"];
    }
    const char *basePath = base.fileSystemRepresentation;
    char *pattern = malloc(strlen(basePath) + sizeof("dulib-XXXXXX"));
    if (pattern == NULL) {
        return nil;
    }
    sprintf(pattern, "%sdulib-XXXXXX", basePath);
    char *created = mkdtemp(pattern);
    if (created == NULL) {
        free(pattern);
        return nil;
    }
    NSString *path = [NSString stringWithUTF8String:created];
    free(pattern);
    return path;
}

int main(void)
{
    @autoreleasepool {
        NSString *scratch = MakeScratchDirectory();
        if (scratch == nil) {
            fprintf(stderr, "FAIL: could not create scratch directory\n");
            return 1;
        }

        // --------------------------------------------------------------
        // Fixtures: a 1 MB all-zero file and a two-entry tar archive,
        // both plain regular files inside the scratch directory.
        // --------------------------------------------------------------
        NSString *zerosPath =
            [scratch stringByAppendingPathComponent:@"zeros.img"];
        // calloc guarantees the all-zero content the negative-path probes
        // below rely on; GNUstep-base has no NSData length initializers.
        void *zeroBytes = calloc(1, OneMegabyte);
        NSData *zeroMegabyte =
            [NSData dataWithBytes:zeroBytes length:OneMegabyte];
        free(zeroBytes);
        PASS([zeroMegabyte writeToFile:zerosPath options:0 error:NULL] == YES,
             "1 MB all-zero fixture written");

        NSString *payloadDir =
            [scratch stringByAppendingPathComponent:@"payload"];
        PASS([[NSFileManager defaultManager]
                  createDirectoryAtPath:payloadDir
                  withIntermediateDirectories:NO
                                   attributes:nil
                                        error:NULL] == YES,
             "payload directory created");
        PASS([@"first\n" writeToFile:[payloadDir stringByAppendingPathComponent:
                                          @"alpha.txt"]
                          atomically:YES encoding:NSUTF8StringEncoding
                               error:NULL] == YES,
             "first payload file written");
        PASS([@"second\n" writeToFile:[payloadDir stringByAppendingPathComponent:
                                           @"beta.txt"]
                           atomically:YES encoding:NSUTF8StringEncoding
                                error:NULL] == YES,
             "second payload file written");

        NSString *tarPath =
            [scratch stringByAppendingPathComponent:@"fixture.tar"];
        BOOL tarReady = NO;
        if ([[NSFileManager defaultManager]
                fileExistsAtPath:@"/usr/bin/tar"]) {
            NSTask *tar = [[NSTask alloc] init];
            tar.launchPath = @"/usr/bin/tar";
            // File-based archive creation only; nothing here touches a
            // device or runs with privileges.
            tar.arguments = @[ @"-cf", tarPath, @"alpha.txt", @"beta.txt" ];
            tar.currentDirectoryPath = payloadDir;
            tar.standardOutput = [NSPipe pipe];
            tar.standardError = [NSPipe pipe];
            @try {
                [tar launch];
                [tar waitUntilExit];
                tarReady = tar.terminationStatus == 0 &&
                    [[NSFileManager defaultManager]
                        fileExistsAtPath:tarPath];
            } @catch (NSException *exception) {
                fprintf(stderr, "tar launch failed: %s\n",
                        exception.reason.UTF8String ?: "?");
            }
        }
        PASS(tarReady == YES, "tar fixture created with /usr/bin/tar");

        NSString *missingPath =
            [scratch stringByAppendingPathComponent:@"does-not-exist"];

        // --------------------------------------------------------------
        // Fixture: an 8 MB raw image, later given a GPT table by sfdisk.
        // Plain regular file; no block device is ever touched.
        // --------------------------------------------------------------
        const NSUInteger imageSize = 8u * OneMegabyte;
        NSString *gptPath =
            [scratch stringByAppendingPathComponent:@"gpt.img"];
        void *imageZeroBytes = calloc(1, imageSize);
        NSData *zeroImage =
            [NSData dataWithBytes:imageZeroBytes length:imageSize];
        free(imageZeroBytes);
        PASS([zeroImage writeToFile:gptPath options:0 error:NULL] == YES,
             "8 MB raw image fixture written");

        BOOL gptReady = NO;
        if ([[NSFileManager defaultManager]
                fileExistsAtPath:@"/usr/sbin/sfdisk"]) {
            NSTask *sfdisk = [[NSTask alloc] init];
            sfdisk.launchPath = @"/usr/sbin/sfdisk";
            // File-based partitioning of our own scratch image only;
            // --no-reread because a regular file has no kernel table.
            sfdisk.arguments =
                @[ @"--no-reread", @"--force", gptPath ];
            NSPipe *scriptInput = [NSPipe pipe];
            sfdisk.standardInput = scriptInput;
            sfdisk.standardOutput = [NSPipe pipe];
            sfdisk.standardError = [NSPipe pipe];
            @try {
                [sfdisk launch];
                [scriptInput.fileHandleForWriting
                    writeData:[@"label: gpt\nunit: sectors\n\n"
                                @"name=first, size=2048, type=linux\n"
                                @"name=second, size=4096, type=linux\n"
                                   dataUsingEncoding:NSUTF8StringEncoding]];
                [scriptInput.fileHandleForWriting closeFile];
                [sfdisk waitUntilExit];
                gptReady = sfdisk.terminationStatus == 0 &&
                    [[NSFileManager defaultManager]
                        attributesOfItemAtPath:gptPath error:NULL]
                            .fileSize == imageSize;
            } @catch (NSException *exception) {
                fprintf(stderr, "sfdisk launch failed: %s\n",
                        exception.reason.UTF8String ?: "?");
            }
        }

        // --------------------------------------------------------------
        // DUArchiveLibrary identification
        // --------------------------------------------------------------
        if ([DUArchiveLibrary isAvailable]) {
            PASS(tarReady == YES,
                 "libarchive build has its tar fixture available");
            NSDictionary *identified =
                [DUArchiveLibrary identifyPath:tarPath];
            PASS([identified isKindOfClass:[NSDictionary class]],
                 "tar fixture is identified as an archive");
            NSString *format = identified[kDUArchiveFormat];
            PASS([format isKindOfClass:[NSString class]] &&
                     [format.lowercaseString containsString:@"tar"],
                 "identified format string contains \"tar\"");
            NSNumber *entryCount = identified[kDUArchiveEntryCount];
            PASS([entryCount isKindOfClass:[NSNumber class]] &&
                     entryCount.unsignedIntegerValue > 0,
                 "tar fixture reports a positive entry count");
        } else {
            // Stub configuration: identification must answer nil for
            // anything, including a real tar file.
            PASS([DUArchiveLibrary identifyPath:tarPath] == nil,
                 "stub identifyPath returns nil without libarchive");
        }
        // These two hold in both configurations: no signature in all-zero
        // bytes, and a missing file never identifies.
        PASS([DUArchiveLibrary identifyPath:zerosPath] == nil,
             "all-zero content identifies as nothing");
        PASS([DUArchiveLibrary identifyPath:missingPath] == nil,
             "a missing path identifies as nothing");

        // --------------------------------------------------------------
        // DUBlkidLibrary probing
        // --------------------------------------------------------------
        if ([DUBlkidLibrary isAvailable]) {
            NSDictionary *tarProbe =
                [DUBlkidLibrary probeDevicePath:tarPath];
            PASS(tarProbe[kDUBlkidFstype] == nil,
                 "tar fixture carries no filesystem superblock");
            NSDictionary *zerosProbe =
                [DUBlkidLibrary probeDevicePath:zerosPath];
            PASS(zerosProbe[kDUBlkidFstype] == nil,
                 "all-zero file carries no filesystem superblock");
        } else {
            PASS([DUBlkidLibrary probeDevicePath:tarPath] == nil &&
                     [DUBlkidLibrary probeDevicePath:zerosPath] == nil,
                 "stub probeDevicePath returns nil without libblkid");
        }

        // --------------------------------------------------------------
        // DUExt2Library detection and statistics
        // --------------------------------------------------------------
        // Negative-path assertions hold in both configurations: the stub
        // answers NO/nil outright, and a linked libext2fs refuses non-ext
        // content just the same. Positive-path coverage needs an ext
        // image fixture which the repository does not ship; creating
        // filesystems in tests is out of bounds.
        PASS([DUExt2Library isExtFilesystemPath:zerosPath] == NO,
             "all-zero file is not detected as an ext filesystem");
        PASS([DUExt2Library statsForPath:zerosPath] == nil,
             "stats refuse a file without an ext superblock");
        PASS([DUExt2Library statsForPath:tarPath] == nil,
             "stats refuse a tar archive");
        if (![DUExt2Library isAvailable]) {
            PASS([DUExt2Library isExtFilesystemPath:tarPath] == NO,
                 "stub isExtFilesystemPath returns NO without libext2fs");
        }

        // --------------------------------------------------------------
        // DUMountLibrary table snapshot
        // --------------------------------------------------------------
        if ([DUMountLibrary isAvailable]) {
            NSArray<NSDictionary *> *mounts = [DUMountLibrary listMounts];
            PASS([mounts isKindOfClass:[NSArray class]] && mounts.count > 0,
                 "live mount table lists at least one entry");
            BOOL allWellFormed = YES;
            for (NSDictionary *entry in mounts) {
                allWellFormed = allWellFormed &&
                    [entry[kDUMountDevice] isKindOfClass:[NSString class]] &&
                    [entry[kDUMountDevice] length] > 0 &&
                    [entry[kDUMountPoint] isKindOfClass:[NSString class]] &&
                    [entry[kDUMountPoint] length] > 0 &&
                    [entry[kDUMountFstype] isKindOfClass:[NSString class]] &&
                    [entry[kDUMountFstype] length] > 0;
            }
            PASS(allWellFormed == YES,
                 "every mount entry carries device, mount point and fstype");
        } else {
            PASS([DUMountLibrary listMounts] == nil,
                 "stub listMounts returns nil without libmount");
        }

        // --------------------------------------------------------------
        // DUFdiskLibrary partition-table inspection
        // --------------------------------------------------------------
        if ([DUFdiskLibrary isAvailable]) {
            if (gptReady) {
                NSDictionary *inspection =
                    [DUFdiskLibrary inspectPath:gptPath];
                PASS([inspection isKindOfClass:[NSDictionary class]],
                     "GPT image is inspected as a partition table");
                NSString *scheme = inspection[kDUFdiskScheme];
                PASS([scheme isKindOfClass:[NSString class]] &&
                         [scheme.lowercaseString isEqualToString:@"gpt"],
                     "inspected scheme token is \"gpt\"");
                NSArray<NSDictionary *> *partitions =
                    inspection[kDUFdiskPartitions];
                PASS([partitions isKindOfClass:[NSArray class]] &&
                         partitions.count == 2,
                     "GPT image reports exactly two partitions");
                unsigned long long sizeSum = 0;
                BOOL wellFormed = partitions.count == 2;
                for (NSDictionary *entry in partitions) {
                    NSNumber *index = entry[kDUFdiskIndex];
                    NSNumber *start = entry[kDUFdiskStartBytes];
                    NSNumber *size = entry[kDUFdiskSizeBytes];
                    NSString *uuid = entry[kDUFdiskUuid];
                    wellFormed = wellFormed &&
                        [index isKindOfClass:[NSNumber class]] &&
                        [start isKindOfClass:[NSNumber class]] &&
                        [size isKindOfClass:[NSNumber class]] &&
                        start.unsignedLongLongValue < imageSize &&
                        [uuid isKindOfClass:[NSString class]] &&
                        uuid.length > 0;
                    sizeSum += size.unsignedLongLongValue;
                }
                PASS(wellFormed == YES,
                     "every inspected partition carries index, bounds "
                     "inside the image and a non-empty UUID");
                PASS(sizeSum <= imageSize,
                     "partition sizes sum to at most the image size");
            } else {
                fprintf(stderr,
                        "sfdisk unavailable; skipping GPT positive path\n");
            }
        } else if (gptReady) {
            // Stub configuration: even a real table answers nothing.
            PASS([DUFdiskLibrary inspectPath:gptPath] == nil,
                 "stub inspectPath returns nil without libfdisk");
        }
        // Negative paths hold in both configurations: all-zero bytes carry
        // no table, a missing path never inspects, and non-partitioned
        // content (the tar fixture) is refused.
        PASS([DUFdiskLibrary inspectPath:zerosPath] == nil,
             "all-zero file carries no partition table");
        PASS([DUFdiskLibrary inspectPath:missingPath] == nil,
             "a missing path inspects as nothing");
        PASS([DUFdiskLibrary inspectPath:tarPath] == nil,
             "non-partitioned content is not reported as a table");

        // Only our own scratch subtree is ever removed.
        [[NSFileManager defaultManager] removeItemAtPath:scratch
                                                   error:NULL];
    }
    return 0;
}
