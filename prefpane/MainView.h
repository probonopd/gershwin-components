#import <Cocoa/Cocoa.h>

@interface MainView : NSView
@property (nonatomic, strong) NSScrollView *tableScrollView;
@property (nonatomic, strong) NSTableView *tableView;
@property (nonatomic, strong) NSButton *createButton;
@property (nonatomic, strong) NSButton *editButton;
@property (nonatomic, strong) NSButton *deleteButton;
@property (nonatomic, strong) NSButton *setActiveButton;
@end
