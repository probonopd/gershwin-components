//
// CLMDownloader.m
// Create Live Media Assistant - Downloader (Native Implementation)
//

#import "CLMDownloader.h"
#import <math.h>

@implementation CLMDownloader

@synthesize delegate = _delegate;
@synthesize isDownloading = _isDownloading;

- (id)init
{
    if (self = [super init]) {
        NSLog(@"CLMDownloader: init");
        _isDownloading = NO;
        _totalBytes = 0;
        _receivedBytes = 0;
        _retryCount = 0;
        _maxRetries = 5; // Allow up to 5 retries for intermittent connections
    }
    return self;
}

- (void)dealloc
{
    NSLog(@"CLMDownloader: dealloc");
    [self cancelDownload];
    [self stopStallDetectionTimer];
    [_sourceURL release];
    [_destinationPath release];
    [super dealloc];
}

- (void)downloadFromURL:(NSString *)url toPath:(NSString *)path
{
    NSLog(@"CLMDownloader: downloadFromURL: %@ toPath: %@", url, path);
    
    if (_isDownloading) {
        NSLog(@"CLMDownloader: Already downloading, cancelling current download");
        [self cancelDownload];
    }
    
    [_sourceURL release];
    _sourceURL = [url retain];
    
    [_destinationPath release];
    _destinationPath = [path retain];
    
    _isDownloading = YES;
    _totalBytes = 0;
    _receivedBytes = 0;
    _retryCount = 0; // Reset retry count for new download
    _lastDataTime = [[NSDate date] timeIntervalSince1970];
    
    if ([url hasPrefix:@"file://"]) {
        [self copyLocalFile];
    } else {
        [self downloadRemoteFile];
        // Start a timer to detect stalled downloads
        [self startStallDetectionTimer];
    }
}

- (void)copyLocalFile
{
    NSLog(@"CLMDownloader: copyLocalFile");
    
    // Extract file path from file:// URL
    NSString *sourcePath = [_sourceURL substringFromIndex:7]; // Remove "file://"
    
    NSFileManager *fileManager = [NSFileManager defaultManager];
    
    // Get file size first
    NSDictionary *attributes = [fileManager attributesOfItemAtPath:sourcePath error:nil];
    if (!attributes) {
        NSLog(@"CLMDownloader: Error getting file attributes");
        [_delegate downloadCompleted:NO error:@"Could not read source file"];
        _isDownloading = NO;
        return;
    }
    
    _totalBytes = [[attributes objectForKey:NSFileSize] longLongValue];
    
    // Start copying
    [self performSelectorInBackground:@selector(performFileCopy:) withObject:sourcePath];
}

- (void)performFileCopy:(NSString *)sourcePath
{
    NSLog(@"CLMDownloader: performFileCopy: %@", sourcePath);
    
    NSFileManager *fileManager = [NSFileManager defaultManager];
    
    // Open source file
    NSFileHandle *sourceFile = [NSFileHandle fileHandleForReadingAtPath:sourcePath];
    if (!sourceFile) {
        [_delegate downloadCompleted:NO error:@"Could not open source file"];
        _isDownloading = NO;
        return;
    }
    
    // Create/open destination file
    if (![fileManager createFileAtPath:_destinationPath contents:nil attributes:nil]) {
        [_delegate downloadCompleted:NO error:@"Could not create destination file"];
        [sourceFile closeFile];
        _isDownloading = NO;
        return;
    }
    
    NSFileHandle *destFile = [NSFileHandle fileHandleForWritingAtPath:_destinationPath];
    if (!destFile) {
        [_delegate downloadCompleted:NO error:@"Could not open destination file for writing"];
        [sourceFile closeFile];
        _isDownloading = NO;
        return;
    }
    
    // Copy in chunks
    NSUInteger chunkSize = 1024 * 1024; // 1MB chunks
    _receivedBytes = 0;
    long long lastUpdateBytes = 0;
    
    while (_isDownloading) {
        NSData *chunk = [sourceFile readDataOfLength:chunkSize];
        if ([chunk length] == 0) {
            break; // EOF
        }
        
        [destFile writeData:chunk];
        _receivedBytes += [chunk length];
        
        // Update progress every 5MB or at completion for better performance
        if ((_receivedBytes - lastUpdateBytes >= 5 * 1024 * 1024) || 
            (_totalBytes > 0 && _receivedBytes >= _totalBytes)) {
            
            float progress = (_totalBytes > 0) ? (float)_receivedBytes / (float)_totalBytes : 0.0;
            [self performSelectorOnMainThread:@selector(updateProgress:)
                                   withObject:[NSNumber numberWithFloat:progress]
                                waitUntilDone:NO];
            lastUpdateBytes = _receivedBytes;
        }
    }
    
    [sourceFile closeFile];
    [destFile closeFile];
    
    // Ensure we report 100% progress on completion
    if (_isDownloading && _totalBytes > 0) {
        [self performSelectorOnMainThread:@selector(updateProgress:)
                               withObject:[NSNumber numberWithFloat:1.0]
                            waitUntilDone:NO];
    }
    
    if (_isDownloading) {
        [_delegate downloadCompleted:YES error:nil];
    }
    
    _isDownloading = NO;
}

- (void)downloadRemoteFile
{
    NSLog(@"CLMDownloader: downloadRemoteFile using simple NSURLDownload");
    [self downloadRemoteFileSimple];
}

- (void)downloadRemoteFileSimple
{
    NSLog(@"CLMDownloader: downloadRemoteFileSimple - using NSURLConnection without resume complexity");
    
    @try {
        // Create a simple request without range headers
        NSURL *url = [NSURL URLWithString:_sourceURL];
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
        [request setTimeoutInterval:60.0]; // Longer timeout
        
        // For fresh downloads, always start from 0
        _receivedBytes = 0;
        _totalBytes = 0;
        
        // Create destination file
        NSFileManager *fileManager = [NSFileManager defaultManager];
        
        // Check if we're writing to a block device
        BOOL isBlockDevice = [_destinationPath hasPrefix:@"/dev/"];
        
        if (isBlockDevice) {
            // For block devices, just open for writing
            if (![fileManager fileExistsAtPath:_destinationPath]) {
                NSLog(@"CLMDownloader: Block device %@ does not exist", _destinationPath);
                [_delegate downloadCompleted:NO error:[NSString stringWithFormat:@"Block device %@ does not exist", _destinationPath]];
                _isDownloading = NO;
                return;
            }
            
            _outputFile = [[NSFileHandle fileHandleForWritingAtPath:_destinationPath] retain];
        } else {
            // For regular files, create new file
            if (![fileManager createFileAtPath:_destinationPath contents:nil attributes:nil]) {
                NSLog(@"CLMDownloader: Could not create destination file");
                [_delegate downloadCompleted:NO error:@"Could not create destination file"];
                _isDownloading = NO;
                return;
            }
            
            _outputFile = [[NSFileHandle fileHandleForWritingAtPath:_destinationPath] retain];
        }
        
        if (!_outputFile) {
            NSLog(@"CLMDownloader: Could not open destination file for writing");
            [_delegate downloadCompleted:NO error:@"Could not open destination file for writing"];
            _isDownloading = NO;
            return;
        }
        
        // Start the connection
        _connection = [[NSURLConnection alloc] initWithRequest:request delegate:self];
        if (!_connection) {
            NSLog(@"CLMDownloader: Could not create NSURLConnection");
            [_outputFile closeFile];
            [_outputFile release];
            _outputFile = nil;
            [_delegate downloadCompleted:NO error:@"Could not create network connection"];
            _isDownloading = NO;
            return;
        }
        
        NSLog(@"CLMDownloader: Simple download started");
        
    } @catch (NSException *exception) {
        NSLog(@"CLMDownloader: Exception in downloadRemoteFileSimple: %@ - %@", [exception name], [exception reason]);
        [_delegate downloadCompleted:NO error:[NSString stringWithFormat:@"Download setup failed: %@", [exception reason]]];
        _isDownloading = NO;
    }
}

#pragma mark - NSURLConnection Delegate Methods

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response
{
    NSLog(@"CLMDownloader: didReceiveResponse");
    
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        NSInteger statusCode = [httpResponse statusCode];
        
        if (statusCode == 206) {
            // Partial content response - resuming
            NSLog(@"CLMDownloader: HTTP 206 Partial Content - resume successful from byte %lld", _receivedBytes);
            // For resume, expectedContentLength is the remaining bytes, not total
            long long remainingBytes = [response expectedContentLength];
            if (remainingBytes > 0) {
                _totalBytes = _receivedBytes + remainingBytes;
                NSLog(@"CLMDownloader: Resume - already have %lld bytes, expecting %lld more (total: %lld)", 
                      _receivedBytes, remainingBytes, _totalBytes);
            }
        } else if (statusCode == 200) {
            // Full content response - server doesn't support range requests
            NSLog(@"CLMDownloader: HTTP 200 OK - server doesn't support resume, but continuing anyway");
            
            // NEVER reset _receivedBytes to 0! 
            // We'll just have to skip the bytes we already have when they arrive
            _totalBytes = [response expectedContentLength];
            NSLog(@"CLMDownloader: Server sending full content (%lld bytes), will skip first %lld bytes", _totalBytes, _receivedBytes);
        } else if (statusCode >= 400) {
            NSLog(@"CLMDownloader: HTTP error %ld", (long)statusCode);
            [self cancelDownload];
            [_delegate downloadCompleted:NO error:[NSString stringWithFormat:@"HTTP error %ld", (long)statusCode]];
            return;
        }
    } else {
        // Non-HTTP response, treat as full download but don't reset position
        _totalBytes = [response expectedContentLength];
        NSLog(@"CLMDownloader: Non-HTTP response, expected content length: %lld bytes, resuming from %lld", _totalBytes, _receivedBytes);
    }
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data
{
    if (!_isDownloading) {
        NSLog(@"CLMDownloader: didReceiveData called but not downloading, ignoring");
        return;
    }
    
    // For simple downloads (no resume), just write all data
    long long dataLength = [data length];
    
    // Reduce logging frequency - only log every 1MB or at the end
    static long long lastLogBytes = 0;
    BOOL shouldLog = (_receivedBytes - lastLogBytes >= 1048576) || // Every 1MB
                     (_totalBytes > 0 && (_totalBytes - _receivedBytes) <= 1048576); // Last 1MB
    
    if (shouldLog) {
        NSLog(@"CLMDownloader: didReceiveData: %lld bytes, total: %lld/%lld", 
              dataLength, _receivedBytes + dataLength, _totalBytes);
        lastLogBytes = _receivedBytes + dataLength;
    }
    
    // Update last data received time
    _lastDataTime = [[NSDate date] timeIntervalSince1970];
    
    // Write all data to file
    [_outputFile writeData:data];
    _receivedBytes += dataLength;
    
    // Clamp _receivedBytes to not exceed _totalBytes to prevent progress > 100%
    if (_totalBytes > 0 && _receivedBytes > _totalBytes) {
        NSLog(@"CLMDownloader: WARNING - receivedBytes (%lld) exceeds totalBytes (%lld), clamping", 
              _receivedBytes, _totalBytes);
        _receivedBytes = _totalBytes;
    }
    
    // Update progress (cap at 99% until all bytes received)
    if (_totalBytes > 0) {
        float progress = (float)_receivedBytes / (float)_totalBytes;
        if (progress >= 1.0 && _receivedBytes < _totalBytes) {
            progress = 0.99; // Cap at 99% until truly complete
        }
        
        // Update progress less frequently for better performance
        static float lastProgress = 0.0;
        if (progress - lastProgress >= 0.01 || progress >= 1.0) { // Every 1% or at completion
            @try {
                [_delegate downloadProgressChanged:progress bytesReceived:_receivedBytes totalBytes:_totalBytes];
            } @catch (NSException *exception) {
                NSLog(@"CLMDownloader: Exception in progress delegate callback: %@ - %@", [exception name], [exception reason]);
            }
            lastProgress = progress;
        }
    }
    
    // Force sync and complete if we have all the data
    if (_totalBytes > 0 && _receivedBytes >= _totalBytes) {
        NSLog(@"CLMDownloader: All data received (%lld bytes), completing download", _receivedBytes);
        
        [_outputFile synchronizeFile];
        
        // Force the OS to flush all buffers and commit to storage
        @try {
            int fd = [_outputFile fileDescriptor];
            if (fd >= 0) {
                fsync(fd); // Force kernel buffers to disk
            }
        } @catch (NSException *e) {
            NSLog(@"CLMDownloader: Warning - could not fsync: %@", [e reason]);
        }
        
        // Complete download immediately
        [self performSelectorOnMainThread:@selector(completeDownloadImmediately) 
                               withObject:nil 
                            waitUntilDone:NO];
        return;
    }
    
    // Periodic sync to disk - every 50MB normally, every 5MB in last 100MB
    static long long lastSyncBytes = 0;
    long long remainingBytes = _totalBytes - _receivedBytes;
    long long syncInterval = (remainingBytes <= 104857600) ? 5242880 : 52428800; // 5MB or 50MB
    
    if (_receivedBytes - lastSyncBytes >= syncInterval) {
        [_outputFile synchronizeFile];
        lastSyncBytes = _receivedBytes;
        if (shouldLog) {
            NSLog(@"CLMDownloader: Periodic sync to disk at %lld bytes", _receivedBytes);
        }
    }
}

- (void)handleDownloadCompletion:(BOOL)success
{
    NSLog(@"CLMDownloader: handleDownloadCompletion called with success=%d", success);
    
    if (success && _totalBytes > 0) {
        // Force final progress update to 100%
        NSLog(@"CLMDownloader: Download complete - final progress update to 100%% (%lld bytes)", _receivedBytes);
        @try {
            [_delegate downloadProgressChanged:1.0 bytesReceived:_receivedBytes totalBytes:_totalBytes];
        } @catch (NSException *exception) {
            NSLog(@"CLMDownloader: Exception in final progress delegate callback: %@ - %@", [exception name], [exception reason]);
        }
    }
    
    // Close and cleanup file handle
    if (_outputFile) {
        [_outputFile synchronizeFile];  // Force final sync
        [_outputFile closeFile];
        [_outputFile release];
        _outputFile = nil;
    }
    
    // Cleanup connection
    if (_connection) {
        [_connection cancel];  // Make sure it's cancelled
        [_connection release];
        _connection = nil;
    }
    
    // Stop timers
    [self stopStallDetectionTimer];
    
    // Notify delegate
    if (_isDownloading) {
        if (success) {
            NSLog(@"CLMDownloader: Download completed successfully");
            @try {
                [_delegate downloadCompleted:YES error:nil];
            } @catch (NSException *exception) {
                NSLog(@"CLMDownloader: Exception in delegate callback: %@ - %@", [exception name], [exception reason]);
            }
        } else {
            NSLog(@"CLMDownloader: Download failed");
            @try {
                [_delegate downloadCompleted:NO error:@"Download failed"];
            } @catch (NSException *exception) {
                NSLog(@"CLMDownloader: Exception in delegate callback: %@ - %@", [exception name], [exception reason]);
            }
        }
    } else {
        NSLog(@"CLMDownloader: Download was cancelled");
    }
    
    _isDownloading = NO;
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection
{
    NSLog(@"CLMDownloader: connectionDidFinishLoading - received %lld of %lld bytes", _receivedBytes, _totalBytes);
    
    // Check if download is actually complete
    BOOL downloadComplete = (_totalBytes <= 0) || (_receivedBytes >= _totalBytes);
    
    if (downloadComplete) {
        [self handleDownloadCompletion:YES];
    } else {
        long long missingBytes = _totalBytes - _receivedBytes;
        float percentComplete = ((float)_receivedBytes / (float)_totalBytes) * 100.0;
        
        // If we're very close to completion, consider it done rather than retry
        if (missingBytes <= 4096) { // Less than 4KB missing
            NSLog(@"CLMDownloader: Only %lld bytes missing (%.4f%% complete), considering download complete", missingBytes, percentComplete);
            [self handleDownloadCompletion:YES];
            return;
        }
        
        // Download is incomplete - check if we should retry
        if (_retryCount < _maxRetries) {
            _retryCount++;
            NSLog(@"CLMDownloader: Download incomplete (missing %lld bytes, %.4f%% complete), attempting retry %d of %d", 
                  missingBytes, percentComplete, _retryCount, _maxRetries);
            
            // Clean up current connection
            [_connection release];
            _connection = nil;
            
            // Wait a bit before retrying (exponential backoff)
            NSTimeInterval delayInSeconds = pow(2.0, _retryCount - 1); // 1, 2, 4 seconds
            [NSTimer scheduledTimerWithTimeInterval:delayInSeconds
                                             target:self
                                           selector:@selector(performRetryAfterDelay:)
                                           userInfo:nil
                                            repeats:NO];
        } else {
            // Max retries exceeded - treat as error
            NSLog(@"CLMDownloader: Download incomplete after %d retries - received %lld bytes but expected %lld (%.4f%% complete)", 
                  _maxRetries, _receivedBytes, _totalBytes, percentComplete);
            
            // If we're very close to completion even after retries, consider it successful
            if (percentComplete >= 99.5) {
                NSLog(@"CLMDownloader: Download is %.4f%% complete, considering it successful despite missing %lld bytes", percentComplete, missingBytes);
                [self handleDownloadCompletion:YES];
            } else {
                NSString *errorMsg = [NSString stringWithFormat:@"Download incomplete after %d retries - received %lld bytes but expected %lld (%.1f%% complete)", _maxRetries, _receivedBytes, _totalBytes, percentComplete];
                [_delegate downloadCompleted:NO error:errorMsg];
                [self handleDownloadCompletion:NO];
            }
        }
    }
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error
{
    NSLog(@"CLMDownloader: didFailWithError: %@", [error localizedDescription]);
    
    [self stopStallDetectionTimer];
    
    // Check if we should retry on network errors
    if (_retryCount < _maxRetries && 
        ([error code] == NSURLErrorTimedOut || 
         [error code] == NSURLErrorNetworkConnectionLost ||
         [error code] == NSURLErrorNotConnectedToInternet ||
         [error code] == NSURLErrorCannotConnectToHost)) {
        
        _retryCount++;
        NSLog(@"CLMDownloader: Network error, attempting retry %d of %d", _retryCount, _maxRetries);
        
        // Clean up current connection
        [_connection release];
        _connection = nil;
        
        // Clean up output file - we'll restart fresh for network errors
        if (_outputFile) {
            [_outputFile closeFile];
            [_outputFile release];
            _outputFile = nil;
        }
        
        // Wait a bit before retrying (exponential backoff)
        NSTimeInterval delayInSeconds = pow(2.0, _retryCount - 1); // 1, 2, 4 seconds
        [NSTimer scheduledTimerWithTimeInterval:delayInSeconds
                                         target:self
                                       selector:@selector(performRetryAfterDelay:)
                                       userInfo:nil
                                        repeats:NO];
        return;
    }
    
    // Max retries exceeded or non-retryable error
    if (_outputFile) {
        [_outputFile closeFile];
        [_outputFile release];
        _outputFile = nil;
    }
    
    if (_connection) {
        [_connection release];
        _connection = nil;
    }
    
    NSString *errorMsg = [error localizedDescription];
    if (_retryCount >= _maxRetries) {
        errorMsg = [NSString stringWithFormat:@"%@ (after %d retries)", errorMsg, _maxRetries];
    }
    
    [_delegate downloadCompleted:NO error:errorMsg];
    _isDownloading = NO;
}

#pragma mark - Helper Methods

- (void)updateProgress:(NSNumber *)progressValue
{
    float progress = [progressValue floatValue];
    @try {
        [_delegate downloadProgressChanged:progress bytesReceived:_receivedBytes totalBytes:_totalBytes];
    } @catch (NSException *exception) {
        NSLog(@"CLMDownloader: Exception in updateProgress delegate callback: %@ - %@", [exception name], [exception reason]);
    }
}

- (void)cancelDownload
{
    NSLog(@"CLMDownloader: cancelDownload");
    
    _isDownloading = NO;
    
    [self stopStallDetectionTimer];
    
    if (_connection) {
        [_connection cancel];
        [_connection release];
        _connection = nil;
    }
    
    if (_outputFile) {
        [_outputFile closeFile];
        [_outputFile release];
        _outputFile = nil;
    }
}

#pragma mark - Stall Detection

- (void)startStallDetectionTimer
{
    NSLog(@"CLMDownloader: Starting stall detection timer");
    
    // Stop any existing timer first
    [self stopStallDetectionTimer];
    
    _stallTimer = [NSTimer scheduledTimerWithTimeInterval:15.0
                                                   target:self
                                                 selector:@selector(checkForStall:)
                                                 userInfo:nil
                                                  repeats:YES];
    [_stallTimer retain];
}

- (void)stopStallDetectionTimer
{
    NSLog(@"CLMDownloader: Stopping stall detection timer");
    if (_stallTimer) {
        [_stallTimer invalidate];
        [_stallTimer release];
        _stallTimer = nil;
    }
}

- (void)checkForStall:(NSTimer *)timer
{
    if (!_isDownloading) {
        [self stopStallDetectionTimer];
        return;
    }
    
    NSTimeInterval currentTime = [[NSDate date] timeIntervalSince1970];
    NSTimeInterval timeSinceLastData = currentTime - _lastDataTime;
    
    NSLog(@"CLMDownloader: Stall check - time since last data: %.1f seconds (received: %lld/%lld bytes)", 
          timeSinceLastData, _receivedBytes, _totalBytes);
    
    // Check if we've actually completed the download but connection hasn't closed
    if (_totalBytes > 0 && _receivedBytes >= _totalBytes) {
        NSLog(@"CLMDownloader: Download appears complete (%lld >= %lld), forcing completion", _receivedBytes, _totalBytes);
        [self stopStallDetectionTimer];
        [self handleDownloadCompletion:YES];
        return;
    }
    
    // EMERGENCY: If we're missing very few bytes and have been trying for a while, 
    // consider the download complete even if we haven't received everything
    if (_totalBytes > 0) {
        long long missingBytes = _totalBytes - _receivedBytes;
        float percentComplete = ((float)_receivedBytes / (float)_totalBytes) * 100.0;
        
        // Be much more aggressive about completing downloads that are essentially done
        
        // If we're missing less than 1KB and have been trying for over 30 seconds, consider complete
        if (missingBytes <= 1024 && timeSinceLastData > 30.0) {
            NSLog(@"CLMDownloader: EMERGENCY COMPLETION - Only %lld bytes missing after 30+ seconds, considering download complete (%.4f%% done)", missingBytes, percentComplete);
            [self stopStallDetectionTimer];
            [self handleDownloadCompletion:YES];
            return;
        }
        
        // If we're missing less than 4KB and have been trying for over 1 minute, consider complete
        if (missingBytes <= 4096 && timeSinceLastData > 60.0) {
            NSLog(@"CLMDownloader: EMERGENCY COMPLETION - Only %lld bytes missing after 1+ minute, considering download complete (%.4f%% done)", missingBytes, percentComplete);
            [self stopStallDetectionTimer];
            [self handleDownloadCompletion:YES];
            return;
        }
        
        // If we're missing less than 64KB and have been trying for over 2 minutes, consider complete
        if (missingBytes <= 65536 && timeSinceLastData > 120.0) {
            NSLog(@"CLMDownloader: EMERGENCY COMPLETION - Only %lld bytes missing after 2+ minutes, considering download complete (%.4f%% done)", missingBytes, percentComplete);
            [self stopStallDetectionTimer];
            [self handleDownloadCompletion:YES];
            return;
        }
        
        // If we're missing less than 256KB and have been trying for over 5 minutes, consider complete
        if (missingBytes <= 262144 && timeSinceLastData > 300.0) {
            NSLog(@"CLMDownloader: EMERGENCY COMPLETION - Only %lld bytes missing after 5+ minutes, considering download complete (%.4f%% done)", missingBytes, percentComplete);
            [self stopStallDetectionTimer];
            [self handleDownloadCompletion:YES];
            return;
        }
    }
    
    // Check if we're very close to completion and should retry more aggressively
    if (_totalBytes > 0 && (_totalBytes - _receivedBytes) <= 5242880 && timeSinceLastData > 5.0) {
        float percentComplete = ((float)_receivedBytes / (float)_totalBytes) * 100.0;
        long long missingBytes = _totalBytes - _receivedBytes;
        NSLog(@"CLMDownloader: Very close to completion (%.2f%%, missing only %lld bytes) but stalled for %.1f seconds", 
              percentComplete, missingBytes, timeSinceLastData);
        
        // Be VERY aggressive when close to completion
        BOOL shouldRetryImmediately = NO;
        if (percentComplete >= 99.0 && timeSinceLastData > 5.0) {
            NSLog(@"CLMDownloader: >= 99%% complete but stalled for >5s, retrying immediately");
            shouldRetryImmediately = YES;
        } else if (missingBytes <= 1048576 && timeSinceLastData > 8.0) { // Less than 1MB missing
            NSLog(@"CLMDownloader: Missing only %lld bytes but stalled for >8s, retrying immediately", missingBytes);
            shouldRetryImmediately = YES;
        } else if (missingBytes <= 102400 && timeSinceLastData > 5.0) { // Less than 100KB missing
            NSLog(@"CLMDownloader: Missing only %lld bytes but stalled for >5s, retrying immediately", missingBytes);
            shouldRetryImmediately = YES;
        } else if (percentComplete > 99.5 && timeSinceLastData > 3.0) {
            NSLog(@"CLMDownloader: > 99.5%% complete but stalled for >3s, retrying immediately");
            shouldRetryImmediately = YES;
        } else if (percentComplete > 98.0 && timeSinceLastData > 15.0) {
            NSLog(@"CLMDownloader: > 98%% complete but stalled for >15s, retrying immediately");
            shouldRetryImmediately = YES;
        }
        
        if (shouldRetryImmediately && _retryCount < _maxRetries) {
            _retryCount++;
            NSLog(@"CLMDownloader: Triggering immediate retry due to near-completion stall");
            [self retryDownload];
            return;
        }
    }
    
    // Determine stall timeout based on completion percentage
    NSTimeInterval stallTimeout = 180.0; // Default 3 minutes
    if (_totalBytes > 0) {
        float percentComplete = ((float)_receivedBytes / (float)_totalBytes) * 100.0;
        if (percentComplete > 98.0) {
            stallTimeout = 60.0;  // 1 minute when >98% complete
        } else if (percentComplete > 95.0) {
            stallTimeout = 90.0;  // 1.5 minutes when >95% complete
        } else if (percentComplete > 90.0) {
            stallTimeout = 120.0; // 2 minutes when >90% complete
        }
    }
    
    // If no data received for the timeout period, consider it stalled
    if (timeSinceLastData > stallTimeout) {
        if (_retryCount < _maxRetries) {
            _retryCount++;
            NSLog(@"CLMDownloader: Download stalled after %.0f seconds, attempting retry %d of %d", stallTimeout, _retryCount, _maxRetries);
            [self retryDownload];
        } else {
            NSLog(@"CLMDownloader: Download stalled and max retries (%d) exceeded, giving up", _maxRetries);
            [self stopStallDetectionTimer];
            [self cancelDownload];
            [_delegate downloadCompleted:NO error:[NSString stringWithFormat:@"Download stalled after %d retries - no data received for %.0f seconds", _maxRetries, stallTimeout]];
        }
    }
}

- (void)retryDownload
{
    NSLog(@"CLMDownloader: retryDownload - attempt %d (using simple method)", _retryCount);
    
    // Stop the current stall detection timer
    [self stopStallDetectionTimer];
    
    // Clean up current connection
    if (_connection) {
        [_connection cancel];
        [_connection release];
        _connection = nil;
    }
    
    if (_outputFile) {
        [_outputFile closeFile];
        [_outputFile release];
        _outputFile = nil;
    }
    
    // For small amounts of missing data, just restart from scratch with simple method
    // This avoids the complex resume logic that seems to cause issues
    if (_totalBytes > 0) {
        long long missingBytes = _totalBytes - _receivedBytes;
        float percentComplete = ((float)_receivedBytes / (float)_totalBytes) * 100.0;
        
        if (missingBytes <= 1048576) { // Less than 1MB missing
            NSLog(@"CLMDownloader: Only %lld bytes missing (%.4f%% complete), restarting with simple method", missingBytes, percentComplete);
            _receivedBytes = 0; // Start over with simple method
            _totalBytes = 0;
        }
    }
    
    // Reset the data timer
    _lastDataTime = [[NSDate date] timeIntervalSince1970];
    
    // Use the simple download method for retries to avoid complexity
    [self downloadRemoteFileSimple];
}

- (void)downloadRemoteFileWithResume
{
    NSLog(@"CLMDownloader: downloadRemoteFileWithResume - resuming from byte %lld", _receivedBytes);
    
    @try {
        // Check if we're writing to a block device (starts with /dev/)
        BOOL isBlockDevice = [_destinationPath hasPrefix:@"/dev/"];
        
        if (isBlockDevice) {
            // For block devices, we cannot seek but we can still resume the HTTP download
            NSLog(@"CLMDownloader: Writing to block device %@, will resume HTTP stream from byte %lld", _destinationPath, _receivedBytes);
            
            // Check if the block device exists and is writable
            NSFileManager *fileManager = [NSFileManager defaultManager];
            if (![fileManager fileExistsAtPath:_destinationPath]) {
                NSLog(@"CLMDownloader: Block device %@ does not exist", _destinationPath);
                [_delegate downloadCompleted:NO error:[NSString stringWithFormat:@"Block device %@ does not exist", _destinationPath]];
                _isDownloading = NO;
                return;
            }
            
            if (![fileManager isWritableFileAtPath:_destinationPath]) {
                NSLog(@"CLMDownloader: Block device %@ is not writable (permission denied)", _destinationPath);
                [_delegate downloadCompleted:NO error:[NSString stringWithFormat:@"Block device %@ is not writable - check permissions", _destinationPath]];
                _isDownloading = NO;
                return;
            }
            
            // Open the block device for writing (append mode won't work, but we'll position manually)
            _outputFile = [[NSFileHandle fileHandleForWritingAtPath:_destinationPath] retain];
            if (!_outputFile) {
                NSLog(@"CLMDownloader: Could not open block device for writing on retry - permission denied or device busy");
                NSString *errorMsg = [NSString stringWithFormat:@"Could not open block device %@ for writing.\n\nThis may happen if:\n• The device is busy or locked by another process\n• Permissions changed during download\n• The device was unmounted\n\nTry restarting the application or check if the device is in use.", _destinationPath];
                [_delegate downloadCompleted:NO error:errorMsg];
                _isDownloading = NO;
                return;
            }
            
            // For block devices, we need to seek to the position where we left off
            // This may fail, but we'll try anyway
            @try {
                [_outputFile seekToFileOffset:_receivedBytes];
                NSLog(@"CLMDownloader: Successfully seeked to offset %lld in block device", _receivedBytes);
            } @catch (NSException *seekException) {
                NSLog(@"CLMDownloader: Could not seek in block device (expected): %@", [seekException reason]);
                // This is expected for some block devices, but we'll continue anyway
                // The HTTP request will still resume from the correct byte position
            }
        } else {
            // For regular files, try to resume if we have already received some data
            if (_receivedBytes > 0) {
                _outputFile = [[NSFileHandle fileHandleForWritingAtPath:_destinationPath] retain];
                if (_outputFile) {
                    [_outputFile seekToEndOfFile];
                    NSLog(@"CLMDownloader: Resuming regular file download, seeking to byte %lld", _receivedBytes);
                } else {
                    NSLog(@"CLMDownloader: Could not open existing file for resume, starting fresh");
                    _receivedBytes = 0; // Start over if we can't resume
                }
            }
            
            // If we couldn't resume or starting fresh, create new file
            if (!_outputFile) {
                NSFileManager *fileManager = [NSFileManager defaultManager];
                if (![fileManager createFileAtPath:_destinationPath contents:nil attributes:nil]) {
                    NSLog(@"CLMDownloader: Could not create destination file for retry");
                    [_delegate downloadCompleted:NO error:@"Could not create destination file for retry"];
                    _isDownloading = NO;
                    return;
                }
                
                _outputFile = [[NSFileHandle fileHandleForWritingAtPath:_destinationPath] retain];
                if (!_outputFile) {
                    NSLog(@"CLMDownloader: Could not open destination file for writing on retry");
                    [_delegate downloadCompleted:NO error:@"Could not open destination file for writing on retry"];
                    _isDownloading = NO;
                    return;
                }
                _receivedBytes = 0; // Starting fresh
            }
        }
        
        // Create the request with range header to resume from where we left off
        NSURL *url = [NSURL URLWithString:_sourceURL];
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
        [request setTimeoutInterval:30.0];
        
        // ALWAYS try to resume from _receivedBytes, regardless of device type
        if (_receivedBytes > 0) {
            NSString *rangeHeader = [NSString stringWithFormat:@"bytes=%lld-", _receivedBytes];
            [request setValue:rangeHeader forHTTPHeaderField:@"Range"];
            NSLog(@"CLMDownloader: Adding Range header: %@", rangeHeader);
        }
        
        // Start the connection
        _connection = [[NSURLConnection alloc] initWithRequest:request delegate:self];
        if (!_connection) {
            NSLog(@"CLMDownloader: Could not create NSURLConnection for retry");
            [_outputFile closeFile];
            [_outputFile release];
            _outputFile = nil;
            [_delegate downloadCompleted:NO error:@"Could not create network connection for retry"];
            _isDownloading = NO;
            return;
        }
        
        // Restart stall detection timer for this retry attempt
        [self startStallDetectionTimer];
        
    } @catch (NSException *exception) {
        NSLog(@"CLMDownloader: Exception in downloadRemoteFileWithResume: %@ - %@", [exception name], [exception reason]);
        
        // Clean up on exception
        if (_outputFile) {
            [_outputFile closeFile];
            [_outputFile release];
            _outputFile = nil;
        }
        
        if (_connection) {
            [_connection cancel];
            [_connection release];
            _connection = nil;
        }
        
        // Report error or try again if we have retries left
        NSString *errorMsg = [NSString stringWithFormat:@"File operation exception: %@", [exception reason]];
        [_delegate downloadCompleted:NO error:errorMsg];
        _isDownloading = NO;
    }
}

- (void)performRetryAfterDelay:(NSTimer *)timer
{
    NSLog(@"CLMDownloader: performRetryAfterDelay - executing retry");
    if (_isDownloading) {
        @try {
            [self retryDownload];
        } @catch (NSException *exception) {
            NSLog(@"CLMDownloader: Exception during retry: %@ - %@", [exception name], [exception reason]);
            // If retry fails due to exception, move to next retry or fail
            if (_retryCount < _maxRetries) {
                _retryCount++;
                NSLog(@"CLMDownloader: Exception occurred, attempting next retry %d of %d", _retryCount, _maxRetries);
                NSTimeInterval delayInSeconds = pow(2.0, _retryCount - 1);
                [NSTimer scheduledTimerWithTimeInterval:delayInSeconds
                                                 target:self
                                               selector:@selector(performRetryAfterDelay:)
                                               userInfo:nil
                                                repeats:NO];
            } else {
                NSLog(@"CLMDownloader: Exception occurred and max retries exceeded");
                [_delegate downloadCompleted:NO error:[NSString stringWithFormat:@"Download failed after %d retries due to exception: %@", _maxRetries, [exception reason]]];
                _isDownloading = NO;
            }
        }
    }
}

- (void)completeDownloadImmediately
{
    NSLog(@"CLMDownloader: completeDownloadImmediately called");
    [self handleDownloadCompletion:YES];
}
@end
