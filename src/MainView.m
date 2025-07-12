#import "MainView.h"

@implementation MainView

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        // Create table scroll view and table view
        self.tableScrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
        [self.tableScrollView setHasVerticalScroller:YES];
        [self.tableScrollView setHasHorizontalScroller:YES];
        [self.tableScrollView setBorderType:NSBezelBorder];
        
        self.tableView = [[NSTableView alloc] initWithFrame:NSZeroRect];
        [self.tableScrollView setDocumentView:self.tableView];
        [self addSubview:self.tableScrollView];
    }
    return self;
}

- (void)setupWithTarget:(id)target actions:(SEL[])actions {
    // Create table columns
    NSArray *columnInfo = @[ @[@"name", @"Name", @150],
                             @[@"kernel", @"Kernel", @150],
                             @[@"rootfs", @"Root FS", @120],
                             @[@"active", @"Active", @60] ];
    for (NSArray *info in columnInfo) {
        NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:info[0]];
        [[col headerCell] setStringValue:info[1]];
        [col setWidth:[info[2] floatValue]];
        [self.tableView addTableColumn:col];
    }
    // Create buttons
    NSArray *buttonTitles = @[ @"Refresh", @"Create New", @"Edit", @"Delete", @"Set Active" ];
    NSMutableArray *buttons = [NSMutableArray array];
    for (NSUInteger i = 0; i < buttonTitles.count; i++) {
        NSButton *btn = [[NSButton alloc] initWithFrame:NSZeroRect];
        [btn setTitle:buttonTitles[i]];
        [btn setTarget:target];
        [btn setAction:actions[i]];
        [self addSubview:btn];
        [buttons addObject:btn];
    }
    self.buttonArray = buttons;
}

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
