//
// GSNetworkUtilities.m
// GSAssistantFramework - Network Utilities
//

#import "GSNetworkUtilities.h"

@implementation GSDownloader

@synthesize delegate = _delegate;
@synthesize isDownloading = _isDownloading;
@synthesize totalBytes = _totalBytes;
@synthesize receivedBytes = _receivedBytes;

- (id)init
{
    if (self = [super init]) {
        NSLog(@"GSDownloader: init");
        _isDownloading = NO;
        _totalBytes = 0;
        _receivedBytes = 0;
    }
    return self;
}

- (void)dealloc
{
    NSLog(@"GSDownloader: dealloc");
    [self cancelDownload];
    [_sourceURL release];
    [_destinationPath release];
    [super dealloc];
}

- (void)downloadFromURL:(NSString *)url toPath:(NSString *)path
{
    NSLog(@"GSDownloader: downloadFromURL: %@ toPath: %@", url, path);
    
    if (_isDownloading) {
        NSLog(@"GSDownloader: Already downloading, cancelling current download");
        [self cancelDownload];
    }
    
    [_sourceURL release];
    _sourceURL = [url retain];
    
    [_destinationPath release];
    _destinationPath = [path retain];
    
    _isDownloading = YES;
    _totalBytes = 0;
    _receivedBytes = 0;
    
    if ([url hasPrefix:@"file://"]) {
        [self copyLocalFile];
    } else {
        [self downloadRemoteFile];
    }
}

- (void)copyLocalFile
{
    NSLog(@"GSDownloader: copyLocalFile");
    
    // Extract file path from file:// URL
    NSString *sourcePath = [_sourceURL substringFromIndex:7]; // Remove "file://"
    
    NSFileManager *fileManager = [NSFileManager defaultManager];
    
    // Get file size first
    NSDictionary *attributes = [fileManager attributesOfItemAtPath:sourcePath error:nil];
    if (!attributes) {
        NSLog(@"GSDownloader: Error getting file attributes");
        [_delegate downloadCompleted:NO error:@"Could not read source file"];
        _isDownloading = NO;
        return;
    }
    
    _totalBytes = [[attributes objectForKey:NSFileSize] longLongValue];
    
    // Start copying in background
    [self performSelectorInBackground:@selector(performFileCopy:) withObject:sourcePath];
}

- (void)performFileCopy:(NSString *)sourcePath
{
    NSLog(@"GSDownloader: performFileCopy: %@", sourcePath);
    
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
    
    while (_isDownloading) {
        NSData *chunk = [sourceFile readDataOfLength:chunkSize];
        if ([chunk length] == 0) {
            break; // EOF
        }
        
        [destFile writeData:chunk];
        _receivedBytes += [chunk length];
        
        // Update progress on main thread
        float progress = (_totalBytes > 0) ? (float)_receivedBytes / (float)_totalBytes : 0.0;
        [self performSelectorOnMainThread:@selector(updateProgress:)
                               withObject:[NSNumber numberWithFloat:progress]
                            waitUntilDone:NO];
    }
    
    [sourceFile closeFile];
    [destFile closeFile];
    
    if (_isDownloading) {
        [_delegate downloadCompleted:YES error:nil];
    }
    
    _isDownloading = NO;
}

- (void)downloadRemoteFile
{
    NSLog(@"GSDownloader: downloadRemoteFile using NSURLConnection");
    
    // Create the request
    NSURL *url = [NSURL URLWithString:_sourceURL];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setTimeoutInterval:30.0];
    
    // Create destination file
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager createFileAtPath:_destinationPath contents:nil attributes:nil]) {
        NSLog(@"GSDownloader: Could not create destination file");
        [_delegate downloadCompleted:NO error:@"Could not create destination file"];
        _isDownloading = NO;
        return;
    }
    
    _outputFile = [[NSFileHandle fileHandleForWritingAtPath:_destinationPath] retain];
    if (!_outputFile) {
        NSLog(@"GSDownloader: Could not open destination file for writing");
        [_delegate downloadCompleted:NO error:@"Could not open destination file for writing"];
        _isDownloading = NO;
        return;
    }
    
    // Start the connection
    _connection = [[NSURLConnection alloc] initWithRequest:request delegate:self];
    if (!_connection) {
        NSLog(@"GSDownloader: Could not create NSURLConnection");
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
    NSLog(@"GSDownloader: didReceiveResponse");
    
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        NSInteger statusCode = [httpResponse statusCode];
        
        if (statusCode >= 400) {
            NSLog(@"GSDownloader: HTTP error %ld", (long)statusCode);
            [self cancelDownload];
            [_delegate downloadCompleted:NO error:[NSString stringWithFormat:@"HTTP error %ld", (long)statusCode]];
            return;
        }
    }
    
    _totalBytes = [response expectedContentLength];
    _receivedBytes = 0;
    
    NSLog(@"GSDownloader: Expected content length: %lld bytes", _totalBytes);
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data
{
    if (!_isDownloading) {
        return;
    }
    
    // Write data to file
    [_outputFile writeData:data];
    _receivedBytes += [data length];
    
    // Update progress
    float progress = 0.0;
    if (_totalBytes > 0) {
        progress = (float)_receivedBytes / (float)_totalBytes;
    } else {
        // Unknown size, show indeterminate progress
        progress = -1.0;
    }
    
    [_delegate downloadProgressChanged:progress bytesReceived:_receivedBytes totalBytes:_totalBytes];
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection
{
    NSLog(@"GSDownloader: connectionDidFinishLoading");
    
    [_outputFile closeFile];
    [_outputFile release];
    _outputFile = nil;
    
    [_connection release];
    _connection = nil;
    
    if (_isDownloading) {
        [_delegate downloadCompleted:YES error:nil];
    }
    
    _isDownloading = NO;
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error
{
    NSLog(@"GSDownloader: didFailWithError: %@", [error localizedDescription]);
    
    [_outputFile closeFile];
    [_outputFile release];
    _outputFile = nil;
    
    [_connection release];
    _connection = nil;
    
    [_delegate downloadCompleted:NO error:[error localizedDescription]];
    _isDownloading = NO;
}

- (void)updateProgress:(NSNumber *)progressValue
{
    float progress = [progressValue floatValue];
    [_delegate downloadProgressChanged:progress bytesReceived:_receivedBytes totalBytes:_totalBytes];
}

- (void)cancelDownload
{
    NSLog(@"GSDownloader: cancelDownload");
    
    _isDownloading = NO;
    
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

@end

@implementation GSHTTPClient

+ (NSData *)sendSynchronousRequest:(NSURLRequest *)request 
                 returningResponse:(NSHTTPURLResponse **)response 
                             error:(NSError **)error
{
    NSLog(@"GSHTTPClient: sendSynchronousRequest to %@", [[request URL] absoluteString]);
    
    NSHTTPURLResponse *urlResponse = nil;
    NSError *urlError = nil;
    NSData *data = [NSURLConnection sendSynchronousRequest:request
                                        returningResponse:&urlResponse
                                                    error:&urlError];
    
    if (response) {
        *response = urlResponse;
    }
    
    if (error) {
        *error = urlError;
    }
    
    return data;
}

+ (id)parseJSONFromData:(NSData *)data error:(NSError **)error
{
    if (!data) {
        return nil;
    }
    
    NSError *jsonError = nil;
    id result = [NSJSONSerialization JSONObjectWithData:data
                                                options:0
                                                  error:&jsonError];
    
    if (error) {
        *error = jsonError;
    }
    
    return result;
}

@end

@implementation GSNetworkUtilities

+ (BOOL)checkInternetConnectivity
{
    return [self checkInternetConnectivityToHost:@"8.8.8.8" port:53 timeout:3];
}

+ (BOOL)checkInternetConnectivityToHost:(NSString *)host port:(int)port timeout:(int)timeout
{
    NSLog(@"GSNetworkUtilities: checkInternetConnectivity to %@:%d", host, port);
    
    // Use a simple command-line approach for internet checking
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"/usr/bin/timeout"];
    [task setArguments:@[[NSString stringWithFormat:@"%d", timeout], @"ping", @"-c", @"1", host]];
    
    NSPipe *pipe = [NSPipe pipe];
    [task setStandardOutput:pipe];
    [task setStandardError:pipe];
    
    BOOL connected = NO;
    
    @try {
        [task launch];
        [task waitUntilExit];
        
        int exitStatus = [task terminationStatus];
        connected = (exitStatus == 0);
    }
    @catch (NSException *exception) {
        NSLog(@"GSNetworkUtilities: Error checking internet connection: %@", [exception reason]);
        connected = NO;
    }
    
    [task release];
    
    NSLog(@"GSNetworkUtilities: Internet connection check result: %d", connected);
    return connected;
}

@end
