#import "MenuBarView.h"

@implementation MenuBarView

- (id)initWithFrame:(NSRect)frameRect
{
    self = [super initWithFrame:frameRect];
    if (self) {
        // Use the theme's menubar background color instead of hardcoded values
        _backgroundColor = [[[GSTheme theme] menuItemBackgroundColor] retain];
    }
    return self;
}

- (void)drawRect:(NSRect)dirtyRect
{
    NSLog(@"MenuBarView: drawRect called with rect: %.0f,%.0f %.0fx%.0f", 
          dirtyRect.origin.x, dirtyRect.origin.y, dirtyRect.size.width, dirtyRect.size.height);
    
    // Fill with theme background color (no gradient)
    if (_backgroundColor) {
        [_backgroundColor set];
        NSRectFill([self bounds]);
        NSLog(@"MenuBarView: Drew theme background color: %@", _backgroundColor);
    } else {
        // Fallback to light gray if theme color is unavailable
        [[NSColor colorWithCalibratedWhite:0.95 alpha:1.0] set];
        NSRectFill([self bounds]);
        NSLog(@"MenuBarView: Warning - used fallback background color");
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
    [super dealloc];
}

@end
