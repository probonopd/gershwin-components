/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "GraphView.h"

@implementation GraphView

@synthesize title = _title;
@synthesize unit = _unit;

- (id)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        _values = [[NSMutableArray alloc] init];
        _title = @"";
        _unit = @"";
    }
    return self;
}

- (void)addValue:(double)value
{
    [_values addObject:[NSNumber numberWithDouble:value]];
    while ([_values count] > 180)
        [_values removeObjectAtIndex:0];
    [self setNeedsDisplay:YES];
}

- (void)clear
{
    [_values removeAllObjects];
    [self setNeedsDisplay:YES];
}

- (BOOL)isFlipped { return YES; }

- (void)drawRect:(NSRect)dirtyRect
{
    [[NSColor controlBackgroundColor] setFill];
    NSRectFill(dirtyRect);

    NSDictionary *attrs = @{ NSFontAttributeName: [NSFont boldSystemFontOfSize:12] };
    [_title drawAtPoint:NSMakePoint(10, 8) withAttributes:attrs];

    NSRect r = NSInsetRect([self bounds], 10, 25);
    [[NSColor gridColor] setStroke];
    NSBezierPath *grid = [NSBezierPath bezierPath];
    for (int i = 0; i <= 4; i++) {
        CGFloat y = NSMinY(r) + NSHeight(r) * i / 4.0;
        [grid moveToPoint:NSMakePoint(NSMinX(r), y)];
        [grid lineToPoint:NSMakePoint(NSMaxX(r), y)];
    }
    [grid stroke];

    if ([_values count] < 2) return;

    double maxValue = 1.0;
    for (NSNumber *n in _values)
        maxValue = MAX(maxValue, [n doubleValue]);

    NSBezierPath *path = [NSBezierPath bezierPath];
    NSUInteger count = [_values count];
    for (NSUInteger i = 0; i < count; i++) {
        double v = [_values[i] doubleValue];
        CGFloat x = NSMinX(r) + NSWidth(r) * (double)i / (double)(count - 1);
        CGFloat y = NSMaxY(r) - NSHeight(r) * v / maxValue;
        if (i == 0) [path moveToPoint:NSMakePoint(x, y)];
        else [path lineToPoint:NSMakePoint(x, y)];
    }

    [[NSColor systemBlueColor] setStroke];
    [path setLineWidth:2.0];
    [path stroke];

    NSString *label = [NSString stringWithFormat:@"%.1f %@", maxValue, _unit ?: @""];
    [label drawAtPoint:NSMakePoint(NSMaxX(r) - 90, NSMinY(r))
        withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:10]}];
}

- (void)dealloc
{
    [_values release];
    [_title release];
    [_unit release];
    [super dealloc];
}

@end
