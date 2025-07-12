#import <Cocoa/Cocoa.h>

@interface MainView : NSView
@property (nonatomic, strong) NSScrollView *tableScrollView;
@property (nonatomic, strong) NSArray<NSButton *> *buttonArray;
@end
