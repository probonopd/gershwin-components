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
                                      fileRoots: @[ ]
                                  developerRoots: @[ ]];
    PASS([items count] == 1
             && [[items[0] title] isEqualToString: @"Welcome"],
         "no inputs -> only the pinned Welcome group");
    PASS_RUNS([GSHelpCatalog catalogItemsWithAppRoots: @[@"/nonexistent-apps"]
                                             manRoots: @[@"/nonexistent-man"]
                                            fileRoots:
                                                @[@"/nonexistent-docs"]
                                        developerRoots:
                                                @[@"/nonexistent-devdocs"]],
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
                                                    fileRoots: @[ ]
                                                developerRoots: @[ ]];
    PASS([groups count] == 2
             && [[groups[0] title] isEqualToString: @"Welcome"]
             && [[groups[1] title] isEqualToString: @"Applications"],
         "apps collected under one Applications group after Welcome");
    NSArray *items = [groups[1] children];
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
                                           fileRoots: @[ ]
                                       developerRoots: @[ ]];
    PASS([[groups[1] children] count] == 2,
         "app without Resources/Help skipped");

    [fm removeFileAtPath: base handler: nil];
  }
  END_SET("application help discovery")

  START_SET("man pages grouped by section")
  {
    NSString *base = MakeBase();
    Touch([base stringByAppendingPathComponent: @"man1/ls.1"]);
    Touch([base stringByAppendingPathComponent: @"man1/gzip.1.gz"]);
    Touch([base stringByAppendingPathComponent: @"man1p/nice.1p"]);
    Touch([base stringByAppendingPathComponent: @"man2/pipe.2"]);
    Touch([base stringByAppendingPathComponent: @"man3/printf.3"]);
    Touch([base stringByAppendingPathComponent: @"man8/fsck.8"]);

    NSArray *groups = [GSHelpCatalog catalogItemsWithAppRoots: @[ ]
                                                     manRoots: @[ base ]
                                                    fileRoots: @[ ]
                                                developerRoots: @[ ]];
    PASS([groups count] == 2
             && [[groups[0] title] isEqualToString: @"Welcome"]
             && [[groups[1] title] isEqualToString: @"Manual Pages"],
          "man pages collected under one Manual Pages group after Welcome");
    NSArray *items = [groups[1] children];
    PASS([items count] == 5, "five sections present");
    PASS([[items[0] title] isEqualToString: @"Section 1: User Commands"],
         "section 1 carries its canonical name");
    PASS([[items[1] title]
              isEqualToString: @"Section 1p: User Commands (POSIX)"],
         "POSIX variant of section 1 annotated");
    PASS([[items[2] title]
              isEqualToString: @"Section 2: System Calls"],
         "section 2 carries its canonical name");
    PASS([[items[3] title]
              isEqualToString: @"Section 3: Library Functions"],
         "section 3 carries its canonical name");
    PASS([[items[4] title]
              isEqualToString: @"Section 8: System Administration"],
         "section 8 carries its canonical name");
    PASS([[items[0] children] count] == 2,
         "both section-1 pages listed");
    PASS([[[items[0] children][0] title] isEqualToString: @"gzip(1)"],
         "compression suffix stripped from display title");
    NSURL *url = [[items[0] children][0] url];    PASS([[[url path] lastPathComponent] isEqualToString: @"gzip.1.gz"],
         "leaf URL points at the real compressed file");
    PASS([[[items[4] children][0] title] isEqualToString: @"fsck(8)"],
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
                                                   fileRoots: @[ base ]
                                               developerRoots: @[ ]];
    PASS(CountLeaves(items) == 3, "Welcome leaf plus Markdown files");
    PASS([items count] == 2
             && [[items[0] title] isEqualToString: @"Welcome"]
             && [[items[1] title] isEqualToString: @"Documentation"],
         "markdown merged into one Documentation group after Welcome");
    NSArray *children = [items[1] children];
    PASS([children count] == 2, "file and folder present");
    PASS([[children[0] title] isEqualToString: @"a"]
              && [[children[0] url] isKindOfClass: [NSURL class]],
         "top-level markdown becomes a leaf, extension stripped");
    GSHelpCatalogItem *sub = children[1];
    PASS([[sub title] isEqualToString: @"sub"]
             && [sub children] != nil, "directory mirrored as a group");
    PASS([[[sub children][0] title] isEqualToString: @"b"],
         "nested markdown leaf keeps its name");

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

    NSArray *groups = [GSHelpCatalog catalogItemsWithAppRoots: @[ ]
                                                      manRoots: @[ ]
                                                     fileRoots: @[ ]
                                                 developerRoots: @[ r1, r2 ]];
    PASS([groups count] == 2
             && [[groups[0] title] isEqualToString: @"Welcome"]
             && [[groups[1] title] isEqualToString: @"Documentation"],
         "Welcome leads, gsdoc under Documentation");

    NSArray *welcome = [groups[0] children];
    PASS([welcome count] == 1
             && [[welcome[0] title] isEqualToString: @"Welcome"]
             && [[[welcome[0] url] absoluteString]
                    isEqualToString: @"help://welcome"],
         "Welcome group holds the welcome page with sentinel URL");
    GSHelpCatalogItem *doc = groups[1];
    PASS([doc children] != nil && [[doc children] count] == 1,
         "gsdoc nested under a Frameworks subgroup of Documentation");
    GSHelpCatalogItem *fw = [doc children][0];
    PASS([[fw title] isEqualToString: @"Frameworks"],
         "gsdoc nested under a Frameworks subgroup");
    NSArray *fwTop = [fw children];
    PASS([fwTop count] == 3, "three top-level framework rows");
    PASS([[fwTop[0] title] isEqualToString: @"Bar"]
             && [[fwTop[0] url] isKindOfClass: [NSURL class]],
         "root-level gsdoc becomes an openable leaf");
    PASS([[fwTop[0] url].path hasPrefix: r1],
         "leaf URL points at the real file");
    PASS([[fwTop[1] title] isEqualToString: @"Foo"],
         "directories become group rows, sorted by name");
    PASS([[fwTop[2] title] isEqualToString: @"X"]
             && [[fwTop[2] url].path hasPrefix: r2],
         "unique file from second root listed too");

    GSHelpCatalogItem *fooGroup = fwTop[1];
    PASS([[[fooGroup children][0] title] isEqualToString: @"B"],
         "nested gsdoc leaf under its directory group");
    PASS([[[fooGroup children][0] url].path hasPrefix: r1],
         "duplicate relative path keeps the first root's copy");
    PASS([[[fooGroup children][1] title] isEqualToString: @"Reference"]
             && [[[[fooGroup children][1] children][0] title]
                    isEqualToString: @"A"],
         "subdirectories nest to mirror the tree");

    PASS(CountLeaves(groups) == 5,
         "non-gsdoc files ignored, duplicates collapsed");

    [fm removeFileAtPath: r1 handler: nil];
    [fm removeFileAtPath: r2 handler: nil];
  }
  END_SET("gsdoc developer documentation")

  START_SET("gsdoc missing roots")
  {
    NSArray *groups = [GSHelpCatalog
        catalogItemsWithAppRoots: @[ ]
                          manRoots: @[ ]
                         fileRoots: @[ ]
                     developerRoots: @[ @"/nonexistent-devdocs" ]];
    PASS_RUNS([GSHelpCatalog
        catalogItemsWithAppRoots: @[ ]
                          manRoots: @[ ]
                         fileRoots: @[ ]
                     developerRoots: @[ @"/nonexistent-devdocs" ]],
              "missing root does not raise");
    PASS([groups count] == 1
             && [[groups[0] title] isEqualToString: @"Welcome"],
         "missing root -> only the Welcome group");
  }
  END_SET("gsdoc missing roots")
}
