#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

@interface MenuApplication : NSApplication <NSApplicationDelegate>
{
}

+ (MenuApplication *)sharedApplication;
- (void)sendEvent:(NSEvent *)event;

@end
