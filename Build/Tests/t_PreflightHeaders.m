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

  [arp release];
  return 0;
}
