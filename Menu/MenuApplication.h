#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

@interface MenuApplication : NSApplication
{
}

+ (MenuApplication *)sharedApplication;
- (void)sendEvent:(NSEvent *)event;

@end
