/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "CLMStreamOperation.h"
#import "CLMStreamDownloader.h"
#import "CLMArchiveExtractor.h"
#import "CLMBlockDeviceWriter.h"

// Compressed file extensions that libarchive can handle
static NSSet *compressedExtensions;

@implementation CLMStreamOperation
{
    NSURL *_url;
    NSString *_devicePath;
    CLMStreamDownloader *_downloader;
    CLMArchiveExtractor *_extractor;
    CLMBlockDeviceWriter *_writer;
    BOOL _executing;
    BOOL _finished;
    float _progress;
    int64_t _bytesProcessed;
    int64_t _totalBytes;
    int64_t _preScannedOutputSize;
    CLMStreamContentType _contentType;
}

@synthesize progress = _progress;
@synthesize bytesProcessed = _bytesProcessed;
@synthesize totalBytes = _totalBytes;

+ (void)initialize
{
    if (self == [CLMStreamOperation class]) {
        compressedExtensions = [NSSet setWithObjects:
            @".gz", @".gzip",
            @".bz2", @".bzip2",
            @".xz",
            @".lz", @".lzma",
            @".zst", @".zstd",
            @".Z",
            @".zip",
            nil];
    }
}

- (instancetype)initWithURL:(NSURL *)url
                 devicePath:(NSString *)devicePath
{
    self = [super init];
    if (self) {
        _url = url;
        _devicePath = [devicePath copy];
        _contentType = [[self class] contentTypeForURL:url];
        _progress = 0.0;
        _bytesProcessed = 0;
        _totalBytes = 0;
    }
    return self;
}

+ (CLMStreamContentType)contentTypeForURL:(NSURL *)url
{
    NSString *path = [url path];
    if (!path) return CLMStreamContentTypeUnknown;

    for (NSString *ext in compressedExtensions) {
        if ([path hasSuffix:ext]) {
            return CLMStreamContentTypeCompressed;
        }
    }
    return CLMStreamContentTypeRaw;
}

+ (BOOL)isImageAssetName:(NSString *)name
{
    if (!name) return NO;
    NSString *lower = [name lowercaseString];
    // Strip known compression extensions to check for .iso or .img base
    NSString *stripped = lower;
    NSArray *compExts = @[@".gz", @".gzip", @".xz", @".bz2", @".bzip2",
                          @".zst", @".zstd", @".lz", @".lzma", @".Z",
                          @".zip"];
    for (NSString *ext in compExts) {
        if ([stripped hasSuffix:ext]) {
            stripped = [stripped substringToIndex:[stripped length] - [ext length]];
            break;
        }
    }
    if ([stripped hasSuffix:@".iso"] || [stripped hasSuffix:@".img"]) {
        return YES;
    }
    // A .zip is a supported container; the extractor streams the image out,
    // so a zip whose name has no .iso/.img base still counts as an image.
    return [lower hasSuffix:@".zip"];
}

- (BOOL)isConcurrent
{
    return YES;
}

- (BOOL)isExecuting
{
    return _executing;
}

- (BOOL)isFinished
{
    return _finished;
}

- (void)start
{
    if ([self isCancelled]) {
        [self _finishWithError:[NSError errorWithDomain:@"CLMStreamOperation"
                                                   code:-1
                                               userInfo:@{
            NSLocalizedDescriptionKey: @"Operation cancelled"
        }]];
        return;
    }

    [self willChangeValueForKey:@"isExecuting"];
    _executing = YES;
    [self didChangeValueForKey:@"isExecuting"];

    [self _reportStatus:NSLocalizedString(@"Opening target device...", @"")];

    _writer = [[CLMBlockDeviceWriter alloc] initWithDevicePath:_devicePath];
    NSError *err = nil;
    if (![_writer openWithError:&err]) {
        [self _finishWithError:err];
        return;
    }

    if (_contentType == CLMStreamContentTypeCompressed) {
        [self _startExtractingStream];
    } else {
        [self _startDirectStream];
    }
}

- (void)_startDirectStream
{
    [self _reportStatus:NSLocalizedString(@"Downloading and writing image...", @"")];

    __weak typeof(self) weakSelf = self;

    _downloader = [[CLMStreamDownloader alloc] initWithURL:_url];
    [_downloader startWithDataCallback:^(NSData *data, int64_t received, int64_t total) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || [strongSelf isCancelled]) return;

        NSError *writeErr = nil;
        if (![strongSelf->_writer writeData:data error:&writeErr]) {
            [strongSelf->_downloader cancel];
            [strongSelf _finishWithError:writeErr];
            return;
        }

        if (total > 0) {
            strongSelf->_totalBytes = total;
        }
        strongSelf->_bytesProcessed = received;
        strongSelf->_progress = (total > 0) ? (float)received / (float)total : 0.0f;
        [strongSelf _reportProgress];
    } completionCallback:^(NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        if (error) {
            [strongSelf _finishWithError:error];
            return;
        }

        [strongSelf _finalizeDevice];
    }];
}

- (void)_startExtractingStream
{
    [self _reportStatus:NSLocalizedString(@"Downloading, decompressing and writing image...", @"")];

    // For local zips the real uncompressed size lives only in the central
    // directory (data descriptors), which a streaming read cannot see. Pre-scan
    // the file so progress can be based on bytes actually written.
    _preScannedOutputSize = 0;
    if ([[_url scheme] isEqualToString:@"file"]) {
        NSString *localPath = [_url path];
        _preScannedOutputSize = [CLMArchiveExtractor scanImageSizeInArchiveFile:localPath];
        if (_preScannedOutputSize > 0) {
            NSLog(@"CLMStreamOperation: pre-scanned local archive output size = %lld",
                  (long long)_preScannedOutputSize);
        }
    }

    __weak typeof(self) weakSelf = self;

    _extractor = [[CLMArchiveExtractor alloc] init];
    _extractor.outputHandler = ^(NSData *decompressed) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || [strongSelf isCancelled]) return;

        NSError *writeErr = nil;
        if (![strongSelf->_writer writeData:decompressed error:&writeErr]) {
            [strongSelf->_extractor cancel];
            [strongSelf->_downloader cancel];
            [strongSelf _finishWithError:writeErr];
            return;
        }

        // When the decompressed size is known (zip), base progress on the
        // bytes actually written to the device, not on download progress,
        // which finishes early for local files.
        int64_t outSize = strongSelf->_preScannedOutputSize;
        if (outSize <= 0) {
            outSize = strongSelf->_extractor.expectedOutputSize;
        }
        if (outSize > 0) {
            strongSelf->_bytesProcessed = strongSelf->_writer.bytesWritten;
            strongSelf->_totalBytes = outSize;
            strongSelf->_progress = (float)strongSelf->_bytesProcessed / (float)outSize;
            static int64_t lastLoggedPct = -1;
            int64_t pct = (int64_t)(strongSelf->_progress * 100.0);
            if (pct >= lastLoggedPct + 10) {
                lastLoggedPct = (pct / 10) * 10;
                NSLog(@"CLMStreamOperation: write progress %lld/%lld (%lld%%)",
                      (long long)strongSelf->_bytesProcessed,
                      (long long)outSize, (long long)pct);
            }
            [strongSelf _reportProgress];
        }
    };
    _extractor.completionHandler = ^(NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        if (error) {
            [strongSelf _finishWithError:error];
            return;
        }

        // Extraction is done; stop the downloader early so trailing entries
        // in a zip (checksums, README) are not fetched.
        [strongSelf->_downloader cancel];
        [strongSelf _finalizeDevice];
    };

    [_extractor startExtracting];

    _downloader = [[CLMStreamDownloader alloc] initWithURL:_url];
    [_downloader startWithDataCallback:^(NSData *data, int64_t received, int64_t total) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || [strongSelf isCancelled]) return;

        if (total > 0) {
            strongSelf->_totalBytes = total;
        }
        // For compressed streams with a known decompressed size (zip), the
        // outputHandler reports progress based on bytes written. Fall back to
        // download progress only when the output size is unknown (gz/xz).
        if (strongSelf->_extractor.expectedOutputSize <= 0) {
            strongSelf->_bytesProcessed = received;
            strongSelf->_progress = (total > 0) ? (float)received / (float)total : 0.0f;
            [strongSelf _reportProgress];
        }

        [strongSelf->_extractor feedCompressedData:data];
    } completionCallback:^(NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        [strongSelf->_extractor finish];

        if (error) {
            [strongSelf->_extractor cancel];
            [strongSelf _finishWithError:error];
        }
    }];
}

- (void)_finalizeDevice
{
    [self _reportStatus:NSLocalizedString(@"Synchronizing device...", @"")];

    NSError *err = nil;
    if (![_writer synchronizeWithError:&err]) {
        [self _finishWithError:err];
        return;
    }

    if (![_writer closeWithError:&err]) {
        [self _finishWithError:err];
        return;
    }

    NSDebugLLog(@"gwcomp", @"CLMStreamOperation: Successfully wrote %lld bytes to %@",
          (long long)_bytesProcessed, _devicePath);

    _progress = 1.0f;
    [self _reportProgress];
    [self _finishWithError:nil];
}

#pragma mark - Delegate dispatch (main thread)

- (void)_reportProgress
{
    if (!_delegate) return;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf && strongSelf->_delegate) {
            [strongSelf->_delegate streamOperation:strongSelf
                                  progressUpdated:strongSelf->_progress
                                     bytesReceived:strongSelf->_bytesProcessed
                                       totalBytes:strongSelf->_totalBytes];
        }
    });
}

- (void)_reportStatus:(NSString *)status
{
    if (!_delegate) return;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf && strongSelf->_delegate) {
            [strongSelf->_delegate streamOperation:strongSelf
                                     statusUpdated:status];
        }
    });
}

- (void)_finishWithError:(NSError *)error
{
    if (_finished) return;

    // Cleanup
    [_writer closeWithError:NULL];
    _writer = nil;
    _extractor = nil;
    _downloader = nil;

    if (_delegate) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (strongSelf && strongSelf->_delegate) {
                [strongSelf->_delegate streamOperation:strongSelf
                                  didCompleteWithError:error];
            }
        });
    }

    [self willChangeValueForKey:@"isExecuting"];
    [self willChangeValueForKey:@"isFinished"];
    _executing = NO;
    _finished = YES;
    [self didChangeValueForKey:@"isExecuting"];
    [self didChangeValueForKey:@"isFinished"];
}

@end
