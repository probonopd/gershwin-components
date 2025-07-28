/*
 * Copyright (c) 2005 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DisplayView.h"
#import "DisplayController.h"

@implementation DisplayRectView

@synthesize displayInfo, showsMenuBar, isSelected;

- (id)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        isDragging = NO;
        showsMenuBar = NO;
        isSelected = NO;
    }
    return self;
}

- (void)drawRect:(NSRect)dirtyRect
{
    // Draw the display rectangle
    NSRect bounds = [self bounds];
    
    // Background color
    NSGradient *gradient = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithCalibratedRed:0.4 green:0.7 blue:0.95 alpha:1.0]
                                                         endingColor:[NSColor colorWithCalibratedRed:0.15 green:0.45 blue:0.6 alpha:1.0]];
    [gradient drawInRect:bounds angle:45];
    [gradient release];
    
    // Selection border (thick black border when selected)
    if (isSelected) {
        [[NSColor blackColor] setStroke];
        NSBezierPath *selectionBorder = [NSBezierPath bezierPathWithRect:NSInsetRect(bounds, 2.5, 2.5)];
        [selectionBorder setLineWidth:5.0];
        [selectionBorder stroke];
    }
    
    // Regular border
    [[NSColor blackColor] setStroke];
    NSBezierPath *border = [NSBezierPath bezierPathWithRect:bounds];
    [border setLineWidth:2.0];
    [border stroke];
    
    // Display name
    if (displayInfo) {
        NSString *displayName = [displayInfo name];
        NSDictionary *attrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:12],
            NSForegroundColorAttributeName: [NSColor whiteColor]
        };
        
        NSSize textSize = [displayName sizeWithAttributes:attrs];
        NSPoint textPoint = NSMakePoint((bounds.size.width - textSize.width) / 2,
                                       (bounds.size.height - textSize.height) / 2);
        [displayName drawAtPoint:textPoint withAttributes:attrs];
    }
    
    // Menu bar representation
    if (showsMenuBar) {
        float menuBarHeight = MIN(18, bounds.size.height * 0.25); // Scale menu bar height
        NSRect menuBarRect = NSMakeRect(2, bounds.size.height - menuBarHeight - 2, bounds.size.width - 4, menuBarHeight);
        [[NSColor colorWithCalibratedWhite:0.9 alpha:0.8] setFill];
        [NSBezierPath fillRect:menuBarRect];
        
        [[NSColor blackColor] setStroke];
        NSBezierPath *menuBarBorder = [NSBezierPath bezierPathWithRect:menuBarRect];
        [menuBarBorder setLineWidth:1.0];
        [menuBarBorder stroke];
    }
}

- (void)mouseDown:(NSEvent *)theEvent
{
    NSPoint localPoint = [self convertPoint:[theEvent locationInWindow] fromView:nil];
    dragOffset = localPoint;
    isDragging = NO; // Don't start dragging immediately
    
    // Notify the parent view (DisplayView) that this display was clicked
    NSView *parentView = [self superview];
    if ([parentView isKindOfClass:[DisplayView class]]) {
        DisplayView *displayView = (DisplayView *)parentView;
        DisplayController *controller = [displayView controller];
        
        if (controller && [controller respondsToSelector:@selector(selectDisplay:)] && displayInfo) {
            // Select this display
            [controller selectDisplay:displayInfo];
            
            // Update all display rect views to show/hide selection
            NSArray *allRectViews = [displayView displayRects];
            for (DisplayRectView *rectView in allRectViews) {
                [rectView setIsSelected:(rectView == self)];
                [rectView setNeedsDisplay:YES];
            }
        }
    }
    
    // Set up for potential dragging on next mouse move
    isDragging = YES;
}

- (void)mouseDragged:(NSEvent *)theEvent
{
    if (!isDragging || !displayInfo) return;
    
    NSPoint windowPoint = [theEvent locationInWindow];
    if (![[self superview] respondsToSelector:@selector(convertPoint:fromView:)]) {
        return;
    }
    
    NSPoint parentPoint = [[self superview] convertPoint:windowPoint fromView:nil];
    
    NSPoint newOrigin = NSMakePoint(parentPoint.x - dragOffset.x, parentPoint.y - dragOffset.y);
    
    // Keep within superview bounds with safety margins
    NSView *superview = [self superview];
    if (!superview) return;
    
    NSRect superBounds = [superview bounds];
    NSRect frame = [self frame];
    
    // Add safety margins to prevent going completely off-screen
    float margin = 10.0;
    newOrigin.x = MAX(-frame.size.width + margin, MIN(newOrigin.x, superBounds.size.width - margin));
    newOrigin.y = MAX(-frame.size.height + margin, MIN(newOrigin.y, superBounds.size.height - margin));
    
    [self setFrameOrigin:newOrigin];
    
    // Update the display info with scaled coordinates
    NSRect newFrame = [displayInfo frame];
    newFrame.origin = newOrigin;
    [displayInfo setFrame:newFrame];
    
    // Mark superview as needing redisplay
    [superview setNeedsDisplay:YES];
}

- (void)mouseUp:(NSEvent *)theEvent
{
    if (!isDragging) return;
    
    isDragging = NO;
    
    NSView *parentView = [self superview];
    if (!parentView || ![parentView isKindOfClass:[DisplayView class]]) {
        return;
    }
    
    DisplayView *displayView = (DisplayView *)parentView;
    
    // Check if we dropped on the menu bar area of another display
    NSPoint windowPoint = [theEvent locationInWindow];
    NSPoint parentPoint = [parentView convertPoint:windowPoint fromView:nil];
    DisplayRectView *targetView = [displayView displayRectAtPoint:parentPoint];
    
    if (targetView && targetView != self && [targetView displayInfo] && displayInfo) {
        // Transfer primary status (menu bar) to the target display
        [self setShowsMenuBar:NO];
        [targetView setShowsMenuBar:YES];
        
        // Update display info
        [displayInfo setIsPrimary:NO];
        [[targetView displayInfo] setIsPrimary:YES];
        
        // Apply changes via controller
        DisplayController *controller = [displayView controller];
        if (controller && [controller respondsToSelector:@selector(setPrimaryDisplay:)]) {
            [controller setPrimaryDisplay:[targetView displayInfo]];
        }
    }
    
    // Apply the new arrangement
    DisplayController *controller = [displayView controller];
    if (controller && [controller respondsToSelector:@selector(applyDisplayConfiguration)]) {
        [controller applyDisplayConfiguration];
    }
    
    [parentView setNeedsDisplay:YES];
}

- (void)rightMouseDown:(NSEvent *)theEvent
{
    // Create and show context menu for the display
    NSMenu *contextMenu = [[NSMenu alloc] initWithTitle:@"Display Options"];
    
    // Add "Use as Main Display" option (matches macOS terminology)
    NSMenuItem *makePrimaryItem = [[NSMenuItem alloc] initWithTitle:@"Use as Main Display" 
                                                             action:@selector(makePrimary:) 
                                                      keyEquivalent:@""];
    [makePrimaryItem setTarget:self];
    [makePrimaryItem setRepresentedObject:displayInfo];
    
    // Disable the option if this display is already primary
    if (displayInfo && [displayInfo isPrimary]) {
        [makePrimaryItem setEnabled:NO];
        [makePrimaryItem setTitle:@"Main Display"]; // Show current status
    }
    
    [contextMenu addItem:makePrimaryItem];
    [makePrimaryItem release];
    
    // Show the context menu
    [NSMenu popUpContextMenu:contextMenu withEvent:theEvent forView:self];
    [contextMenu release];
}

- (void)makePrimary:(id)sender
{
    NSMenuItem *item = (NSMenuItem *)sender;
    DisplayInfo *targetDisplay = [item representedObject];
    
    if (!targetDisplay) return;
    
    NSLog(@"DisplayRectView: Making display %@ primary via context menu", [targetDisplay name]);
    
    // Find the parent view and controller
    NSView *parentView = [self superview];
    if (parentView && [parentView isKindOfClass:[DisplayView class]]) {
        DisplayView *displayView = (DisplayView *)parentView;
        DisplayController *controller = [displayView controller];
        
        if (controller && [controller respondsToSelector:@selector(setPrimaryDisplay:)]) {
            [controller setPrimaryDisplay:targetDisplay];
            
            // Update the visual state of all display rectangles
            NSArray *allRectViews = [displayView displayRects];
            for (DisplayRectView *rectView in allRectViews) {
                [rectView setShowsMenuBar:([rectView displayInfo] == targetDisplay)];
                [rectView setNeedsDisplay:YES];
            }
        }
    }
}

@end

@implementation DisplayView

@synthesize controller;

- (id)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        displayRects = [[NSMutableArray alloc] init];
    }
    return self;
}

- (void)dealloc
{
    [displayRects release];
    [super dealloc];
}



- (void)drawRect:(NSRect)dirtyRect
{
    // Draw background
    [[NSColor colorWithCalibratedWhite:0.95 alpha:1.0] setFill];
    [NSBezierPath fillRect:[self bounds]];
    
    // Draw border
    [[NSColor grayColor] setStroke];
    NSBezierPath *border = [NSBezierPath bezierPathWithRect:[self bounds]];
    [border setLineWidth:1.0];
    [border stroke];
}

- (void)updateDisplayRects
{
    // Remove existing display rect views
    for (DisplayRectView *rectView in displayRects) {
        [rectView removeFromSuperview];
    }
    [displayRects removeAllObjects];
    
    if (!controller) {
        NSLog(@"DisplayView: No controller available for updateDisplayRects");
        return;
    }
    
    NSArray *displays = nil;
    if ([controller respondsToSelector:@selector(displays)]) {
        displays = [controller displays];
    }
    
    if (!displays || [displays count] == 0) {
        NSLog(@"DisplayView: No displays available");
        return;
    }
    
    NSLog(@"DisplayView: Updating display rects for %lu displays", (unsigned long)[displays count]);
    
    // Ensure at least one display is primary
    BOOL hasPrimary = NO;
    for (DisplayInfo *display in displays) {
        if ([display isPrimary]) {
            hasPrimary = YES;
            break;
        }
    }
    
    // If no primary display, make the first one primary
    if (!hasPrimary && [displays count] > 0) {
        DisplayInfo *firstDisplay = [displays objectAtIndex:0];
        [firstDisplay setIsPrimary:YES];
        NSLog(@"DisplayView: Auto-setting first display as primary: %@", [firstDisplay name]);
    }
    
    // Calculate scaling factor to fit displays in view
    NSRect bounds = [self bounds];
    NSRect totalBounds = NSZeroRect;
    
    NSLog(@"DisplayView: View bounds: %@", NSStringFromRect(bounds));
    
    for (DisplayInfo *display in displays) {
        NSRect displayFrame = [display frame];
        NSLog(@"DisplayView: Display %@ frame: %@", [display name], NSStringFromRect(displayFrame));
        
        if (NSIsEmptyRect(totalBounds)) {
            totalBounds = displayFrame;
        } else {
            totalBounds = NSUnionRect(totalBounds, displayFrame);
        }
    }
    
    NSLog(@"DisplayView: Total bounds: %@", NSStringFromRect(totalBounds));
    
    if (NSIsEmptyRect(totalBounds) || totalBounds.size.width <= 0 || totalBounds.size.height <= 0) {
        NSLog(@"DisplayView: Invalid total bounds, using default single display layout");
        // Handle single display or invalid bounds case
        if ([displays count] == 1) {
            DisplayInfo *display = [displays objectAtIndex:0];
            // Give it a reasonable default size if it doesn't have one
            if ([display frame].size.width <= 0 || [display frame].size.height <= 0) {
                [display setFrame:NSMakeRect(0, 0, 1920, 1080)];
                [display setResolution:NSMakeSize(1920, 1080)];
                NSLog(@"DisplayView: Set default frame for display %@", [display name]);
            }
            totalBounds = [display frame];
        } else {
            NSLog(@"DisplayView: Cannot display - no valid bounds");
            return;
        }
    }
    
    // Use smaller margins for the compact layout
    float margin = 10.0;
    float availableWidth = bounds.size.width - (2 * margin);
    float availableHeight = bounds.size.height - (2 * margin);
    
    // Ensure we have positive available space
    if (availableWidth <= 0) availableWidth = bounds.size.width * 0.8;
    if (availableHeight <= 0) availableHeight = bounds.size.height * 0.8;
    
    // Calculate scale to fit all displays with margin
    float scaleX = availableWidth / totalBounds.size.width;
    float scaleY = availableHeight / totalBounds.size.height;
    float scale = MIN(scaleX, scaleY);
    
    // For the smaller display area, use tighter scale bounds
    scale = MIN(scale, 0.25); // Smaller maximum scale for compact view
    scale = MAX(scale, 0.05); // Ensure they're still visible
    
    NSLog(@"DisplayView: Scaling displays by factor: %f (bounds: %@, totalBounds: %@)", 
          scale, NSStringFromRect(bounds), NSStringFromRect(totalBounds));
    
    DisplayInfo *selectedDisplayInfo = nil;
    if ([controller respondsToSelector:@selector(selectedDisplay)]) {
        selectedDisplayInfo = [controller selectedDisplay];
        NSLog(@"DisplayView: Current selected display: %@", selectedDisplayInfo ? [selectedDisplayInfo name] : @"none");
    }
    
    // Calculate the scaled total bounds for centering
    float scaledTotalWidth = totalBounds.size.width * scale;
    float scaledTotalHeight = totalBounds.size.height * scale;
    
    // Center the display arrangement in the view
    float offsetX = (bounds.size.width - scaledTotalWidth) / 2.0;
    float offsetY = (bounds.size.height - scaledTotalHeight) / 2.0;
    
    NSLog(@"DisplayView: Centering displays with offset: (%f, %f)", offsetX, offsetY);
    
    // Create display rect views
    for (DisplayInfo *display in displays) {
        NSRect displayFrame = [display frame];
        
        // Scale and position the rectangle relative to total bounds, then center
        float scaledX = (displayFrame.origin.x - totalBounds.origin.x) * scale;
        float scaledY = (displayFrame.origin.y - totalBounds.origin.y) * scale;
        float scaledWidth = displayFrame.size.width * scale;
        float scaledHeight = displayFrame.size.height * scale;
        
        NSRect scaledFrame = NSMakeRect(
            offsetX + scaledX,
            offsetY + scaledY, 
            scaledWidth,
            scaledHeight
        );
        
        // Ensure minimum size for visibility and usability in the compact view
        if (scaledFrame.size.width < 50) {
            float centerX = NSMidX(scaledFrame);
            scaledFrame.size.width = 50;
            scaledFrame.origin.x = centerX - 25;
        }
        if (scaledFrame.size.height < 35) {
            float centerY = NSMidY(scaledFrame);
            scaledFrame.size.height = 35;
            scaledFrame.origin.y = centerY - 17.5;
        }
        
        NSLog(@"DisplayView: Creating display rect for %@ at %@ (original: %@)", 
              [display name], NSStringFromRect(scaledFrame), NSStringFromRect(displayFrame));
        
        // Verify the rectangle is within the bounds
        if (!NSContainsRect(bounds, scaledFrame)) {
            NSLog(@"DisplayView: WARNING - Display rectangle extends outside bounds!");
            NSLog(@"  Bounds: %@", NSStringFromRect(bounds));
            NSLog(@"  Display rect: %@", NSStringFromRect(scaledFrame));
        }
        
        DisplayRectView *rectView = [[DisplayRectView alloc] initWithFrame:scaledFrame];
        [rectView setDisplayInfo:display];
        [rectView setShowsMenuBar:[display isPrimary]]; // Always show menu bar for primary display
        
        // Set selection state - preserve existing selection if possible
        BOOL shouldBeSelected = NO;
        if (selectedDisplayInfo && selectedDisplayInfo == display) {
            // Keep the previously selected display selected
            shouldBeSelected = YES;
            NSLog(@"DisplayView: Preserving selection for display: %@", [display name]);
        } else if (!selectedDisplayInfo && [display isPrimary]) {
            // Default to selecting the primary display only if no selection exists
            shouldBeSelected = YES;
            if (controller && [controller respondsToSelector:@selector(selectDisplay:)]) {
                [controller selectDisplay:display];
                NSLog(@"DisplayView: Auto-selecting primary display: %@", [display name]);
            }
        }
        
        [rectView setIsSelected:shouldBeSelected];
        
        [self addSubview:rectView];
        [displayRects addObject:rectView];
        [rectView release];
    }
}

- (DisplayRectView *)displayRectAtPoint:(NSPoint)point
{
    for (DisplayRectView *rectView in displayRects) {
        if (NSPointInRect(point, [rectView frame])) {
            return rectView;
        }
    }
    return nil;
}

- (void)setNeedsDisplay:(BOOL)flag
{
    [super setNeedsDisplay:flag];
    if (flag) {
        [self updateDisplayRects];
    }
}

- (NSArray *)displayRects
{
    return displayRects;
}

@end
