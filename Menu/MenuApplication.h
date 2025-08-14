#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

@interface MenuApplication : NSApplication
{
}

- (void)sendEvent:(NSEvent *)event;

@end
