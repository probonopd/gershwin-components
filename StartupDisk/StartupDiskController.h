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
