/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "CLMArchiveExtractor.h"
#include <archive.h>
#include <archive_entry.h>

@implementation CLMArchiveExtractor
{
    NSMutableArray *_bufferQueue;
    NSCondition *_cond;
    BOOL _producerDone;
    BOOL _cancelled;
    BOOL _extracting;
    dispatch_queue_t _extractQueue;
    // Holds the current NSData being read by libarchive so it stays alive
    NSData *_currentReadData;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _bufferQueue = [[NSMutableArray alloc] init];
        _cond = [[NSCondition alloc] init];
        _producerDone = NO;
        _cancelled = NO;
        _extracting = NO;
        _extractQueue = dispatch_queue_create("com.gershwin.extractor",
                                               DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)startExtracting
{
    if (_extracting) return;
    _extracting = YES;

    dispatch_async(_extractQueue, ^{
        [self _runExtraction];
    });
}

- (void)feedCompressedData:(NSData *)data
{
    [_cond lock];
    [_bufferQueue addObject:data];
    [_cond signal];
    [_cond unlock];
}

- (void)finish
{
    [_cond lock];
    _producerDone = YES;
    [_cond signal];
    [_cond unlock];
}

- (void)cancel
{
    [_cond lock];
    _cancelled = YES;
    [_cond signal];
    [_cond unlock];
}

#pragma mark - Libarchive Read Callbacks

struct extractor_context {
    __unsafe_unretained CLMArchiveExtractor *self;
};

static la_ssize_t
archive_read_cb(struct archive *a, void *client_data, const void **buf)
{
    struct extractor_context *ctx = (struct extractor_context *)client_data;
    CLMArchiveExtractor *ext = ctx->self;

    [ext->_cond lock];

    while ([ext->_bufferQueue count] == 0 && !ext->_producerDone && !ext->_cancelled) {
        [ext->_cond wait];
    }

    if (ext->_cancelled) {
        [ext->_cond unlock];
        return -1; // ARCHIVE_FATAL
    }

    if ([ext->_bufferQueue count] == 0) {
        [ext->_cond unlock];
        return 0; // EOF
    }

    NSData *data = ext->_bufferQueue[0];
    [ext->_bufferQueue removeObjectAtIndex:0];

    *buf = [data bytes];
    la_ssize_t len = (la_ssize_t)[data length];
    ext->_currentReadData = data;

    [ext->_cond unlock];
    return len;
}

#pragma mark - Extraction Loop

- (void)_runExtraction
{
    struct archive *a = archive_read_new();
    if (!a) {
        [self _finishWithError:[self _errorWithFormat:@"Failed to create archive handle"]];
        return;
    }

    archive_read_support_filter_all(a);
    // raw is the fallback for single-stream compressed files (iso.gz, iso.xz);
    // zip is registered so a .zip container's first regular file (the image)
    // is decompressed and streamed out on the fly.
    archive_read_support_format_raw(a);
    archive_read_support_format_zip(a);

    struct extractor_context ctx;
    ctx.self = self;

    int r = archive_read_open(a, &ctx, NULL, archive_read_cb, NULL);
    if (r != ARCHIVE_OK) {
        NSString *err = [NSString stringWithUTF8String:archive_error_string(a)];
        archive_read_free(a);
        [self _finishWithError:[self _errorWithFormat:@"archive_read_open failed: %@", err]];
        return;
    }

    struct archive_entry *entry;
    BOOL extractedAny = NO;
    BOOL isZip = NO;
    while ((r = archive_read_next_header(a, &entry)) == ARCHIVE_OK) {
        // libarchive only settles on the format while reading the first
        // header, so detect it here rather than right after archive_read_open.
        if (!isZip) {
            int fmt = archive_format(a);
            isZip = ((fmt & ARCHIVE_FORMAT_BASE_MASK) == ARCHIVE_FORMAT_ZIP);
        }

        // For zip containers, skip non-regular entries (directories, symlinks)
        // and non-image files (checksums, README), extracting the image on the
        // fly. A raw stream reports a single regular entry, so this preserves
        // the old behaviour. The source is a non-seekable download stream, so
        // we cannot scan all entries first to pick the largest one; preferring
        // .iso/.img entries is the streaming equivalent.
        mode_t filetype = archive_entry_filetype(entry);
        if (filetype == AE_IFDIR || filetype == AE_IFLNK) {
            archive_read_data_skip(a);
            continue;
        }

        if (isZip) {
            const char *name = archive_entry_pathname(entry);
            NSString *fname = name ? [NSString stringWithUTF8String:name] : @"";
            NSString *lower = [fname lowercaseString];
            if (!([lower hasSuffix:@".iso"] || [lower hasSuffix:@".img"])) {
                archive_read_data_skip(a);
                continue;
            }
        }

        extractedAny = YES;

        // Read decompressed data in a loop
        const void *decompBuf;
        size_t decompLen;
        int64_t offset;

        while ((r = archive_read_data_block(a, &decompBuf, &decompLen, &offset)) == ARCHIVE_OK) {
            if (_cancelled) {
                archive_read_close(a);
                archive_read_free(a);
                [self _finishWithError:[self _errorWithFormat:@"Extraction cancelled"]];
                return;
            }

            if (decompLen > 0 && _outputHandler) {
                NSData *chunk = [NSData dataWithBytes:decompBuf length:decompLen];
                _outputHandler(chunk);
            }
        }

        // Only the first matching entry is extracted; stop here.
        break;
    }

    archive_read_close(a);
    archive_read_free(a);

    if (_cancelled) {
        [self _finishWithError:[self _errorWithFormat:@"Extraction cancelled"]];
        return;
    }

    if (!extractedAny) {
        [self _finishWithError:[self _errorWithFormat:
            @"No .iso or .img file found in the archive"]];
        return;
    }

    [self _finishWithError:nil];
}

- (void)_finishWithError:(NSError *)error
{
    _extracting = NO;
    _currentReadData = nil;
    if (_completionHandler) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_completionHandler(error);
        });
    }
}

- (NSError *)_errorWithFormat:(NSString *)format, ... NS_FORMAT_FUNCTION(1,2)
{
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    return [NSError errorWithDomain:@"CLMArchiveExtractor"
                               code:-1
                           userInfo:@{NSLocalizedDescriptionKey: msg}];
}

@end
