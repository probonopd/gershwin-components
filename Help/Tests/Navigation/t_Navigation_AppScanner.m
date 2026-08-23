/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "GSHelpAppScanner.h"

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  NSString *base =
      [NSString stringWithFormat: @"/tmp/opencode/appscan-%d", (int)getpid()];
  [[NSFileManager defaultManager] removeFileAtPath: base handler: nil];
  NSFileManager *fm = [NSFileManager defaultManager];

  void (^MakeApp)(NSString *, void (^)(NSString *)) =
      ^(NSString *name, void (^populate)(NSString *helpDir)) {
        NSString *app = [base stringByAppendingPathComponent:
                                   [name stringByAppendingString: @".app"]];
        NSString *helpDir =
            [app stringByAppendingPathComponent: @"Resources/Help"];
        [fm createDirectoryAtPath: helpDir
             withIntermediateDirectories: YES attributes: nil error: NULL];
        populate(helpDir);
      };

  START_SET("no help bundle")
  {
    NSString *bareApp =
        [base stringByAppendingPathComponent: @"Bare.app"];
    [fm createDirectoryAtPath: bareApp
         withIntermediateDirectories: YES attributes: nil error: NULL];
    NSError *error = nil;
    GSHelpAppScan *scan =
        [GSHelpAppScanner scanApplicationHelpAtPath: bareApp error: &error];
    PASS(scan == nil, "app without Resources/Help -> nil");
    PASS(error != nil, "error reported for missing bundle");
  }
  END_SET("no help bundle")

  START_SET("index.md only, no manifest")
  {
    __block NSString *dir;
    MakeApp(@"IndexOnly", ^(NSString *helpDir) {
      dir = helpDir;
      [@"# App" writeToFile: [helpDir stringByAppendingPathComponent:
                                       @"index.md"]
                 atomically: YES encoding: NSUTF8StringEncoding error: NULL];
      [@"Other" writeToFile: [helpDir stringByAppendingPathComponent:
                                        @"usage.md"]
                  atomically: YES encoding: NSUTF8StringEncoding error: NULL];
    });

    GSHelpAppScan *scan = [GSHelpAppScanner scanApplicationHelpAtPath:
        [base stringByAppendingPathComponent: @"IndexOnly.app"] error: NULL];
    PASS(scan != nil, "scan succeeds without manifest");
    PASS([[[scan entryURL] path] hasSuffix: @"index.md"],
         "index.md becomes the entry point");
    PASS([[scan items] count] == 1,
         "entry excluded from derived items");
    PASS([[[scan items][0] objectForKey: @"Title"]
              isEqualToString: @"usage.md"],
         "derived item titled by filename");
    PASS([[[scan items][0] objectForKey: @"FileURL"] isKindOfClass:
              [NSURL class]], "item carries a file URL");
    (void)dir;
  }
  END_SET("index.md only, no manifest")

  START_SET("manifest honored")
  {
    MakeApp(@"WithManifest", ^(NSString *helpDir) {
      [@"" writeToFile: [helpDir stringByAppendingPathComponent:
                                   @"intro.md"]
             atomically: YES encoding: NSUTF8StringEncoding error: NULL];
      [@"" writeToFile: [helpDir stringByAppendingPathComponent:
                                   @"prefs.md"]
             atomically: YES encoding: NSUTF8StringEncoding error: NULL];
      /* missing.md deliberately NOT created */
      [@"" writeToFile: [helpDir stringByAppendingPathComponent:
                                   @"custom-home.md"]
             atomically: YES encoding: NSUTF8StringEncoding error: NULL];
      NSDictionary *plist = @{
        @"FormatVersion": @1,
        @"Title": @"My Application",
        @"Index": @"custom-home.md",
        @"Contents": @[ @{ @"Title": @"Preferences",
                           @"File": @"prefs.md" },
                        @{ @"Title": @"Broken",
                           @"File": @"missing.md" },
                        @{ @"File": @"intro.md" } ],
      };
      [plist writeToFile: [helpDir stringByAppendingPathComponent:
                                     @"Help.plist"]
              atomically: YES];
    });

    GSHelpAppScan *scan = [GSHelpAppScanner scanApplicationHelpAtPath:
        [base stringByAppendingPathComponent: @"WithManifest.app"] error: NULL];
    PASS(scan != nil, "manifest app scans");
    PASS([[[scan entryURL] path] hasSuffix: @"custom-home.md"],
         "manifest Index overrides index.md default");
    PASS([[scan items] count] == 2,
         "manifest entries drive the item list");
    PASS([[[scan items][0] objectForKey: @"Title"]
              isEqualToString: @"Preferences"],
         "manifest titles preserved in order");
    PASS([[[scan items][1] objectForKey: @"Title"]
              isEqualToString: @"intro.md"],
         "entry without Title falls back to filename");
  }
  END_SET("manifest honored")

  START_SET("empty help dir")
  {
    MakeApp(@"Empty", ^(NSString *helpDir) {
      /* leave it empty */
    });
    GSHelpAppScan *scan = [GSHelpAppScanner scanApplicationHelpAtPath:
        [base stringByAppendingPathComponent: @"Empty.app"] error: NULL];
    PASS(scan != nil, "empty bundle still yields a scan result");
    PASS([scan entryURL] == nil && [[scan items] count] == 0,
         "empty bundle has no entry and no items");
  }
  END_SET("empty help dir")

  [fm removeFileAtPath: base handler: nil];

  [arp release];
  return 0;
}
