#import "WideHitMenuView.h"

@implementation WideHitMenuView





    - (void)mouseDown:(NSEvent *)event {
        NSPoint location = [self convertPoint:[event locationInWindow] fromView:nil];
        NSArray *items = [[self menu] itemArray];
        CGFloat itemWidth = [self bounds].size.width / [items count];
        CGFloat itemHeight = [self bounds].size.height;
        for (NSUInteger i = 0; i < [items count]; i++) {
            NSRect itemFrame = NSMakeRect(i * itemWidth, 0, itemWidth, itemHeight);
            NSRect expandedFrame = NSMakeRect(itemFrame.origin.x, itemFrame.origin.y - 10, itemFrame.size.width, itemFrame.size.height + 10);
            if (NSPointInRect(location, expandedFrame) && !NSPointInRect(location, itemFrame)) {
                // Synthesize a mouse event at the center of the menu item
                NSPoint center = NSMakePoint(itemFrame.origin.x + itemWidth / 2, itemFrame.origin.y + itemHeight / 2);
                NSEvent *newEvent = [NSEvent mouseEventWithType:[event type]
                                                      location:[self convertPoint:center toView:nil]
                                                 modifierFlags:[event modifierFlags]
                                                     timestamp:[event timestamp]
                                                  windowNumber:[event windowNumber]
                                                       context:[event context]
                                                   eventNumber:[event eventNumber]
                                                    clickCount:[event clickCount]
                                                      pressure:[event pressure]];
                [super mouseDown:newEvent];
                return;
            }
        }
        [super mouseDown:event];
    }
@end
