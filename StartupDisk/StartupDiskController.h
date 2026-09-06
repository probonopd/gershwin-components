/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

@class EasyDragTableView;

@interface StartupDiskController : NSObject <NSTableViewDataSource, NSTableViewDelegate>
{
    NSView *mainView;
    NSScrollView *scrollView;
    NSTableView *tableView;
    NSTextField *titleLabel;
    NSTextField *instructionLabel;
    NSButton *restartButton;
    NSMutableArray *bootEntries;
    BOOL bootOrderChanged;
    
    // Helper process for sudo operations
    NSTask *helperTask;
    NSPipe *helperInput;
    NSPipe *helperOutput;
    NSFileHandle *helperInputHandle;
    NSFileHandle *helperOutputHandle;
    
    // Guards against overlapping background fetches / helper use
    BOOL isFetching;
    NSLock *helperLock;
}

- (void)setMainView:(NSView *)view;
- (void)setupUI;
- (void)relayoutWithWidth:(CGFloat)width;
- (void)refreshBootEntries;
- (void)updateBootEntriesDisplay;
- (void)applyBootOrder:(id)sender;
- (void)restartClicked:(id)sender;
- (void)showBootErrorAlert:(NSDictionary *)alertInfo;
- (void)showSystemErrorAlert:(NSDictionary *)alertInfo;
- (void)showBootOrderErrorAlert:(NSString *)errorMessage;
- (BOOL)startHelperProcess;
- (BOOL)startHelperProcessLocked;
- (void)stopHelperProcess;
- (BOOL)sendHelperCommand:(NSString *)command withResponse:(NSString **)response withError:(NSString **)error;
- (BOOL)sendHelperCommandLocked:(NSString *)command withResponse:(NSString **)response withError:(NSString **)error;
- (void)fetchBootEntriesInBackground;
- (void)handleBootEntriesResult:(NSDictionary *)resultDict;
- (NSImage *)iconForBootEntry:(NSDictionary *)entry;

@end

@interface EasyDragTableView : NSTableView
{
    BOOL isDragging;
    NSPoint dragStartPoint;
}

- (BOOL)writeRowsWithIndexes:(NSIndexSet *)rowIndexes toPasteboard:(NSPasteboard *)pboard;

@end
