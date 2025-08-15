#import "RoundedCornersView.h"

@implementation RoundedCornersView

- (id)initWithFrame:(NSRect)frameRect cornerRadius:(CGFloat)radius
{
    self = [super initWithFrame:frameRect];
    if (self) {
        _cornerRadius = radius;
    }
    return self;
}

- (id)initWithFrame:(NSRect)frameRect
{
    return [self initWithFrame:frameRect cornerRadius:5.0];
}

- (void)drawRect:(NSRect)dirtyRect
{
    // Draw black rounded corners on the top edges
    
    NSGraphicsContext *context = [NSGraphicsContext currentContext];
    [context saveGraphicsState];
    
    // Enable antialiasing for smooth corners
    [context setShouldAntialias:YES];
    
    NSRect bounds = [self bounds];
    CGFloat width = bounds.size.width;
    CGFloat height = bounds.size.height;
    
    // Set black color for the corner masks
    [[NSColor blackColor] setFill];
    
    // Left corner mask: draw the area that should be black (outside the rounded corner)
    NSBezierPath *leftCornerMask = [NSBezierPath bezierPath];
    [leftCornerMask moveToPoint:NSMakePoint(0, height)]; // Top-left corner
    [leftCornerMask lineToPoint:NSMakePoint(_cornerRadius, height)]; // Move right along top
    [leftCornerMask appendBezierPathWithArcWithCenter:NSMakePoint(_cornerRadius, height - _cornerRadius)
                                               radius:_cornerRadius
                                           startAngle:90.0   // Start at top
                                             endAngle:180.0  // End at left
                                            clockwise:NO];    // Counter-clockwise for outer curve
    [leftCornerMask lineToPoint:NSMakePoint(0, height - _cornerRadius)]; // Down to left edge
    [leftCornerMask closePath];
    [leftCornerMask fill];
    
    // Right corner mask: draw the area that should be black (outside the rounded corner)
    NSBezierPath *rightCornerMask = [NSBezierPath bezierPath];
    [rightCornerMask moveToPoint:NSMakePoint(width, height)]; // Top-right corner
    [rightCornerMask lineToPoint:NSMakePoint(width - _cornerRadius, height)]; // Move left along top
    [rightCornerMask appendBezierPathWithArcWithCenter:NSMakePoint(width - _cornerRadius, height - _cornerRadius)
                                                radius:_cornerRadius
                                            startAngle:90.0   // Start at top
                                              endAngle:0.0    // End at right
                                             clockwise:YES];   // Clockwise for outer curve
    [rightCornerMask lineToPoint:NSMakePoint(width, height - _cornerRadius)]; // Down to right edge
    [rightCornerMask closePath];
    [rightCornerMask fill];
    
    [context restoreGraphicsState];
}

- (BOOL)isOpaque
{
    return NO;
}

@end
