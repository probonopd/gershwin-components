//
// CLMGitHubAPI.h
// Create Live Media Assistant - GitHub API Client
//

#import <Foundation/Foundation.h>

@interface CLMRelease : NSObject
@property (nonatomic, retain) NSString *tagName;
@property (nonatomic, retain) NSString *name;
@property (nonatomic, retain) NSString *body;
@property (nonatomic, retain) NSString *htmlURL;
@property (nonatomic, retain) NSDate *updatedAt;
@property (nonatomic, assign) BOOL prerelease;
@property (nonatomic, retain) NSArray *assets;
@end

@interface CLMAsset : NSObject
@property (nonatomic, retain) NSString *name;
@property (nonatomic, retain) NSString *browserDownloadURL;
@property (nonatomic, assign) long long size;
@property (nonatomic, retain) NSDate *updatedAt;
@end

@interface CLMGitHubAPI : NSObject

+ (NSArray *)fetchReleasesFromRepository:(NSString *)repoURL includePrereleases:(BOOL)includePrereleases;
+ (NSArray *)extractISOAssetsFromReleases:(NSArray *)releases includePrereleases:(BOOL)includePrereleases;

@end
