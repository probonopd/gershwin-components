/*
 * Copyright (c) 2005 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

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
        
        // Create action buttons
        [self setupButtons];
        
        // Setup table columns and appearance
        [self setupTableView];
    }
    return self;
}

- (void)setupButtons {
    // Create action buttons with default style
    self.createButton = [[NSButton alloc] initWithFrame:NSZeroRect];
    [self.createButton setTitle:@"Create"];
    [self addSubview:self.createButton];
    
    self.editButton = [[NSButton alloc] initWithFrame:NSZeroRect];
    [self.editButton setTitle:@"Edit"];
    [self addSubview:self.editButton];
    
    self.deleteButton = [[NSButton alloc] initWithFrame:NSZeroRect];
    [self.deleteButton setTitle:@"Delete"];
    [self addSubview:self.deleteButton];
    
    self.setActiveButton = [[NSButton alloc] initWithFrame:NSZeroRect];
    [self.setActiveButton setTitle:@"Set Active"];
    [self addSubview:self.setActiveButton];
    
    self.mountButton = [[NSButton alloc] initWithFrame:NSZeroRect];
    [self.mountButton setTitle:@"Mount"];
    [self addSubview:self.mountButton];
    
    self.unmountButton = [[NSButton alloc] initWithFrame:NSZeroRect];
    [self.unmountButton setTitle:@"Unmount"];
    [self addSubview:self.unmountButton];
}

- (void)setupTableView {
    // Create table columns (removed kernel and rootfs columns)
    NSArray *columnInfo = @[ @[@"name", @"Name", @250],
                             @[@"size", @"Size", @100],
                             @[@"date", @"Date", @150],
                             @[@"active", @"Active", @80] ];
    for (NSArray *info in columnInfo) {
        NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:info[0]];
        [[col headerCell] setStringValue:info[1]];
        [col setWidth:[info[2] floatValue]];
        [col setMinWidth:40];
        [col setResizingMask:NSTableColumnAutoresizingMask];
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
    [self.tableView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [self.tableScrollView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
}

- (void)resizeSubviewsWithOldSize:(NSSize)oldSize {
    [super resizeSubviewsWithOldSize:oldSize];
    NSRect bounds = [self bounds];
    
    // Button layout at the bottom with default sizing
    CGFloat buttonHeight = 24; // Default button height
    CGFloat buttonSpacing = 10;
    CGFloat bottomMargin = 20;
    CGFloat leftMargin = 20;
    
    // Size buttons to fit their content
    [self.createButton sizeToFit];
    [self.editButton sizeToFit];
    [self.deleteButton sizeToFit];
    [self.setActiveButton sizeToFit];
    [self.mountButton sizeToFit];
    [self.unmountButton sizeToFit];
    
    // Position buttons in a row at the bottom
    CGFloat buttonY = bottomMargin;
    CGFloat currentX = leftMargin;
    
    NSRect createFrame = [self.createButton frame];
    createFrame.origin = NSMakePoint(currentX, buttonY);
    [self.createButton setFrame:createFrame];
    currentX += NSWidth(createFrame) + buttonSpacing;
    
    NSRect editFrame = [self.editButton frame];
    editFrame.origin = NSMakePoint(currentX, buttonY);
    [self.editButton setFrame:editFrame];
    currentX += NSWidth(editFrame) + buttonSpacing;
    
    NSRect deleteFrame = [self.deleteButton frame];
    deleteFrame.origin = NSMakePoint(currentX, buttonY);
    [self.deleteButton setFrame:deleteFrame];
    currentX += NSWidth(deleteFrame) + buttonSpacing;
    
    NSRect activeFrame = [self.setActiveButton frame];
    activeFrame.origin = NSMakePoint(currentX, buttonY);
    [self.setActiveButton setFrame:activeFrame];
    currentX += NSWidth(activeFrame) + buttonSpacing;
    
    NSRect mountFrame = [self.mountButton frame];
    mountFrame.origin = NSMakePoint(currentX, buttonY);
    [self.mountButton setFrame:mountFrame];
    currentX += NSWidth(mountFrame) + buttonSpacing;
    
    NSRect unmountFrame = [self.unmountButton frame];
    unmountFrame.origin = NSMakePoint(currentX, buttonY);
    [self.unmountButton setFrame:unmountFrame];
    
    // Layout table above the buttons - use more of the vertical space
    CGFloat tableTop = bounds.size.height - 20;
    CGFloat tableBottom = buttonY + buttonHeight + 10; // 10px spacing above buttons
    CGFloat availableHeight = tableTop - tableBottom;
    CGFloat tableHeight = availableHeight * 0.8; // Use 80% of available height instead of 50%
    CGFloat tableStartY = tableBottom + (availableHeight - tableHeight) * 0.5; // Center vertically in remaining space
    
    NSRect tableRect = NSMakeRect(leftMargin, tableStartY, bounds.size.width - 40, tableHeight);
    [self.tableScrollView setFrame:tableRect];
}

@end
