// Copyright (c) 2025, Simon Peter
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//
// 1. Redistributions of source code must retain the above copyright notice,
//    this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright notice,
//    this list of conditions and the following disclaimer in the documentation
//    and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
// ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
// LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGE.

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
}

- (void)setMainView:(NSView *)view;
- (void)refreshBootEntries;
- (void)setupUI;
- (void)updateBootEntriesDisplay;
- (void)applyBootOrder:(id)sender;
- (void)restartClicked:(id)sender;
- (void)showBootErrorAlert:(NSDictionary *)alertInfo;
- (void)showSystemErrorAlert:(NSDictionary *)alertInfo;
- (void)showBootOrderErrorAlert:(NSString *)errorMessage;
- (BOOL)startHelperProcess;
- (void)stopHelperProcess;
- (BOOL)sendHelperCommand:(NSString *)command withResponse:(NSString **)response withError:(NSString **)error;
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
