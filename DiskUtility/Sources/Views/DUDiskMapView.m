/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUDiskMapView.h"

#import "AppearanceMetrics.h"
#import "DUPartition.h"
#import "DUPartitionLayout.h"

// Pure drawing constants; AppearanceMetrics.h has no equivalents for these
// visual-only values (tile shape, hatch pattern, selection stroke width).
static const CGFloat kMapTileCornerRadius = 3.0;
static const CGFloat kMapSelectedBorderWidth = 2.0;
static const CGFloat kMapNormalBorderWidth = 1.0;
static const CGFloat kMapHatchSpacing = 6.0;
static const CGFloat kMapHatchLineWidth = 1.0;

// Floor for drag resizing; mirrors the minimum enforced by DUPartitionLayout
// (ARCHITECTURE.md section 44) so the preview never shows an invalid size.
static const unsigned long long kMinimumDragSizeBytes = 1024ull * 1024ull;

@interface DUDiskMapView ()
@property (nonatomic, strong, readwrite) DUPartitionLayout *layout;
// Live preview while a boundary is being dragged; NSNotFound otherwise.
@property (nonatomic, assign) NSUInteger pendingResizeIndex;
@property (nonatomic, assign) unsigned long long pendingResizeBytes;
@end

@implementation DUDiskMapView

- (instancetype)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (self == nil) {
        return nil;
    }
    _selectedPartitionIndex = -1;
    _resizingEnabled = YES;
    _pendingResizeIndex = NSNotFound;
    return self;
}

#pragma mark - Content

- (void)setLayout:(DUPartitionLayout *)layout
{
    if (_layout == layout) {
        return;
    }
    _layout = layout;
    _pendingResizeIndex = NSNotFound;
    self.selectedPartitionIndex =
        (layout.partitions.count > 0) ? 0 : -1;
    [self invalidateCursorRects];
    [self setNeedsDisplay:YES];
}

- (void)setSelectedPartitionIndex:(NSInteger)index
{
    NSInteger clamped = index;
    if (clamped >= (NSInteger)_layout.partitions.count) {
        clamped = -1;
    }
    if (_selectedPartitionIndex == clamped) {
        return;
    }
    _selectedPartitionIndex = clamped;
    [self setNeedsDisplay:YES];
}

- (void)setResizingEnabled:(BOOL)enabled
{
    if (_resizingEnabled == enabled) {
        return;
    }
    _resizingEnabled = enabled;
    [self invalidateCursorRects];
}

#pragma mark - Geometry helpers

// Plot area inside the view with a small breathing margin so selection
// borders are never clipped.
- (NSRect)plotArea
{
    return NSInsetRect(self.bounds, METRICS_SPACE_8, METRICS_SPACE_8);
}

// Effective size of a partition, taking the live drag preview into account.
- (unsigned long long)sizeOfPartitionAtIndex:(NSUInteger)index
                       inArray:(NSArray<DUPartition *> *)partitions
{
    if (index != _pendingResizeIndex || _pendingResizeIndex == NSNotFound
        || index >= partitions.count) {
        return partitions[index].sizeBytes;
    }
    return _pendingResizeBytes;
}

- (NSRect)rectForPartitionAtIndex:(NSUInteger)index
                    inSortedArray:(NSArray<DUPartition *> *)sorted
{
    NSRect area = [self plotArea];
    if (self.layout.capacityBytes == 0 || index >= sorted.count) {
        return NSZeroRect;
    }
    double scale = (double)NSWidth(area)
        / (double)self.layout.capacityBytes;
    DUPartition *partition = sorted[index];
    CGFloat x = NSMinX(area)
        + (CGFloat)((double)partition.offsetBytes * scale);
    CGFloat width = (CGFloat)((double)[self sizeOfPartitionAtIndex:index
                                                          inArray:sorted]
                              * scale);
    return NSMakeRect(x, NSMinY(area), width, NSHeight(area));
}

// Free gap after the partition at index (device end counts as a gap too).
- (NSRect)rectForGapAfterPartitionAtIndex:(NSUInteger)index
                            inSortedArray:(NSArray<DUPartition *> *)sorted
{
    NSRect area = [self plotArea];
    if (self.layout.capacityBytes == 0 || index >= sorted.count) {
        return NSZeroRect;
    }
    double scale = (double)NSWidth(area)
        / (double)self.layout.capacityBytes;
    DUPartition *partition = sorted[index];
    unsigned long long start =
        partition.offsetBytes
            + [self sizeOfPartitionAtIndex:index inArray:sorted];
    unsigned long long end =
        start + [self.layout freeBytesAfterPartition:partition];
    CGFloat x = NSMinX(area) + (CGFloat)((double)start * scale);
    CGFloat width = (CGFloat)((double)(end - start) * scale);
    return NSMakeRect(x, NSMinY(area), width, NSHeight(area));
}

// Index of the partition whose right edge sits within grab distance of
// point, and still has free space behind it to grow into. NSNotFound when
// no boundary can be grabbed here.
- (NSUInteger)resizableBoundaryNearPoint:(NSPoint)point
                           inSortedArray:(NSArray<DUPartition *> *)sorted
{
    if (!_resizingEnabled || sorted.count == 0) {
        return NSNotFound;
    }
    for (NSUInteger i = 0; i < sorted.count; i++) {
        DUPartition *partition = sorted[i];
        if ([self.layout freeBytesAfterPartition:partition] == 0) {
            continue;
        }
        NSRect rect = [self rectForPartitionAtIndex:i inSortedArray:sorted];
        CGFloat edge = NSMaxX(rect);
        if (fabs(point.x - edge) <= (CGFloat)METRICS_RESIZE_EDGE_THICKNESS
            && point.y >= NSMinY(rect) && point.y <= NSMaxY(rect)) {
            return i;
        }
    }
    return NSNotFound;
}

- (NSUInteger)partitionIndexAtPoint:(NSPoint)point
                      inSortedArray:(NSArray<DUPartition *> *)sorted
{
    for (NSUInteger i = 0; i < sorted.count; i++) {
        NSRect rect = [self rectForPartitionAtIndex:i inSortedArray:sorted];
        if (NSPointInRect(point, rect)) {
            return i;
        }
    }
    return NSNotFound;
}

#pragma mark - Drawing

+ (NSAttributedString *)labelForText:(NSString *)text
{
    NSDictionary *attributes =
        @{ NSFontAttributeName : METRICS_FONT_SYSTEM_REGULAR_11,
           NSForegroundColorAttributeName : [NSColor labelColor] };
    return [[NSAttributedString alloc]
        initWithString:text ?: @"" attributes:attributes];
}

// Manual truncation: GNUstep drawing does not reliably elide single-line
// attributed strings on every backend, so shorten here instead.
+ (NSString *)truncatedText:(NSString *)text
                   maxWidth:(CGFloat)maxWidth
{
    if (maxWidth <= 0.0) {
        return @"";
    }
    NSString *result = text ?: @"";
    NSDictionary *attributes = @{ NSFontAttributeName :
                                  METRICS_FONT_SYSTEM_REGULAR_11 };
    NSString *ellipsis = @"...";
    if ([result sizeWithAttributes:attributes].width <= maxWidth) {
        return result;
    }
    while (result.length > 0
           && ([result sizeWithAttributes:attributes].width
                  + [ellipsis sizeWithAttributes:attributes].width)
               > maxWidth) {
        result = [result substringToIndex:result.length - 1];
    }
    return [result stringByAppendingString:ellipsis];
}

- (void)drawHatchInRect:(NSRect)gapRect
{
    [NSGraphicsContext saveGraphicsState];
    NSBezierPath *clipPath = [NSBezierPath bezierPathWithRect:gapRect];
    [clipPath addClip];

    // Diagonal lines covering the whole view, clipped down to the gap so
    // every gap shows the same pattern angle.
    NSRect bounds = self.bounds;
    NSBezierPath *lines = [NSBezierPath bezierPath];
    lines.lineWidth = kMapHatchLineWidth;
    CGFloat span = NSWidth(bounds) + NSHeight(bounds);
    for (CGFloat offset = -NSHeight(bounds); offset < span;
         offset += kMapHatchSpacing) {
        [lines moveToPoint:NSMakePoint(NSMinX(bounds) + offset,
                                       NSMaxY(bounds))];
        [lines lineToPoint:NSMakePoint(NSMinX(bounds) + offset
                                           + NSHeight(bounds),
                                       NSMinY(bounds))];
    }
    [[NSColor lightGrayColor] setStroke];
    [lines stroke];
    [NSGraphicsContext restoreGraphicsState];
}

- (void)drawRect:(NSRect)dirtyRect
{
    (void)dirtyRect;
    NSRect area = [self plotArea];

    [[NSColor controlBackgroundColor] setFill];
    [[NSBezierPath bezierPathWithRect:area] fill];

    NSArray<DUPartition *> *sorted = self.layout.partitions;

    // Free gaps first so tile fills never cover the hatching.
    for (NSUInteger i = 0; i < sorted.count; i++) {
        NSRect gapRect = [self rectForGapAfterPartitionAtIndex:i
                                                 inSortedArray:sorted];
        if (!NSEqualRects(gapRect, NSZeroRect) && NSWidth(gapRect) > 0.5) {
            [self drawHatchInRect:gapRect];
        }
    }

    for (NSUInteger i = 0; i < sorted.count; i++) {
        NSRect rect = [self rectForPartitionAtIndex:i inSortedArray:sorted];
        if (NSWidth(rect) <= 0.5) {
            continue;
        }
        BOOL selected = ((NSInteger)i == _selectedPartitionIndex);

        NSBezierPath *tile =
            [NSBezierPath bezierPathWithRoundedRect:rect
                                            xRadius:kMapTileCornerRadius
                                            yRadius:kMapTileCornerRadius];
        [[NSColor lightGrayColor] setFill];
        [tile fill];

        NSColor *borderColor =
            selected ? [NSColor blackColor] : [NSColor darkGrayColor];
        [borderColor setStroke];
        tile.lineWidth =
            selected ? kMapSelectedBorderWidth : kMapNormalBorderWidth;
        [tile stroke];

        // Name centered and truncated to the visible tile width.
        DUPartition *partition = sorted[i];
        NSString *name =
            partition.name.length > 0
                ? partition.name
                : (partition.displayName ?: NSLocalizedString(@"Untitled", nil));
        NSAttributedString *label = [[self class]
            labelForText:[[self class] truncatedText:name
                                             maxWidth:NSWidth(rect)
                                                          - 2 * METRICS_SPACE_8]];
        NSSize textSize = label.size;
        NSPoint origin =
            NSMakePoint(NSMinX(rect)
                            + (NSWidth(rect) - textSize.width) / 2.0,
                        NSMidY(rect) - textSize.height / 2.0);
        [label drawAtPoint:origin];
    }

    // Frame around the whole map so empty devices read as one disk.
    [[NSColor darkGrayColor] setStroke];
    NSBezierPath *frame =
        [NSBezierPath bezierPathWithRoundedRect:area
                                        xRadius:kMapTileCornerRadius
                                        yRadius:kMapTileCornerRadius];
    frame.lineWidth = kMapNormalBorderWidth;
    [frame stroke];
}

#pragma mark - Cursor tracking

// Cursor rectangles over every growable right edge; refreshed whenever
// content or geometry changes via invalidateCursorRectsForView:.
- (void)resetCursorRects
{
    if (!_resizingEnabled || _pendingResizeIndex != NSNotFound) {
        return;
    }
    NSArray<DUPartition *> *sorted = _layout.partitions;
    for (NSUInteger i = 0; i < sorted.count; i++) {
        if ([_layout freeBytesAfterPartition:sorted[i]] == 0) {
            continue;
        }
        NSRect rect = [self rectForPartitionAtIndex:i inSortedArray:sorted];
        NSRect grab =
            NSMakeRect(NSMaxX(rect) - (CGFloat)METRICS_RESIZE_EDGE_THICKNESS,
                       NSMinY(rect),
                       2 * (CGFloat)METRICS_RESIZE_EDGE_THICKNESS,
                       NSHeight(rect));
        [self addCursorRect:grab
                     cursor:[NSCursor resizeLeftRightCursor]];
    }
}

- (void)invalidateCursorRects
{
    if (self.window != nil && self.window.isVisible) {
        [self.window invalidateCursorRectsForView:self];
    }
}

#pragma mark - Mouse interaction

- (void)mouseDown:(NSEvent *)event
{
    NSArray<DUPartition *> *sorted = self.layout.partitions;
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];

    NSUInteger boundary =
        [self resizableBoundaryNearPoint:point inSortedArray:sorted];
    if (boundary != NSNotFound) {
        _pendingResizeIndex = boundary;
        _pendingResizeBytes = sorted[boundary].sizeBytes;
        [[NSCursor resizeLeftRightCursor] push];
        return;
    }

    NSUInteger hit = [self partitionIndexAtPoint:point inSortedArray:sorted];
    if (hit == NSNotFound) {
        return;
    }
    self.selectedPartitionIndex = (NSInteger)hit;
    if ([self.delegate respondsToSelector:
            @selector(mapView:didSelectPartitionAtIndex:)]) {
        [self.delegate mapView:self didSelectPartitionAtIndex:hit];
    }
}

- (void)mouseDragged:(NSEvent *)event
{
    if (_pendingResizeIndex == NSNotFound) {
        return;
    }
    NSArray<DUPartition *> *sorted = self.layout.partitions;
    if (_pendingResizeIndex >= sorted.count) {
        return;
    }
    DUPartition *partition = sorted[_pendingResizeIndex];
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    NSRect rect =
        [self rectForPartitionAtIndex:_pendingResizeIndex inSortedArray:sorted];

    double scale = (double)NSWidth([self plotArea])
        / (double)self.layout.capacityBytes;
    unsigned long long bytesAtPointer =
        (scale > 0.0)
            ? (unsigned long long)(((double)(point.x - NSMinX(rect)) / scale))
            : partition.sizeBytes;

    unsigned long long maxBytes =
        partition.offsetBytes + partition.sizeBytes
        + [self.layout freeBytesAfterPartition:partition];
    unsigned long long wanted = bytesAtPointer - MIN(bytesAtPointer,
                                                     partition.offsetBytes);
    _pendingResizeBytes =
        MAX(MIN(wanted, maxBytes), MIN(kMinimumDragSizeBytes, maxBytes));
    [self setNeedsDisplay:YES];
}

- (void)mouseUp:(NSEvent *)event
{
    (void)event;
    if (_pendingResizeIndex == NSNotFound) {
        return;
    }
    NSUInteger index = _pendingResizeIndex;
    unsigned long long bytes = _pendingResizeBytes;
    _pendingResizeIndex = NSNotFound;
    _pendingResizeBytes = 0;
    [NSCursor pop];

    NSArray<DUPartition *> *sorted = self.layout.partitions;
    if (index >= sorted.count) {
        return;
    }
    DUPartition *partition = sorted[index];
    if (bytes == partition.sizeBytes) {
        [self invalidateCursorRects];
        [self setNeedsDisplay:YES];
        return;
    }
    NSError *error = nil;
    if ([self.layout resizePartition:partition
                         toSizeBytes:bytes
                               error:&error]) {
        if ([self.delegate respondsToSelector:
                @selector(mapViewDidChangeLayout:)]) {
            [self.delegate mapViewDidChangeLayout:self];
        }
    }
    [self invalidateCursorRects];
    [self setNeedsDisplay:YES];
}

@end
