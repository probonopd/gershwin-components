/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

@interface MenuControllerPrefPane : NSObject <NSTableViewDataSource, NSTableViewDelegate>
{
    NSView *_mainView;
    NSMutableArray *_extras;
    NSMutableDictionary *_enabledMap;
    NSTableView *_tableView;
}

- (NSView *)createMainView;
- (void)refreshExtras;

@end
