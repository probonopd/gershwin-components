#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import "GNUstepGUI/GSTheme.h"

@interface MenuBarView : NSView
{
    NSColor *_backgroundColor;
}

- (void)drawRect:(NSRect)dirtyRect;

@end
