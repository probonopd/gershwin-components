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
        _streamPosition = 0;
        _streamPositionInitialized = NO;
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
    _streamPosition = 0; // Reset stream position for new download
    _streamPositionInitialized = NO; // Reset stream position tracking
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
    NSLog(@"CLMDownloader: downloadRemoteFile using NSURLConnection");
    [self downloadRemoteFileWithResume];
}

#pragma mark - NSURLConnection Delegate Methods

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response
{
    NSLog(@"CLMDownloader: didReceiveResponse");
    
    BOOL isBlockDevice = [_destinationPath hasPrefix:@"/dev/"];
    
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
    
    // Initialize stream position on first data packet of a new connection
    if (!_streamPositionInitialized) {
        _streamPosition = _receivedBytes; // Start from where we want to resume
        _streamPositionInitialized = YES;
        NSLog(@"CLMDownloader: Initializing stream position to %lld", _streamPosition);
    }
    
    // Calculate how much of this data we actually need
    long long dataLength = [data length];
    long long dataStartPosition = _streamPosition;
    long long dataEndPosition = _streamPosition + dataLength;
    
    NSLog(@"CLMDownloader: didReceiveData: %lld bytes (stream pos: %lld-%lld, need from: %lld)", 
          dataLength, dataStartPosition, dataEndPosition - 1, _receivedBytes);
    
    // Update last data received time
    _lastDataTime = [[NSDate date] timeIntervalSince1970];
    
    // Determine what part of this data to write
    NSData *dataToWrite = data;
    long long bytesToSkip = 0;
    
    if (_receivedBytes > _streamPosition) {
        // We need to skip some bytes at the beginning of this packet
        bytesToSkip = _receivedBytes - _streamPosition;
        NSLog(@"CLMDownloader: Need to skip %lld bytes (have: %lld, stream at: %lld)", bytesToSkip, _receivedBytes, _streamPosition);
        
        if (bytesToSkip >= dataLength) {
            // Skip this entire packet
            NSLog(@"CLMDownloader: Skipping entire packet (%lld bytes) - already have this data", dataLength);
            _streamPosition += dataLength;
            return;
        } else {
            // Skip part of the packet
            NSLog(@"CLMDownloader: Skipping first %lld bytes of packet", bytesToSkip);
            dataToWrite = [data subdataWithRange:NSMakeRange(bytesToSkip, dataLength - bytesToSkip)];
        }
    } else {
        // We need all or most of this data
        NSLog(@"CLMDownloader: Using entire packet (%lld bytes)", dataLength);
    }
    
    // Write the data (or remaining part) to file
    if ([dataToWrite length] > 0) {
        NSLog(@"CLMDownloader: About to write %lu bytes to file", (unsigned long)[dataToWrite length]);
        [_outputFile writeData:dataToWrite];
        _receivedBytes += [dataToWrite length];
        NSLog(@"CLMDownloader: Wrote %lu bytes, total received: %lld/%lld", 
              (unsigned long)[dataToWrite length], _receivedBytes, _totalBytes);
        
        // Force sync for the last chunk to ensure it's written
        if (_totalBytes > 0 && _receivedBytes >= _totalBytes) {
            NSLog(@"CLMDownloader: Final chunk received, forcing sync to disk");
            [_outputFile synchronizeFile];
        }
    } else {
        NSLog(@"CLMDownloader: No data to write (dataToWrite length = 0)");
    }
    
    // Update stream position
    _streamPosition += dataLength;
    
    // Periodically sync to disk for block devices (every 10MB)
    static long long lastSyncBytes = 0;
    if (_receivedBytes - lastSyncBytes >= 10 * 1024 * 1024) {
        [_outputFile synchronizeFile];
        lastSyncBytes = _receivedBytes;
    }
    
    // Check if we've received all expected data
    if (_totalBytes > 0 && _receivedBytes >= _totalBytes) {
        NSLog(@"CLMDownloader: All expected data received (%lld >= %lld)", _receivedBytes, _totalBytes);
    }
    
    // Update progress, but throttle updates to avoid overwhelming the UI
    static long long lastUpdateBytes = 0;
    static NSTimeInterval lastUpdateTime = 0;
    NSTimeInterval currentTime = [[NSDate date] timeIntervalSince1970];
    
    // Update every 64KB or every 0.1 seconds, whichever comes first
    BOOL shouldUpdate = (_receivedBytes - lastUpdateBytes >= 65536) || 
                       (currentTime - lastUpdateTime >= 0.1) ||
                       (_totalBytes > 0 && _receivedBytes >= _totalBytes);
    
    if (shouldUpdate) {
        float progress = 0.0;
        if (_totalBytes > 0) {
            progress = (float)_receivedBytes / (float)_totalBytes;
        } else {
            // Unknown size, show indeterminate progress
            progress = -1.0;
        }
        
        NSLog(@"CLMDownloader: Updating progress: %.4f (%lld/%lld)", progress, _receivedBytes, _totalBytes);
        [_delegate downloadProgressChanged:progress bytesReceived:_receivedBytes totalBytes:_totalBytes];
        
        lastUpdateBytes = _receivedBytes;
        lastUpdateTime = currentTime;
    }
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection
{
    NSLog(@"CLMDownloader: connectionDidFinishLoading - received %lld of %lld bytes", _receivedBytes, _totalBytes);
    
    [self stopStallDetectionTimer];
    
    // Check if download is actually complete
    BOOL downloadComplete = (_totalBytes <= 0) || (_receivedBytes >= _totalBytes);
    
    if (downloadComplete) {
        // Only report 100% if we actually received all bytes
        if (_isDownloading && _totalBytes > 0) {
            NSLog(@"CLMDownloader: Download complete - final progress update to 100%%");
            [_delegate downloadProgressChanged:1.0 bytesReceived:_receivedBytes totalBytes:_totalBytes];
        }
        
        [_outputFile closeFile];
        [_outputFile release];
        _outputFile = nil;
        
        [_connection release];
        _connection = nil;
        
        if (_isDownloading) {
            NSLog(@"CLMDownloader: Download completed successfully");
            [_delegate downloadCompleted:YES error:nil];
        } else {
            NSLog(@"CLMDownloader: Download was cancelled");
        }
        
        _isDownloading = NO;
    } else {
        // Download is incomplete - check if we should retry
        if (_retryCount < _maxRetries) {
            _retryCount++;
            NSLog(@"CLMDownloader: Download incomplete, attempting retry %d of %d", _retryCount, _maxRetries);
            
            // Clean up current connection
            [_connection release];
            _connection = nil;
            
            // Don't close output file - we'll try to resume
            
            // Wait a bit before retrying (exponential backoff)
            NSTimeInterval delayInSeconds = pow(2.0, _retryCount - 1); // 1, 2, 4 seconds
            [NSTimer scheduledTimerWithTimeInterval:delayInSeconds
                                             target:self
                                           selector:@selector(performRetryAfterDelay:)
                                           userInfo:nil
                                            repeats:NO];
        } else {
            // Max retries exceeded - treat as error
            NSLog(@"CLMDownloader: Download incomplete after %d retries - received %lld bytes but expected %lld", _maxRetries, _receivedBytes, _totalBytes);
            
            [_outputFile closeFile];
            [_outputFile release];
            _outputFile = nil;
            
            [_connection release];
            _connection = nil;
            
            NSString *errorMsg = [NSString stringWithFormat:@"Download incomplete after %d retries - received %lld bytes but expected %lld", _maxRetries, _receivedBytes, _totalBytes];
            [_delegate downloadCompleted:NO error:errorMsg];
            _isDownloading = NO;
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
        
        // Don't close output file - we may be able to resume
        
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
    [_outputFile closeFile];
    [_outputFile release];
    _outputFile = nil;
    
    [_connection release];
    _connection = nil;
    
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
    [_delegate downloadProgressChanged:progress bytesReceived:_receivedBytes totalBytes:_totalBytes];
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
    
    NSLog(@"CLMDownloader: Stall check - time since last data: %.1f seconds", timeSinceLastData);
    
    // If no data received for 180 seconds (3 minutes), consider it stalled
    if (timeSinceLastData > 180.0) {
        if (_retryCount < _maxRetries) {
            _retryCount++;
            NSLog(@"CLMDownloader: Download stalled after 3 minutes, attempting retry %d of %d", _retryCount, _maxRetries);
            [self retryDownload];
        } else {
            NSLog(@"CLMDownloader: Download stalled and max retries (%d) exceeded, giving up", _maxRetries);
            [self stopStallDetectionTimer];
            [self cancelDownload];
            [_delegate downloadCompleted:NO error:[NSString stringWithFormat:@"Download stalled after %d retries - no data received for 3 minutes", _maxRetries]];
        }
    }
}

- (void)retryDownload
{
    NSLog(@"CLMDownloader: retryDownload - attempt %d", _retryCount);
    
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
    
    // Don't reset _receivedBytes - we'll try to resume from where we left off
    // Reset the data timer
    _lastDataTime = [[NSDate date] timeIntervalSince1970];
    
    // Try to resume the download from where we left off
    [self downloadRemoteFileWithResume];
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
            
            // Open the block device for writing (append mode won't work, but we'll position manually)
            _outputFile = [[NSFileHandle fileHandleForWritingAtPath:_destinationPath] retain];
            if (!_outputFile) {
                NSLog(@"CLMDownloader: Could not open block device for writing on retry");
                [_delegate downloadCompleted:NO error:@"Could not open block device for writing on retry"];
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
        
        // Reset stream position tracking for new connection
        _streamPositionInitialized = NO;
        
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
@end
