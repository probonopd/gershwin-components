//
// CLMDownloader.h
// Create Live Media Assistant - Downloader
//

#import <Foundation/Foundation.h>

@protocol CLMDownloaderDelegate <NSObject>
- (void)downloadProgressChanged:(float)progress bytesReceived:(long long)bytesReceived totalBytes:(long long)totalBytes;
- (void)downloadCompleted:(BOOL)success error:(NSString *)error;
@end

@interface CLMDownloader : NSObject
{
    id<CLMDownloaderDelegate> _delegate;
    NSString *_sourceURL;
    NSString *_destinationPath;
    NSURLConnection *_connection;
    NSFileHandle *_outputFile;
    BOOL _isDownloading;
    long long _totalBytes;
    long long _receivedBytes;
    NSTimeInterval _lastDataTime;
    NSTimer *_stallTimer;
    int _retryCount;
    int _maxRetries;
    long long _streamPosition;
    BOOL _streamPositionInitialized;
}

@property (nonatomic, assign) id<CLMDownloaderDelegate> delegate;
@property (nonatomic, readonly) BOOL isDownloading;

- (void)downloadFromURL:(NSString *)url toPath:(NSString *)path;
- (void)cancelDownload;

@end
