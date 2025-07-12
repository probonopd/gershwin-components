#import <Cocoa/Cocoa.h>

@interface MainView : NSView
@property (nonatomic, strong) NSScrollView *tableScrollView;
@property (nonatomic, strong) NSTableView *tableView;
@property (nonatomic, strong) NSArray<NSButton *> *buttonArray;
- (void)setupWithTarget:(id)target actions:(SEL[])actions;
@end
