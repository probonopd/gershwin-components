/*
 * Copyright (c) 2005 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Cocoa/Cocoa.h>

@interface MainView : NSView
@property (nonatomic, strong) NSScrollView *tableScrollView;
@property (nonatomic, strong) NSTableView *tableView;
@property (nonatomic, strong) NSButton *createButton;
@property (nonatomic, strong) NSButton *editButton;
@property (nonatomic, strong) NSButton *deleteButton;
@property (nonatomic, strong) NSButton *setActiveButton;
@property (nonatomic, strong) NSButton *mountButton;
@property (nonatomic, strong) NSButton *unmountButton;
@end
