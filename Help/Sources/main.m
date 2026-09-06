/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>
#import "AppController.h"

int main(int argc, char **argv)
{
  @autoreleasepool {
    [NSApplication sharedApplication];
    AppController *controller = [[AppController alloc] init];
    [NSApp setDelegate: controller];
    [NSApp run];
  }
  return 0;
}
