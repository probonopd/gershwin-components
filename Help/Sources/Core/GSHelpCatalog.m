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

/* Canonical man section names (man-pages(7)); a trailing p marks
 * the POSIX variant of the base section. Unknown sections keep
 * their raw label. */
+ (NSString *)displayNameForManSection:(NSString *)section
{
    static NSDictionary<NSString *, NSString *> *names = nil;
    if (names == nil)
      {
        names = @{
            @"1": @"User Commands",
            @"2": @"System Calls",
            @"3": @"Library Functions",
            @"4": @"Special Files",
            @"5": @"File Formats",
            @"6": @"Games",
            @"7": @"Miscellaneous",
            @"8": @"System Administration",
            @"9": @"Kernel Routines",
        };
      }
    NSString *base = section;
    NSString *suffix = @"";
    if ([section length] > 1)
      {
        base = [section substringToIndex: 1];
        NSString *rest = [section substringFromIndex: 1];
        if ([rest isEqualToString: @"p"])
          {
            suffix = @" (POSIX)";
          }
        else if ([rest length] > 0)
          {
            suffix = [NSString stringWithFormat: @" (%@)", rest];
          }
      }
    NSString *name = names[base];
    if (name == nil)
      {
        return [@"Section " stringByAppendingString: section];
      }
    return [NSString stringWithFormat:
                     @"Section %@: %@%@", section, name, suffix];
}

+ (NSArray<GSHelpCatalogItem *> *)catalogItemsWithAppRoots:
                                     (NSArray<NSString *> *)appRoots
                                            manRoots:
                                                (NSArray<NSString *> *)manRoots
                                           fileRoots:
                                               (NSArray<NSString *> *)fileRoots
                                       developerRoots:
                                           (NSArray<NSString *> *)developerRoots
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
                [self displayNameForManSection: section]
                      url: nil
                 children: pages]];
      }

    /* --- Welcome: pinned landing page, leads the sidebar --- */
    GSHelpCatalogItem *welcomeGroup = [[GSHelpCatalogItem alloc]
        initWithTitle: @"Welcome"
                  url: nil
             children: @[ [[GSHelpCatalogItem alloc]
                 initWithTitle: @"Welcome"
                           url: [NSURL URLWithString: @"help://welcome"]
                      children: nil] ]];
    [items addObject: welcomeGroup];

    /* --- Documentation: merged markdown + gsdoc tree --- */
    GSHelpCatalogItem *docGroup =
        [self documentationGroupWithFileRoots: fileRoots
                              developerRoots: developerRoots];
    if (docGroup != nil)
      {
        [items addObject: docGroup];
      }

    if ([appItems count] > 0)
      {
        [items addObject: [[GSHelpCatalogItem alloc]
            initWithTitle: @"Applications"
                      url: nil
                 children: appItems]];
      }

    /* --- Manual Pages: trails the list so a huge man tree never
     * pushes Documentation out of easy reach --- */
    if ([sectionItems count] > 0)
      {
        [items addObject: [[GSHelpCatalogItem alloc]
            initWithTitle: @"Manual Pages"
                      url: nil
                 children: sectionItems]];
      }
    return items;
}

/* Builds the merged Documentation group: markdown trees (fileRoots) and
 * gsdoc trees (developerRoots) share one sidebar section, gsdoc under a
 * "Frameworks" subgroup; a "Getting Started" leaf is pinned first. Returns
 * nil when nothing was found. */
+ (GSHelpCatalogItem *)documentationGroupWithFileRoots:(NSArray *)fileRoots
                                        developerRoots:(NSArray *)developerRoots
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSDictionary *> *mdEntries = [NSMutableArray new];
    NSMutableArray<NSDictionary *> *gsdocEntries = [NSMutableArray new];

    /* fileRoots contribute markdown only. GNUstep's
     * -enumeratorAtURL: returns item URLs rooted at the current
     * working directory rather than the supplied root, so enumerate
     * by path and rebuild absolute paths from the known root. */
    for (NSString *root in fileRoots)
      {
        NSString *rootPath = [root stringByStandardizingPath];
        NSDirectoryEnumerator *enumerator =
            [fm enumeratorAtPath: rootPath];
        for (NSString *relPath in enumerator)
          {
            NSString *name = [relPath lastPathComponent];
            if ([name hasSuffix: @".md"] || [name hasSuffix: @".markdown"])
              {
                [mdEntries addObject: @{
                  @"rel": relPath,
                  @"abs": [rootPath stringByAppendingPathComponent: relPath]
                }];
              }
          }
      }

    /* developerRoots contribute both gsdoc and markdown. */
    for (NSString *root in developerRoots)
      {
        NSMutableArray<NSDictionary *> *found = [NSMutableArray new];
        [self collectGSdocFilesInDir: root into: found];
        for (NSDictionary *entry in found)
          {
            NSString *ext =
                [[entry[@"abs"] pathExtension] lowercaseString];
            if ([ext isEqualToString: @"gsdoc"])
              {
                [gsdocEntries addObject: entry];
              }
            else if ([ext isEqualToString: @"md"]
                       || [ext isEqualToString: @"markdown"])
              {
                [mdEntries addObject: entry];
              }
          }
      }

    /* Dedupe by relative path across all roots so overlapping sweeps
     * (e.g. /Developer contains /Developer/Library/Sources) and domain
     * mirrors keep their first copy, never the absolute path: the same
     * file can legitimately live under two roots. */
    NSMutableArray<NSDictionary *> *mdDedup = [NSMutableArray new];
    NSMutableSet<NSString *> *seenMd = [NSMutableSet new];
    for (NSDictionary *entry in mdEntries)
      {
        if ([seenMd containsObject: entry[@"rel"]])
          {
            continue;
          }
        [seenMd addObject: entry[@"rel"]];
        [mdDedup addObject: entry];
      }
    NSMutableArray<NSDictionary *> *gsDedup = [NSMutableArray new];
    NSMutableSet<NSString *> *seenGs = [NSMutableSet new];
    for (NSDictionary *entry in gsdocEntries)
      {
        if ([seenGs containsObject: entry[@"rel"]])
          {
            continue;
          }
        [seenGs addObject: entry[@"rel"]];
        [gsDedup addObject: entry];
      }

    /* No documentation at all: omit the group entirely. */
    if ([mdDedup count] == 0 && [gsDedup count] == 0)
      {
        return nil;
      }

    NSMutableArray<GSHelpCatalogItem *> *children = [NSMutableArray new];
    [children addObjectsFromArray: [self gsdocItemsForRelPaths: mdDedup]];

    if ([gsDedup count] > 0)
      {
        NSArray<GSHelpCatalogItem *> *fwItems =
            [self gsdocItemsForRelPaths: gsDedup];
        [children addObject: [[GSHelpCatalogItem alloc]
            initWithTitle: @"Frameworks"
                      url: nil
                 children: fwItems]];
      }

    return [[GSHelpCatalogItem alloc]
        initWithTitle: @"Documentation"
                  url: nil
             children: children];
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
    /* Source trees document themselves with *.gsdoc next to the
     * code they describe (libs-base/Tools/HTMLLinker.gsdoc and
     * friends); the tree mirrors <project>/<subdir>/<file>. */
    NSString *sourcesRoot = @"/Developer/Library/Sources";
    if ([[NSFileManager defaultManager] fileExistsAtPath: sourcesRoot])
      {
        [developerRoots addObject: sourcesRoot];
      }
    /* Whole-tree sweeps for markdown documentation ship with sources and
     * system components alike; appended last so the narrower roots keep
     * their shorter, project-rooted relative paths. */
    if ([[NSFileManager defaultManager] fileExistsAtPath:
            @"/Developer"])
      {
        [developerRoots addObject: @"/Developer"];
      }
    if ([[NSFileManager defaultManager] fileExistsAtPath: @"/System"])
      {
        [developerRoots addObject: @"/System"];
      }

    return [self catalogItemsWithAppRoots: appRoots
                                  manRoots:
                                      [GSHelpManLocator defaultSearchPaths]
                                 fileRoots:
                                     @[ @"/System/Library/Documentation" ]
                             developerRoots: developerRoots];
}

#pragma mark GSdoc developer documentation

/* Depth-first walk gathering every *.gsdoc below dir as
 * { @"rel": path relative to the scan root, @"abs": real path }.
 * Uses one streaming enumerator with prefetched types instead of
 * per-entry stat calls: source trees hold tens of thousands of
 * files and most of them are irrelevant. */
/* Depth-first walk gathering every *.gsdoc below dir as
 * { @"rel": path relative to the scan root, @"abs": real path }.
 * Build trees, VCS metadata and build output are pruned; source
 * trees hold tens of thousands of irrelevant files. */
+ (void)collectGSdocFilesInDir:(NSString *)dir
                          into:(NSMutableArray<NSDictionary *> *)result
{
    static NSFileManager *fm = nil;
    if (fm == nil)
      {
        fm = [NSFileManager defaultManager];
      }
    NSString *rootPath = [dir stringByStandardizingPath];
    [self collectGSdocInRoot: rootPath
                    relative: @""
                        into: result];
}

+ (void)collectGSdocInRoot:(NSString *)rootPath
                  relative:(NSString *)relative
                      into:(NSMutableArray<NSDictionary *> *)result
{
    NSArray *entries =
        [[NSFileManager defaultManager]
            contentsOfDirectoryAtPath:
                [rootPath stringByAppendingPathComponent: relative]
                                  error: NULL];
    if (entries == nil)
      {
        return;
      }
    for (NSString *name in
             [entries sortedArrayUsingSelector: @selector(compare:)])
      {
        if ([name hasPrefix: @"."])
          {
            continue;
          }
        NSString *rel = [relative length] > 0
            ? [relative stringByAppendingPathComponent: name] : name;
        NSString *path =
            [rootPath stringByAppendingPathComponent: rel];
        NSDictionary *attributes =
            [[NSFileManager defaultManager]
                attributesOfItemAtPath: path error: NULL];
        BOOL isDirectory =
            [[attributes fileType]
                isEqualToString: NSFileTypeDirectory];
        if (isDirectory)
          {
            /* Bundles, build output and VCS/dependency metadata do not
             * carry references. */
            if ([name isEqualToString: @"obj"]
                    || [name isEqualToString: @".git"]
                    || [name isEqualToString: @".svn"]
                    || [name isEqualToString: @".hg"]
                    || [name isEqualToString: @"node_modules"]
                    || [name hasSuffix: @".app"]
                    || [name hasSuffix: @".bundle"]
                    || [name hasSuffix: @".framework"]
                    || [name hasSuffix: @".build"])
              {
                continue;
              }
            [self collectGSdocInRoot: rootPath
                            relative: rel
                                into: result];
          }
        else if ([name hasSuffix: @".gsdoc"] ||
                 [name hasSuffix: @".md"])
          {
            [result addObject: @{ @"rel": rel, @"abs": path }];
          }
      }
}

/* Like index.html for a directory: if a folder holds a README
 * (case-insensitive, .md or .markdown), that file becomes the folder's
 * own page and is removed from the child list so it does not show up as
 * a second "README" entry. Returns the URL and pulls the entry out of
 * `entries` so the caller can hand the slimmed list to its children. */
+ (NSURL *)extractReadmeURLFromEntries:(NSMutableArray<NSDictionary *> *)entries
{
    for (NSUInteger i = 0; i < [entries count]; i++)
      {
        /* Like index.html, a directory's README only counts when it
         * sits directly inside that directory: its rel path must be a
         * single component. A README nested in a subdirectory belongs
         * to that subdirectory, not to this folder. */
        NSString *rel = entries[i][@"rel"];
        if ([[rel pathComponents] count] != 1)
          {
            continue;
          }
        NSString *name = [entries[i][@"abs"] lastPathComponent];
        NSString *base = [[name stringByDeletingPathExtension] lowercaseString];
        NSString *ext = [[name pathExtension] lowercaseString];
        if ([base isEqualToString: @"readme"]
              && ([ext isEqualToString: @"md"]
                    || [ext isEqualToString: @"markdown"]))
          {
            NSURL *url = [NSURL fileURLWithPath: entries[i][@"abs"]];
            [entries removeObjectAtIndex: i];
            return url;
          }
      }
    return nil;
}

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
        NSMutableArray<NSDictionary *> *groupEntries = groups[groupName];
        /* Promote a directory's README to the headline (see
         * -extractReadmeURLFromEntries:); the child list is slimmed. */
        NSURL *readme = [self extractReadmeURLFromEntries: groupEntries];
        [items addObject: [[GSHelpCatalogItem alloc]
            initWithTitle: groupName
                      url: readme
                 children: [self gsdocItemsForRelPaths: groupEntries]]];
      }

    return [items sortedArrayUsingComparator:
                    ^NSComparisonResult(GSHelpCatalogItem *a,
                                        GSHelpCatalogItem *b) {
                      return [[a title] compare: [b title]];
                    }];
}

@end
