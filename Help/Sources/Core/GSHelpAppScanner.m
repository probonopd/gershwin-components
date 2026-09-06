/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "GSHelpAppScanner.h"

static NSString *const kManifestName = @"Help.plist";
static NSString *const kDefaultIndex = @"index.md";

@implementation GSHelpAppScan
{
    NSString *_helpDirectory;
    NSURL *_entryURL;
    NSArray<NSDictionary *> *_items;
}

- (instancetype)initWithDirectory:(NSString *)directory
                         entryURL:(NSURL *)entryURL
                            items:(NSArray<NSDictionary *> *)items
{
    self = [super init];
    if (self != nil)
      {
        _helpDirectory = [directory copy];
        _entryURL = entryURL;
        _items = [items copy];
      }
    return self;
}

- (NSString *)helpDirectory
{
    return _helpDirectory;
}

- (NSURL *)entryURL
{
    return _entryURL;
}

- (NSArray<NSDictionary *> *)items
{
    return _items;
}

@end

@implementation GSHelpAppScanner

+ (NSDictionary *)manifestInDirectory:(NSString *)dir
{
    return [NSDictionary dictionaryWithContentsOfFile:
                [dir stringByAppendingPathComponent: kManifestName]];
}

+ (NSArray<NSURL *> *)markdownFilesInDirectory:(NSString *)dir
{
    NSMutableArray<NSURL *> *files = [NSMutableArray new];
    for (NSString *name in [[NSFileManager defaultManager]
             contentsOfDirectoryAtPath: dir error: NULL])
      {
        if ([name hasSuffix: @".md"] || [name hasSuffix: @".markdown"])
          {
            [files addObject:
                [NSURL fileURLWithPath:
                    [dir stringByAppendingPathComponent: name]]];
          }
      }
    /* Deterministic order for consumers and tests. */
    [files sortUsingComparator:^NSComparisonResult(
               NSURL *a, NSURL *b) {
      return [[a lastPathComponent] compare: [b lastPathComponent]];
    }];
    return files;
}

+ (GSHelpAppScan *)scanApplicationHelpAtPath:(NSString *)appPath
                                       error:(NSError **)error
{
    NSString *helpDir = [appPath stringByAppendingPathComponent:
                                    @"Resources/Help"];
    if (![[NSFileManager defaultManager] fileExistsAtPath: helpDir])
      {
        if (error != NULL)
          {
            *error = [NSError errorWithDomain: @"GSHelpErrorDomain"
                                         code: 1
                                     userInfo: @{
              NSLocalizedDescriptionKey:
                  [NSString stringWithFormat:
                                @"No help bundle at %@", helpDir],
            }];
          }
        return nil;
      }

    NSDictionary *manifest = [self manifestInDirectory: helpDir];
    NSMutableArray<NSDictionary *> *items = [NSMutableArray new];
    NSURL *entryURL = nil;

    if (manifest != nil)
      {
        NSString *indexName =
            manifest[@"Index"] ?: manifest[@"index"] ?: kDefaultIndex;
        NSString *indexPath =
            [helpDir stringByAppendingPathComponent: indexName];
        if ([[NSFileManager defaultManager] fileExistsAtPath: indexPath])
          {
            entryURL = [NSURL fileURLWithPath: indexPath];
          }

        for (NSDictionary *entry in manifest[@"Contents"])
          {
            NSString *file = entry[@"File"];
            if (![file length])
              {
                continue;
              }
            NSString *path =
                [helpDir stringByAppendingPathComponent: file];
            if (![[NSFileManager defaultManager] fileExistsAtPath: path])
              {
                continue;
              }
            [items addObject: @{
              @"Title": entry[@"Title"] ?: file,
              @"FileURL": [NSURL fileURLWithPath: path],
            }];
          }
      }

    if (entryURL == nil)
      {
        NSString *defaultIndex =
            [helpDir stringByAppendingPathComponent: kDefaultIndex];
        if ([[NSFileManager defaultManager] fileExistsAtPath: defaultIndex])
          {
            entryURL = [NSURL fileURLWithPath: defaultIndex];
          }
      }

    if ([items count] == 0)
      {
        /* No manifest: derive items from the .md files so the UI can
         * still offer navigation (SPEC 15 - manifest is optional). */
        for (NSURL *url in [self markdownFilesInDirectory: helpDir])
          {
            if (![url isEqual: entryURL])
              {
                [items addObject: @{
                  @"Title": [url lastPathComponent],
                  @"FileURL": url,
                }];
              }
          }
      }

    return [[GSHelpAppScan alloc] initWithDirectory: helpDir
                                           entryURL: entryURL
                                              items: items];
}

@end
