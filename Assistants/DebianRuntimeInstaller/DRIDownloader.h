//
// DRIDownloader.h
// Debian Runtime Installer - File Downloader
//
// Handles downloading runtime images with progress tracking
//

#import <Foundation/Foundation.h>

@protocol DRIDownloaderDelegate <NSObject>
- (void)downloader:(id)downloader didStartDownloadWithExpectedSize:(long long)expectedSize;
- (void)downloader:(id)downloader didUpdateProgress:(double)progress bytesDownloaded:(long long)bytesDownloaded;
- (void)downloader:(id)downloader didCompleteWithFilePath:(NSString *)filePath;
- (void)downloader:(id)downloader didFailWithError:(NSError *)error;
@end

@interface DRIDownloader : NSObject
@property (nonatomic, assign) id<DRIDownloaderDelegate> delegate;
@property (nonatomic, readonly) BOOL isDownloading;
@property (nonatomic, readonly) double progress;
@property (nonatomic, readonly) long long bytesDownloaded;
@property (nonatomic, readonly) long long expectedBytes;

- (void)downloadFileFromURL:(NSString *)urlString toPath:(NSString *)destinationPath;
- (void)cancelDownload;
@end
