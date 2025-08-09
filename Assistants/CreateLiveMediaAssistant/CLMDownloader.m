//
// CLMDownloader.m
// Create Live Media Assistant - Downloader (Native Implementation)
//

#import "CLMDownloader.h"

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
    
    // Create the request
    NSURL *url = [NSURL URLWithString:_sourceURL];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setTimeoutInterval:30.0];
    
    // Create destination file
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager createFileAtPath:_destinationPath contents:nil attributes:nil]) {
        NSLog(@"CLMDownloader: Could not create destination file");
        [_delegate downloadCompleted:NO error:@"Could not create destination file"];
        _isDownloading = NO;
        return;
    }
    
    _outputFile = [[NSFileHandle fileHandleForWritingAtPath:_destinationPath] retain];
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
    }
}

#pragma mark - NSURLConnection Delegate Methods

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response
{
    NSLog(@"CLMDownloader: didReceiveResponse");
    
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        NSInteger statusCode = [httpResponse statusCode];
        
        if (statusCode >= 400) {
            NSLog(@"CLMDownloader: HTTP error %ld", (long)statusCode);
            [self cancelDownload];
            [_delegate downloadCompleted:NO error:[NSString stringWithFormat:@"HTTP error %ld", (long)statusCode]];
            return;
        }
    }
    
    _totalBytes = [response expectedContentLength];
    _receivedBytes = 0;
    
    NSLog(@"CLMDownloader: Expected content length: %lld bytes", _totalBytes);
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data
{
    if (!_isDownloading) {
        NSLog(@"CLMDownloader: didReceiveData called but not downloading, ignoring");
        return;
    }
    
    NSLog(@"CLMDownloader: didReceiveData: %lu bytes (total: %lld/%lld)", 
          (unsigned long)[data length], _receivedBytes + [data length], _totalBytes);
    
    // Update last data received time
    _lastDataTime = [[NSDate date] timeIntervalSince1970];
    
    // Write data to file
    [_outputFile writeData:data];
    _receivedBytes += [data length];
    
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
    
    // Ensure we report 100% progress on completion
    if (_isDownloading && _totalBytes > 0) {
        NSLog(@"CLMDownloader: Forcing final progress update to 100%%");
        [_delegate downloadProgressChanged:1.0 bytesReceived:_totalBytes totalBytes:_totalBytes];
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
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error
{
    NSLog(@"CLMDownloader: didFailWithError: %@", [error localizedDescription]);
    
    [self stopStallDetectionTimer];
    
    [_outputFile closeFile];
    [_outputFile release];
    _outputFile = nil;
    
    [_connection release];
    _connection = nil;
    
    [_delegate downloadCompleted:NO error:[error localizedDescription]];
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
    _stallTimer = [NSTimer scheduledTimerWithTimeInterval:30.0
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
    
    // If no data received for 60 seconds, consider it stalled
    if (timeSinceLastData > 60.0) {
        NSLog(@"CLMDownloader: Download appears to be stalled, cancelling");
        [self stopStallDetectionTimer];
        [self cancelDownload];
        [_delegate downloadCompleted:NO error:@"Download stalled - no data received for 60 seconds"];
    }
}
@end
