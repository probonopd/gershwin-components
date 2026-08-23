/* Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* t_Navigation_ManLocator - man page resolution on disk: exact
 * <name>.<section> before compressed/globbed variants, preferred
 * manN dir first, first search root wins, MANPATH honored. */

#import <Foundation/Foundation.h>
#import "Testing.h"

#import "GSHelpManLocator.h"

static NSString *MakeTempDir(const char *tag)
{
  NSString *base =
      [NSString stringWithFormat: @"/tmp/opencode/manloc-%s-%d",
                    tag, (int)getpid()];
  [[NSFileManager defaultManager] removeFileAtPath: base handler: nil];
  return base;
}

static void Touch(NSString *path)
{
  NSString *dir = [path stringByDeletingLastPathComponent];
  [[NSFileManager defaultManager]
      createDirectoryAtPath: dir withIntermediateDirectories: YES
                 attributes: nil error: NULL];
  [@"" writeToFile: path atomically: YES encoding: NSUTF8StringEncoding
         error: NULL];
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  START_SET("default search paths")
  {
    NSArray *paths = [GSHelpManLocator defaultSearchPaths];

    PASS([paths count] > 0, "defaults are non-empty");
    PASS([paths containsObject: @"/usr/share/man"],
         "standard system man tree included");
    PASS([paths containsObject: @"/usr/local/share/man"],
         "local man tree included");
    PASS([paths containsObject: @"/usr/man"],
         "legacy man tree included");

    /* GNUstep documentation dir only when the environment points at
     * a GNUstep installation. */
    setenv("MANPATH", "/fixture/first:/fixture/second", 1);
    NSArray *withManpath = [GSHelpManLocator defaultSearchPaths];
    PASS([withManpath count] >= 2, "MANPATH contributes entries");
    PASS_EQUAL(withManpath[0], @"/fixture/first",
               "MANPATH entries come first, order preserved");
    PASS_EQUAL(withManpath[1], @"/fixture/second",
               "colon-separated MANPATH split");
    unsetenv("MANPATH");

    setenv("GNUSTEP_SYSTEM_ROOT", "/fixture/step", 1);
    NSArray *withStep = [GSHelpManLocator defaultSearchPaths];
    PASS([withStep containsObject:
              @"/fixture/step/Library/Documentation/man"],
         "GNUstep docs dir added when GNUSTEP_SYSTEM_ROOT is set");
    unsetenv("GNUSTEP_SYSTEM_ROOT");
  }
  END_SET("default search paths")

  NSString *root = MakeTempDir("root");
  START_SET("resolution within one root")
  {
    Touch([root stringByAppendingPathComponent: @"man1/ls.1"]);
    Touch([root stringByAppendingPathComponent: @"man8/mytool.8"]);
    Touch([root stringByAppendingPathComponent: @"man3x/odd.3x"]);

    NSURL *ls = [GSHelpManLocator locateManPageWithCommand: @"ls"
                                                   section: @"1"
                                               searchPaths: @[ root ]];
    PASS(ls != nil, "page found in its section dir");
    PASS([[ls path] hasSuffix: @"man1/ls.1"], "exact file matched");

    NSURL *mytool = [GSHelpManLocator
        locateManPageWithCommand: @"mytool" section: @"8"
                     searchPaths: @[ root ]];
    PASS(mytool != nil && [[mytool path] hasSuffix: @"man8/mytool.8"],
         "other sections resolved too");

    /* Section 3 must reach odd.3x in the man3x directory via the
     * glob pass. */
    NSURL *odd = [GSHelpManLocator locateManPageWithCommand: @"odd"
                                                    section: @"3"
                                                searchPaths: @[ root ]];
    PASS(odd != nil && [[odd path] hasSuffix: @"man3x/odd.3x"],
         "section suffix dirs (man3x) searched");

    NSURL *missing = [GSHelpManLocator
        locateManPageWithCommand: @"nosuchcommand" section: @"1"
                     searchPaths: @[ root ]];
    PASS(missing == nil, "unknown command -> nil");
  }
  END_SET("resolution within one root")

  START_SET("precedence")
  {
    NSString *a = MakeTempDir("a");
    NSString *b = MakeTempDir("b");
    NSArray *bothRoots = @[ a, b ];

    /* Exact beats compressed variant. */
    Touch([a stringByAppendingPathComponent: @"man1/dup.1.gz"]);
    Touch([a stringByAppendingPathComponent: @"man1/dup.1"]);
    NSURL *dup = [GSHelpManLocator locateManPageWithCommand: @"dup"
                                                    section: @"1"
                                                searchPaths: @[ a ]];
    PASS(dup != nil && [[dup path] hasSuffix: @"dup.1"],
         "uncompressed exact match preferred over .gz");

    /* Preferred manN dir beats other man* dirs holding the same
     * name with matching numeric prefix. */
    Touch([b stringByAppendingPathComponent: @"man4/wander.5"]);
    Touch([b stringByAppendingPathComponent: @"man5/wander.5"]);
    NSURL *wander = [GSHelpManLocator locateManPageWithCommand: @"wander"
                                                       section: @"5"
                                                   searchPaths: @[ b ]];
    PASS(wander != nil
             && [[wander path] containsString: @"/man5/"],
         "matching manN dir preferred over other man dirs");

    /* First search root wins entirely. */
    Touch([a stringByAppendingPathComponent: @"man9/two.9"]);
    Touch([b stringByAppendingPathComponent: @"man9/two.9"]);
    NSURL *two = [GSHelpManLocator locateManPageWithCommand: @"two"
                                                    section: @"9"
                                                searchPaths: bothRoots];
    PASS(two != nil && [[two path] hasPrefix: a],
         "earlier search root wins");

    /* Later roots are used when earlier ones lack the page. */
    Touch([b stringByAppendingPathComponent: @"man1/onlyb.1"]);
    NSURL *onlyb = [GSHelpManLocator locateManPageWithCommand: @"onlyb"
                                                      section: @"1"
                                                  searchPaths: bothRoots];
    PASS(onlyb != nil && [[onlyb path] hasPrefix: b],
         "later root consulted when earlier lacks the page");

    NSURL *nowhere =
        [GSHelpManLocator locateManPageWithCommand: @"nothing"
                                           section: @"7"
                                       searchPaths: bothRoots];
    PASS(nowhere == nil, "absent everywhere -> nil");
    PASS([GSHelpManLocator locateManPageWithCommand: @"ls"
                                            section: @"1"
                                        searchPaths: @[] ] == nil,
         "empty search paths -> nil");

    [a release];
    [b release];
  }
  END_SET("precedence")

  START_SET("garbage input")
  {
    PASS_RUNS([GSHelpManLocator locateManPageWithCommand: nil
                                                 section: @"1"
                                             searchPaths: @[ root ]],
              "nil command does not raise");
    PASS([GSHelpManLocator locateManPageWithCommand: nil
                                            section: @"1"
                                        searchPaths: @[ root ]] == nil,
         "nil command -> nil");
    PASS([GSHelpManLocator locateManPageWithCommand: @""
                                            section: @"1"
                                        searchPaths: @[ root ]] == nil,
         "empty command -> nil");
    PASS([GSHelpManLocator locateManPageWithCommand: @"ls"
                                            section: nil
                                        searchPaths: @[ root ]] != nil,
         "nil section falls back to any-section lookup");
  }
  END_SET("garbage input")

  [[NSFileManager defaultManager] removeFileAtPath: root handler: nil];

  [arp release];
  return 0;
}
