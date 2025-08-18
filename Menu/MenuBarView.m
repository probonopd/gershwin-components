#import "MenuBarView.h"

@implementation MenuBarView

- (id)initWithFrame:(NSRect)frameRect
{
    self = [super initWithFrame:frameRect];
    if (self) {
        _backgroundColor = [[NSColor colorWithCalibratedWhite:0.95 alpha:0.95] retain];
        
        NSColor *topColor = [NSColor colorWithCalibratedWhite:0.98 alpha:0.95];
        NSColor *bottomColor = [NSColor colorWithCalibratedWhite:0.92 alpha:0.95];
        _backgroundGradient = [[NSGradient alloc] initWithStartingColor:topColor 
                                                            endingColor:bottomColor];
    }
    return self;
}

- (void)drawRect:(NSRect)dirtyRect
{
    NSLog(@"MenuBarView: drawRect called with rect: %.0f,%.0f %.0fx%.0f", 
          dirtyRect.origin.x, dirtyRect.origin.y, dirtyRect.size.width, dirtyRect.size.height);
    
    // Fill with solid color first for debugging
    [[NSColor colorWithCalibratedRed:0.9 green:0.9 blue:0.9 alpha:1.0] set];
    NSRectFill([self bounds]);
    
    // Draw background gradient
    if (_backgroundGradient) {
        [_backgroundGradient drawInRect:[self bounds] angle:90.0];
        NSLog(@"MenuBarView: Drew background gradient");
    } else {
        NSLog(@"MenuBarView: Warning - no background gradient");
    }
    
    // Draw bottom border
    NSRect borderRect = NSMakeRect(0, 0, [self bounds].size.width, 1);
    [[NSColor colorWithCalibratedWhite:0.8 alpha:1.0] set];
    NSRectFill(borderRect);
    NSLog(@"MenuBarView: Drew bottom border");
}

- (BOOL)isOpaque
{
    return NO;
}

- (void)dealloc
{
    [_backgroundColor release];
    [_backgroundGradient release];
    [super dealloc];
}

@end
