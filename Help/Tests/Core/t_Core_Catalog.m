/* Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* t_Core_Catalog - documentation catalog tree: application help
 * bundles, man pages grouped by section, Markdown files found under
 * given roots. Fixtures are synthetic temp trees. */

#import <Foundation/Foundation.h>
#import "Testing.h"

#import "GSHelpCatalog.h"
#import "GSHelpURL.h"

static NSString *MakeBaseNamed(NSString *suffix)
{
  NSString *base = [@"/tmp/opencode/catalog-"
      stringByAppendingString:
      [[NSString stringWithFormat: @"%d", (int)getpid()]
          stringByAppendingString: suffix]];
  [[NSFileManager defaultManager] removeFileAtPath: base handler: nil];
  return base;
}

static NSString *MakeBase(void)
{
  return MakeBaseNamed(@"");
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

static void TouchApp(NSString *base, NSString *name)
{
  NSString *helpDir = [[base stringByAppendingPathComponent:
                                   [name stringByAppendingString: @".app"]]
                           stringByAppendingPathComponent:
                       @"Resources/Help"];
  [[NSFileManager defaultManager]
      createDirectoryAtPath: helpDir withIntermediateDirectories: YES
                 attributes: nil error: NULL];
  [@"# x" writeToFile: [helpDir stringByAppendingPathComponent: @"index.md"]
            atomically: YES encoding: NSUTF8StringEncoding error: NULL];
}

static NSInteger CountLeaves(NSArray *items)
{
  NSInteger count = 0;
  for (GSHelpCatalogItem *item in items)
    {
      if ([item children] == nil || [[item children] count] == 0)
        {
          count += 1;
        }
      else
        {
          count += CountLeaves([item children]);
        }
    }
  return count;
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];
  (void)arp;
  NSFileManager *fm = [NSFileManager defaultManager];

  START_SET("empty inputs")
  {
    NSArray *items =
        [GSHelpCatalog catalogItemsWithAppRoots: @[ ]
                                       manRoots: @[ ]
                                      fileRoots: @[ ]];
    PASS([items count] == 0, "no inputs -> empty catalog");
    PASS_RUNS([GSHelpCatalog catalogItemsWithAppRoots: @[@"/nonexistent-apps"]
                                             manRoots: @[@"/nonexistent-man"]
                                            fileRoots:
                                                @[@"/nonexistent-docs"]],
              "missing roots do not raise");
  }
  END_SET("empty inputs")

  START_SET("application help discovery")
  {
    NSString *base = MakeBase();
    TouchApp(base, @"Foo");
    TouchApp(base, @"Bar");

    NSArray *groups = [GSHelpCatalog catalogItemsWithAppRoots: @[ base ]
                                                     manRoots: @[ ]
                                                    fileRoots: @[ ]];
    PASS([groups count] == 1
             && [[groups[0] title] isEqualToString: @"Applications"],
         "apps collected under one Applications group");
    NSArray *items = [groups[0] children];
    PASS([items count] == 2, "one item per app bundle");
    PASS([[items[0] title] isEqualToString: @"Bar"]
             && [[items[1] title] isEqualToString: @"Foo"],
         "apps sorted by name");
    PASS([[items[0] url] isKindOfClass: [NSURL class]],
         "app leaf carries its index URL");

    /* App without help bundle is not listed. */
    [fm createDirectoryAtPath:
              [base stringByAppendingPathComponent: @"Naked.app"]
       withIntermediateDirectories: YES attributes: nil error: NULL];
    groups = [GSHelpCatalog catalogItemsWithAppRoots: @[ base ]
                                            manRoots: @[ ]
                                           fileRoots: @[ ]];
    PASS([[groups[0] children] count] == 2,
         "app without Resources/Help skipped");

    [fm removeFileAtPath: base handler: nil];
  }
  END_SET("application help discovery")

  START_SET("man pages grouped by section")
  {
    NSString *base = MakeBase();
    Touch([base stringByAppendingPathComponent: @"man1/ls.1"]);
    Touch([base stringByAppendingPathComponent: @"man1/gzip.1.gz"]);
    Touch([base stringByAppendingPathComponent: @"man3/printf.3"]);
    Touch([base stringByAppendingPathComponent: @"man8/fsck.8"]);

    NSArray *groups = [GSHelpCatalog catalogItemsWithAppRoots: @[ ]
                                                     manRoots: @[ base ]
                                                    fileRoots: @[ ]];
    PASS([groups count] == 1
             && [[groups[0] title] isEqualToString: @"Commands"],
         "man pages collected under one Commands group");
    NSArray *items = [groups[0] children];
    PASS([items count] == 3, "three sections present");
    PASS([[items[0] title] isEqualToString: @"Section 1"],
         "sections ordered numerically");
    PASS([[items[0] children] count] == 2,
         "both section-1 pages listed");
    PASS([[[items[0] children][0] title] isEqualToString: @"gzip(1)"],
         "compression suffix stripped from display title");
    NSURL *url = [[items[0] children][0] url];    PASS([[[url path] lastPathComponent] isEqualToString: @"gzip.1.gz"],
         "leaf URL points at the real compressed file");
    PASS([[[items[2] children][0] title] isEqualToString: @"fsck(8)"],
         "section 8 pages listed");

    [fm removeFileAtPath: base handler: nil];
  }
  END_SET("man pages grouped by section")

  START_SET("markdown files")
  {
    NSString *base = MakeBase();
    Touch([base stringByAppendingPathComponent: @"a.md"]);
    Touch([base stringByAppendingPathComponent: @"sub/b.markdown"]);
    Touch([base stringByAppendingPathComponent: @"notes.txt"]);

    NSArray *items = [GSHelpCatalog catalogItemsWithAppRoots: @[ ]
                                                    manRoots: @[ ]
                                                   fileRoots: @[ base ]];
    PASS(CountLeaves(items) == 2, "only Markdown files collected");
    PASS([items count] == 1, "one System Documentation group");
    NSMutableSet *titles =
        [NSMutableSet setWithCapacity: [[items[0] children] count]];
    for (GSHelpCatalogItem *leaf in [items[0] children])
      {
        [titles addObject: [leaf title]];
      }
    PASS([titles containsObject: @"a"] && [titles containsObject: @"b"],
         "extension stripped from title");

    [fm removeFileAtPath: base handler: nil];
  }
  END_SET("markdown files")

  START_SET("gsdoc developer documentation")
  {
    NSString *r1 = MakeBaseNamed(@"-sys");
    NSString *r2 = MakeBaseNamed(@"-usr");
    Touch([r1 stringByAppendingPathComponent: @"Foo/Reference/A.gsdoc"]);
    Touch([r1 stringByAppendingPathComponent: @"Foo/B.gsdoc"]);
    Touch([r1 stringByAppendingPathComponent: @"Bar.gsdoc"]);
    Touch([r1 stringByAppendingPathComponent: @"notes.txt"]);
    Touch([r2 stringByAppendingPathComponent: @"Foo/B.gsdoc"]);
    Touch([r2 stringByAppendingPathComponent: @"X.gsdoc"]);

    NSArray *groups =
        [GSHelpCatalog developerDocItemsWithRoots: @[ r1, r2 ]];
    PASS([groups count] == 1
             && [[groups[0] title] isEqualToString:
                     @"Developer Documentation"],
         "all gsdoc collected under one Developer Documentation group");

    NSArray *top = [groups[0] children];
    PASS([top count] == 3, "three top-level rows");
    PASS([[top[0] title] isEqualToString: @"Bar"]
             && [[top[0] url] isKindOfClass: [NSURL class]],
         "root-level gsdoc becomes an openable leaf");
    PASS([[top[0] url].path hasPrefix: r1],
         "leaf URL points at the real file");
    PASS([[top[1] title] isEqualToString: @"Foo"],
         "directories become group rows, sorted by name");
    PASS([[top[2] title] isEqualToString: @"X"]
             && [[top[2] url].path hasPrefix: r2],
         "unique file from second root listed too");

    GSHelpCatalogItem *fooGroup = top[1];
    PASS([[[fooGroup children][0] title] isEqualToString: @"B"],
         "nested gsdoc leaf under its directory group");
    PASS([[[fooGroup children][0] url].path hasPrefix: r1],
         "duplicate relative path keeps the first root's copy");
    PASS([[[fooGroup children][1] title] isEqualToString: @"Reference"]
             && [[[[fooGroup children][1] children][0] title]
                    isEqualToString: @"A"],
         "subdirectories nest to mirror the tree");

    PASS(CountLeaves(groups) == 4,
         "non-gsdoc files ignored, duplicates collapsed");

    [fm removeFileAtPath: r1 handler: nil];
    [fm removeFileAtPath: r2 handler: nil];
  }
  END_SET("gsdoc developer documentation")

  START_SET("gsdoc missing roots")
  {
    NSArray *groups = [GSHelpCatalog developerDocItemsWithRoots:
                                          @[ @"/nonexistent-devdocs" ]];
    PASS_RUNS([GSHelpCatalog developerDocItemsWithRoots:
                              @[ @"/nonexistent-devdocs" ]],
              "missing root does not raise");
    PASS([groups count] == 0, "missing root -> no group");
  }
  END_SET("gsdoc missing roots")
}
