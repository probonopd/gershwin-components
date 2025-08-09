//
// GSSelectionStep.m
// GSAssistantFramework - Selection Step Base Class
//

#import "GSSelectionStep.h"

@implementation GSSelectionStep

@synthesize stepTitle = _stepTitle;
@synthesize stepDescription = _stepDescription;
@synthesize tableView = _tableView;
@synthesize arrayController = _arrayController;
@synthesize items = _items;
@synthesize selectedItem = _selectedItem;
@synthesize allowsEmptySelection = _allowsEmptySelection;
@synthesize allowsMultipleSelection = _allowsMultipleSelection;

- (id)init
{
    if (self = [super init]) {
        NSLog(@"GSSelectionStep: init");
        _items = [[NSMutableArray alloc] init];
        _stepTitle = [@"Selection" retain];
        _stepDescription = [@"Please make a selection" retain];
        _allowsEmptySelection = NO;
        _allowsMultipleSelection = NO;
        [self setupView];
    }
    return self;
}

- (void)dealloc
{
    NSLog(@"GSSelectionStep: dealloc");
    [_stepView release];
    [_items release];
    [_stepTitle release];
    [_stepDescription release];
    [_selectedItem release];
    [_arrayController release];
    [super dealloc];
}

- (void)setupView
{
    NSLog(@"GSSelectionStep: setupView");
    
    _stepView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 480, 360)];
    
    // Main container
    NSView *containerView = [[NSView alloc] initWithFrame:NSMakeRect(20, 20, 440, 320)];
    [_stepView addSubview:containerView];
    
    // Create table view
    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 60, 440, 200)];
    [scrollView setHasVerticalScroller:YES];
    [scrollView setHasHorizontalScroller:NO];
    [scrollView setBorderType:NSBezelBorder];
    
    _tableView = [[NSTableView alloc] init];
    [_tableView setAllowsMultipleSelection:_allowsMultipleSelection];
    [_tableView setAllowsEmptySelection:_allowsEmptySelection];
    
    [scrollView setDocumentView:_tableView];
    [containerView addSubview:scrollView];
    [scrollView release];
    
    // Create array controller
    _arrayController = [[NSArrayController alloc] init];
    [_arrayController setContent:_items];
    
    // Bind selection
    [_tableView bind:@"selectionIndexes" 
            toObject:_arrayController 
         withKeyPath:@"selectionIndexes" 
             options:nil];
    
    // Selection change notification
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(tableSelectionDidChange:)
                                                 name:NSTableViewSelectionDidChangeNotification
                                               object:_tableView];
    
    // Let subclasses set up table columns
    [self setupTableColumns];
    
    // Let subclasses add additional views
    [self setupAdditionalViews:containerView];
    
    [containerView release];
}

- (void)setupTableColumns
{
    // Default implementation - subclasses should override
    [self addTableColumn:@"description" title:@"Item" width:300 keyPath:@"description"];
}

- (void)setupAdditionalViews:(NSView *)containerView
{
    // Default implementation - subclasses can override
    // Add any additional controls above or below the table
}

- (void)addTableColumn:(NSString *)identifier title:(NSString *)title width:(CGFloat)width keyPath:(NSString *)keyPath
{
    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:identifier];
    [[column headerCell] setStringValue:title];
    [column setWidth:width];
    [_tableView addTableColumn:column];
    
    // Bind the column to the array controller
    [column bind:@"value" 
        toObject:_arrayController 
     withKeyPath:[NSString stringWithFormat:@"arrangedObjects.%@", keyPath] 
         options:nil];
    
    [column release];
}

- (void)refreshItems
{
    [_arrayController rearrangeObjects];
}

- (void)selectItemAtIndex:(NSInteger)index
{
    if (index >= 0 && index < (NSInteger)[_items count]) {
        [_arrayController setSelectionIndex:index];
    }
}

- (void)tableSelectionDidChange:(NSNotification *)notification
{
    NSLog(@"GSSelectionStep: tableSelectionDidChange");
    
    NSInteger selectedRow = [_tableView selectedRow];
    
    if (selectedRow >= 0 && selectedRow < (NSInteger)[_items count]) {
        [_selectedItem release];
        _selectedItem = [[_items objectAtIndex:selectedRow] retain];
    } else {
        [_selectedItem release];
        _selectedItem = nil;
    }
    
    // Call subclass method
    [self selectionDidChange];
    
    // Update navigation buttons based on new selection
    [self requestNavigationUpdate];
}

- (void)selectionDidChange
{
    // Default implementation - subclasses should override
}

- (void)loadItems
{
    // Default implementation - subclasses should override
}

#pragma mark - GSAssistantStepProtocol

- (NSString *)stepTitle
{
    return _stepTitle;
}

- (NSString *)stepDescription  
{
    return _stepDescription;
}

- (NSView *)stepView
{
    return _stepView;
}

- (BOOL)canContinue
{
    if (_allowsEmptySelection) {
        return YES;
    }
    return (_selectedItem != nil);
}

- (void)stepWillAppear
{
    NSLog(@"GSSelectionStep: stepWillAppear");
    [self loadItems];
}

- (void)stepDidAppear
{
    NSLog(@"GSSelectionStep: stepDidAppear");
}

- (void)stepWillDisappear
{
    NSLog(@"GSSelectionStep: stepWillDisappear");
}

- (void)requestNavigationUpdate
{
    NSWindow *window = [[self stepView] window];
    if (!window) {
        window = [NSApp keyWindow];
    }
    NSWindowController *wc = [window windowController];
    if ([wc isKindOfClass:[GSAssistantWindow class]]) {
        NSLog(@"GSSelectionStep: requesting navigation button update");
        GSAssistantWindow *assistantWindow = (GSAssistantWindow *)wc;
        [assistantWindow updateNavigationButtons];
    } else {
        NSLog(@"GSSelectionStep: could not find GSAssistantWindow to update navigation (wc=%@)", wc);
    }
}

@end
