/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>
#import "BooksAppDelegate.h"
#import "BookshelfController.h"
#import "LibraryStore.h"
#import "LibraryBook.h"

@implementation BooksAppDelegate
{
  BookshelfController *_shelf;
  BOOL _launchedWithFile;
}

- (void)applicationWillFinishLaunching:(NSNotification *)notifier
{
  [self buildMainMenu];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notifier
{
  if (_shelf == nil)
    _shelf = [[BookshelfController alloc] init];
  // Restore the book that was left open: open it directly and keep the shelf
  // hidden. Only fall back to the bookshelf when nothing was open before.
  if (!_launchedWithFile)
    {
      NSString *last = [[LibraryStore sharedStore] currentBookPath];
      if (last != nil && [[NSFileManager defaultManager] fileExistsAtPath:last])
        {
          LibraryBook *b = [_shelf bookForPath:last];
          if (b && [_shelf openBook:b])
            return;
        }
      [_shelf showWindow:self];
    }
}

- (void)buildMainMenu
{
  // Build a fresh main menu rather than appending to GNUstep's default one,
  // which already carries an application menu; otherwise we'd get two "Books".
  NSMenu *mainMenu = [[NSMenu alloc] initWithTitle:@"MainMenu"];
  NSString *appName = [[NSProcessInfo processInfo] processName];

  NSMenu *appMenu = [[NSMenu alloc] initWithTitle:appName];
  [appMenu addItemWithTitle:[NSString stringWithFormat:@"About %@", appName]
                      action:@selector(orderFrontStandardAboutPanel:)
               keyEquivalent:@""];
  [appMenu addItem:[NSMenuItem separatorItem]];
  [appMenu addItemWithTitle:[NSString stringWithFormat:@"Hide %@", appName]
                      action:@selector(hide:)
               keyEquivalent:@"h"];
  [appMenu addItemWithTitle:@"Hide Others"
                      action:@selector(hideOtherApplications:)
               keyEquivalent:@""];
  [appMenu addItemWithTitle:@"Show All"
                      action:@selector(unhideAllApplications:)
               keyEquivalent:@""];
  [appMenu addItem:[NSMenuItem separatorItem]];
  [appMenu addItemWithTitle:[NSString stringWithFormat:@"Quit %@", appName]
                      action:@selector(terminate:)
               keyEquivalent:@"q"];
  NSMenuItem *appItem = [mainMenu addItemWithTitle:appName action:NULL keyEquivalent:@""];
  [mainMenu setSubmenu:appMenu forItem:appItem];

  NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
  [fileMenu addItemWithTitle:@"Add Book…"
                       action:@selector(addBookFromMenu:)
                keyEquivalent:@"o"];
  [fileMenu addItemWithTitle:@"Open Library"
                       action:@selector(showShelf:)
                keyEquivalent:@""];
  NSMenuItem *fileItem = [mainMenu addItemWithTitle:@"File" action:NULL keyEquivalent:@""];
  [mainMenu setSubmenu:fileMenu forItem:fileItem];

  NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
  [editMenu addItemWithTitle:@"Undo" action:@selector(undo:) keyEquivalent:@"z"];
  [editMenu addItemWithTitle:@"Redo" action:@selector(redo:) keyEquivalent:@"Z"];
  [editMenu addItem:[NSMenuItem separatorItem]];
  [editMenu addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
  [editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
  [editMenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
  [editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
  NSMenuItem *editItem = [mainMenu addItemWithTitle:@"Edit" action:NULL keyEquivalent:@""];
  [mainMenu setSubmenu:editMenu forItem:editItem];

  NSMenu *windowMenu = [[NSMenu alloc] initWithTitle:@"Window"];
  [windowMenu addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
  [windowMenu addItemWithTitle:@"Zoom" action:@selector(performZoom:) keyEquivalent:@""];
  [windowMenu addItem:[NSMenuItem separatorItem]];
  [windowMenu addItemWithTitle:@"Bring All to Front"
                        action:@selector(arrangeInFront:)
                 keyEquivalent:@""];
  NSMenuItem *windowItem = [mainMenu addItemWithTitle:@"Window" action:NULL keyEquivalent:@""];
  [mainMenu setSubmenu:windowMenu forItem:windowItem];
  [NSApp setWindowsMenu:windowMenu];

  NSMenu *helpMenu = [[NSMenu alloc] initWithTitle:@"Help"];
  NSMenuItem *helpItem = [mainMenu addItemWithTitle:@"Help" action:NULL keyEquivalent:@""];
  [mainMenu setSubmenu:helpMenu forItem:helpItem];

  [NSApp setMainMenu:mainMenu];
}

- (void)addBookFromMenu:(id)sender
{
  if (_shelf == nil) _shelf = [[BookshelfController alloc] init];
  [_shelf addBook:sender];
}

- (void)showShelf:(id)sender
{
  if (_shelf == nil) _shelf = [[BookshelfController alloc] init];
  [_shelf showWindow:self];
}

- (BOOL)application:(NSApplication *)app openFile:(NSString *)filename
{
  if ([[filename pathExtension] caseInsensitiveCompare:@"epub"] == NSOrderedSame)
    {
      _launchedWithFile = YES;
      [[LibraryStore sharedStore] addBookAtPath:filename];
      if (_shelf == nil) _shelf = [[BookshelfController alloc] init];
      if ([_shelf openBookForPath:filename])
        return YES;
      [_shelf showWindow:self];
      return YES;
    }
  return NO;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app
{
  // The shelf is kept open (only hidden) while a book is being read and is
  // brought back when the last reader closes, so reaching zero windows means
  // the user closed the shelf itself: quit.
  return YES;
}

@end
