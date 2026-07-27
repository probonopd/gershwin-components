/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * OnDemand — Placeholder on-demand installer application.
 *
 * Normal mode: reads its embedded Install.plist, checks if the target
 * command exists, installs packages if needed, then launches the command.
 *
 * Direct install mode: when invoked with a package file path as argument
 * (e.g., "OnDemand /path/to/file.deb"), detects the format and installs
 * the package via the system package manager.
 */

#import <AppKit/NSApplication.h>
#import <Foundation/NSAutoreleasePool.h>
#import "OnDemandController.h"

// Keep controller alive for the run loop
static OnDemandController *gController = nil;

int main(int argc, const char *argv[])
{
  [NSApplication sharedApplication];
  gController = [[OnDemandController alloc] init];
  [[NSApplication sharedApplication] setDelegate:gController];

  /* Direct install mode: file path provided */
  if (argc > 1)
    {
      NSString *path = [NSString stringWithUTF8String:argv[1]];
      NSLog(@"OnDemand -> main: direct install mode for %@", path);
      if (![gController setupFromFile:path])
        {
          NSLog(@"OnDemand [FAIL] main: failed to handle %@", path);
          [gController showError:[NSString stringWithFormat:
            @"Could not install %@.\n\nThe format may not be supported or the file may be corrupt.",
            [path lastPathComponent]]];
        }
      [[NSApplication sharedApplication] run];
      return 0;
    }

  if (![gController setupFromPlist])
    {
      NSLog(@"OnDemand [FAIL] main: failed to read install plist, exiting");
      return 1;
    }

  // If command is already available, launch silently and exit (no GUI)
  if ([gController commandIsAvailable])
    {
      NSLog(@"OnDemand -> main: command already installed, launching silently");
      [gController launchAndExit]; // never returns
      return 1;
    }

  // Otherwise start run loop; window will be shown in applicationDidFinishLaunching:
  NSLog(@"OnDemand -> main: starting run loop");
  [[NSApplication sharedApplication] run];
  return 0;
}
