/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "MenuExtrasPrefPanel.h"
#import "StatusItemManager.h"

@interface MenuExtrasPrefPanel () <NSTableViewDataSource, NSTableViewDelegate>
{
    StatusItemManager *_manager;
    NSMutableSet<NSString *> *_enabledIdentifiers;
    NSTableView *_tableView;
    NSButton *_closeButton;
}
@end

@implementation MenuExtrasPrefPanel

- (instancetype)initWithManager:(StatusItemManager *)manager
{
    NSRect screenRect = [[NSScreen mainScreen] visibleFrame];
    NSRect winRect = NSMakeRect(0, 0, 420, 320);
    winRect.origin.x = NSMidX(screenRect) - NSWidth(winRect) / 2;
    winRect.origin.y = NSMidY(screenRect) - NSHeight(winRect) / 2;

    NSUInteger style = NSTitledWindowMask | NSClosableWindowMask |
                       NSMiniaturizableWindowMask | NSResizableWindowMask;

    NSWindow *window = [[NSWindow alloc] initWithContentRect:winRect
                                                   styleMask:style
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    [window setTitle:@"Menu Extras"];
    [window setReleasedWhenClosed:NO];

    self = [super initWithWindow:window];
    if (self) {
        _manager = manager;
        _enabledIdentifiers = [NSMutableSet set];

        for (id<StatusItemProvider> p in [_manager statusItems]) {
            [_enabledIdentifiers addObject:[p identifier]];
        }

        [self setupUI];
    }
    return self;
}

- (void)setupUI
{
    NSView *content = [[self window] contentView];

    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(20, 60, 380, 220)];
    [scrollView setHasVerticalScroller:YES];
    [scrollView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

    _tableView = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, 360, 200)];
    [_tableView setDataSource:self];
    [_tableView setDelegate:self];
    [_tableView setHeaderView:nil];
    [_tableView setAllowsMultipleSelection:NO];

    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"enabled"];
    [[col headerCell] setStringValue:@""];
    [col setWidth:30];
    [_tableView addTableColumn:col];

    NSTableColumn *nameCol = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    [[nameCol headerCell] setStringValue:@"Name"];
    [nameCol setWidth:160];
    [_tableView addTableColumn:nameCol];

    NSTableColumn *idCol = [[NSTableColumn alloc] initWithIdentifier:@"identifier"];
    [[idCol headerCell] setStringValue:@"Identifier"];
    [idCol setWidth:160];
    [_tableView addTableColumn:idCol];

    [scrollView setDocumentView:_tableView];
    [content addSubview:scrollView];

    _closeButton = [[NSButton alloc] initWithFrame:NSMakeRect(320, 20, 80, 28)];
    [_closeButton setTitle:@"Close"];
    [_closeButton setBezelStyle:NSRoundedBezelStyle];
    [_closeButton setTarget:self];
    [_closeButton setAction:@selector(closePanel:)];
    [_closeButton setAutoresizingMask:NSViewMinXMargin | NSViewMaxYMargin];
    [content addSubview:_closeButton];

    [self updateBundleList];
}

- (void)updateBundleList
{
    [_tableView reloadData];
}

- (void)closePanel:(id)sender
{
    (void)sender;

    NSMutableArray *enabledArray = [NSMutableArray array];
    for (id<StatusItemProvider> p in [_manager statusItems]) {
        if ([_enabledIdentifiers containsObject:[p identifier]]) {
            [enabledArray addObject:[p identifier]];
        }
    }
    [[NSUserDefaults standardUserDefaults] setObject:enabledArray forKey:@"GSMenuExtraEnabled"];
    [[NSUserDefaults standardUserDefaults] synchronize];

    [[self window] close];
}

#pragma mark - NSTableViewDataSource

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
    (void)tableView;
    return [[_manager statusItems] count];
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)tableColumn
            row:(NSInteger)row
{
    (void)tableView;
    NSArray *items = [_manager statusItems];
    if (row < 0 || row >= (NSInteger)[items count]) return @"";

    id<StatusItemProvider> p = [items objectAtIndex:(NSUInteger)row];
    NSString *colId = [tableColumn identifier];

    if ([colId isEqualToString:@"enabled"]) {
        return @([_enabledIdentifiers containsObject:[p identifier]]);
    } else if ([colId isEqualToString:@"name"]) {
        return [p identifier];
    } else if ([colId isEqualToString:@"identifier"]) {
        return [p identifier];
    }
    return @"";
}

- (void)tableView:(NSTableView *)tableView setObjectValue:(id)object
    forTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
    (void)tableView;
    (void)tableColumn;

    NSArray *items = [_manager statusItems];
    if (row < 0 || row >= (NSInteger)[items count]) return;

    id<StatusItemProvider> p = [items objectAtIndex:(NSUInteger)row];
    BOOL enabled = [object boolValue];
    if (enabled) {
        [_enabledIdentifiers addObject:[p identifier]];
    } else {
        [_enabledIdentifiers removeObject:[p identifier]];
    }
}

@end
