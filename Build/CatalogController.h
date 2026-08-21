/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

@interface CatalogController : NSObject <NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate>
{
    NSWindow *_window;
    NSTableView *_tableView;
    NSSearchField *_searchField;
    NSButton *_buildButton;
    NSArray *_entries;
    NSArray *_filteredEntries;
    BOOL _catalogRefreshStarted;
    NSProgressIndicator *_spinner;
    NSTextField *_statusLabel;
}

- (void)showWindow;

@end
