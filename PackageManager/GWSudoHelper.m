/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * GWSudoHelper implementation.
 */

#import "GWSudoHelper.h"
#import <unistd.h>

NSString *GWSudoPath(void)
{
  // sudo is always looked up via $PATH (NSTask searches PATH for a launch
  // path without a slash), so we never hardcode its install location.  This
  // keeps the backends portable across Linux (/usr/bin) and the BSDs
  // (/usr/local/bin) without platform-specific path lists.
  return @"sudo";
}

NSArray<NSString *> *GWSudoArgPrefix(void)
{
  // Already root: run the package manager directly, no escalation needed.
  if (getuid() == 0)
    return @[];
  return @[ @"-A", @"-E" ];
}
