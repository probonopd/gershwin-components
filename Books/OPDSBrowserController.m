/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "OPDSBrowserController.h"
#import "OPDSFeedParser.h"
#import "OPDSEntry.h"
#import "LibraryStore.h"
#import "LibraryBook.h"

static const CGFloat kBarHeight = 44.0;

@interface OPDSBrowserController () <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, strong) NSSearchField *searchField;
@property (nonatomic, strong) NSPopUpButton *feedPopup;
@property (nonatomic, strong) NSButton *downloadButton;
@property (nonatomic, strong) NSButton *reloadButton;
@property (nonatomic, strong) NSTableView *tableView;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) NSProgressIndicator *spinner;
@property (nonatomic, strong) OPDSFeedParser *parser;
@property (nonatomic, strong) NSArray<OPDSEntry *> *entries;
@property (nonatomic, strong) NSArray<NSDictionary *> *feeds;
@end

@implementation OPDSBrowserController

- (instancetype)initWithFeedURL:(NSURL *)url title:(NSString *)title
{
  self = [super initWithWindow:nil];
  if (self)
    {
      _parser = [[OPDSFeedParser alloc] init];
      _entries = [NSArray array];
      [self loadFeeds];
      [self buildWindow];
      if (url != nil)
        {
          NSUInteger idx = [self indexOfFeedWithURL:url];
          if (idx != NSNotFound)
            [_feedPopup selectItemAtIndex:idx];
        }
      [self fetchCurrentFeed];
    }
  return self;
}

#pragma mark - Feed list

- (void)loadFeeds
{
  NSString *path = [[NSBundle mainBundle] pathForResource:@"BooksInfo" ofType:@"plist"];
  NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:path];
  _feeds = info[@"OPDSFeeds"];
  if (_feeds == nil) _feeds = @[];
}

- (NSUInteger)indexOfFeedWithURL:(NSURL *)url
{
  NSString *target = [url absoluteString];
  for (NSUInteger i = 0; i < [_feeds count]; i++)
    {
      NSString *u = _feeds[i][@"URL"];
      if ([u isEqualToString:target]) return i;
    }
  return NSNotFound;
}

#pragma mark - UI

- (void)buildWindow
{
  NSRect screen = [[NSScreen mainScreen] frame];
  NSRect r = NSMakeRect(0, 0, 720, 520);
  r.origin.x = (screen.size.width - r.size.width) / 2.0;
  r.origin.y = (screen.size.height - r.size.height) / 2.0;

  NSWindow *win = [[NSWindow alloc]
      initWithContentRect:r
                styleMask:(NSTitledWindowMask | NSClosableWindowMask |
                           NSResizableWindowMask | NSMiniaturizableWindowMask)
                  backing:NSBackingStoreBuffered
                    defer:NO];
  [win setTitle:@"Book Store"];
  [win setMinSize:NSMakeSize(480, 300)];
  self.window = win;

  NSView *content = [win contentView];

  // --- Toolbar bar ---
  NSRect barFrame = NSMakeRect(0, r.size.height - kBarHeight,
                               r.size.width, kBarHeight);
  NSView *topBar = [[NSView alloc] initWithFrame:barFrame];
  [topBar setAutoresizingMask:(NSViewWidthSizable | NSViewMinYMargin)];
  [content addSubview:topBar];

  // Feed popup
  _feedPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 9, 160, 26)
                                               pullsDown:NO];
  for (NSDictionary *f in _feeds)
    [_feedPopup addItemWithTitle:f[@"Name"] ?: f[@"URL"]];
  [_feedPopup setTarget:self];
  [_feedPopup setAction:@selector(feedChanged:)];
  [topBar addSubview:_feedPopup];

  // Search field
  _searchField = [[NSSearchField alloc] initWithFrame:NSMakeRect(0, 9, 180, 26)];
  [_searchField setPlaceholderString:@"Search"];
  [_searchField setTarget:self];
  [_searchField setAction:@selector(searchEntered:)];
  [topBar addSubview:_searchField];

  // Reload button
  _reloadButton = [[NSButton alloc] initWithFrame:NSMakeRect(0, 9, 60, 26)];
  [_reloadButton setTitle:@"Reload"];
  [_reloadButton setBezelStyle:NSRoundedBezelStyle];
  [_reloadButton setTarget:self];
  [_reloadButton setAction:@selector(reloadFeed:)];
  [topBar addSubview:_reloadButton];

  // Download button (right-aligned)
  _downloadButton = [[NSButton alloc] initWithFrame:NSMakeRect(0, 9, 80, 26)];
  [_downloadButton setTitle:@"Download"];
  [_downloadButton setBezelStyle:NSRoundedBezelStyle];
  [_downloadButton setTarget:self];
  [_downloadButton setAction:@selector(downloadSelected:)];
  [_downloadButton setEnabled:NO];
  [topBar addSubview:_downloadButton];

  // Status label
  _statusLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 12, 200, 20)];
  [_statusLabel setBezeled:NO];
  [_statusLabel setEditable:NO];
  [_statusLabel setSelectable:NO];
  [_statusLabel setDrawsBackground:NO];
  [_statusLabel setFont:[NSFont systemFontOfSize:11]];
  [_statusLabel setStringValue:@"Ready"];
  [topBar addSubview:_statusLabel];

  // Spinner
  _spinner = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(0, 9, 18, 18)];
  [_spinner setStyle:NSProgressIndicatorSpinningStyle];
  [_spinner setDisplayedWhenStopped:NO];
  [topBar addSubview:_spinner];

  // Layout toolbar
  CGFloat Y = (kBarHeight - 26.0) / 2.0;
  CGFloat x = 16.0;
  for (NSView *v in @[_feedPopup, _searchField, _reloadButton, _statusLabel, _spinner])
    {
      NSRect f = [v frame];
      f.origin.x = x;
      f.origin.y = Y;
      f.size.height = 26.0;
      [v setFrame:f];
      x += f.size.width + 8.0;
    }
  // Right-align the download button.
  NSRect df = [_downloadButton frame];
  df.origin.x = r.size.width - df.size.width - 16.0;
  df.origin.y = Y;
  df.size.height = 26.0;
  [_downloadButton setFrame:df];
  [_downloadButton setAutoresizingMask:(NSViewMinXMargin)];

  // --- Table view ---
  NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:
      NSMakeRect(0, 0, r.size.width, r.size.height - kBarHeight)];
  [scroll setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];
  [scroll setHasVerticalScroller:YES];
  [scroll setBorderType:NSNoBorder];

  _tableView = [[NSTableView alloc] initWithFrame:NSZeroRect];
  [_tableView setDataSource:self];
  [_tableView setDelegate:self];
  [_tableView setAllowsMultipleSelection:NO];
  [_tableView setUsesAlternatingRowBackgroundColors:YES];

  NSTableColumn *titleCol = [[NSTableColumn alloc] initWithIdentifier:@"title"];
  [titleCol setTitle:@"Title"];
  [titleCol setWidth:250];
  [_tableView addTableColumn:titleCol];

  NSTableColumn *authorCol = [[NSTableColumn alloc] initWithIdentifier:@"author"];
  [authorCol setTitle:@"Author"];
  [authorCol setWidth:180];
  [_tableView addTableColumn:authorCol];

  NSTableColumn *summaryCol = [[NSTableColumn alloc] initWithIdentifier:@"summary"];
  [summaryCol setTitle:@"Summary"];
  [summaryCol setWidth:250];
  [_tableView addTableColumn:summaryCol];

  [scroll setDocumentView:_tableView];
  [content addSubview:scroll];
}

#pragma mark - Feed operations

- (NSURL *)currentFeedURL
{
  NSUInteger idx = [_feedPopup indexOfSelectedItem];
  if (idx >= [_feeds count]) return nil;
  return [NSURL URLWithString:_feeds[idx][@"URL"]];
}

- (void)fetchCurrentFeed
{
  NSURL *url = [self currentFeedURL];
  if (url == nil) return;

  [_spinner startAnimation:nil];
  [_statusLabel setStringValue:@"Loading..."];
  [_downloadButton setEnabled:NO];

  __weak typeof(self) weakSelf = self;
  [_parser fetchFeedAtURL:url searchFor:nil completion:^(NSArray<OPDSEntry *> *entries,
                                                          NSString *feedTitle,
                                                          NSError *error) {
    __strong typeof(self) self = weakSelf;
    if (self == nil) return;
    if (error != nil)
      {
        [self.spinner stopAnimation:nil];
        [self.statusLabel setStringValue:[error localizedDescription]];
        return;
      }
    if (feedTitle != nil)
      [self.window setTitle:feedTitle];
    // Resolve EPUB download links from per-book subsection feeds.
    [self.statusLabel setStringValue:@"Resolving downloads..."];
    [self.parser resolveEPUBLinksForEntries:entries completion:^(NSArray<OPDSEntry *> *resolved) {
      [self.spinner stopAnimation:nil];
      self.entries = resolved;
      [self.tableView reloadData];
      NSString *count = [NSString stringWithFormat:@"%lu EPUBs", (unsigned long)[resolved count]];
      [self.statusLabel setStringValue:count];
    }];
  }];
}

- (void)fetchSearchResults:(NSString *)query
{
  NSURL *url = [self currentFeedURL];
  if (url == nil) return;

  [_spinner startAnimation:nil];
  [_statusLabel setStringValue:@"Searching..."];
  [_downloadButton setEnabled:NO];

  __weak typeof(self) weakSelf = self;
  [_parser fetchFeedAtURL:url searchFor:query completion:^(NSArray<OPDSEntry *> *entries,
                                                           NSString *feedTitle,
                                                           NSError *error) {
    __strong typeof(self) self = weakSelf;
    if (self == nil) return;
    if (error != nil)
      {
        [self.spinner stopAnimation:nil];
        [self.statusLabel setStringValue:[error localizedDescription]];
        return;
      }
    // Resolve EPUB download links from per-book subsection feeds.
    [self.statusLabel setStringValue:@"Resolving downloads..."];
    [self.parser resolveEPUBLinksForEntries:entries completion:^(NSArray<OPDSEntry *> *resolved) {
      [self.spinner stopAnimation:nil];
      self.entries = resolved;
      [self.tableView reloadData];
      NSString *count = [NSString stringWithFormat:@"%lu EPUBs", (unsigned long)[resolved count]];
      [self.statusLabel setStringValue:count];
    }];
  }];
}

#pragma mark - Actions

- (void)feedChanged:(id)sender
{
  [self fetchCurrentFeed];
}

- (void)searchEntered:(id)sender
{
  NSString *query = [_searchField stringValue];
  if ([query length] == 0)
    {
      [self fetchCurrentFeed];
      return;
    }
  [self fetchSearchResults:query];
}

- (void)reloadFeed:(id)sender
{
  [self fetchCurrentFeed];
}

- (void)downloadSelected:(id)sender
{
  NSInteger row = [_tableView selectedRow];
  if (row < 0 || row >= (NSInteger)[_entries count]) return;
  OPDSEntry *entry = _entries[row];
  if (entry.epubURL == nil)
    {
      NSAlert *a = [NSAlert alertWithMessageText:@"No Download"
                                    defaultButton:@"OK"
                                  alternateButton:nil
                                      otherButton:nil
                        informativeTextWithFormat:@"This entry has no EPUB download link."];
      [a runModal];
      return;
    }

  [_spinner startAnimation:nil];
  [_statusLabel setStringValue:@"Downloading..."];
  [_downloadButton setEnabled:NO];

  __weak typeof(self) weakSelf = self;
  [_parser downloadEPUBAtURL:entry.epubURL
                  completion:^(NSString *path, NSError *error) {
    __strong typeof(self) self = weakSelf;
    if (self == nil) return;
    [self.spinner stopAnimation:nil];
    if (error != nil)
      {
        [self.statusLabel setStringValue:[error localizedDescription]];
        return;
      }

    // Add to library.
    [[LibraryStore sharedStore] addBookAtPath:path];
    NSString *msg = [NSString stringWithFormat:@"Added: %@", entry.title ?: @"book"];
    [self.statusLabel setStringValue:msg];
    [self.downloadButton setEnabled:YES];
  }];
}

#pragma mark - NSTableViewDataSource

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
  return [_entries count];
}

- (id)tableView:(NSTableView *)tableView
objectValueForTableColumn:(NSTableColumn *)tableColumn
            row:(NSInteger)row
{
  if (row < 0 || row >= (NSInteger)[_entries count]) return nil;
  OPDSEntry *e = _entries[row];
  NSString *ident = [tableColumn identifier];
  if ([ident isEqualToString:@"title"]) return e.title ?: @"";
  if ([ident isEqualToString:@"author"]) return e.author ?: @"";
  if ([ident isEqualToString:@"summary"]) return e.summary ?: @"";
  return @"";
}

#pragma mark - NSTableViewDelegate

- (void)tableViewSelectionDidChange:(NSNotification *)notification
{
  BOOL enabled = ([_tableView selectedRow] >= 0);
  [_downloadButton setEnabled:enabled];
}

@end
