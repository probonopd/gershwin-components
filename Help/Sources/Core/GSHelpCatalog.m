/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "GSHelpCatalog.h"
#import "GSHelpAppScanner.h"
#import "GSHelpManLocator.h"

@implementation GSHelpCatalogItem
{
    NSString *_title;
    NSURL *_url;
    NSArray<GSHelpCatalogItem *> *_children;
}

- (instancetype)initWithTitle:(NSString *)title
                          url:(NSURL *)url
                     children:(NSArray<GSHelpCatalogItem *> *)children
{
    self = [super init];
    if (self != nil)
      {
        _title = [title copy];
        _url = url;
        _children = children ?: @[];
      }
    return self;
}

- (NSString *)title
{
    return _title;
}

- (NSURL *)url
{
    return _url;
}

- (NSArray<GSHelpCatalogItem *> *)children
{
    return _children;
}
@end

@implementation GSHelpCatalog


+ (NSArray<NSString *> *)appBundlesInRoot:(NSString *)root
{
    NSMutableArray<NSString *> *apps = [NSMutableArray new];
    for (NSString *name in [[NSFileManager defaultManager]
             contentsOfDirectoryAtPath: root error: NULL])
      {
        if ([name hasSuffix: @".app"])
          {
            [apps addObject: [root stringByAppendingPathComponent: name]];
          }
      }
    return apps;
}

/* "ls.1.gz" -> ("ls", "1"); returns nil for non-page names. */
+ (NSDictionary *)manPageNameAndSection:(NSString *)fileName
{
    static NSRegularExpression *regex = nil;
    if (regex == nil)
      {
        regex = [NSRegularExpression
            regularExpressionWithPattern:
                @"^(.+)\\.([0-9][A-Za-z0-9]*)(\\.(gz|bz2|xz|Z))?$"
                                 options: 0
                                   error: NULL];
      }
    NSTextCheckingResult *match =
        [regex firstMatchInString: fileName
                          options: 0
                            range: NSMakeRange(0, [fileName length])];
    if (match == nil)
      {
        return nil;
      }
    return @{
        @"name": [fileName substringWithRange: [match rangeAtIndex: 1]],
        @"section": [fileName substringWithRange: [match rangeAtIndex: 2]],
    };
}

+ (NSArray<GSHelpCatalogItem *> *)catalogItemsWithAppRoots:
                                     (NSArray<NSString *> *)appRoots
                                            manRoots:
                                                (NSArray<NSString *> *)manRoots
                                           fileRoots:
                                               (NSArray<NSString *> *)fileRoots
{
    NSMutableArray<GSHelpCatalogItem *> *items = [NSMutableArray new];

    /* --- Application help bundles --- */
    NSMutableArray<GSHelpCatalogItem *> *appItems = [NSMutableArray new];
    for (NSString *root in appRoots)
      {
        for (NSString *app in [self appBundlesInRoot: root])
          {
            NSError *error = nil;
            GSHelpAppScan *scan = [GSHelpAppScanner
                scanApplicationHelpAtPath: app error: &error];
            if (scan == nil || [scan entryURL] == nil)
              {
                continue;
              }
            NSString *name = [[[app lastPathComponent]
                stringByDeletingPathExtension] copy];
            /* Prefer the bundle display name from the manifest. */
            NSDictionary *manifest = [NSDictionary dictionaryWithContentsOfFile:
                [[scan helpDirectory] stringByAppendingPathComponent:
                                       @"Help.plist"]];
            if ([[manifest objectForKey: @"Title"] length] > 0)
              {
                name = [manifest objectForKey: @"Title"];
              }
            NSMutableArray<GSHelpCatalogItem *> *docItems =
                [NSMutableArray new];
            if ([scan entryURL] != nil)
              {
                [docItems addObject: [[GSHelpCatalogItem alloc]
                    initWithTitle: @"Overview"
                              url: [scan entryURL]
                         children: nil]];
              }
            for (NSDictionary *entry in [scan items])
              {
                [docItems addObject: [[GSHelpCatalogItem alloc]
                    initWithTitle: entry[@"Title"]
                              url: entry[@"FileURL"]
                         children: nil]];
              }
            [appItems addObject: [[GSHelpCatalogItem alloc]
                initWithTitle: name
                          url: [scan entryURL]
                     children: docItems]];
          }
      }

    /* --- Man pages, grouped by section --- */
    NSMutableDictionary<NSString *,
                        NSMutableArray<NSDictionary *> *> *bySection =
        [NSMutableDictionary new];
    void (^ScanManDir)(NSString *, NSString *) =
        ^(NSString *root, NSString *dirName) {
          NSString *dir =
              [root stringByAppendingPathComponent: dirName];
          NSArray *pageNames =
              [[NSFileManager defaultManager]
                  contentsOfDirectoryAtPath: dir error: NULL];
          /* Deterministic order regardless of filesystem. */
          pageNames = [pageNames sortedArrayUsingSelector:
                                 @selector(compare:)];
          for (NSString *page in pageNames)
            {
              NSDictionary *parsed = [self manPageNameAndSection: page];
              if (parsed == nil)
                {
                  continue;
                }
              NSString *key = parsed[@"section"];
              if (bySection[key] == nil)
                {
                  bySection[key] = [NSMutableArray new];
                }
              [bySection[key] addObject: @{
                @"name": parsed[@"name"],
                @"section": key,
                @"path": [dir stringByAppendingPathComponent: page],
              }];
            }
        };
    for (NSString *root in manRoots)
      {
        NSArray *entries = [[NSFileManager defaultManager]
            contentsOfDirectoryAtPath: root error: NULL];
        entries = [entries sortedArrayUsingSelector: @selector(compare:)];

        /* Unlocalized trees first so their pages win the dedupe;
         * some layouts nest manN under per-locale directories
         * (/usr/share/man/en/man1). */
        for (NSString *dirName in entries)
          {
            if ([dirName hasPrefix: @"man"]
                  && ![dirName isEqualToString: @"man"])
              {
                ScanManDir(root, dirName);
              }
          }
        for (NSString *dirName in entries)
          {
            NSString *path =
                [root stringByAppendingPathComponent: dirName];
            BOOL isDirectory = NO;
            [[NSFileManager defaultManager] fileExistsAtPath: path
                                                 isDirectory:
                                                     &isDirectory];
            if (!isDirectory || ([dirName hasPrefix: @"man"]
                                   && ![dirName isEqualToString: @"man"]))
              {
                continue;
              }
            for (NSString *nested in [[NSFileManager defaultManager]
                          contentsOfDirectoryAtPath: path error: NULL])
              {
                if ([nested hasPrefix: @"man"]
                      && ![nested isEqualToString: @"man"])
                  {
                    ScanManDir(path, nested);
                  }
              }
          }
      }

    NSMutableArray<GSHelpCatalogItem *> *sectionItems = [NSMutableArray new];
    NSArray *sections =
        [bySection.allKeys sortedArrayUsingComparator:
                               ^NSComparisonResult(NSString *a, NSString *b) {
      NSInteger na = [a integerValue], nb = [b integerValue];
      if (na != nb)
        {
          return na < nb ? NSOrderedAscending : NSOrderedDescending;
        }
      return [a compare: b options: NSNumericSearch];
    }];
    for (NSString *section in sections)
      {
        NSMutableArray<GSHelpCatalogItem *> *pages = [NSMutableArray new];
        NSMutableSet *seen = [NSMutableSet new];
        /* Pages arrive in scan order; sort by command name so the
         * sidebar is stable and predictable. */
        NSArray *sorted = [bySection[section]
            sortedArrayUsingComparator:^NSComparisonResult(
                                         NSDictionary *a, NSDictionary *b) {
              return [a[@"name"] compare: b[@"name"]];
            }];
        for (NSDictionary *page in sorted)
          {
            NSString *name = page[@"name"];
            if ([seen containsObject: name])
              {
                continue;
              }
            [seen addObject: name];
            [pages addObject: [[GSHelpCatalogItem alloc]
                initWithTitle: [NSString stringWithFormat:
                                       @"%@(%@)", name, section]
                          url: [NSURL fileURLWithPath: page[@"path"]]
                     children: nil]];
          }
        [sectionItems addObject: [[GSHelpCatalogItem alloc]
            initWithTitle:
                [@"Section " stringByAppendingString: section]
                      url: nil
                 children: pages]];
      }

    /* --- Markdown files under the documentation roots --- */
    NSMutableArray<GSHelpCatalogItem *> *mdItems = [NSMutableArray new];
    for (NSString *root in fileRoots)
      {
        NSDirectoryEnumerator *enumerator =
            [[NSFileManager defaultManager]
                enumeratorAtURL: [NSURL fileURLWithPath: root]
     includingPropertiesForKeys: @[ NSURLIsRegularFileKey ]
                        options: NSDirectoryEnumerationSkipsPackageDescendants
                   errorHandler: ^BOOL(NSURL *url, NSError *error) {
                     (void)url;
                     (void)error;
                     /* Skip unreadable subtrees, keep walking. */
                     return YES;
                   }];
        for (NSURL *url in enumerator)
          {
            NSString *name = [url lastPathComponent];
            if ([name hasSuffix: @".md"] || [name hasSuffix: @".markdown"])
              {
                NSString *base =
                    [name stringByDeletingPathExtension];
                [mdItems addObject: [[GSHelpCatalogItem alloc]
                    initWithTitle: base
                              url: url
                         children: nil]];
              }
          }
      }

    if ([appItems count] > 0)
      {
        [items addObject: [[GSHelpCatalogItem alloc]
            initWithTitle: @"Applications"
                      url: nil
                 children: appItems]];
      }
    if ([sectionItems count] > 0)
      {
        [items addObject: [[GSHelpCatalogItem alloc]
            initWithTitle: @"Commands"
                      url: nil
                 children: sectionItems]];
      }
    if ([mdItems count] > 0)
      {
        [items addObject: [[GSHelpCatalogItem alloc]
            initWithTitle: @"System Documentation"
                      url: nil
                 children: mdItems]];
      }
    return items;
}

+ (NSArray<GSHelpCatalogItem *> *)systemCatalogItems
{
    NSMutableArray<NSString *> *appRoots =
        [@[
            @"/System/Applications",
            @"/System/Library/CoreServices/Applications",
            @"/usr/GNUstep/System/Applications",
        ] mutableCopy];
    NSString *localApps = @"/Local/Applications";
    if ([[NSFileManager defaultManager] fileExistsAtPath: localApps])
      {
        [appRoots addObject: localApps];
      }
    NSMutableArray *items =
        [[self catalogItemsWithAppRoots: appRoots
                               manRoots:
                                   [GSHelpManLocator defaultSearchPaths]
                              fileRoots:
                                  @[ @"/System/Library/Documentation" ]]
            mutableCopy];

    /* Framework reference (*.gsdoc) lives under
     * Library/Documentation/Developer in every domain. */
    NSArray *libraryDirs = NSSearchPathForDirectoriesInDomains(
        NSLibraryDirectory,
        NSSystemDomainMask | NSNetworkDomainMask | NSLocalDomainMask
                                   | NSUserDomainMask,
        YES);
    /* Returned least specific first; reverse so System precedes
     * Local/User and keeps its copy of duplicated docs. */
    NSMutableArray<NSString *> *developerRoots = [NSMutableArray new];
    for (NSString *library in [libraryDirs reverseObjectEnumerator])
      {
        [developerRoots addObject:
            [library stringByAppendingPathComponent:
                          @"Documentation/Developer"]];
      }
    [items addObjectsFromArray:
               [self developerDocItemsWithRoots: developerRoots]];
    return items;
}

#pragma mark GSdoc developer documentation

/* Depth-first walk gathering every *.gsdoc below dir as
 * { @"rel": path relative to the scan root, @"abs": real path }. */
+ (void)collectGSdocFilesInDir:(NSString *)dir
                    relativeTo:(NSString *)relative
                          into:(NSMutableArray<NSDictionary *> *)result
{
    NSArray *entries = [[NSFileManager defaultManager]
        contentsOfDirectoryAtPath: dir error: NULL];
    entries = [entries sortedArrayUsingSelector: @selector(compare:)];
    for (NSString *name in entries)
      {
        NSString *path = [dir stringByAppendingPathComponent: name];
        NSString *rel = [relative length] > 0
            ? [relative stringByAppendingPathComponent: name] : name;
        BOOL isDirectory = NO;
        [[NSFileManager defaultManager] fileExistsAtPath: path
                                              isDirectory: &isDirectory];
        if (isDirectory)
          {
            [self collectGSdocFilesInDir: path
                              relativeTo: rel
                                    into: result];
          }
        else if ([name hasSuffix: @".gsdoc"])
          {
            [result addObject: @{ @"rel": rel, @"abs": path }];
          }
      }
}

/* Turns relative paths into one sorted level of sidebar rows: a
 * single component is a leaf, deeper paths group under their first
 * component and recurse with it stripped. */
+ (NSArray<GSHelpCatalogItem *> *)gsdocItemsForRelPaths:
    (NSArray<NSDictionary *> *)entries
{
    NSMutableArray<GSHelpCatalogItem *> *items = [NSMutableArray new];
    NSMutableArray<NSString *> *groupNames = [NSMutableArray new];
    NSMutableDictionary<NSString *,
                        NSMutableArray<NSDictionary *> *> *groups =
        [NSMutableDictionary new];

    for (NSDictionary *entry in entries)
      {
        NSArray *components =
            [entry[@"rel"] pathComponents];
        if ([components count] == 1)
          {
            NSString *file = components[0];
            [items addObject: [[GSHelpCatalogItem alloc]
                initWithTitle: [file stringByDeletingPathExtension]
                          url: [NSURL fileURLWithPath: entry[@"abs"]]
                     children: nil]];
            continue;
          }
        NSString *groupName = components[0];
        if (groups[groupName] == nil)
          {
            groups[groupName] = [NSMutableArray new];
            [groupNames addObject: groupName];
          }
        NSArray *rest =
            [components subarrayWithRange:
                            NSMakeRange(1, [components count] - 1)];
        [groups[groupName] addObject: @{
            @"rel": [rest componentsJoinedByString: @"/"],
            @"abs": entry[@"abs"],
        }];
      }

    for (NSString *groupName in [groupNames sortedArrayUsingSelector:
                                          @selector(compare:)])
      {
        [items addObject: [[GSHelpCatalogItem alloc]
            initWithTitle: groupName
                      url: nil
                 children: [self gsdocItemsForRelPaths:
                                     groups[groupName]]]];
      }

    return [items sortedArrayUsingComparator:
                   ^NSComparisonResult(GSHelpCatalogItem *a,
                                       GSHelpCatalogItem *b) {
                     return [[a title] compare: [b title]];
                   }];
}

+ (NSArray<GSHelpCatalogItem *> *)developerDocItemsWithRoots:
    (NSArray<NSString *> *)roots
{
    /* Roots arrive most significant first, so an identical relative
     * path in several domains keeps its first copy. */
    NSMutableArray<NSDictionary *> *collected = [NSMutableArray new];
    NSMutableSet<NSString *> *seen = [NSMutableSet new];
    for (NSString *root in roots)
      {
        NSMutableArray<NSDictionary *> *found = [NSMutableArray new];
        [self collectGSdocFilesInDir: root
                          relativeTo: @""
                                into: found];
        for (NSDictionary *entry in found)
          {
            if ([seen containsObject: entry[@"rel"]])
              {
                continue;
              }
            [seen addObject: entry[@"rel"]];
            [collected addObject: entry];
          }
      }
    if ([collected count] == 0)
      {
        return @[];
      }

    GSHelpCatalogItem *group = [[GSHelpCatalogItem alloc]
        initWithTitle: @"Developer Documentation"
                  url: nil
             children: [self gsdocItemsForRelPaths: collected]];
    return @[ group ];
}


@end
