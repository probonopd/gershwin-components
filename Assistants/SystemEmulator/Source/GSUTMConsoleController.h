#import <AppKit/AppKit.h>

@interface GSUTMConsoleController : NSWindowController

@property (nonatomic, strong, readonly) NSTextView *textView;

- (void)appendData:(NSData *)data;
- (void)clear;
- (void)setConsolePort:(int)port;

@end
