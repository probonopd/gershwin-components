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
        
        // Setup table columns and appearance
        [self setupTableView];
    }
    return self;
}

- (void)setupTableView {
    // Create table columns
    NSArray *columnInfo = @[ @[@"name", @"Name", @150],
                             @[@"kernel", @"Kernel", @150],
                             @[@"rootfs", @"Root FS", @120],
                             @[@"size", @"Size", @80],
                             @[@"date", @"Date", @120],
                             @[@"active", @"Active", @60] ];
    for (NSArray *info in columnInfo) {
        NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:info[0]];
        [[col headerCell] setStringValue:info[1]];
        [col setWidth:[info[2] floatValue]];
        // Make column non-editable
        [col setEditable:NO];
        [self.tableView addTableColumn:col];
    }
    // Mac-like table appearance
    [self.tableView setUsesAlternatingRowBackgroundColors:YES];
    if ([self.tableView respondsToSelector:@selector(setSelectionHighlightStyle:)]) {
        [self.tableView setSelectionHighlightStyle:NSTableViewSelectionHighlightStyleRegular];
    }
    [self.tableView setRowHeight:22.0];
    NSFont *font = [NSFont systemFontOfSize:13.0];
    [self.tableView setFont:font];
}

- (void)resizeSubviewsWithOldSize:(NSSize)oldSize {
    [super resizeSubviewsWithOldSize:oldSize];
    NSRect bounds = [self bounds];
    
    // Layout table to fill the entire view with margins
    NSRect tableRect = NSMakeRect(20, 20, bounds.size.width - 40, bounds.size.height - 40);
    [self.tableScrollView setFrame:tableRect];
}

@end
