#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

@interface RoundedCornersView : NSView
{
    CGFloat _cornerRadius;
}

- (id)initWithFrame:(NSRect)frameRect cornerRadius:(CGFloat)radius;
- (void)drawRect:(NSRect)dirtyRect;

@end
