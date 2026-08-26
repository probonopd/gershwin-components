/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>
#import "BookshelfController.h"
#import "BookshelfView.h"
#import "LibraryStore.h"
#import "LibraryBook.h"
#import "BookReaderController.h"

@interface BookshelfController () <BookshelfViewDelegate, NSWindowDelegate>
@property (nonatomic, strong) BookshelfView *shelf;
@property (nonatomic, strong) NSScrollView *scroll;
@property (nonatomic, strong) NSMutableArray<BookReaderController *> *openReaders;
@end

@implementation BookshelfController

- (instancetype)init
{
  self = [super initWithWindow:nil];
  if (self)
    {
      [self buildWindow];
    }
  return self;
}

- (void)buildWindow
{
  NSRect screen = [[NSScreen mainScreen] frame];
  NSRect r = NSMakeRect(0, 0, 940, 660);
  r.origin.x = (screen.size.width - r.size.width) / 2.0;
  r.origin.y = (screen.size.height - r.size.height) / 2.0;

  NSWindow *win = [[NSWindow alloc]
      initWithContentRect:r
                styleMask:(NSTitledWindowMask | NSClosableWindowMask |
                           NSResizableWindowMask | NSMiniaturizableWindowMask)
                  backing:NSBackingStoreBuffered
                    defer:NO];
  [win setTitle:@"Books"];
  [win setMinSize:NSMakeSize(520, 380)];
  [win setDelegate:self];
  self.window = win;

  NSView *content = [win contentView];
  NSRect bar = NSMakeRect(0, r.size.height - 46, r.size.width, 46);
  NSView *toolbar = [[NSView alloc] initWithFrame:bar];
  [toolbar setAutoresizingMask:(NSViewWidthSizable | NSViewMinYMargin)];
  [self addButtonTo:toolbar title:@"Add Book" action:@selector(addBook:) x:16];
  [self addButtonTo:toolbar title:@"Open" action:@selector(openSelected:) x:116];
  [self addButtonTo:toolbar title:@"Remove" action:@selector(removeSelected:) x:206];
  [content addSubview:toolbar];

  NSRect sv = NSMakeRect(0, 0, r.size.width, r.size.height - 46);
  _scroll = [[NSScrollView alloc] initWithFrame:sv];
  [_scroll setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];
  [_scroll setHasVerticalScroller:YES];
  [_scroll setBorderType:NSNoBorder];
  _shelf = [[BookshelfView alloc] initWithFrame:NSMakeRect(0, 0, sv.size.width, sv.size.height)];
  [_shelf setAutoresizingMask:NSViewWidthSizable];
  [  _shelf setDelegate:self];
  [_scroll setDocumentView:_shelf];
  [content addSubview:_scroll];

  _openReaders = [NSMutableArray array];
  [self reload];
}

- (void)addButtonTo:(NSView *)parent title:(NSString *)title action:(SEL)action x:(CGFloat)x
{
  NSButton *b = [[NSButton alloc] initWithFrame:NSMakeRect(x, 9, 92, 28)];
  [b setBezelStyle:NSRoundedBezelStyle];
  [b setTitle:title];
  [b setTarget:self];
  [b setAction:action];
  [parent addSubview:b];
}

- (void)reload
{
  [_shelf setBooks:[[LibraryStore sharedStore] books]];
}

- (void)addBook:(id)sender
{
  NSOpenPanel *panel = [NSOpenPanel openPanel];
  [panel setAllowedFileTypes:@[ @"epub" ]];
  [panel setAllowsMultipleSelection:YES];
  [panel setTitle:@"Add EPUB Books"];
  NSInteger rc = [panel runModal];
  if (rc == NSOKButton)
    {
      for (NSURL *u in [panel URLs])
        [[LibraryStore sharedStore] addBookAtPath:[u path]];
      [self reload];
    }
}

- (void)openSelected:(id)sender
{
  if (_shelf.selectedIndex < 0) return;
  NSArray *books = [[LibraryStore sharedStore] books];
  if (_shelf.selectedIndex >= (NSInteger)[books count]) return;
  [self openBook:books[_shelf.selectedIndex]];
}

- (void)removeSelected:(id)sender
{
  if (_shelf.selectedIndex < 0) return;
  NSArray *books = [[LibraryStore sharedStore] books];
  if (_shelf.selectedIndex >= (NSInteger)[books count]) return;
  [[LibraryStore sharedStore] removeBook:books[_shelf.selectedIndex]];
  _shelf.selectedIndex = -1;
  [self reload];
}

- (BOOL)openBook:(LibraryBook *)book
{
  if (![[NSFileManager defaultManager] fileExistsAtPath:book.epubPath])
    {
      NSAlert *a = [NSAlert alertWithMessageText:@"Book not found"
                                    defaultButton:@"OK"
                                  alternateButton:nil
                                      otherButton:nil
                        informativeTextWithFormat:
                          @"The file %@ could not be found.", book.epubPath];
      [a runModal];
      return NO;
    }
  BookReaderController *reader = [[BookReaderController alloc] initWithLibraryBook:book];
  if (reader == nil) return NO;
  NSRect screenRect;
  if (_shelf.selectedIndex >= 0)
    {
      NSRect shelfRect = [_shelf rectForBookAtIndex:_shelf.selectedIndex];
      NSRect localRect = [_shelf convertRect:shelfRect toView:nil];
      NSPoint p = [[self window] convertBaseToScreen:localRect.origin];
      screenRect = localRect;
      screenRect.origin = p;
    }
  else
    {
      NSRect sr = [[NSScreen mainScreen] frame];
      screenRect = NSMakeRect(NSMidX(sr) - 120, NSMidY(sr) - 120, 240, 240);
    }
  [reader showWithZoomFromRect:screenRect];
  [_openReaders addObject:reader];
  [[LibraryStore sharedStore] setCurrentBookPath:book.epubPath];
  // A book is open: hide the bookshelf until every reader is closed again.
  [[self window] orderOut:nil];
  [[NSNotificationCenter defaultCenter]
      addObserver:self
         selector:@selector(readerWindowWillClose:)
             name:NSWindowWillCloseNotification
           object:reader.window];
  return YES;
}

- (LibraryBook *)bookForPath:(NSString *)path
{
  NSString *std = [path stringByStandardizingPath];
  for (LibraryBook *b in [[LibraryStore sharedStore] books])
    if ([[b.epubPath stringByStandardizingPath] isEqualToString:std])
      return b;
  return nil;
}

- (BOOL)openBookForPath:(NSString *)path
{
  LibraryBook *b = [self bookForPath:path];
  if (b == nil) return NO;
  return [self openBook:b];
}

- (void)readerWindowWillClose:(NSNotification *)note
{
  NSWindow *win = [note object];
  for (NSUInteger i = 0; i < [_openReaders count]; i++)
    {
      if (_openReaders[i].window == win)
        {
          [[NSNotificationCenter defaultCenter] removeObserver:self
                                                          name:NSWindowWillCloseNotification
                                                        object:win];
          [_openReaders removeObjectAtIndex:i];
          break;
        }
    }
  // No readers left: forget the open book and bring the shelf back.
  if ([_openReaders count] == 0)
    {
      [[LibraryStore sharedStore] setCurrentBookPath:nil];
      [self reload];
      [self showWindow:self];
    }
  else
    {
      [[LibraryStore sharedStore] setCurrentBookPath:[[_openReaders lastObject] libraryBook].epubPath];
    }
}

#pragma mark - BookshelfViewDelegate

- (void)bookshelfDidRequestOpen:(LibraryBook *)book
{
  [self openBook:book];
}

- (void)bookshelfDidRequestAddFiles:(NSArray<NSString *> *)paths
{
  for (NSString *p in paths)
    [[LibraryStore sharedStore] addBookAtPath:p];
  [self reload];
}

- (void)bookshelfDidRequestDelete:(LibraryBook *)book
{
  [[LibraryStore sharedStore] removeBook:book];
  _shelf.selectedIndex = -1;
  [self reload];
}

#pragma mark - NSWindowDelegate

- (void)windowDidResize:(NSNotification *)note
{
  [_shelf reloadData];
}

- (void)showWindow:(id)sender
{
  [super showWindow:sender];
  [NSApp activateIgnoringOtherApps:YES];
}

@end
