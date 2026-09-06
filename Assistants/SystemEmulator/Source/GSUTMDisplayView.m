#import "GSUTMDisplayView.h"
#import "AppearanceMetrics.h"

@interface GSUTMDisplayView ()
{
    BOOL _vmRunning;
}
@end

@implementation GSUTMDisplayView

- (instancetype)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        _vmRunning = NO;
    }
    return self;
}

- (void)setVMRunning:(BOOL)running
{
    _vmRunning = running;
    [self setNeedsDisplay:YES];
}

- (BOOL)isOpaque
{
    return YES;
}

- (void)drawRect:(NSRect)dirtyRect
{
    [[NSColor darkGrayColor] setFill];
    NSRectFill(dirtyRect);

    NSString *msg = _vmRunning ? @"VM is running in a separate window." : @"VM will appear here";
    NSDictionary *attrs = @{NSForegroundColorAttributeName: [NSColor lightGrayColor],
                            NSFontAttributeName: METRICS_FONT_SYSTEM_REGULAR_13};
    NSSize textSize = [msg sizeWithAttributes:attrs];
    NSPoint p = NSMakePoint((NSWidth(self.bounds) - textSize.width) / 2,
                            (NSHeight(self.bounds) - textSize.height) / 2);
    [msg drawAtPoint:p withAttributes:attrs];

    if (_vmRunning) {
        NSString *sub = @"QEMU SDL window is separate — arrange as needed.";
        NSDictionary *subAttrs = @{NSForegroundColorAttributeName: [NSColor lightGrayColor],
                                   NSFontAttributeName: METRICS_FONT_SYSTEM_REGULAR_11};
        NSSize subSize = [sub sizeWithAttributes:subAttrs];
        NSPoint subP = NSMakePoint((NSWidth(self.bounds) - subSize.width) / 2,
                                   p.y - subSize.height - METRICS_SPACE_8);
        [sub drawAtPoint:subP withAttributes:subAttrs];
    }
}

- (void)dealloc
{
    [super dealloc];
}

@end
