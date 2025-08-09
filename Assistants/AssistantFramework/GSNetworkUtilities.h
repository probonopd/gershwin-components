//
// GSNetworkUtilities.h
// GSAssistantFramework - Network Utilities
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol GSDownloaderDelegate <NSObject>
- (void)downloadProgressChanged:(float)progress bytesReceived:(long long)bytesReceived totalBytes:(long long)totalBytes;
- (void)downloadCompleted:(BOOL)success error:(nullable NSString *)error;
@end

@interface GSDownloader : NSObject
{
    id<GSDownloaderDelegate> _delegate;
    NSString *_sourceURL;
    NSString *_destinationPath;
    NSURLConnection *_connection;
    NSFileHandle *_outputFile;
    BOOL _isDownloading;
    long long _totalBytes;
    long long _receivedBytes;
}

@property (nonatomic, assign) id<GSDownloaderDelegate> delegate;
@property (nonatomic, readonly) BOOL isDownloading;
@property (nonatomic, readonly) long long totalBytes;
@property (nonatomic, readonly) long long receivedBytes;

- (void)downloadFromURL:(NSString *)url toPath:(NSString *)path;
- (void)cancelDownload;

@end

@interface GSHTTPClient : NSObject

+ (nullable NSData *)sendSynchronousRequest:(NSURLRequest *)request 
                          returningResponse:(NSHTTPURLResponse * _Nullable * _Nullable)response 
                                      error:(NSError * _Nullable * _Nullable)error;

+ (nullable id)parseJSONFromData:(NSData *)data error:(NSError * _Nullable * _Nullable)error;

@end

@interface GSNetworkUtilities : NSObject

+ (BOOL)checkInternetConnectivity;
+ (BOOL)checkInternetConnectivityToHost:(NSString *)host port:(int)port timeout:(int)timeout;

@end

NS_ASSUME_NONNULL_END
