#import <AppKit/AppKit.h>

@interface StartupDiskController : NSObject
{
    NSView *mainView;
    NSScrollView *scrollView;
    NSView *contentView;
    NSTextField *titleLabel;
    NSTextField *selectedLabel;
    NSButton *restartButton;
    NSMutableArray *bootEntries;
    NSMutableArray *bootButtons;
    int selectedBootEntry;
    
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
- (void)bootEntrySelected:(id)sender;
- (void)restartClicked:(id)sender;
- (void)showBootErrorAlert:(NSDictionary *)alertInfo;
- (void)showSystemErrorAlert:(NSDictionary *)alertInfo;
- (BOOL)startHelperProcess;
- (void)stopHelperProcess;
- (BOOL)sendHelperCommand:(NSString *)command withResponse:(NSString **)response withError:(NSString **)error;
- (void)fetchBootEntriesInBackground;
- (void)handleBootEntriesResult:(NSDictionary *)resultDict;

@end
