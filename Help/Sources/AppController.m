/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "AppController.h"

#import "HelpWindowController.h"
#import "GSHelpManLocator.h"

#include <stdio.h>
#include <stdlib.h>

@implementation AppController

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification
{
  [self setupMenus];
  [self showWindow];
  [self processArguments];
}

/* Standard app/Edit/Window menu bar so text selection, window
 * handling and Quit behave like every other Gershwin app. */
- (void)setupMenus
{
  NSMenu *mainMenu = [[NSMenu alloc] initWithTitle: @""];

  NSString *appName = [[NSProcessInfo processInfo] processName];
  NSMenuItem *appMenuItem = [[NSMenuItem alloc] initWithTitle: appName
                                                       action: nil
                                                keyEquivalent: @""];
  [mainMenu addItem: appMenuItem];
  NSMenu *appMenu = [[NSMenu alloc] initWithTitle: appName];
  [appMenu addItemWithTitle: @"About"
                     action: @selector(orderFrontStandardAboutPanel:)
              keyEquivalent: @""];
  [appMenu addItemWithTitle: @"Preferences..."
                     action: nil
              keyEquivalent: @","];
  [appMenu addItem: [NSMenuItem separatorItem]];
  [appMenu addItemWithTitle: @"Hide"
                     action: @selector(hide:)
              keyEquivalent: @"h"];
  [appMenu addItem: [NSMenuItem separatorItem]];
  [appMenu addItemWithTitle: @"Quit"
                     action: @selector(terminate:)
              keyEquivalent: @"q"];
  [appMenuItem setSubmenu: appMenu];

  NSMenuItem *editMenuItem = [[NSMenuItem alloc] initWithTitle: @"Edit"
                                                        action: nil
                                                 keyEquivalent: @""];
  [mainMenu addItem: editMenuItem];
  NSMenu *editMenu = [[NSMenu alloc] initWithTitle: @"Edit"];
  [editMenu addItemWithTitle: @"Cut"
                      action: @selector(cut:)
               keyEquivalent: @"x"];
  [editMenu addItemWithTitle: @"Copy"
                      action: @selector(copy:)
               keyEquivalent: @"c"];
  [editMenu addItemWithTitle: @"Paste"
                      action: @selector(paste:)
               keyEquivalent: @"v"];
  [editMenu addItem: [NSMenuItem separatorItem]];
  [editMenu addItemWithTitle: @"Select All"
                      action: @selector(selectAll:)
               keyEquivalent: @"a"];
  [editMenuItem setSubmenu: editMenu];

  NSMenuItem *windowMenuItem = [[NSMenuItem alloc] initWithTitle: @"Window"
                                                          action: nil
                                                   keyEquivalent: @""];
  [mainMenu addItem: windowMenuItem];
  NSMenu *windowMenu = [[NSMenu alloc] initWithTitle: @"Window"];
  [windowMenu addItemWithTitle: @"Miniaturize"
                        action: @selector(performMiniaturize:)
                 keyEquivalent: @"m"];
  [windowMenu addItemWithTitle: @"Zoom"
                        action: @selector(performZoom:)
                 keyEquivalent: @""];
  [windowMenu addItem: [NSMenuItem separatorItem]];
  [windowMenu addItemWithTitle: @"Bring All to Front"
                        action: @selector(arrangeInFront:)
                 keyEquivalent: @""];
  [windowMenuItem setSubmenu: windowMenu];

  [NSApp setMainMenu: mainMenu];
  [NSApp setWindowsMenu: windowMenu];
}

- (void)processArguments
{
  /* CLI usage (SPEC 64): Help.app <file>, --man <cmd> [section].
   * Flags are consumed in order; the first plain argument is offered
   * to the parser registry. */
  NSArray *arguments = [[NSProcessInfo processInfo] arguments];
  BOOL handled = NO;
  for (NSUInteger i = 1; i < [arguments count]; i++)
    {
      NSString *argument = arguments[i];
      if ([argument isEqualToString: @"--man"])
        {
          if (i + 1 >= [arguments count])
            {
              fputs("Help: --man requires a command name\n", stderr);
              exit(2);
            }
          NSString *section =
              (i + 2 < [arguments count]
                   && ![arguments[i + 2] hasPrefix: @"-"])
                  ? arguments[i + 2] : nil;
          NSURL *page = [GSHelpManLocator
              locateManPageWithCommand: arguments[i + 1]
                               section: section
                           searchPaths:
                               [GSHelpManLocator defaultSearchPaths]];
          if (page == nil)
            {
              fprintf(stderr, "Help: no man page for %s\n",
                      [arguments[i + 1] UTF8String]);
              exit(2);
            }
          [_windowController openFileAtPath: [page path]];
          handled = YES;
          break;
        }
      if ([argument hasPrefix: @"-"])
        {
          continue;
        }
      [_windowController openFileAtPath: argument];
      handled = YES;
      break;
    }
  (void)handled;
}

- (void)showWindow
{
  if (_windowController == nil)
    {
      _windowController = [[HelpWindowController alloc] init];
    }
  [_windowController showWindow];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app
{
  return YES;
}

- (BOOL)application:(NSApplication *)application openFile:(NSString *)filename
{
  return [_windowController openFileAtPath: filename];
}

@end
