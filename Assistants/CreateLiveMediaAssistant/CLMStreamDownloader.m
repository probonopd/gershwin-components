/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "CLMStreamDownloader.h"
#include <curl/curl.h>

@interface CLMStreamDownloader ()
- (void)handleDataChunk:(NSData *)data;
- (void)updateTotalBytes:(int64_t)total;
@end

// Write callback: curl calls this with incoming data. The buffer is only
// valid during this callback, and we feed it to the extractor asynchronously,
// so it must be copied rather than wrapped with dataWithBytesNoCopy.
static size_t
write_cb(char *ptr, size_t size, size_t nmemb, void *userdata)
{
    CLMStreamDownloader *downloader = (__bridge CLMStreamDownloader *)userdata;
    size_t total = size * nmemb;
    NSData *chunk = [NSData dataWithBytes:ptr length:total];

    [downloader handleDataChunk:chunk];
    return total;
}

// Progress callback: curl calls this periodically
static int
progress_cb(void *userdata, curl_off_t dltotal, curl_off_t dlnow,
            curl_off_t ultotal, curl_off_t ulnow)
{
    CLMStreamDownloader *downloader = (__bridge CLMStreamDownloader *)userdata;
    @synchronized(downloader) {
        if ([downloader isCancelled]) {
            return 1;
        }
        if (dltotal > 0) {
            [downloader updateTotalBytes:dltotal];
        }
    }
    return 0;
}

@implementation CLMStreamDownloader
{
    void (^_dataCallback)(NSData *, int64_t, int64_t);
    void (^_completionCallback)(NSError *);
    CURL *_curl;
    int64_t _totalBytes;
    int64_t _receivedBytes;
    BOOL _running;
    BOOL _cancelled;
    dispatch_queue_t _queue;
}

@synthesize url = _url;
@synthesize running = _running;

- (instancetype)initWithURL:(NSURL *)url
{
    self = [super init];
    if (self) {
        _url = url;
        _connectTimeout = 30.0;
        _totalTimeout = 0;
        _cancelled = NO;
        _running = NO;
        _receivedBytes = 0;
        _totalBytes = 0;
        _queue = dispatch_queue_create("com.gershwin.downloader", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)dealloc
{
    [self cancel];
}

- (void)startWithDataCallback:(void (^)(NSData *, int64_t, int64_t))dataCallback
            completionCallback:(void (^)(NSError *))completionCallback
{
    _dataCallback = dataCallback;
    _completionCallback = completionCallback;

    dispatch_async(_queue, ^{
        [self _run];
    });
}

- (void)_run
{
    _running = YES;
    _cancelled = NO;
    _receivedBytes = 0;

    _curl = curl_easy_init();
    if (!_curl) {
        [self _finishWithError:[NSError errorWithDomain:@"CLMStreamDownloader"
                                                   code:-1
                                               userInfo:@{
            NSLocalizedDescriptionKey: NSLocalizedString(@"Failed to initialize curl", @"")
        }]];
        return;
    }

    curl_easy_setopt(_curl, CURLOPT_URL, [[_url absoluteString] UTF8String]);
    curl_easy_setopt(_curl, CURLOPT_WRITEFUNCTION, write_cb);
    curl_easy_setopt(_curl, CURLOPT_WRITEDATA, (__bridge void *)self);
    curl_easy_setopt(_curl, CURLOPT_XFERINFOFUNCTION, progress_cb);
    curl_easy_setopt(_curl, CURLOPT_XFERINFODATA, (__bridge void *)self);
    curl_easy_setopt(_curl, CURLOPT_NOPROGRESS, 0L);
    curl_easy_setopt(_curl, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(_curl, CURLOPT_MAXREDIRS, 5L);
    curl_easy_setopt(_curl, CURLOPT_USERAGENT, "CreateLiveMediaAssistant/2.0");
    curl_easy_setopt(_curl, CURLOPT_CONNECTTIMEOUT, (long)_connectTimeout);
    curl_easy_setopt(_curl, CURLOPT_SSL_VERIFYPEER, 1L);
    curl_easy_setopt(_curl, CURLOPT_SSL_VERIFYHOST, 2L);

    if (_totalTimeout > 0) {
        curl_easy_setopt(_curl, CURLOPT_TIMEOUT, (long)_totalTimeout);
    }

    CURLcode res = curl_easy_perform(_curl);

    if (_cancelled) {
        [self _finishWithError:[NSError errorWithDomain:@"CLMStreamDownloader"
                                                   code:-2
                                               userInfo:@{
            NSLocalizedDescriptionKey: NSLocalizedString(@"Download cancelled", @"")
        }]];
        return;
    }

    if (res != CURLE_OK) {
        NSString *errMsg = [NSString stringWithFormat:@"%s", curl_easy_strerror(res)];
        // Attempt to get HTTP response code for better diagnostics
        long httpCode = 0;
        curl_easy_getinfo(_curl, CURLINFO_RESPONSE_CODE, &httpCode);
        if (httpCode >= 400) {
            errMsg = [NSString stringWithFormat:@"HTTP %ld: %@", httpCode,
                       [NSHTTPURLResponse localizedStringForStatusCode:httpCode]];
        }
        [self _finishWithError:[NSError errorWithDomain:@"CLMStreamDownloader"
                                                   code:res
                                               userInfo:@{
            NSLocalizedDescriptionKey: errMsg
        }]];
        return;
    }

    // Get actual content-length for verification
    curl_off_t cl;
    curl_easy_getinfo(_curl, CURLINFO_CONTENT_LENGTH_DOWNLOAD_T, &cl);
    _totalBytes = (int64_t)cl;
    _totalBytes = MAX(_totalBytes, _receivedBytes);

    [self _finishWithError:nil];
}

- (void)_finishWithError:(NSError *)error
{
    if (_curl) {
        curl_easy_cleanup(_curl);
        _curl = NULL;
    }
    _running = NO;
    if (_completionCallback) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_completionCallback(error);
        });
    }
}

- (void)handleDataChunk:(NSData *)data
{
    @synchronized(self) {
        if (_cancelled) return;
        _receivedBytes += [data length];
        if (_dataCallback) {
            _dataCallback(data, _receivedBytes, _totalBytes);
        }
    }
}

- (void)updateTotalBytes:(int64_t)total
{
    @synchronized(self) {
        _totalBytes = total;
    }
}

- (void)cancel
{
    @synchronized(self) {
        _cancelled = YES;
    }
}

- (BOOL)isCancelled
{
    @synchronized(self) {
        return _cancelled;
    }
}

@end
