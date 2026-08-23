/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#if defined(__linux__)

#import "DULinuxImageTool.h"

#import "DUStorageBackend.h"

#import <fcntl.h>
#import <errno.h>
#import <string.h>
#import <unistd.h>

#import <sys/stat.h>
#import <unistd.h>

#import <sys/wait.h>

#import "DUErrors.h"
#import "DULinuxFilesystemTool.h"
#import "DUParsing.h"
#import "DUProcessRunner.h"
#import "DUAuthorizationManager.h"

@implementation DULinuxImageTool

+ (BOOL)conversionAvailable
{
    return [DUProcessRunner executablePathForName:@"qemu-img"] != nil;
}

+ (NSString *)probeFormatForImageAtPath:(NSString *)path
{
    if ([self conversionAvailable]) {
        NSError *error = nil;
        NSDictionary<NSString *, id> *info =
            [self infoForImageAtPath:path error:&error];
        NSString *format = [info[@"format"] isKindOfClass:[NSString class]]
            ? info[@"format"]
            : nil;
        if (error == nil && format.length > 0) {
            return format;
        }
    }

    // Extension map for systems without qemu-img; honest nil when nothing
    // is known instead of pretending every file is raw.
    NSString *extension = [path.pathExtension lowercaseString];
    NSDictionary<NSString *, NSString *> *table =
        @{ @"img" : @"raw",
           @"raw" : @"raw",
           @"dd" : @"raw",
           @"iso" : @"raw",
           @"qcow2" : @"qcow2",
           @"qcow" : @"qcow",
           @"qed" : @"qed",
           @"vmdk" : @"vmdk",
           @"vdi" : @"vdi",
           @"vhd" : @"vpc",
           @"vpc" : @"vpc" };
    return table[extension];
}

+ (NSDictionary<NSString *, id> *)infoForImageAtPath:(NSString *)path
                                               error:(NSError **)error
{
    NSString *qemuImg = [DUProcessRunner executablePathForName:@"qemu-img"];
    if (qemuImg == nil || path.length == 0) {
        if (error != NULL) {
            *error = DUErrorMake(DUErrorUnsupportedOperation,
                                 NSLocalizedString(@"Image inspection "
                                                    @"requires the qemu-img "
                                                    @"tool.",
                                                   nil));
        }
        return nil;
    }

    NSError *launchError = nil;
    DUProcessResult *result =
        [DUProcessRunner runExecutable:qemuImg
                             arguments:@[ @"info", @"--output=json", path ]
                                 error:&launchError];
    if (launchError != nil) {
        if (error != NULL) {
            *error = launchError;
        }
        return nil;
    }
    if (!result.exitedNormally ||
        WEXITSTATUS(result.terminationStatus) != 0) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:DUStorageErrorDomain
                                         code:DUErrorUnknown
                                     userInfo:@{
                NSLocalizedDescriptionKey :
                    NSLocalizedString(@"The image could not be inspected.",
                                      nil),
                kDUBackendDetailKey :
                    [DUParsing trimmedString:result.standardError],
            }];
        }
        return nil;
    }
    NSData *json = [result.standardOutput
        dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary<NSString *, id> *parsed = nil;
    if (json != nil) {
        parsed = [NSJSONSerialization JSONObjectWithData:json
                                                 options:0
                                                   error:NULL];
    }
    if (![parsed isKindOfClass:[NSDictionary class]]) {
        if (error != NULL) {
            *error = DUErrorMake(DUErrorUnknown,
                                 NSLocalizedString(@"The image inspector "
                                                    @"returned unreadable "
                                                    @"output.",
                                                   nil));
        }
        return nil;
    }
    return parsed;
}

+ (NSError *)createImageFileAtPath:(NSString *)path
                         sizeBytes:(unsigned long long)sizeBytes
{
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if ([fileManager fileExistsAtPath:path]) {
        return DUErrorMake(DUErrorInvalidArgument,
                           NSLocalizedString(@"A file already exists at "
                                              @"that location.",
                                             nil));
    }

    // Sparse creation via truncate keeps multi-gigabyte images instant;
    // formatting the contained filesystem happens through a loop device,
    // which is the caller's concern, not this file-level adapter's.
    if (![[NSData data] writeToFile:path options:NSDataWritingAtomic
                              error:NULL]) {
        return DUErrorMake(DUErrorPermissionDenied,
                           NSLocalizedString(@"The image file could not be "
                                              @"created.",
                                             nil));
    }

    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (handle == nil) {
        [fileManager removeItemAtPath:path error:NULL];
        return DUErrorMake(DUErrorPermissionDenied,
                           NSLocalizedString(@"The image file could not be "
                                              @"opened for writing.",
                                             nil));
    }
    // ftruncate on the raw descriptor: the NSFileHandle truncation API
    // used elsewhere is not available in GNUstep.
    int fd = handle.fileDescriptor;
    if (ftruncate(fd, (off_t)sizeBytes) != 0 || fsync(fd) != 0) {
        [handle closeFile];
        [fileManager removeItemAtPath:path error:NULL];
        return DUErrorMake(DUErrorUnknown,
                           NSLocalizedString(@"The image file could not be "
                                              @"sized.",
                                             nil));
    }
    [handle closeFile];

    struct stat st;
    if (stat(path.fileSystemRepresentation, &st) != 0) {
        [fileManager removeItemAtPath:path error:NULL];
        return DUErrorMake(DUErrorUnknown,
                           NSLocalizedString(@"The image file could not be "
                                              @"verified after sizing.",
                                             nil));
    }
    unsigned long long actualSize = (unsigned long long)st.st_size;
    if (actualSize != sizeBytes) {
        [fileManager removeItemAtPath:path error:NULL];
        return DUErrorMake(DUErrorUnknown,
                           NSLocalizedString(@"The image file size does not "
                                              @"match the requested size.",
                                             nil));
    }
    return nil;
}

+ (NSError *)convertImageAtPath:(NSString *)sourcePath
                       toPath:(NSString *)destinationPath
                       format:(NSString *)format
{
    NSString *qemuImg = [DUProcessRunner executablePathForName:@"qemu-img"];
    if (qemuImg == nil) {
        return DUErrorMake(DUErrorUnsupportedOperation,
                           NSLocalizedString(@"Converting images requires "
                                              @"the qemu-img tool.",
                                             nil));
    }
    if ([[NSFileManager defaultManager] fileExistsAtPath:destinationPath]) {
        return DUErrorMake(DUErrorInvalidArgument,
                           NSLocalizedString(@"A file already exists at the "
                                              @"destination.",
                                             nil));
    }

    NSString *targetFormat =
        format.length > 0 ? format : @"raw";
    NSError *launchError = nil;
    DUProcessResult *result =
        [DUProcessRunner runExecutable:qemuImg
                             arguments:@[ @"convert", @"-O", targetFormat,
                                          sourcePath, destinationPath ]
                                 error:&launchError];
    if (launchError != nil) {
        // Never leave a half-written destination behind.
        [[NSFileManager defaultManager] removeItemAtPath:destinationPath
                                                   error:NULL];
        return launchError;
    }
    int status = WEXITSTATUS(result.terminationStatus);
    if (!result.exitedNormally || status != 0) {
        [[NSFileManager defaultManager] removeItemAtPath:destinationPath
                                                   error:NULL];
        return [NSError errorWithDomain:DUStorageErrorDomain
                                   code:DUErrorUnknown
                               userInfo:@{
            NSLocalizedDescriptionKey :
                NSLocalizedString(@"The image conversion failed.", nil),
            kDUBackendDetailKey :
                [DUParsing trimmedString:result.standardError],
        }];
    }
    return nil;
}

+ (NSError *)resizeImageAtPath:(NSString *)path
                 sizeDeltaBytes:(long long)deltaBytes
{
    NSString *qemuImg = [DUProcessRunner executablePathForName:@"qemu-img"];
    if (qemuImg == nil) {
        return DUErrorMake(DUErrorUnsupportedOperation,
                           NSLocalizedString(@"Resizing images requires the "
                                              @"qemu-img tool.",
                                             nil));
    }
    if (deltaBytes == 0) {
        return DUErrorMake(DUErrorInvalidArgument,
                           NSLocalizedString(@"The resize amount must not be "
                                              @"zero.",
                                             nil));
    }

    // qemu-img speaks its own signed suffix form ("+5368709120"/"-...").
    NSString *deltaSpec = [NSString stringWithFormat:@"%c%lld",
                               deltaBytes > 0 ? '+' : '-',
                               deltaBytes > 0 ? deltaBytes : -deltaBytes];
    NSError *launchError = nil;
    DUProcessResult *result =
        [DUProcessRunner runExecutable:qemuImg
                             arguments:@[ @"resize", path, deltaSpec ]
                                 error:&launchError];
    if (launchError != nil) {
        return launchError;
    }
    int status = WEXITSTATUS(result.terminationStatus);
    if (!result.exitedNormally || status != 0) {
        return [NSError errorWithDomain:DUStorageErrorDomain
                                   code:DUErrorUnknown
                               userInfo:@{
            NSLocalizedDescriptionKey :
                NSLocalizedString(@"The image could not be resized.", nil),
            kDUBackendDetailKey :
                [DUParsing trimmedString:result.standardError],
        }];
    }
    return nil;
}

#pragma mark - Device imaging

// Image-creation targets: raw and gzipped raw need nothing but this
// process; the qemu conversion formats appear only with qemu-img present.
+ (NSArray<NSDictionary *> *)imageCreationFormats
{
    NSMutableArray<NSDictionary *> *formats = [NSMutableArray array];
    [formats addObject:@{
        kDUFormatIdentifierKey : @"raw",
        kDUFormatDisplayNameKey :
            NSLocalizedString(@"Raw disk image (.img)", nil),
    }];
    [formats addObject:@{
        kDUFormatIdentifierKey : @"gz",
        kDUFormatDisplayNameKey :
            NSLocalizedString(@"Gzipped raw image (.img.gz)", nil),
    }];
    if ([self conversionAvailable]) {
        for (NSString *format in @[ @"qcow2", @"vhd", @"vdi" ]) {
            [formats addObject:@{
                kDUFormatIdentifierKey : format,
                kDUFormatDisplayNameKey :
                    [NSString stringWithFormat:
                        NSLocalizedString(@"QEMU %@ (via qemu-img)", nil),
                        format.uppercaseString],
            }];
        }
    }
    return formats;
}

+ (NSError *)errorWithCode:(DUStorageErrorCode)code
                  message:(NSString *)message
                   detail:(NSString *)detail
{
    if (detail.length == 0) {
        return DUErrorMake(code, message);
    }
    return [NSError errorWithDomain:DUStorageErrorDomain
                               code:code
                           userInfo:@{
        NSLocalizedDescriptionKey : message,
        kDUBackendDetailKey : detail,
    }];
}

// Refuses to clobber; the UI layer owns the destructive confirmation.
+ (NSError *)existingFileError:(NSString *)path
{
    return DUErrorMake(DUErrorInvalidArgument,
                       [NSString stringWithFormat:NSLocalizedString(
                           @"A file named %@ already exists.", nil),
                           path.lastPathComponent]);
}

// Copies sourceBytes from an open source stream into outputHandle,
// calling progress per chunk. Returns bytes copied, or -1 read failure /
// -2 cancelled.
// Human-readable size for progress messages ("1.4 GiB"); binary units
// match what capacity displays elsewhere in the app show.
static NSString *ImageToolHumanBytes(unsigned long long bytes)
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

+ (long long)copyStream:(NSFileHandle *)source
             sizeBytes:(unsigned long long)sourceBytes
         outputHandle:(NSFileHandle *)outputHandle
             progress:(void (^)(double, NSString *))progress
          cancelBlock:(BOOL (^)(void))cancelBlock
{
    @try {
        unsigned long long copied = 0;
        const unsigned long long chunkSize = 1024ull * 1024ull;
        // Per-chunk callbacks would flood the main thread with thousands of
        // notifications per second on fast storage; report at most four
        // times a second (and always at completion).
        NSTimeInterval lastReport = 0.0;
        while (copied < sourceBytes) {
            if (cancelBlock != nil && cancelBlock()) {
                return -2;
            }
            unsigned long long remaining = sourceBytes - copied;
            NSUInteger want =
                remaining < chunkSize ? (NSUInteger)remaining
                                      : (NSUInteger)chunkSize;
            NSData *chunk = [source readDataOfLength:want];
            if (chunk.length == 0) {
                break;
            }
            [outputHandle writeData:chunk];
            copied += chunk.length;

            NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
            BOOL done = copied >= sourceBytes;
            if (progress != NULL &&
                (done || now - lastReport >= 0.25)) {
                lastReport = now;
                progress((double)copied / (double)sourceBytes,
                         [NSString stringWithFormat:
                              NSLocalizedString(@"Copied %@ of %@...",
                                                nil),
                              ImageToolHumanBytes(copied),
                              ImageToolHumanBytes(sourceBytes)]);
            }
        }
        return (long long)copied;
    } @finally {
        // The caller owns the handle lifecycle (direct fd vs task pipe).
    }
}

// qemu post-pass for the optional formats: convert the finished raw file,
// then remove it.
+ (NSError *)convertRawToFormat:(NSString *)format
                       imagePath:(NSString *)rawPath
                    finalPath:(NSString *)finalPath
{
    NSError *result = [self convertImageAtPath:rawPath
                                        toPath:finalPath
                                        format:format];
    [[NSFileManager defaultManager] removeItemAtPath:rawPath error:NULL];
    return result;
}

+ (NSError *)streamDeviceAtPath:(NSString *)devicePath
                       sizeBytes:(unsigned long long)sourceBytes
                        toImage:(NSString *)path
                         format:(NSString *)format
                       progress:(void (^)(double, NSString *))progress
                     cancelCheck:(BOOL (^)(void))cancelCheck
{
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if ([fileManager fileExistsAtPath:path]) {
        return [self existingFileError:path];
    }

    BOOL compressed = [format isEqualToString:@"gz"];
    NSString *rawPath = path;

    // The qemu formats are produced by converting a temporary raw copy,
    // so every format funnels through the same byte-stream loop.
    BOOL convertAfter = ![format isEqualToString:@"raw"] && !compressed;
    if (convertAfter) {
        rawPath = [path stringByAppendingPathExtension:@"tmp-raw"];
        if (rawPath == nil || [fileManager fileExistsAtPath:rawPath]) {
            return [self existingFileError:rawPath ?: path];
        }
    }

    // Open the source before creating any destination state so a bad
    // source never leaves a partial image behind.
    NSFileHandle *source =
        [NSFileHandle fileHandleForReadingAtPath:devicePath];
    NSTask *readerTask = nil;
    NSPipe *readerErrPipe = nil;
    if (source == nil) {
        // Block nodes are typically root-only; re-read them through a
        // privileged `cat` we spawn directly (no shell). The launch goes
        // through the authorization manager so it uses sudo -A (GUI
        // askpass); when authentication is refused we fail with a clear
        // permission error instead of hanging on a prompt.
        NSString *cat = [DUProcessRunner executablePathForName:@"cat"];
        NSString *launchPath = nil;
        NSArray<NSString *> *launchArguments = nil;
        NSError *resolveError = nil;
        if (cat == nil ||
            ![[DUAuthorizationManager sharedManager]
                resolveLaunch:cat
                    toolArguments:@[ devicePath ]
                   launchPathOut:&launchPath
                    argumentsOut:&launchArguments
                            error:&resolveError]) {
            return resolveError ?: DUErrorMake(
                                       DUErrorPermissionDenied,
                                       [NSString stringWithFormat:
                                           NSLocalizedString(
                                               @"The device %@ cannot be read without privileges.",
                                               nil),
                                           devicePath]);
        }
        readerTask = [[NSTask alloc] init];
        readerTask.launchPath = launchPath;
        readerTask.arguments = launchArguments;
        NSPipe *readerOutPipe = [NSPipe pipe];
        readerErrPipe = [NSPipe pipe];
        readerTask.standardOutput = readerOutPipe;
        readerTask.standardError = readerErrPipe;
        @try {
            [readerTask launch];
        } @catch (NSException *exception) {
            return DUErrorMake(DUErrorPermissionDenied,
                               exception.reason ?: NSLocalizedString(
                                                       @"Privileged read failed.",
                                                   nil));
        }
        source = readerOutPipe.fileHandleForReading;
    }

    NSTask *gzipTask = nil;
    NSPipe *gzipIn = nil;
    NSFileHandle *outputHandle = nil;

    if (compressed) {
        // gzip filter without any shell: we own the stdin pipe and feed
        // it chunk by chunk; gzip writes stdout straight to the target.
        NSString *gzip = [DUProcessRunner executablePathForName:@"gzip"];
        if (gzip == nil) {
            return DUErrorMake(DUErrorBackendUnavailable,
                               NSLocalizedString(
                                   @"The gzip tool is not available.", nil));
        }
        NSString *expanded = [path stringByExpandingTildeInPath];
        int fd = open(expanded.fileSystemRepresentation,
                      O_WRONLY | O_CREAT | O_EXCL, 0644);
        if (fd < 0) {
            return [self existingFileError:path];
        }
        NSFileHandle *gzipOut = [[NSFileHandle alloc]
            initWithFileDescriptor:fd closeOnDealloc:YES];

        gzipTask = [[NSTask alloc] init];
        gzipTask.launchPath = gzip;
        // -1 keeps compression cheap on slow disk streams.
        gzipTask.arguments = @[ @"-c", @"-1" ];
        gzipIn = [NSPipe pipe];
        gzipTask.standardInput = gzipIn;
        gzipTask.standardOutput = gzipOut;
        gzipTask.standardError = [NSPipe pipe];
        @try {
            [gzipTask launch];
        } @catch (NSException *exception) {
            close(fd);
            return DUErrorMake(DUErrorUnknown,
                               exception.reason ?: NSLocalizedString(
                                                       @"Could not launch gzip.",
                                                   nil));
        }
        outputHandle = gzipIn.fileHandleForWriting;
    } else {
        NSString *expanded = [rawPath stringByExpandingTildeInPath];
        int fd = open(expanded.fileSystemRepresentation,
                      O_WRONLY | O_CREAT | O_EXCL, 0644);
        if (fd < 0) {
            return [self existingFileError:rawPath];
        }
        outputHandle = [[NSFileHandle alloc]
            initWithFileDescriptor:fd closeOnDealloc:YES];
    }

    long long copied = [self copyStream:source
                              sizeBytes:sourceBytes
                           outputHandle:outputHandle
                               progress:progress
                            cancelBlock:^BOOL(void) {
        return cancelCheck != nil && cancelCheck();
    }];

    // Tear the pipeline down in every path: an unclosed stdin would keep
    // gzip alive forever, and an unwaited child becomes a zombie.
    if (readerTask != nil && readerTask.isRunning && copied == -2) {
        [readerTask terminate];
    }
    if (compressed) {
        [gzipIn.fileHandleForWriting closeFile];
        [gzipTask waitUntilExit];
    } else {
        @try {
            [outputHandle synchronizeFile];
            [outputHandle closeFile];
        } @catch (NSException __attribute__((unused)) *ignored) {
            // A broken pipe from an already-failed reader is fine here.
        }
    }
    if (readerTask != nil) {
        [readerTask waitUntilExit];
    }

    // Surface sudo failures (password required, node gone, ...) instead of
    // reporting a silently short image.
    if (copied >= 0 && readerTask != nil &&
        readerTask.terminationStatus != 0) {
        NSData *errData =
            [readerErrPipe.fileHandleForReading readDataToEndOfFile];
        NSString *detail = [[NSString alloc] initWithData:errData
                                                 encoding:NSUTF8StringEncoding]
            ?: @"";
        [fileManager removeItemAtPath:rawPath error:NULL];
        if (compressed) {
            [fileManager removeItemAtPath:path error:NULL];
        }
        // A password prompt requirement deserves its own explanation;
        // anything else keeps the tool output verbatim in the details.
        NSString *message =
            [detail rangeOfString:@"password is required"].location != NSNotFound ||
                [detail rangeOfString:@"Passwort"].location != NSNotFound
            ? NSLocalizedString(
                  @"Reading this device requires administrator rights. "
                  @"Start Disk Utility with elevated privileges to image "
                  @"it.",
                  nil)
            : NSLocalizedString(
                  @"The privileged read of the device failed.", nil);
        return [self errorWithCode:DUErrorPermissionDenied
                           message:message
                            detail:detail];
    }

    if (copied == -2) {
        [fileManager removeItemAtPath:rawPath error:NULL];
        if (compressed) {
            [fileManager removeItemAtPath:path error:NULL];
        }
        return DUErrorMake(DUErrorCancelled,
                           NSLocalizedString(@"Image creation cancelled.",
                                             nil));
    }
    if (copied < 0) {
        [fileManager removeItemAtPath:rawPath error:NULL];
        if (compressed) {
            [fileManager removeItemAtPath:path error:NULL];
        }
        return DUErrorMake(DUErrorDeviceNotFound,
                           NSLocalizedString(
                               @"The source device could not be read.",
                               nil));
    }

    if (convertAfter) {
        progress(0.98, NSLocalizedString(@"Converting image...", nil));
        NSError *conversion = [self convertRawToFormat:format
                                               imagePath:rawPath
                                              finalPath:path];
        if (conversion != nil) {
            return conversion;
        }
    }

    progress(1.0, NSLocalizedString(@"Image created successfully.", nil));
    return nil;
}

@end

#endif /* defined(__linux__) */
