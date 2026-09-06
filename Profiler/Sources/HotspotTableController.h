/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

@interface HotspotTableController : NSObject <NSTableViewDataSource, NSTableViewDelegate>
- (void)setRows:(NSArray *)rows;
- (void)configureTable:(NSTableView *)table;
@end
