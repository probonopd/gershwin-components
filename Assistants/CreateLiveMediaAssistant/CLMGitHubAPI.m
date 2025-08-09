//
// CLMGitHubAPI.m
// Create Live Media Assistant - GitHub API Client
//

#import "CLMGitHubAPI.h"

@implementation CLMRelease

@synthesize tagName, name, body, htmlURL, updatedAt, prerelease, assets;

- (void)dealloc
{
    [tagName release];
    [name release];
    [body release];
    [htmlURL release];
    [updatedAt release];
    [assets release];
    [super dealloc];
}

@end

@implementation CLMAsset

@synthesize name, browserDownloadURL, size, updatedAt;

- (void)dealloc
{
    [name release];
    [browserDownloadURL release];
    [updatedAt release];
    [super dealloc];
}

@end

@implementation CLMGitHubAPI

+ (NSArray *)fetchReleasesFromRepository:(NSString *)repoURL includePrereleases:(BOOL)includePrereleases
{
    NSLog(@"CLMGitHubAPI: fetchReleasesFromRepository: %@", repoURL);
    
    NSMutableArray *releases = [NSMutableArray array];
    
    // Create URL request
    NSURL *url = [NSURL URLWithString:repoURL];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setValue:@"application/vnd.github.v3+json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"CreateLiveMediaAssistant/1.0" forHTTPHeaderField:@"User-Agent"];
    [request setTimeoutInterval:30.0];
    
    // Perform synchronous request
    NSHTTPURLResponse *response = nil;
    NSError *connectionError = nil;
    NSData *data = [NSURLConnection sendSynchronousRequest:request
                                         returningResponse:&response
                                                     error:&connectionError];
    
    if (connectionError) {
        NSLog(@"CLMGitHubAPI: Connection error: %@", [connectionError localizedDescription]);
        return releases;
    }
    
    if (!data || [data length] == 0) {
        NSLog(@"CLMGitHubAPI: No data received");
        return releases;
    }
    
    NSInteger statusCode = [response statusCode];
    if (statusCode != 200) {
        NSLog(@"CLMGitHubAPI: HTTP error %ld", (long)statusCode);
        return releases;
    }
    
    // Parse JSON response
    NSError *jsonError = nil;
    id jsonResult = [NSJSONSerialization JSONObjectWithData:data
                                                    options:0
                                                      error:&jsonError];
    
    if (jsonError || ![jsonResult isKindOfClass:[NSArray class]]) {
        NSLog(@"CLMGitHubAPI: JSON parsing error: %@", [jsonError localizedDescription]);
        return releases;
    }
    
    NSArray *jsonReleases = (NSArray *)jsonResult;
    
    // Convert JSON to CLMRelease objects
    for (NSDictionary *releaseDict in jsonReleases) {
        if (![releaseDict isKindOfClass:[NSDictionary class]]) continue;
        
        CLMRelease *release = [[CLMRelease alloc] init];
        
        release.tagName = [releaseDict objectForKey:@"tag_name"];
        release.name = [releaseDict objectForKey:@"name"];
        release.body = [releaseDict objectForKey:@"body"];
        release.htmlURL = [releaseDict objectForKey:@"html_url"];
        release.prerelease = [[releaseDict objectForKey:@"prerelease"] boolValue];
        
        // Parse date
        NSString *dateString = [releaseDict objectForKey:@"published_at"];
        if (dateString) {
            NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
            [formatter setDateFormat:@"yyyy-MM-dd'T'HH:mm:ss'Z'"];
            [formatter setTimeZone:[NSTimeZone timeZoneWithName:@"UTC"]];
            release.updatedAt = [formatter dateFromString:dateString];
            [formatter release];
        }
        
        // Parse assets
        NSArray *assetsArray = [releaseDict objectForKey:@"assets"];
        if (assetsArray && [assetsArray isKindOfClass:[NSArray class]]) {
            NSMutableArray *assetObjects = [NSMutableArray array];
            
            for (NSDictionary *assetDict in assetsArray) {
                if (![assetDict isKindOfClass:[NSDictionary class]]) continue;
                
                CLMAsset *asset = [[CLMAsset alloc] init];
                asset.name = [assetDict objectForKey:@"name"];
                asset.browserDownloadURL = [assetDict objectForKey:@"browser_download_url"];
                asset.size = [[assetDict objectForKey:@"size"] longLongValue];
                
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
            
            release.assets = assetObjects;
        }
        
        // Filter by prerelease preference
        if (!release.prerelease || includePrereleases) {
            [releases addObject:release];
        }
        
        [release release];
    }
    
    NSLog(@"CLMGitHubAPI: Fetched %lu releases", (unsigned long)[releases count]);
    return releases;
}

+ (NSArray *)extractISOAssetsFromReleases:(NSArray *)releases includePrereleases:(BOOL)includePrereleases
{
    NSLog(@"CLMGitHubAPI: extractISOAssetsFromReleases");
    
    NSMutableArray *isoAssets = [NSMutableArray array];
    
    for (CLMRelease *release in releases) {
        if (!includePrereleases && release.prerelease) continue;
        
        // Skip prereleases older than 6 months
        if (release.prerelease && release.updatedAt) {
            NSTimeInterval sixMonthsAgo = -6 * 30 * 24 * 60 * 60; // Approximate 6 months in seconds
            NSDate *cutoffDate = [NSDate dateWithTimeIntervalSinceNow:sixMonthsAgo];
            if ([release.updatedAt compare:cutoffDate] == NSOrderedAscending) {
                continue;
            }
        }
        
        for (CLMAsset *asset in release.assets) {
            if ([asset.browserDownloadURL hasSuffix:@".iso"]) {
                // Create a composite object with both release and asset info
                NSMutableDictionary *assetInfo = [NSMutableDictionary dictionary];
                [assetInfo setObject:asset.name forKey:@"name"];
                [assetInfo setObject:asset.browserDownloadURL forKey:@"url"];
                [assetInfo setObject:[NSNumber numberWithLongLong:asset.size] forKey:@"size"];
                [assetInfo setObject:release.tagName forKey:@"version"];
                [assetInfo setObject:release.htmlURL forKey:@"htmlURL"];
                [assetInfo setObject:[NSNumber numberWithBool:release.prerelease] forKey:@"prerelease"];
                
                if (asset.updatedAt) {
                    [assetInfo setObject:asset.updatedAt forKey:@"updatedAt"];
                }
                if (release.body) {
                    [assetInfo setObject:release.body forKey:@"description"];
                }
                
                [isoAssets addObject:assetInfo];
            }
        }
    }
    
    NSLog(@"CLMGitHubAPI: Found %lu ISO assets", (unsigned long)[isoAssets count]);
    return isoAssets;
}

@end
