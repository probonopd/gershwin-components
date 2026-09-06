/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUImageOperation.h"

#import "DUAuthorizationManager.h"
#import "DUErrors.h"
#import "DUImageService.h"
#import "DUProcessRunner.h"

NSString *const kDUImageVerbCreate = @"create";
NSString *const kDUImageVerbConvert = @"convert";
NSString *const kDUImageVerbResize = @"resize";

NSString *const kDUImageSizeBytesKey = @"sizeBytes";
NSString *const kDUImageOutputPathKey = @"outputPath";
NSString *const kDUImageFormatKey = @"format";

@implementation DUImageOperation {
    __weak id<DUStorageBackend> _backend;
    NSLock *_handleLock;
    DUProcessHandle *_runningHandle;
}

- (instancetype)initWithBackend:(id<DUStorageBackend>)backend
                       imagePath:(NSString *)imagePath
                            verb:(NSString *)verb
                         options:(NSDictionary *)options
{
    NSParameterAssert(backend != nil);
    NSParameterAssert(imagePath.length > 0);
    NSParameterAssert(verb.length > 0);
    if ((self = [super initWithPrimaryObject:nil]) == nil) {
        return nil;
    }
    _backend = backend;
    _imagePath = [imagePath copy];
    _verb = [verb copy];
    _options = [options copy];
    _handleLock = [[NSLock alloc] init];
    return self;
}

- (NSString *)displayName
{
    return [NSString stringWithFormat:NSLocalizedString(@"%@ image %@",
                                                        @"verb, path"),
                     _verb, _imagePath.lastPathComponent];
}

- (void)cancel
{
    [super cancel];
    // qemu-img cannot see our flag, so interrupt it directly. The handle is
    // nil unless a tool run is in flight.
    [_handleLock lock];
    DUProcessHandle *handle = _runningHandle;
    [_handleLock unlock];
    [handle cancel];
}

- (void)execute
{
    if ([self cancelRequested]) {
        [self finishWithError:DUErrorMake(DUErrorCancelled, @"Cancelled before start")];
        return;
    }

    if ([_verb isEqualToString:kDUImageVerbCreate]) {
        [self runCreate];
    } else if ([_verb isEqualToString:kDUImageVerbResize]) {
        [self runQemuImg:@[ @"resize", _imagePath ]];
    } else if ([_verb isEqualToString:kDUImageVerbConvert]) {
        NSString *outputPath = _options[kDUImageOutputPathKey];
        if (outputPath.length == 0) {
            [self finishWithError:
                DUErrorMake(DUErrorInvalidArgument,
                            @"Conversion requires an output path")];
            return;
        }
        NSString *format = _options[kDUImageFormatKey] ?: @"raw";
        [self runQemuImg:@[ @"convert", @"-O", format, _imagePath, outputPath ]];
    } else {
        [self finishWithError:
            DUErrorMake(DUErrorInvalidArgument,
                        [NSString stringWithFormat:@"unknown image verb %@", _verb])];
    }
}

- (void)runCreate
{
    NSNumber *sizeNumber = _options[kDUImageSizeBytesKey];
    if (sizeNumber == nil || sizeNumber.unsignedLongLongValue == 0) {
        [self finishWithError:
            DUErrorMake(DUErrorInvalidArgument,
                        @"Creation requires a non-zero size")];
        return;
    }

    [self setProgress:0.2 message:NSLocalizedString(@"Creating image file", nil)];
    NSError *error = nil;
    // Sparse creation is instant; no intermediate progress needed.
    if (![DUImageService createImageAtPath:_imagePath
                                 sizeBytes:sizeNumber.unsignedLongLongValue
                                     error:&error]) {
        [self finishWithError:error ?: DUErrorMake(DUErrorUnknown,
                                                   @"Image could not be created")];
        return;
    }
    [self setProgress:1.0 message:NSLocalizedString(@"Image created", nil)];
    [self finishWithError:nil];
}

- (void)runQemuImg:(NSArray<NSString *> *)arguments
{
    NSString *tool = [DUProcessRunner executablePathForName:@"qemu-img"];
    if (tool == nil) {
        // Honest gap report instead of a half-working fallback.
        [self finishWithError:
            DUErrorMake(DUErrorUnsupportedOperation,
                        NSLocalizedString(@"qemu-img is required for this operation",
                                          nil))];
        return;
    }

    [self setProgress:0.1 message:NSLocalizedString(@"Running image tool", nil)];
    NSMutableArray<NSString *> *argv =
        [NSMutableArray arrayWithObject:tool];
    [argv addObjectsFromArray:arguments];

    __weak typeof(self) weakSelf = self;
    DUProcessHandle *handle =
        [DUProcessRunner streamExecutable:argv.firstObject
                                arguments:[argv subarrayWithRange:NSMakeRange(1, argv.count - 1)]
                              environment:nil
                            stdoutHandler:nil
                             finishHandler:^(DUProcessResult *result) {
            [weakSelf toolDidFinish:result];
        }];
    [_handleLock lock];
    _runningHandle = handle;
    [_handleLock unlock];

    // The finish handler owns the terminal transition; execute returns now
    // and the worker thread ends while the external tool keeps running.
}

- (void)toolDidFinish:(DUProcessResult *)result
{
    [_handleLock lock];
    _runningHandle = nil;
    [_handleLock unlock];

    if (result.wasCancelled || [self cancelRequested]) {
        [self finishWithError:DUErrorMake(DUErrorCancelled, @"Cancelled during tool run")];
        return;
    }
    if (!(result.exitedNormally && result.terminationStatus == 0)) {
        NSString *detail = result.standardError.length > 0
            ? result.standardError
            : NSLocalizedString(@"Image tool failed", nil);
        [self finishWithError:DUErrorMake(DUErrorUnknown, detail)];
        return;
    }
    [self setProgress:1.0 message:NSLocalizedString(@"Done", nil)];
    [self finishWithError:nil];
}

@end
