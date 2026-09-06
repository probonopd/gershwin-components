/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "HotspotTableController.h"

@implementation HotspotTableController
{
    NSArray *_rows;
}

- (void)setRows:(NSArray *)rows
{
    [_rows release];
    _rows = [rows copy];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
    (void)tableView;
    return [_rows count];
}

- (id)tableView:(NSTableView *)tableView
 objectValueForTableColumn:(NSTableColumn *)column
           row:(NSInteger)row
{
    (void)tableView;
    NSDictionary *item = _rows[row];
    return item[column.identifier] ?: @"";
}

- (void)configureTable:(NSTableView *)table
{
    NSTableColumn *name = [[[NSTableColumn alloc] initWithIdentifier:@"name"] autorelease];
    [[name headerCell] setStringValue:@"Function / Method"];
    [name setWidth:360];

    NSTableColumn *percent = [[[NSTableColumn alloc] initWithIdentifier:@"percent"] autorelease];
    [[percent headerCell] setStringValue:@"Samples"];
    [percent setWidth:100];

    [table addTableColumn:name];
    [table addTableColumn:percent];
    table.dataSource = self;
    table.delegate = self;
}

- (void)dealloc
{
    [_rows release];
    [super dealloc];
}

@end
