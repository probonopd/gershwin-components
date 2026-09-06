/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>
#import "ProcessInfo.h"

@interface ProcessesController : NSObject <NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate, NSTextFieldDelegate>
{
    NSMutableArray *_processes;
    NSTimer *_refreshTimer;
    NSTimeInterval _refreshInterval;
    NSLock *_processesLock;
    
    // UI References
    NSWindow *_mainWindow;
    NSSearchField *_searchField;
    NSTableView *_processesTableView;
    NSDrawer *_infoDrawer;
    NSTextField *_infoTextField;
    NSButton *_forceQuitButton;

    NSArray *_sortDescriptors;
    NSMutableDictionary *_prevCpuTimes; // pid -> NSDictionary with keys: @"totalTicks", @"time"
    BOOL _isRefreshing;
    NSString *_searchFilter;
}

@property (nonatomic, strong) NSMutableArray *processes;

+ (ProcessesController *)sharedController;

// Process management
- (void)refreshProcesses;
- (void)startMonitoring;
- (void)stopMonitoring;

// Returns whether a refresh is currently running
- (BOOL)isRefreshing;

// UI Actions
- (void)setupMenu;
- (IBAction)forceQuitProcess:(id)sender;
- (void)clearSearchFilter;

// Sorting
- (void)sortProcesses;

// Table view data source
- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView;
- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row;

// Table view delegate
- (void)tableViewSelectionDidChange:(NSNotification *)notification;
- (void)tableView:(NSTableView *)tableView didClickTableColumn:(NSTableColumn *)tableColumn;
- (void)tableView:(NSTableView *)tableView sortDescriptorsDidChange:(NSArray *)oldDescriptors;

@end