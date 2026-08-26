/* t_PreflightHeaders.m - ObjectTesting coverage for the preflight's handling
   of headers that ship with gnustep-make itself (its TestFramework, e.g.
   Testing.h).  Projects whose test tools use ObjectTesting must still build
   even though no distro package provides those headers.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#import <AppKit/AppKit.h>
#import "Testing.h"
#import "GWBuildPreflight.h"
#include "../GWBuildPreflight.m"

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  /* Headers from gnustep-make's TestFramework are available on every
     machine with gnustep-make and must be treated as installed. */
  PASS([GWBuildPreflight headerIsShippedWithGnustepMake: @"Testing.h"],
       "Testing.h ships with gnustep-make");
  PASS([GWBuildPreflight headerIsShippedWithGnustepMake: @"ObjectTesting.h"],
       "ObjectTesting.h ships with gnustep-make");

  /* Anything outside the TestFramework stays unresolved so the package
     manager still gets a chance to install it. */
  PASS(![GWBuildPreflight headerIsShippedWithGnustepMake: @"curl/curl.h"],
       "curl/curl.h does not ship with gnustep-make");
  PASS(![GWBuildPreflight headerIsShippedWithGnustepMake: @"TestingX.h"],
        "unknown headers are not claimed as gnustep-make headers");

  /* A header guarded by a foreign-OS macro that is never defined on this host
     (e.g. windows.h under #ifdef __MINGW32__) is dead code and must be
     skipped, not reported as a missing dependency. */
  {
    GWBuildPreflight *pf = [GWBuildPreflight new];
    NSString *src = @"#ifdef __MINGW32__\n#include <windows.h>\n#endif\n";
    NSSet *undef = [pf _undefinedPlatformMacros];
    NSMutableArray *actives = [NSMutableArray array];
    NSMutableArray *inBlocks = [NSMutableArray array];
    NSMutableArray *ranges = [NSMutableArray array];
    [pf _scanContent:src undefined:undef lineActives:actives
        inBlockStarts:inBlocks ranges:ranges];
    NSArray *matches = [GWHeaderRegex() matchesInString:src
                                                options:0
                                                  range:NSMakeRange(0, [src length])];
    PASS([matches count] == 1, "windows.h is matched");
    PASS([pf _shouldSkipHeaderAtMatch:matches[0] inContent:src
                             actives:actives inBlocks:inBlocks ranges:ranges],
         "windows.h under __MINGW32__ is skipped");
    [pf release];
  }

  /* A commented-out import is dead code and must be skipped. */
  {
    GWBuildPreflight *pf = [GWBuildPreflight new];
    NSString *src = @"//#import <Renaissance/Renaissance.h>\n";
    NSSet *undef = [pf _undefinedPlatformMacros];
    NSMutableArray *actives = [NSMutableArray array];
    NSMutableArray *inBlocks = [NSMutableArray array];
    NSMutableArray *ranges = [NSMutableArray array];
    [pf _scanContent:src undefined:undef lineActives:actives
        inBlockStarts:inBlocks ranges:ranges];
    NSArray *matches = [GWHeaderRegex() matchesInString:src
                                                options:0
                                                  range:NSMakeRange(0, [src length])];
    PASS([matches count] == 1, "commented Renaissance import is matched");
    PASS([pf _shouldSkipHeaderAtMatch:matches[0] inContent:src
                             actives:actives inBlocks:inBlocks ranges:ranges],
         "commented-out import is skipped");
    [pf release];
  }

  /* A header that is actually compiled must NOT be skipped. */
  {
    GWBuildPreflight *pf = [GWBuildPreflight new];
    NSString *src = @"#import <stdio.h>\n";
    NSSet *undef = [pf _undefinedPlatformMacros];
    NSMutableArray *actives = [NSMutableArray array];
    NSMutableArray *inBlocks = [NSMutableArray array];
    NSMutableArray *ranges = [NSMutableArray array];
    [pf _scanContent:src undefined:undef lineActives:actives
        inBlockStarts:inBlocks ranges:ranges];
    NSArray *matches = [GWHeaderRegex() matchesInString:src
                                                options:0
                                                  range:NSMakeRange(0, [src length])];
    PASS([matches count] == 1, "stdio.h is matched");
    PASS(![pf _shouldSkipHeaderAtMatch:matches[0] inContent:src
                              actives:actives inBlocks:inBlocks ranges:ranges],
         "compiled import is not skipped");
    [pf release];
  }

  [arp release];
  return 0;
}
