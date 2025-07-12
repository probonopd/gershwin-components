#import "MainView.h"

@implementation MainView

- (void)resizeSubviewsWithOldSize:(NSSize)oldSize {
    [super resizeSubviewsWithOldSize:oldSize];
    NSRect bounds = [self bounds];
    CGFloat buttonWidth = 100;
    CGFloat buttonHeight = 30;
    CGFloat buttonSpacing = 20;
    NSUInteger buttonCount = self.buttonArray.count;
    CGFloat totalButtonsWidth = buttonCount * buttonWidth + (buttonCount - 1) * buttonSpacing;
    CGFloat startX = (bounds.size.width - totalButtonsWidth) / 2.0;
    CGFloat buttonY = 20;
    // Layout buttons
    for (NSUInteger i = 0; i < buttonCount; i++) {
        NSButton *btn = self.buttonArray[i];
        [btn setFrame:NSMakeRect(startX + i * (buttonWidth + buttonSpacing), buttonY, buttonWidth, buttonHeight)];
    }
    // Layout table
    CGFloat tableBottom = buttonY + buttonHeight + 20;
    NSRect tableRect = NSMakeRect(20, tableBottom, bounds.size.width - 40, bounds.size.height - tableBottom - 20);
    [self.tableScrollView setFrame:tableRect];
}

@end
