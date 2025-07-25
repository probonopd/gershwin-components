#import "GlobalShortcutsController.h"

// Helper function to parse key combinations with both + and - separators
NSArray *parseKeyComboInPrefPane(NSString *keyCombo) {
    if (!keyCombo || [keyCombo length] == 0) {
        return nil;
    }
    
    // First try + separator
    NSArray *parts = [keyCombo componentsSeparatedByString:@"+"];
    if ([parts count] > 1) {
        return parts;
    }
    
    // Then try - separator
    parts = [keyCombo componentsSeparatedByString:@"-"];
    if ([parts count] > 1) {
        return parts;
    }
    
    // Single part, return as is
    return [NSArray arrayWithObject:keyCombo];
}

@interface ShortcutEditController : NSObject
{
    NSWindow *editWindow;
    NSTextField *keyComboField;
    NSTextField *commandField;
    NSButton *okButton;
    NSButton *cancelButton;
    NSMutableDictionary *currentShortcut;
    GlobalShortcutsController *parentController;
    BOOL isEditing;
}

- (id)initWithParent:(GlobalShortcutsController *)parent;
- (void)showSheetForShortcut:(NSMutableDictionary *)shortcut isEditing:(BOOL)editing parentWindow:(NSWindow *)parentWindow;
- (void)okClicked:(id)sender;
- (void)cancelClicked:(id)sender;

@end

@implementation GlobalShortcutsController

- (id)init
{
    self = [super init];
    if (self) {
        shortcuts = [[NSMutableArray alloc] init];
        isDaemonRunning = NO;
    }
    return self;
}

- (void)dealloc
{
    [mainView release];
    [shortcuts release];
    [super dealloc];
}

- (NSView *)createMainView
{
    if (mainView) {
        return mainView;
    }
    
    // Create main view
    mainView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 600, 400)];
    
    // Remove status label below the table
    // Create table view with scroll view
    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(12, 60, mainView.frame.size.width - 24, 280)];
    [scrollView setAutoresizingMask:NSViewWidthSizable];
    [scrollView setHasVerticalScroller:YES];
    [scrollView setHasHorizontalScroller:NO];
    [scrollView setBorderType:NSBezelBorder];
    
    shortcutsTable = [[NSTableView alloc] initWithFrame:[scrollView bounds]];
    [shortcutsTable setAutoresizingMask:NSViewWidthSizable];
    [shortcutsTable setDelegate:self];
    [shortcutsTable setDataSource:self];
    [shortcutsTable setDoubleAction:@selector(tableDoubleClicked:)];
    [shortcutsTable setTarget:self];
    
    // Create columns
    NSTableColumn *keyColumn = [[NSTableColumn alloc] initWithIdentifier:@"keyCombo"];
    [keyColumn setTitle:@"Key Combination"];
    [keyColumn setWidth:180];
    [keyColumn setMinWidth:100];
    [keyColumn setResizingMask:NSTableColumnAutoresizingMask];
    [keyColumn setEditable:NO];
    [shortcutsTable addTableColumn:keyColumn];
    [keyColumn release];
    
    NSTableColumn *commandColumn = [[NSTableColumn alloc] initWithIdentifier:@"command"];
    [commandColumn setTitle:@"Command"];
    [commandColumn setWidth:shortcutsTable.frame.size.width - 180 - 20];
    [commandColumn setMinWidth:100];
    [commandColumn setResizingMask:NSTableColumnAutoresizingMask];
    [commandColumn setEditable:NO];
    [shortcutsTable addTableColumn:commandColumn];
    [commandColumn release];
    
    [scrollView setDocumentView:shortcutsTable];
    [mainView addSubview:scrollView];
    [scrollView release];
    
    // Place buttons below the table, horizontally centered and autoresizing
    CGFloat buttonY = 20;
    CGFloat buttonWidth = 80;
    CGFloat buttonSpacing = 20;
    CGFloat totalButtonWidth = buttonWidth * 3 + buttonSpacing * 2;
    CGFloat startX = 12 + (mainView.frame.size.width - 24 - totalButtonWidth) / 2;
    
    addButton = [[NSButton alloc] init];
    [addButton setTitle:@"Add"];
    [addButton setTarget:self];
    [addButton setAction:@selector(addShortcut:)];
    [addButton sizeToFit];
    [addButton setFrame:NSMakeRect(startX, buttonY, buttonWidth, addButton.frame.size.height)];
    [addButton setAutoresizingMask:NSViewMinXMargin | NSViewMaxXMargin];
    [mainView addSubview:addButton];
    
    editButton = [[NSButton alloc] init];
    [editButton setTitle:@"Edit"];
    [editButton setTarget:self];
    [editButton setAction:@selector(editShortcut:)];
    [editButton setEnabled:NO];
    [editButton sizeToFit];
    [editButton setFrame:NSMakeRect(startX + buttonWidth + buttonSpacing, buttonY, buttonWidth, editButton.frame.size.height)];
    [editButton setAutoresizingMask:NSViewMinXMargin | NSViewMaxXMargin];
    [mainView addSubview:editButton];
    
    deleteButton = [[NSButton alloc] init];
    [deleteButton setTitle:@"Delete"];
    [deleteButton setTarget:self];
    [deleteButton setAction:@selector(deleteShortcut:)];
    [deleteButton setEnabled:NO];
    [deleteButton sizeToFit];
    [deleteButton setFrame:NSMakeRect(startX + (buttonWidth + buttonSpacing) * 2, buttonY, buttonWidth, deleteButton.frame.size.height)];
    [deleteButton setAutoresizingMask:NSViewMinXMargin | NSViewMaxXMargin];
    [mainView addSubview:deleteButton];
    
    return mainView;
}

- (void)refreshShortcuts:(NSTimer *)timer
{
    [self updateDaemonStatus];
    [self loadShortcutsFromDefaults];
    [shortcutsTable reloadData];
}

- (BOOL)loadShortcutsFromDefaults
{
    [shortcuts removeAllObjects];
    
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    
    // Only use GlobalShortcuts domain
    NSDictionary *globalShortcuts = [defaults persistentDomainForName:@"GlobalShortcuts"];
    
    if (!globalShortcuts || [globalShortcuts count] == 0) {
        [statusLabel setStringValue:@"No shortcuts configured. Add shortcuts to create GlobalShortcuts domain."];
        return NO;
    }
    
    // Convert dictionary to array of dictionaries for table view
    NSEnumerator *keyEnum = [globalShortcuts keyEnumerator];
    NSString *keyCombo;
    int shortcutCount = 0;
    
    while ((keyCombo = [keyEnum nextObject])) {
        NSString *command = [globalShortcuts objectForKey:keyCombo];
        if (command && [command length] > 0) {
            NSMutableDictionary *shortcut = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                keyCombo, @"keyCombo",
                command, @"command",
                nil];
            [shortcuts addObject:shortcut];
            shortcutCount++;
        }
    }
    
    NSString *daemonStatus = isDaemonRunning ? @"running" : @"not running";
    [statusLabel setStringValue:[NSString stringWithFormat:@"Loaded %d shortcuts. Daemon is %@", 
                               shortcutCount, daemonStatus]];
    
    return YES;
}

- (BOOL)saveShortcutsToDefaults
{
    NSMutableDictionary *globalShortcuts = [NSMutableDictionary dictionary];
    
    // Convert array of dictionaries back to key-value dictionary
    for (NSDictionary *shortcut in shortcuts) {
        NSString *keyCombo = [shortcut objectForKey:@"keyCombo"];
        NSString *command = [shortcut objectForKey:@"command"];
        if (keyCombo && command && [keyCombo length] > 0 && [command length] > 0) {
            [globalShortcuts setObject:command forKey:keyCombo];
        }
    }
    
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    
    // Save to primary domain
    [defaults setPersistentDomain:globalShortcuts forName:@"GlobalShortcuts"];
    [defaults synchronize];
    
    // Send SIGHUP to daemon to reload configuration
    if (isDaemonRunning) {
        system("killall -HUP globalshortcutsd 2>/dev/null");
    }
    
    return YES;
}

- (BOOL)isDaemonRunningCheck
{
    // Check if globalshortcutsd is running
    FILE *pipe = popen("pgrep -x globalshortcutsd", "r");
    if (!pipe) {
        return NO;
    }
    
    char buffer[128];
    BOOL found = (fgets(buffer, sizeof(buffer), pipe) != NULL);
    pclose(pipe);
    
    return found;
}

- (void)updateDaemonStatus
{
    isDaemonRunning = [self isDaemonRunningCheck];
}

- (void)addShortcut:(id)sender
{
    NSMutableDictionary *newShortcut = [NSMutableDictionary dictionaryWithObjectsAndKeys:
        @"", @"keyCombo",
        @"", @"command",
        nil];
    [self showAddEditShortcutSheet:newShortcut isEditing:NO];
}

- (void)editShortcut:(id)sender
{
    NSInteger selectedRow = [shortcutsTable selectedRow];
    if (selectedRow >= 0 && selectedRow < (NSInteger)[shortcuts count]) {
        NSMutableDictionary *shortcut = [shortcuts objectAtIndex:selectedRow];
        [self showAddEditShortcutSheet:shortcut isEditing:YES];
    }
}

- (void)deleteShortcut:(id)sender
{
    NSInteger selectedRow = [shortcutsTable selectedRow];
    if (selectedRow >= 0 && selectedRow < (NSInteger)[shortcuts count]) {
        [shortcuts removeObjectAtIndex:selectedRow];
        [self saveShortcutsToDefaults];
        [shortcutsTable reloadData];
        [self tableViewSelectionDidChange:nil];
    }
}

- (void)showAddEditShortcutSheet:(NSMutableDictionary *)shortcut isEditing:(BOOL)editing
{
    ShortcutEditController *editController = [[ShortcutEditController alloc] initWithParent:self];
    [editController showSheetForShortcut:shortcut isEditing:editing parentWindow:[mainView window]];
    [editController release];
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification
{
    NSInteger selectedRow = [shortcutsTable selectedRow];
    BOOL hasSelection = (selectedRow >= 0);
    
    [editButton setEnabled:hasSelection];
    [deleteButton setEnabled:hasSelection];
}

- (BOOL)isValidKeyCombo:(NSString *)keyCombo
{
    if (!keyCombo || [keyCombo length] == 0) {
        return NO;
    }
    
    NSArray *parts = parseKeyComboInPrefPane(keyCombo);
    if (!parts || [parts count] < 1) {
        return NO;
    }
    
    BOOL hasModifier = NO;
    BOOL hasKey = NO;
    
    for (NSString *part in parts) {
        NSString *cleanPart = [[part stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceCharacterSet]] lowercaseString];
        
        if ([cleanPart length] == 0) {
            return NO;
        }
        
        if ([cleanPart isEqualToString:@"ctrl"] || [cleanPart isEqualToString:@"control"] ||
            [cleanPart isEqualToString:@"shift"] || [cleanPart isEqualToString:@"alt"] ||
            [cleanPart isEqualToString:@"mod1"] || [cleanPart isEqualToString:@"mod2"] ||
            [cleanPart isEqualToString:@"mod3"] || [cleanPart isEqualToString:@"mod4"] ||
            [cleanPart isEqualToString:@"mod5"]) {
            hasModifier = YES;
        } else {
            hasKey = YES;
        }
    }
    
    return hasModifier && hasKey;
}

// Table view data source methods
- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
    return [shortcuts count];
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
    if (row >= 0 && row < (NSInteger)[shortcuts count]) {
        NSDictionary *shortcut = [shortcuts objectAtIndex:row];
        return [shortcut objectForKey:[tableColumn identifier]];
    }
    return nil;
}

// Table view delegate methods
- (void)tableView:(NSTableView *)tableView setObjectValue:(id)object forTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
    // Table cells are not editable - use double-click or Edit button instead
    return;
}

- (void)tableDoubleClicked:(id)sender
{
    NSInteger selectedRow = [shortcutsTable selectedRow];
    if (selectedRow >= 0 && selectedRow < (NSInteger)[shortcuts count]) {
        [self editShortcut:sender];
    }
}

@end

@implementation ShortcutEditController

- (id)initWithParent:(GlobalShortcutsController *)parent
{
    self = [super init];
    if (self) {
        parentController = parent;
    }
    return self;
}

- (void)showSheetForShortcut:(NSMutableDictionary *)shortcut isEditing:(BOOL)editing parentWindow:(NSWindow *)parentWindow
{
    currentShortcut = [shortcut retain];
    isEditing = editing;
    
    // Create edit window
    editWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 400, 150)
                                             styleMask:NSTitledWindowMask
                                               backing:NSBackingStoreBuffered
                                                 defer:NO];
    
    [editWindow setTitle:editing ? @"Edit Shortcut" : @"Add Shortcut"];
    
    NSView *contentView = [editWindow contentView];
    
    // Key combination label and field
    NSTextField *keyLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 100, 120, 20)];
    [keyLabel setEditable:NO];
    [keyLabel setSelectable:NO];
    [keyLabel setBezeled:NO];
    [keyLabel setDrawsBackground:NO];
    [keyLabel setStringValue:@"Key Combination:"];
    [contentView addSubview:keyLabel];
    [keyLabel release];
    
    keyComboField = [[NSTextField alloc] initWithFrame:NSMakeRect(150, 100, 220, 22)];
    [keyComboField setStringValue:[currentShortcut objectForKey:@"keyCombo"]];
    [contentView addSubview:keyComboField];
    
    // Command label and field
    NSTextField *commandLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 70, 120, 20)];
    [commandLabel setEditable:NO];
    [commandLabel setSelectable:NO];
    [commandLabel setBezeled:NO];
    [commandLabel setDrawsBackground:NO];
    [commandLabel setStringValue:@"Command:"];
    [contentView addSubview:commandLabel];
    [commandLabel release];
    
    commandField = [[NSTextField alloc] initWithFrame:NSMakeRect(150, 70, 220, 22)];
    [commandField setStringValue:[currentShortcut objectForKey:@"command"]];
    [contentView addSubview:commandField];
    
    // Buttons
    cancelButton = [[NSButton alloc] init];
    [cancelButton setTitle:@"Cancel"];
    [cancelButton setTarget:self];
    [cancelButton setAction:@selector(cancelClicked:)];
    [cancelButton sizeToFit];
    [cancelButton setFrame:NSMakeRect(220, 20, 80, cancelButton.frame.size.height)];
    [contentView addSubview:cancelButton];
    
    okButton = [[NSButton alloc] init];
    [okButton setTitle:@"OK"];
    [okButton setTarget:self];
    [okButton setAction:@selector(okClicked:)];
    [okButton setKeyEquivalent:@"\r"];
    [okButton sizeToFit];
    [okButton setFrame:NSMakeRect(310, 20, 80, okButton.frame.size.height)];
    [contentView addSubview:okButton];
    
    [NSApp beginSheet:editWindow modalForWindow:parentWindow modalDelegate:nil didEndSelector:nil contextInfo:nil];
}

- (void)okClicked:(id)sender
{
    NSString *keyCombo = [[keyComboField stringValue] stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceCharacterSet]];
    NSString *command = [[commandField stringValue] stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceCharacterSet]];
    
    if ([keyCombo length] == 0) {
        NSAlert *alert = [NSAlert alertWithMessageText:@"Invalid Input"
                                         defaultButton:@"OK"
                                       alternateButton:nil
                                           otherButton:nil
                             informativeTextWithFormat:@"Please enter a key combination."];
        [alert runModal];
        return;
    }
    
    if (![parentController isValidKeyCombo:keyCombo]) {
        NSAlert *alert = [NSAlert alertWithMessageText:@"Invalid Key Combination"
                                         defaultButton:@"OK"
                                       alternateButton:nil
                                           otherButton:nil
                             informativeTextWithFormat:@"Key combination format is invalid. Use format: modifier+modifier+key (e.g., ctrl+shift+t).\n\nSupported modifiers: ctrl, shift, alt, mod1-mod5\nSupported keys: a-z, 0-9, f1-f24, special keys, multimedia keys"];
        [alert runModal];
        return;
    }
    
    if ([command length] == 0) {
        NSAlert *alert = [NSAlert alertWithMessageText:@"Invalid Input"
                                         defaultButton:@"OK"
                                       alternateButton:nil
                                           otherButton:nil
                             informativeTextWithFormat:@"Please enter a command."];
        [alert runModal];
        return;
    }
    
    [currentShortcut setObject:keyCombo forKey:@"keyCombo"];
    [currentShortcut setObject:command forKey:@"command"];
    
    if (!isEditing) {
        [parentController->shortcuts addObject:currentShortcut];
    }
    
    [parentController saveShortcutsToDefaults];
    [parentController->shortcutsTable reloadData];
    
    [NSApp endSheet:editWindow];
    [editWindow orderOut:nil];
    [editWindow release];
    [currentShortcut release];
}

- (void)cancelClicked:(id)sender
{
    [NSApp endSheet:editWindow];
    [editWindow orderOut:nil];
    [editWindow release];
    [currentShortcut release];
}

@end
