/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "CatalogEntry.h"

@implementation CatalogEntry

+ (NSString *)remoteCatalogURLString
{
    return @"https://raw.githubusercontent.com/gershwin-desktop/gershwin-components/refs/heads/dev/Build/Resources/Catalog.plist";
}

/* Path to the cached catalog in the user Caches directory, creating the
   app-specific subdirectory if needed. Returns nil if Caches is unavailable. */
+ (NSString *)catalogCachePath
{
    NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSCachesDirectory,
                                                        NSUserDomainMask, YES);
    if ([dirs count] == 0) return nil;
    NSString *cacheDir = [dirs objectAtIndex:0];
    NSString *appDir = [cacheDir stringByAppendingPathComponent:
                        [[NSBundle mainBundle] bundleIdentifier]];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:appDir]) {
        [fm createDirectoryAtPath:appDir
          withIntermediateDirectories:YES
                           attributes:nil
                                error:NULL];
    }
    return [appDir stringByAppendingPathComponent:@"Catalog.plist"];
}

/* The catalog is never bundled; it is always fetched from the server into
   Caches. Return the Caches path (which may not exist yet on a fresh run);
   the loader tolerates a missing file by yielding an empty list until the
   first fetch completes. */
+ (NSString *)localCatalogPath
{
    return [self catalogCachePath];
}

+ (NSArray *)loadCatalog
{
    return [self loadCatalogFromPath:[self localCatalogPath]];
}

+ (NSArray *)loadCatalogFromPath:(NSString *)catalogPath
{
    NSArray *entries = [NSArray arrayWithContentsOfFile:catalogPath];
    if (!entries) return @[];

    NSMutableArray *result = [NSMutableArray array];
    for (id item in entries) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        NSString *name = [item objectForKey:@"Name"];
        NSString *gitURL = [item objectForKey:@"GitURL"];
        if (!name || [name length] == 0 || !gitURL || [gitURL length] == 0) continue;

        CatalogEntry *entry = [[CatalogEntry alloc] init];
        entry.name = name;
        entry.gitURL = gitURL;
        entry.desc = [item objectForKey:@"Description"];
        entry.makefilePath = [item objectForKey:@"MakefilePath"];
        [result addObject:entry];
    }

    [result sortUsingComparator:^NSComparisonResult(CatalogEntry *a, CatalogEntry *b) {
        return [a.name localizedCaseInsensitiveCompare:b.name];
    }];

    return result;
}

@end
