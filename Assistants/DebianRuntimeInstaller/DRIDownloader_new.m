//
// DRIDownloader.m
// Debian Runtime Installer - File Downloader
//

#import "DRIDownloader.h"

@interface DRIDownloader() <NSURLConnectionDelegate, NSURLConnectionDataDelegate>
@property (nonatomic, strong) NSURLConnection *connection;
@property (nonatomic, strong) NSMutableData *downloadedData;
@property (nonatomic, strong) NSString *destinationPath;
@property (nonatomic, assign) BOOL isDownloading;
@property (nonatomic, assign) double progress;
@property (nonatomic, assign) long long bytesDownloaded;
@property (nonatomic, assign) long long expectedBytes;
@end

@implementation DRIDownloader

- (instancetype)init
{
    if (self = [super init]) {
        NSLog(@"DRIDownloader: init");
        
        _isDownloading = NO;
        _progress = 0.0;
        _bytesDownloaded = 0;
        _expectedBytes = 0;
        _downloadedData = [[NSMutableData alloc] init];
    }
    return self;
}

- (void)dealloc
{
    NSLog(@"DRIDownloader: dealloc");
    [self cancelDownload];
    [_downloadedData release];
    [super dealloc];
}

- (void)downloadFileFromURL:(NSString *)urlString toPath:(NSString *)destinationPath
{
    NSLog(@"[DRIDownloader] *** downloadFileFromURL: %@ to: %@", urlString, destinationPath);
    
    if (_isDownloading) {
        NSLog(@"[DRIDownloader] *** Download already in progress, canceling previous download");
        [self cancelDownload];
    }
    
    // Store destination path
    [_destinationPath release];
    _destinationPath = [destinationPath retain];
    
    // Reset state
    _isDownloading = YES;
    _progress = 0.0;
    _bytesDownloaded = 0;
    _expectedBytes = 0;
    [_downloadedData setLength:0];
    
    // Create URL request
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        NSLog(@"[DRIDownloader] *** Invalid URL: %@", urlString);
        NSError *error = [NSError errorWithDomain:@"DRIDownloaderError" 
                                             code:1001 
                                         userInfo:@{NSLocalizedDescriptionKey: @"Invalid URL"}];
        [self notifyDelegateOfError:error];
        return;
    }
    
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setHTTPMethod:@"GET"];
    [request setCachePolicy:NSURLRequestReloadIgnoringLocalCacheData];
    [request setTimeoutInterval:300.0]; // 5 minutes timeout
    
    NSLog(@"[DRIDownloader] *** Creating NSURLConnection with request: %@", request);
    
    // Start the connection
    _connection = [[NSURLConnection alloc] initWithRequest:request delegate:self];
    if (!_connection) {
        NSLog(@"[DRIDownloader] *** Failed to create NSURLConnection");
        NSError *error = [NSError errorWithDomain:@"DRIDownloaderError" 
                                             code:1002 
                                         userInfo:@{NSLocalizedDescriptionKey: @"Failed to create connection"}];
        [self notifyDelegateOfError:error];
        return;
    }
    
    NSLog(@"[DRIDownloader] *** NSURLConnection created successfully, starting download");
}

- (void)cancelDownload
{
    NSLog(@"[DRIDownloader] *** cancelDownload");
    
    if (_connection) {
        [_connection cancel];
        [_connection release];
        _connection = nil;
    }
    
    _isDownloading = NO;
    _progress = 0.0;
    _bytesDownloaded = 0;
    _expectedBytes = 0;
    [_downloadedData setLength:0];
    
    [_destinationPath release];
    _destinationPath = nil;
}

#pragma mark - NSURLConnectionDelegate

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error
{
    NSLog(@"[DRIDownloader] *** connection:didFailWithError: %@", error);
    
    _isDownloading = NO;
    [self notifyDelegateOfError:error];
    [self cancelDownload];
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection
{
    NSLog(@"[DRIDownloader] *** connectionDidFinishLoading - %lld bytes total", _bytesDownloaded);
    
    _isDownloading = NO;
    
    // Write data to file
    BOOL success = [_downloadedData writeToFile:_destinationPath atomically:YES];
    if (success) {
        NSLog(@"[DRIDownloader] *** Successfully wrote %lld bytes to: %@", _bytesDownloaded, _destinationPath);
        [self notifyDelegateOfCompletion:_destinationPath];
    } else {
        NSLog(@"[DRIDownloader] *** Failed to write data to file: %@", _destinationPath);
        NSError *error = [NSError errorWithDomain:@"DRIDownloaderError" 
                                             code:1003 
                                         userInfo:@{NSLocalizedDescriptionKey: @"Failed to write downloaded data to file"}];
        [self notifyDelegateOfError:error];
    }
    
    [self cancelDownload];
}

#pragma mark - NSURLConnectionDataDelegate

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response
{
    NSLog(@"[DRIDownloader] *** connection:didReceiveResponse:");
    
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        NSLog(@"[DRIDownloader] *** HTTP Status Code: %ld", [httpResponse statusCode]);
        NSLog(@"[DRIDownloader] *** Content-Length: %lld", [response expectedContentLength]);
        
        if ([httpResponse statusCode] != 200) {
            NSLog(@"[DRIDownloader] *** HTTP error: %ld", [httpResponse statusCode]);
            NSError *error = [NSError errorWithDomain:@"DRIDownloaderError" 
                                                 code:[httpResponse statusCode] 
                                             userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"HTTP Error %ld", [httpResponse statusCode]]}];
            [self notifyDelegateOfError:error];
            [self cancelDownload];
            return;
        }
    }
    
    _expectedBytes = [response expectedContentLength];
    _bytesDownloaded = 0;
    _progress = 0.0;
    [_downloadedData setLength:0];
    
    NSLog(@"[DRIDownloader] *** Expected bytes: %lld", _expectedBytes);
    [self notifyDelegateOfStart:_expectedBytes];
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data
{
    NSLog(@"[DRIDownloader] *** connection:didReceiveData: %lu bytes", [data length]);
    
    [_downloadedData appendData:data];
    _bytesDownloaded = [_downloadedData length];
    
    if (_expectedBytes > 0) {
        _progress = (double)_bytesDownloaded / (double)_expectedBytes;
    } else {
        _progress = 0.0;
    }
    
    NSLog(@"[DRIDownloader] *** Progress: %.2f%% (%lld / %lld bytes)", _progress * 100.0, _bytesDownloaded, _expectedBytes);
    [self notifyDelegateOfProgress:_progress bytesDownloaded:_bytesDownloaded];
}

#pragma mark - Helper Methods

- (void)notifyDelegateOfStart:(long long)expectedSize
{
    NSLog(@"[DRIDownloader] *** notifyDelegateOfStart: %lld", expectedSize);
    if (_delegate && [_delegate respondsToSelector:@selector(downloader:didStartDownloadWithExpectedSize:)]) {
        [_delegate downloader:self didStartDownloadWithExpectedSize:expectedSize];
    }
}

- (void)notifyDelegateOfProgress:(double)progress bytesDownloaded:(long long)bytesDownloaded
{
    NSLog(@"[DRIDownloader] *** notifyDelegateOfProgress: %.2f%% (%lld bytes)", progress * 100.0, bytesDownloaded);
    if (_delegate && [_delegate respondsToSelector:@selector(downloader:didUpdateProgress:bytesDownloaded:)]) {
        [_delegate downloader:self didUpdateProgress:progress bytesDownloaded:bytesDownloaded];
    }
}

- (void)notifyDelegateOfCompletion:(NSString *)filePath
{
    NSLog(@"[DRIDownloader] *** notifyDelegateOfCompletion: %@", filePath);
    if (_delegate && [_delegate respondsToSelector:@selector(downloader:didCompleteWithFilePath:)]) {
        [_delegate downloader:self didCompleteWithFilePath:filePath];
    }
}

- (void)notifyDelegateOfError:(NSError *)error
{
    NSLog(@"[DRIDownloader] *** notifyDelegateOfError: %@", error);
    if (_delegate && [_delegate respondsToSelector:@selector(downloader:didFailWithError:)]) {
        [_delegate downloader:self didFailWithError:error];
    }
}

@end
