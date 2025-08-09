//
// DRIGitHubAPI.h
// Debian Runtime Installer - GitHub API Client
//
// Handles GitHub API interactions for fetching releases and assets
//

#import <Foundation/Foundation.h>

@interface DRIRelease : NSObject
@property (nonatomic, strong) NSString *name;
@property (nonatomic, strong) NSString *tagName;
@property (nonatomic, assign) BOOL prerelease;
@property (nonatomic, strong) NSDate *publishedAt;
@property (nonatomic, strong) NSArray *assets;
@end

@interface DRIAsset : NSObject
@property (nonatomic, strong) NSString *name;
@property (nonatomic, strong) NSString *downloadURL;
@property (nonatomic, assign) long long size;
@property (nonatomic, strong) NSDate *updatedAt;
@property (nonatomic, strong) NSString *contentType;
@end

@protocol DRIGitHubAPIDelegate <NSObject>
- (void)gitHubAPI:(id)api didFetchReleases:(NSArray *)releases;
- (void)gitHubAPI:(id)api didFailWithError:(NSError *)error;
@end

@interface DRIGitHubAPI : NSObject
@property (nonatomic, assign) id<DRIGitHubAPIDelegate> delegate;
@property (nonatomic, strong) NSString *repositoryOwner;
@property (nonatomic, strong) NSString *repositoryName;

- (instancetype)initWithRepository:(NSString *)owner name:(NSString *)name;
- (void)fetchReleasesIncludingPrereleases:(BOOL)includePrereleases;
- (void)cancelCurrentRequest;

// Synchronous methods for easier usage
+ (NSArray *)fetchReleasesFromRepository:(NSString *)owner name:(NSString *)name includePrereleases:(BOOL)includePrereleases;
+ (NSArray *)extractImageAssetsFromReleases:(NSArray *)releases includePrereleases:(BOOL)includePrereleases;
@end
