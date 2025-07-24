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
}

- (void)setMainView:(NSView *)view;
- (void)refreshBootEntries;
- (void)setupUI;
- (void)updateBootEntriesDisplay;
- (void)bootEntrySelected:(id)sender;
- (void)restartClicked:(id)sender;
- (void)showBootErrorAlert:(NSDictionary *)alertInfo;
- (void)showSystemErrorAlert:(NSDictionary *)alertInfo;

@end
