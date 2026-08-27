/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "EPUBBook.h"
#import "LCP/LCPError.h"

/* Locate the vendored fixture, robust to cwd / argv[0] form. */
static NSString *fixture(NSString *name, char **argv)
{
  NSArray *candidates = @[
    [[[NSString stringWithUTF8String: argv[0]] stringByStandardizingPath]
        stringByDeletingLastPathComponent],                       // .../obj
    [NSString stringWithUTF8String: "."]                          // cwd
  ];
  for (NSString *dir in candidates)
    {
      NSString *base = [dir stringByDeletingLastPathComponent];   // .../Tests/LCP
      NSString *p = [base stringByAppendingPathComponent:
          [@"fixtures" stringByAppendingPathComponent: name]];
      if ([[NSFileManager defaultManager] fileExistsAtPath: p])
        return p;
    }
  return [@"fixtures" stringByAppendingPathComponent: name];
}

int main(int argc, char **argv)
{
  CREATE_AUTORELEASE_POOL(pool);
  (void)pool;
  int failed = 0;

  NSString *epub = fixture(@"moby-dick.epub", argv);
  PASS([[NSFileManager defaultManager] fileExistsAtPath: epub], "fixture present");

  NSError *e = nil;
  EPUBBook *b = [[EPUBBook alloc] initWithEPUBAtPath: epub error: &e];
  PASS(b != nil, "real LCP EPUB opens");
  if (b == nil) return 1;

  /* The EDRLab test books ship the license as a separate .lcpl next to the
   * EPUB (the container itself has no META-INF/license.lcpl). */
  PASS(b.lcpProtected == YES, "separate .lcpl detected as LCP-protected");
  PASS([b.lcpPassphraseHint rangeOfString: @"EDRLab"
                                   options: NSCaseInsensitiveSearch].location != NSNotFound,
       "passphrase hint mentions EDRLab");

  PASS([b.spine count] > 0, "spine parsed from OPF");

  /* Wrong passphrase is always rejected. The decrypt path (and the correct
   * passphrase) cannot be verified here: these EDRLab front-prod demo files
   * use a private/sandbox passphrase we do not have, so we cap the test at
   * detection. The full unlock+decrypt path is verified by t_EPUB_LCP with a
   * self-generated real LCP EPUB (incl. profile 2.1 and compression). */
  PASS([b lcpUnlockWithPassphrase: @"definitely-not-the-passphrase" error: &e] == NO,
       "wrong passphrase rejected");

  [b cleanupExtraction];
  return failed;
}
