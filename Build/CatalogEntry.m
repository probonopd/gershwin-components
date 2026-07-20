/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "CatalogEntry.h"

@implementation CatalogEntry

+ (NSArray *)loadCatalog
{
    NSBundle *bundle = [NSBundle mainBundle];
    NSString *catalogPath = [[bundle resourcePath] stringByAppendingPathComponent:@"Catalog.plist"];
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
