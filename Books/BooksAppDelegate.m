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
}

- (void)applicationWillFinishLaunching:(NSNotification *)notifier
{
  [self buildMainMenu];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notifier
{
  if (_shelf == nil)
    _shelf = [[BookshelfController alloc] init];
  [_shelf showWindow:self];
}

- (void)buildMainMenu
{
  NSMenu *mainMenu = [NSApp mainMenu];
  if (mainMenu == nil)
    {
      mainMenu = [[NSMenu alloc] initWithTitle:@"MainMenu"];
      [NSApp setMainMenu:mainMenu];
    }

  NSString *appName = [[NSProcessInfo processInfo] processName];
  NSMenu *appMenu = [[NSMenu alloc] initWithTitle:appName];
  NSMenuItem *appItem = (NSMenuItem *)[mainMenu addItemWithTitle:appName action:NULL keyEquivalent:@""];
  [mainMenu setSubmenu:appMenu forItem:appItem];
  [appMenu addItemWithTitle:[NSString stringWithFormat:@"About %@", appName]
                     action:@selector(orderFrontStandardAboutPanel:)
              keyEquivalent:@""];
  [appMenu addItem:[NSMenuItem separatorItem]];
  [appMenu addItemWithTitle:@"Add Book…"
                     action:@selector(addBookFromMenu:)
              keyEquivalent:@"o"];
  [appMenu addItem:[NSMenuItem separatorItem]];
  [appMenu addItemWithTitle:[NSString stringWithFormat:@"Quit %@", appName]
                     action:@selector(terminate:)
              keyEquivalent:@"q"];

  NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
  NSMenuItem *fileItem = (NSMenuItem *)[mainMenu addItemWithTitle:@"File" action:NULL keyEquivalent:@""];
  [mainMenu setSubmenu:fileMenu forItem:fileItem];
  [fileMenu addItemWithTitle:@"Open Library"
                      action:@selector(showShelf:)
               keyEquivalent:@""];

  [NSApp setMainMenu:mainMenu];
}

- (void)addBookFromMenu:(id)sender
{
  if (_shelf == nil) _shelf = [[BookshelfController alloc] init];
  [_shelf showWindow:self];
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
      [[LibraryStore sharedStore] addBookAtPath:filename];
      if (_shelf == nil) _shelf = [[BookshelfController alloc] init];
      [_shelf reload];
      [_shelf showWindow:self];
      return YES;
    }
  return NO;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app
{
  return NO;
}

@end
