#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

@class DisplayController;
@class DisplayInfo;

// Custom view that represents a single display rectangle
@interface DisplayRectView : NSView
{
    DisplayInfo *displayInfo;
    BOOL isDragging;
    BOOL showsMenuBar;
    BOOL isSelected;
    NSPoint dragOffset;
}

@property (assign) DisplayInfo *displayInfo;
@property BOOL showsMenuBar;
@property BOOL isSelected;

@end

// Main view that contains all display rectangles and handles arrangement
@interface DisplayView : NSView
{
    DisplayController *controller;
    NSMutableArray *displayRects;
    DisplayRectView *draggingView;
}

@property (assign) DisplayController *controller;

- (void)updateDisplayRects;
- (DisplayRectView *)displayRectAtPoint:(NSPoint)point;
- (NSArray *)displayRects;

@end
