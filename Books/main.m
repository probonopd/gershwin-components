/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>
#import "BooksAppDelegate.h"

int main(int argc, const char *argv[])
{
  @autoreleasepool
    {
      NSApplication *app = [NSApplication sharedApplication];
      BooksAppDelegate *delegate = [[BooksAppDelegate alloc] init];
      [app setDelegate:delegate];
      [app run];
    }
  return 0;
}
