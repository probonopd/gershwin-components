/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "MenuExtrasPrefPanel.h"
#import "MenuExtraManager.h"
#import "GSMenuExtraInstance.h"

@interface MenuExtrasPrefPanel () <NSTableViewDataSource, NSTableViewDelegate>
{
    NSArray<GSMenuExtraInstance *> *_allItems;
    MenuExtraManager *_manager;
    NSMutableSet<NSString *> *_enabledIdentifiers;
    NSTableView *_tableView;
    NSButton *_closeButton;
}
@end

@implementation MenuExtrasPrefPanel

- (instancetype)initWithManager:(MenuExtraManager *)manager
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
        _allItems = [[_manager allMenuExtras] copy];
        _enabledIdentifiers = [NSMutableSet set];
        [self readEnabledState];
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
    [[nameCol headerCell] setStringValue:@"Extra"];
    [nameCol setWidth:350];
    [_tableView addTableColumn:nameCol];

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

- (void)reloadExtras
{
    _allItems = [[_manager allMenuExtras] copy];
    [self readEnabledState];
    [_tableView reloadData];
}

- (void)readEnabledState
{
    [_enabledIdentifiers removeAllObjects];
    NSArray *savedEnabled = [[NSUserDefaults standardUserDefaults] arrayForKey:@"GSMenuExtraEnabled"];
    if ([savedEnabled isKindOfClass:[NSArray class]] && [savedEnabled count] > 0) {
        [_enabledIdentifiers addObjectsFromArray:savedEnabled];
    } else {
        for (GSMenuExtraInstance *inst in _allItems) {
            [_enabledIdentifiers addObject:[inst identifier]];
        }
    }
}

- (void)updateBundleList
{
    [_tableView reloadData];
}

- (void)closePanel:(id)sender
{
    (void)sender;

    NSMutableArray *enabledArray = [NSMutableArray array];
    for (GSMenuExtraInstance *inst in _allItems) {
        if ([_enabledIdentifiers containsObject:[inst identifier]]) {
            [enabledArray addObject:[inst identifier]];
        }
    }
    [[NSUserDefaults standardUserDefaults] setObject:enabledArray forKey:@"GSMenuExtraEnabled"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [_manager reloadEnabledFromDefaults];

    [[self window] close];
}

#pragma mark - NSTableViewDataSource

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
    (void)tableView;
    return [_allItems count];
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)tableColumn
            row:(NSInteger)row
{
    (void)tableView;
    if (row < 0 || row >= (NSInteger)[_allItems count]) return @"";

    GSMenuExtraInstance *inst = [_allItems objectAtIndex:(NSUInteger)row];
    NSString *colId = [tableColumn identifier];

    if ([colId isEqualToString:@"enabled"]) {
        return @([_enabledIdentifiers containsObject:[inst identifier]]);
    } else if ([colId isEqualToString:@"name"]) {
        return [inst displayName] ?: [inst identifier];
    }
    return @"";
}

- (void)tableView:(NSTableView *)tableView setObjectValue:(id)object
    forTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
    (void)tableView;
    (void)tableColumn;

    if (row < 0 || row >= (NSInteger)[_allItems count]) return;

    GSMenuExtraInstance *inst = [_allItems objectAtIndex:(NSUInteger)row];
    BOOL enabled = [object boolValue];
    if (enabled) {
        [_enabledIdentifiers addObject:[inst identifier]];
    } else {
        [_enabledIdentifiers removeObject:[inst identifier]];
    }
}

@end
