#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

@interface MenuBarView : NSView
{
    NSColor *_backgroundColor;
    NSGradient *_backgroundGradient;
}

- (void)drawRect:(NSRect)dirtyRect;

@end
