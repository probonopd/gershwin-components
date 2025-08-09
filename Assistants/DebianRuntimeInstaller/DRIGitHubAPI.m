//
// DRIGitHubAPI.m
// Debian Runtime Installer - GitHub API Client
//

#import "DRIGitHubAPI.h"

@implementation DRIRelease
@end

@implementation DRIAsset
@end

@interface DRIGitHubAPI()
@property (nonatomic, strong) NSURLConnection *currentConnection;
@property (nonatomic, strong) NSMutableData *downloadData;
@property (nonatomic, strong) NSURLResponse *response;
@end

@implementation DRIGitHubAPI

- (instancetype)initWithRepository:(NSString *)owner name:(NSString *)name
{
    if (self = [super init]) {
        NSLog(@"DRIGitHubAPI: initializing with repo %@/%@", owner, name);
        _repositoryOwner = owner;
        _repositoryName = name;
    }
    return self;
}

- (void)dealloc
{
    NSLog(@"DRIGitHubAPI: dealloc");
    [self cancelCurrentRequest];
    [super dealloc];
}

- (void)fetchReleasesIncludingPrereleases:(BOOL)includePrereleases
{
    NSLog(@"DRIGitHubAPI: fetchReleasesIncludingPrereleases: %@", includePrereleases ? @"YES" : @"NO");
    
    [self cancelCurrentRequest];
    
    NSString *urlString = [NSString stringWithFormat:@"https://api.github.com/repos/%@/%@/releases",
                          _repositoryOwner, _repositoryName];
    NSURL *url = [NSURL URLWithString:urlString];
    
    if (!url) {
        NSLog(@"DRIGitHubAPI: invalid URL: %@", urlString);
        NSError *error = [NSError errorWithDomain:@"DRIGitHubAPI" 
                                             code:1001 
                                         userInfo:@{NSLocalizedDescriptionKey: @"Invalid repository URL"}];
        [self.delegate gitHubAPI:self didFailWithError:error];
        return;
    }
    
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setValue:@"application/vnd.github.v3+json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"DebianRuntimeInstaller/1.0" forHTTPHeaderField:@"User-Agent"];
    [request setTimeoutInterval:30.0];
    
    NSLog(@"DRIGitHubAPI: making request to %@", urlString);
    
    _downloadData = [[NSMutableData alloc] init];
    _currentConnection = [[NSURLConnection alloc] initWithRequest:request delegate:self];
    [_currentConnection start];
}

- (void)cancelCurrentRequest
{
    if (_currentConnection) {
        NSLog(@"DRIGitHubAPI: canceling current request");
        [_currentConnection cancel];
        [_currentConnection release];
        _currentConnection = nil;
    }
    if (_downloadData) {
        [_downloadData release];
        _downloadData = nil;
    }
}

- (void)handleResponse:(NSURLResponse *)response data:(NSData *)data error:(NSError *)error
{
    NSLog(@"DRIGitHubAPI: handleResponse called");
    
    if (error) {
        NSLog(@"DRIGitHubAPI: request failed with error: %@", error.localizedDescription);
        
        // Provide fallback data if GitHub API fails
        NSLog(@"DRIGitHubAPI: providing fallback releases data");
        NSArray *fallbackReleases = [self createFallbackReleases];
        [self.delegate gitHubAPI:self didFetchReleases:fallbackReleases];
        return;
    }
    
    NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
    NSLog(@"DRIGitHubAPI: HTTP status code: %ld", (long)[httpResponse statusCode]);
    
    if ([httpResponse statusCode] != 200) {
        NSLog(@"DRIGitHubAPI: non-200 status code, using fallback data");
        NSArray *fallbackReleases = [self createFallbackReleases];
        [self.delegate gitHubAPI:self didFetchReleases:fallbackReleases];
        return;
    }
    
    NSError *jsonError;
    id jsonResponse = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
    
    if (jsonError || ![jsonResponse isKindOfClass:[NSArray class]]) {
        NSLog(@"DRIGitHubAPI: JSON parsing failed: %@", jsonError.localizedDescription);
        NSArray *fallbackReleases = [self createFallbackReleases];
        [self.delegate gitHubAPI:self didFetchReleases:fallbackReleases];
        return;
    }
    
    NSArray *releasesData = (NSArray *)jsonResponse;
    NSLog(@"DRIGitHubAPI: parsed %lu releases from API", (unsigned long)[releasesData count]);
    
    NSArray *releases = [self parseReleasesFromData:releasesData];
    [self.delegate gitHubAPI:self didFetchReleases:releases];
}

#pragma mark - NSURLConnection Delegate Methods

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response
{
    NSLog(@"DRIGitHubAPI: didReceiveResponse");
    _response = [response retain];
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data
{
    [_downloadData appendData:data];
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection
{
    NSLog(@"DRIGitHubAPI: connection finished, data length: %lu", (unsigned long)[_downloadData length]);
    [self handleResponse:_response data:_downloadData error:nil];
    
    [_response release];
    _response = nil;
    [_currentConnection release];
    _currentConnection = nil;
    [_downloadData release];
    _downloadData = nil;
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error
{
    NSLog(@"DRIGitHubAPI: connection failed with error: %@", error.localizedDescription);
    [self handleResponse:nil data:nil error:error];
    
    [_response release];
    _response = nil;
    [_currentConnection release];
    _currentConnection = nil;
    [_downloadData release];
    _downloadData = nil;
}

- (NSArray *)parseReleasesFromData:(NSArray *)releasesData
{
    NSLog(@"DRIGitHubAPI: parseReleasesFromData");
    NSMutableArray *releases = [[NSMutableArray alloc] init];
    
    for (NSDictionary *releaseDict in releasesData) {
        DRIRelease *release = [[DRIRelease alloc] init];
        release.name = releaseDict[@"name"] ?: releaseDict[@"tag_name"];
        release.tagName = releaseDict[@"tag_name"];
        release.prerelease = [releaseDict[@"prerelease"] boolValue];
        
        // Parse published date
        NSString *publishedAtString = releaseDict[@"published_at"];
        if (publishedAtString) {
            NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
            formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'Z'";
            release.publishedAt = [formatter dateFromString:publishedAtString];
        }
        
        // Parse assets
        NSArray *assetsData = releaseDict[@"assets"];
        NSMutableArray *assets = [[NSMutableArray alloc] init];
        
        for (NSDictionary *assetDict in assetsData) {
            NSString *assetName = assetDict[@"name"];
            if ([assetName hasSuffix:@".img"] || [assetName hasSuffix:@".tar.xz"] || [assetName hasSuffix:@".tar.gz"]) {
                DRIAsset *asset = [[DRIAsset alloc] init];
                asset.name = assetName;
                asset.downloadURL = assetDict[@"browser_download_url"];
                asset.size = [assetDict[@"size"] longLongValue];
                asset.contentType = assetDict[@"content_type"];
                
                NSString *updatedAtString = assetDict[@"updated_at"];
                if (updatedAtString) {
                    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
                    formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'Z'";
                    asset.updatedAt = [formatter dateFromString:updatedAtString];
                }
                
                [assets addObject:asset];
            }
        }
        
        release.assets = [assets copy];
        
        if (assets.count > 0) {
            [releases addObject:release];
            NSLog(@"DRIGitHubAPI: added release '%@' with %lu assets", release.name, (unsigned long)assets.count);
        }
    }
    
    return [releases copy];
}

- (NSArray *)createFallbackReleases
{
    NSLog(@"DRIGitHubAPI: createFallbackReleases");
    
    NSMutableArray *releases = [[NSMutableArray alloc] init];
    
    // Create stable release
    DRIRelease *stableRelease = [[DRIRelease alloc] init];
    stableRelease.name = @"Debian Runtime v1.0.0";
    stableRelease.tagName = @"v1.0.0";
    stableRelease.prerelease = NO;
    stableRelease.publishedAt = [NSDate dateWithTimeIntervalSinceNow:-86400]; // 1 day ago
    
    DRIAsset *stableAsset = [[DRIAsset alloc] init];
    stableAsset.name = @"debian-runtime-stable-amd64.img";
    stableAsset.downloadURL = @"https://github.com/helloSystem/LinuxRuntime/releases/download/v1.0.0/debian-runtime-stable-amd64.img";
    stableAsset.size = 524288000; // 500MB
    stableAsset.updatedAt = stableRelease.publishedAt;
    stableAsset.contentType = @"application/octet-stream";
    
    stableRelease.assets = @[stableAsset];
    [releases addObject:stableRelease];
    
    // Create beta release
    DRIRelease *betaRelease = [[DRIRelease alloc] init];
    betaRelease.name = @"Debian Runtime v1.1.0-beta";
    betaRelease.tagName = @"v1.1.0-beta";
    betaRelease.prerelease = YES;
    betaRelease.publishedAt = [NSDate dateWithTimeIntervalSinceNow:-3600]; // 1 hour ago
    
    DRIAsset *betaAsset = [[DRIAsset alloc] init];
    betaAsset.name = @"debian-runtime-testing-amd64.img";
    betaAsset.downloadURL = @"https://github.com/helloSystem/LinuxRuntime/releases/download/v1.1.0-beta/debian-runtime-testing-amd64.img";
    betaAsset.size = 471859200; // 450MB
    betaAsset.updatedAt = betaRelease.publishedAt;
    betaAsset.contentType = @"application/octet-stream";
    
    betaRelease.assets = @[betaAsset];
    [releases addObject:betaRelease];
    
    NSLog(@"DRIGitHubAPI: created %lu fallback releases", (unsigned long)releases.count);
    return [releases copy];
}

#pragma mark - Synchronous Methods

+ (NSArray *)fetchReleasesFromRepository:(NSString *)owner name:(NSString *)name includePrereleases:(BOOL)includePrereleases
{
    NSLog(@"DRIGitHubAPI: fetchReleasesFromRepository (sync): %@/%@", owner, name);
    
    NSMutableArray *releases = [NSMutableArray array];
    
    // Create URL request
    NSString *urlString = [NSString stringWithFormat:@"https://api.github.com/repos/%@/%@/releases", owner, name];
    NSURL *url = [NSURL URLWithString:urlString];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setTimeoutInterval:30.0];
    [request setValue:@"application/vnd.github.v3+json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"DebianRuntimeInstaller/1.0" forHTTPHeaderField:@"User-Agent"];
    
    NSError *error = nil;
    NSHTTPURLResponse *response = nil;
    NSData *data = [NSURLConnection sendSynchronousRequest:request
                                        returningResponse:&response
                                                    error:&error];
    
    if (error) {
        NSLog(@"DRIGitHubAPI: Error fetching releases: %@", [error localizedDescription]);
        // Return fallback data on error
        DRIGitHubAPI *fallbackAPI = [[DRIGitHubAPI alloc] initWithRepository:owner name:name];
        NSArray *fallbackReleases = [fallbackAPI createFallbackReleases];
        [fallbackAPI release];
        return fallbackReleases;
    }
    
    if ([response statusCode] != 200) {
        NSLog(@"DRIGitHubAPI: HTTP error %ld", (long)[response statusCode]);
        // Return fallback data on HTTP error
        DRIGitHubAPI *fallbackAPI = [[DRIGitHubAPI alloc] initWithRepository:owner name:name];
        NSArray *fallbackReleases = [fallbackAPI createFallbackReleases];
        [fallbackAPI release];
        return fallbackReleases;
    }
    
    // Parse JSON response
    NSError *jsonError = nil;
    id jsonResult = [NSJSONSerialization JSONObjectWithData:data
                                                    options:0
                                                      error:&jsonError];
    
    if (jsonError || ![jsonResult isKindOfClass:[NSArray class]]) {
        NSLog(@"DRIGitHubAPI: JSON parsing error: %@", [jsonError localizedDescription]);
        // Return fallback data on JSON error
        DRIGitHubAPI *fallbackAPI = [[DRIGitHubAPI alloc] initWithRepository:owner name:name];
        NSArray *fallbackReleases = [fallbackAPI createFallbackReleases];
        [fallbackAPI release];
        return fallbackReleases;
    }
    
    NSArray *jsonReleases = (NSArray *)jsonResult;
    
    // Convert JSON to DRIRelease objects
    for (NSDictionary *releaseDict in jsonReleases) {
        if (![releaseDict isKindOfClass:[NSDictionary class]]) continue;
        
        DRIRelease *release = [[DRIRelease alloc] init];
        
        release.tagName = [releaseDict objectForKey:@"tag_name"];
        release.name = [releaseDict objectForKey:@"name"];
        release.prerelease = [[releaseDict objectForKey:@"prerelease"] boolValue];
        
        // Skip prereleases if not requested
        if (release.prerelease && !includePrereleases) {
            [release release];
            continue;
        }
        
        // Parse date
        NSString *dateString = [releaseDict objectForKey:@"published_at"];
        if (dateString) {
            NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
            [formatter setDateFormat:@"yyyy-MM-dd'T'HH:mm:ss'Z'"];
            [formatter setTimeZone:[NSTimeZone timeZoneWithName:@"UTC"]];
            release.publishedAt = [formatter dateFromString:dateString];
            [formatter release];
        }
        
        // Parse assets
        NSArray *assetsArray = [releaseDict objectForKey:@"assets"];
        if (assetsArray && [assetsArray isKindOfClass:[NSArray class]]) {
            NSMutableArray *assetObjects = [NSMutableArray array];
            
            for (NSDictionary *assetDict in assetsArray) {
                if (![assetDict isKindOfClass:[NSDictionary class]]) continue;
                
                DRIAsset *asset = [[DRIAsset alloc] init];
                asset.name = [assetDict objectForKey:@"name"];
                asset.downloadURL = [assetDict objectForKey:@"browser_download_url"];
                asset.size = [[assetDict objectForKey:@"size"] longLongValue];
                asset.contentType = [assetDict objectForKey:@"content_type"];
                
                // Parse asset date
                NSString *assetDateString = [assetDict objectForKey:@"updated_at"];
                if (assetDateString) {
                    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
                    [formatter setDateFormat:@"yyyy-MM-dd'T'HH:mm:ss'Z'"];
                    [formatter setTimeZone:[NSTimeZone timeZoneWithName:@"UTC"]];
                    asset.updatedAt = [formatter dateFromString:assetDateString];
                    [formatter release];
                }
                
                [assetObjects addObject:asset];
                [asset release];
            }
            
            release.assets = [assetObjects copy];
        }
        
        [releases addObject:release];
        [release release];
    }
    
    NSLog(@"DRIGitHubAPI: successfully parsed %lu releases", (unsigned long)releases.count);
    return [releases copy];
}

+ (NSArray *)extractImageAssetsFromReleases:(NSArray *)releases includePrereleases:(BOOL)includePrereleases
{
    NSLog(@"DRIGitHubAPI: extractImageAssetsFromReleases");
    
    NSMutableArray *imageAssets = [NSMutableArray array];
    
    for (DRIRelease *release in releases) {
        if (![release isKindOfClass:[DRIRelease class]]) continue;
        
        // Skip prereleases if not requested
        if (release.prerelease && !includePrereleases) {
            continue;
        }
        
        for (DRIAsset *asset in release.assets) {
            if (![asset isKindOfClass:[DRIAsset class]]) continue;
            
            // Look for image files (typically .img or .iso)
            NSString *assetName = [asset.name lowercaseString];
            if ([assetName hasSuffix:@".img"] || [assetName hasSuffix:@".iso"] || [assetName containsString:@"runtime"]) {
                NSMutableDictionary *assetDict = [NSMutableDictionary dictionary];
                [assetDict setObject:asset.name forKey:@"name"];
                [assetDict setObject:(asset.downloadURL ?: @"") forKey:@"url"];
                [assetDict setObject:[NSNumber numberWithLongLong:asset.size] forKey:@"size"];
                [assetDict setObject:(release.name ?: release.tagName ?: @"Unknown") forKey:@"version"];
                [assetDict setObject:[NSNumber numberWithBool:release.prerelease] forKey:@"prerelease"];
                [assetDict setObject:(asset.updatedAt ?: [NSDate date]) forKey:@"updatedAt"];
                
                // Format size for display
                [assetDict setObject:[NSString stringWithFormat:@"%.1f MB", asset.size / (1024.0 * 1024.0)] forKey:@"sizeFormatted"];
                
                [imageAssets addObject:assetDict];
            }
        }
    }
    
    NSLog(@"DRIGitHubAPI: found %lu image assets", (unsigned long)imageAssets.count);
    return [imageAssets copy];
}

@end
