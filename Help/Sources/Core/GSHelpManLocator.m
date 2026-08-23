/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "GSHelpManLocator.h"

@implementation GSHelpManLocator

+ (NSArray<NSString *> *)defaultSearchPaths
{
    NSMutableArray<NSString *> *paths = [NSMutableArray new];

    /* MANPATH overrides/augments everything, entries keep their
     * order (SPEC 19). Read via getenv because GNUstep snapshots
     * NSProcessInfo.environment before in-process setenv calls. */
    const char *manpath = getenv("MANPATH");
    if (manpath != NULL && *manpath != '\0')
      {
        for (NSString *entry in [[NSString stringWithUTF8String: manpath]
                     componentsSeparatedByString: @":"])
          {
            if ([entry length] > 0)
              {
                [paths addObject: entry];
              }
          }
      }

    [paths addObjectsFromArray: @[
        @"/usr/share/man",
        @"/usr/local/share/man",
        @"/usr/man",
    ]];

    const char *stepRoot = getenv("GNUSTEP_SYSTEM_ROOT");
    if (stepRoot != NULL && *stepRoot != '\0')
      {
        [paths addObject:
            [[NSString stringWithUTF8String: stepRoot]
                stringByAppendingPathComponent:
                    @"Library/Documentation/man"]];
      }

    return paths;
}

/* Directories under one search root, preferred man<section> first,
 * then other man* dirs with the section prefix, then the rest. */
+ (NSArray<NSString *> *)manDirsInRoot:(NSString *)root
                              section:(NSString *)section
{
    NSArray *contents =
        [[NSFileManager defaultManager] contentsOfDirectoryAtPath: root
                                                            error: NULL];
    NSMutableArray<NSString *> *preferred = [NSMutableArray new];
    NSMutableArray<NSString *> *prefixed = [NSMutableArray new];
    NSMutableArray<NSString *> *others = [NSMutableArray new];

    for (NSString *name in contents)
      {
        if (![name hasPrefix: @"man"])
          {
            continue;
          }
        NSString *path = [root stringByAppendingPathComponent: name];
        if ([section length] > 0 && [name isEqualToString:
                [@"man" stringByAppendingString: section]])
          {
            [preferred addObject: path];
          }
        else if ([section length] > 0 && [name hasPrefix:
                     [@"man" stringByAppendingString: section]])
          {
            [prefixed addObject: path];
          }
        else
          {
            [others addObject: path];
          }
      }

    NSMutableArray<NSString *> *result = [NSMutableArray new];
    [result addObjectsFromArray: preferred];
    [result addObjectsFromArray: prefixed];
    [result addObjectsFromArray: others];
    return result;
}

+ (NSURL *)locateManPageWithCommand:(NSString *)command
                            section:(NSString *)section
                        searchPaths:(NSArray<NSString *> *)searchPaths
{
    if (![command length])
      {
        return nil;
      }

    for (NSString *root in searchPaths)
      {
        for (NSString *dir in [self manDirsInRoot: root section: section])
          {
            NSArray *files = [[NSFileManager defaultManager]
                contentsOfDirectoryAtPath: dir error: NULL];
            /* Two passes per directory: exact <command>.<section>
             * beats any <command>.<section>* variant. */
            for (int pass = 0; pass < 2; pass++)
              {
                for (NSString *file in files)
                  {
                    if (![file hasPrefix:
                              [command stringByAppendingString: @"."]])
                      {
                        continue;
                      }
                    NSString *suffix = [file substringFromIndex:
                                               [command length] + 1];
                    BOOL exact = [suffix isEqualToString: section];
                    BOOL prefixMatch = [section length] == 0
                        || ([suffix length] > [section length]
                            && [suffix hasPrefix: section]);
                    if ((pass == 0 && exact)
                        || (pass == 1 && !exact && prefixMatch))
                      {
                        return [NSURL fileURLWithPath:
                                    [dir stringByAppendingPathComponent:
                                             file]];
                      }
                  }
              }
          }
      }
    return nil;
}

@end
