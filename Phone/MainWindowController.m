/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "MainWindowController.h"

@interface MainWindowController ()
@property (strong) SIPManager *sipManager;
@property (strong) NSTextField *statusField;
@property (strong) NSTextField *numberField;
@property (strong) NSButton *callButton;
@property (strong) NSButton *hangupButton;
@property (strong) NSButton *muteButton;
@property (strong) NSSlider *volumeSlider;
@property (strong) NSTextField *statusBar;

@property (strong) NSMutableArray *contacts;
@property (strong) NSTableView *tableView;

// Persistent lightweight alert panel to avoid repeated NSAlert allocations
@property (strong) NSWindow *persistentAlertPanel;
@property (copy) void (^persistentAlertHandler)(void);

// Helper: create or update a persistent lightweight panel
- (void)ensurePersistentAlertPanel;
- (void)showPersistentAlertWithTitle:(NSString *)title message:(NSString *)message buttonTitle:(NSString *)buttonTitle handler:(void(^)(void))handler;
- (void)_persistentAlertOK:(id)sender;
@end

@implementation MainWindowController

- (instancetype)initWithSIPManager:(SIPManager *)manager {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 550, 480)
                                                   styleMask:NSTitledWindowMask | NSClosableWindowMask | NSMiniaturizableWindowMask
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    [window setTitle:@"Phone"];

    self = [super initWithWindow:window];
    if (self) {
        _sipManager = manager;
        _sipManager.delegate = self;
        
        NSArray *saved = [[NSUserDefaults standardUserDefaults] arrayForKey:@"SavedContacts"];
        if (saved) {
            _contacts = [saved mutableCopy];
        } else {
            _contacts = [NSMutableArray array];
        }
        
        [self setupUI];
    }
    return self;
}

- (void)setupUI {
    NSView *contentView = [self.window contentView];
    
    // --- Left Pane: Phone ---
    
    // Status Field
    self.statusField = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 440, 260, 20)];
    [self.statusField setBezeled:NO];
    [self.statusField setDrawsBackground:NO];
    [self.statusField setEditable:NO];
    [self.statusField setSelectable:NO];
    [self.statusField setAlignment:NSCenterTextAlignment];
    [self.statusField setStringValue:@"Initializing..."];
    [contentView addSubview:self.statusField];
    
    // Number Field
    self.numberField = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 400, 260, 30)];
    [self.numberField setFont:[NSFont systemFontOfSize:18]];
    [self.numberField setAlignment:NSCenterTextAlignment];
    [self.numberField setTarget:self];
    [self.numberField setAction:@selector(makeCall:)];
    [contentView addSubview:self.numberField];
    
    // Dialpad
    NSArray *labels = @[@"1", @"2", @"3", @"4", @"5", @"6", @"7", @"8", @"9", @"*", @"0", @"#"];
    CGFloat startX = 40;
    CGFloat startY = 350;
    CGFloat width = 60;
    CGFloat height = 40;
    CGFloat padding = 20;
    
    int col = 0;
    int row = 0;
    
    for (NSString *label in labels) {
        NSButton *btn = [[NSButton alloc] initWithFrame:NSMakeRect(startX + (col * (width + padding)), startY - (row * (height + padding)), width, height)];
        [btn setTitle:label];
        [btn setTarget:self];
        [btn setAction:@selector(digitPressed:)];
        [contentView addSubview:btn];
        
        col++;
        if (col > 2) {
            col = 0;
            row++;
        }
    }
    
    // Call Button
    self.callButton = [[NSButton alloc] initWithFrame:NSMakeRect(40, 80, 100, 40)];
    [self.callButton setTitle:@"Call"];
    [self.callButton setTarget:self];
    [self.callButton setAction:@selector(makeCall:)];
    [self.callButton setKeyEquivalent:@"\r"];
    [contentView addSubview:self.callButton];

    // Hangup Button
    self.hangupButton = [[NSButton alloc] initWithFrame:NSMakeRect(160, 80, 100, 40)];
    [self.hangupButton setTitle:@"Hangup"];
    [self.hangupButton setTarget:self];
    [self.hangupButton setAction:@selector(hangup:)];
    [self.hangupButton setEnabled:NO];
    [contentView addSubview:self.hangupButton];

    // Volume Slider
    self.volumeSlider = [[NSSlider alloc] initWithFrame:NSMakeRect(40, 45, 100, 20)];
    [self.volumeSlider setMinValue:0];
    [self.volumeSlider setMaxValue:100];
    [self.volumeSlider setDoubleValue:80];
    [self.volumeSlider setTarget:self];
    [self.volumeSlider setAction:@selector(volumeChanged:)];
    [contentView addSubview:self.volumeSlider];
    
    // Mute Button
    self.muteButton = [[NSButton alloc] initWithFrame:NSMakeRect(160, 45, 100, 25)];
    [self.muteButton setButtonType:NSToggleButton];
    [self.muteButton setTitle:@"Mute"];
    [self.muteButton setTarget:self];
    [self.muteButton setAction:@selector(muteToggled:)];
    [contentView addSubview:self.muteButton];
    
    // --- Right Pane: Address Book ---
    
    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(300, 80, 230, 380)];
    [scrollView setHasVerticalScroller:YES];
    [scrollView setBorderType:NSBezelBorder];
    
    self.tableView = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, 230, 380)];
    NSTableColumn *nameCol = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    [[nameCol headerCell] setStringValue:@"Name"];
    [nameCol setWidth:100];
    [self.tableView addTableColumn:nameCol];
    
    NSTableColumn *numCol = [[NSTableColumn alloc] initWithIdentifier:@"number"];
    [[numCol headerCell] setStringValue:@"Number"];
    [numCol setWidth:100];
    [self.tableView addTableColumn:numCol];
    
    [self.tableView setDataSource:self];
    [self.tableView setDelegate:self];
    [self.tableView setDoubleAction:@selector(tableDoubleClicked:)];
    [self.tableView setTarget:self];
    
    [scrollView setDocumentView:self.tableView];
    [contentView addSubview:scrollView];
    
    NSButton *addBtn = [[NSButton alloc] initWithFrame:NSMakeRect(300, 40, 110, 32)];
    [addBtn setTitle:@"Add"];
    [addBtn setTarget:self];
    [addBtn setAction:@selector(addContact:)];
    [contentView addSubview:addBtn];
    
    NSButton *removeBtn = [[NSButton alloc] initWithFrame:NSMakeRect(420, 40, 110, 32)];
    [removeBtn setTitle:@"Remove"];
    [removeBtn setTarget:self];
    [removeBtn setAction:@selector(removeContact:)];
    [contentView addSubview:removeBtn];

    // Status Bar
    self.statusBar = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 550, 22)];
    [self.statusBar setBezeled:NO];
    [self.statusBar setDrawsBackground:YES];
    [self.statusBar setBackgroundColor:[NSColor windowBackgroundColor]];
    [self.statusBar setEditable:NO];
    [self.statusBar setSelectable:NO];
    [self.statusBar setFont:[NSFont systemFontOfSize:11]];
    [self.statusBar setStringValue:@" Ready"];
    [contentView addSubview:self.statusBar];
}

- (void)ensurePersistentAlertPanel {
    if (self.persistentAlertPanel) return;

    NSRect frame = NSMakeRect(0, 0, 400, 160);
    NSWindow *panel = [[NSWindow alloc] initWithContentRect:frame
                                                    styleMask:(NSTitledWindowMask | NSClosableWindowMask)
                                                      backing:NSBackingStoreBuffered
                                                        defer:NO];
    [panel setReleasedWhenClosed:NO];

    NSView *content = [panel contentView];

    NSTextField *titleField = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 110, 360, 24)];
    [titleField setBezeled:NO];
    [titleField setDrawsBackground:NO];
    [titleField setEditable:NO];
    [titleField setSelectable:NO];
    [titleField setFont:[NSFont boldSystemFontOfSize:14]];
    titleField.tag = 1001;
    [content addSubview:titleField];

    NSTextField *messageField = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 50, 360, 48)];
    [messageField setBezeled:NO];
    [messageField setDrawsBackground:NO];
    [messageField setEditable:NO];
    [messageField setSelectable:NO];
    messageField.tag = 1002;
    [content addSubview:messageField];

    NSButton *ok = [[NSButton alloc] initWithFrame:NSMakeRect(160, 12, 80, 28)];
    [ok setBezelStyle:NSRoundedBezelStyle];
    [ok setTitle:@"OK"];
    [ok setTarget:self];
    [ok setAction:@selector(_persistentAlertOK:)];
    ok.tag = 1003;
    [content addSubview:ok];

    self.persistentAlertPanel = panel;
}

- (void)showPersistentAlertWithTitle:(NSString *)title message:(NSString *)message buttonTitle:(NSString *)buttonTitle handler:(void(^)(void))handler {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self ensurePersistentAlertPanel];
        NSView *content = [self.persistentAlertPanel contentView];
        NSTextField *titleField = [content viewWithTag:1001];
        NSTextField *messageField = [content viewWithTag:1002];
        NSButton *ok = [content viewWithTag:1003];

        [titleField setStringValue:title ?: @""];
        [messageField setStringValue:message ?: @""];
        [ok setTitle:buttonTitle ?: @"OK"];

        self.persistentAlertHandler = handler;

        [[NSApplication sharedApplication] activateIgnoringOtherApps:YES];
        [self.persistentAlertPanel center];
        [self.persistentAlertPanel makeKeyAndOrderFront:self];
    });
}

- (void)_persistentAlertOK:(id)sender {
    if (self.persistentAlertHandler) self.persistentAlertHandler();
    [self.persistentAlertPanel orderOut:nil];
    self.persistentAlertHandler = nil;
}

- (void)digitPressed:(id)sender {
    NSButton *btn = sender;
    NSString *digit = [btn title];
    if (self.sipManager.isInCall) {
        if (digit.length > 0)
             [self.sipManager sendDTMF:(char)[digit characterAtIndex:0]];
    } else {
        NSString *current = [self.numberField stringValue];
        [self.numberField setStringValue:[current stringByAppendingString:digit]];
    }
}

- (void)makeCall:(id)sender {
    NSString *number = [self.numberField stringValue];
    if (number.length > 0) {
        [self.sipManager makeCall:number];
    }
}

- (void)answerCall:(id)sender {
    [self.sipManager answer];
}

- (void)hangup:(id)sender {
    [self.sipManager hangup];
}

- (void)volumeChanged:(id)sender {
    [self.sipManager setVolume:[self.volumeSlider doubleValue]];
}

- (void)muteToggled:(id)sender {
    [self.sipManager setMuted:[self.muteButton state] == NSOnState];
}

#pragma mark - Address Book

- (void)addContact:(id)sender {
    NSString *currentNumber = [self.numberField stringValue];
    NSMutableDictionary *newContact = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                       @"New Contact", @"name",
                                       currentNumber, @"number",
                                       nil];
    [self.contacts addObject:newContact];
    [self.tableView reloadData];
    [self saveContacts];
}

- (void)removeContact:(id)sender {
    NSInteger row = [self.tableView selectedRow];
    if (row >= 0 && row < self.contacts.count) {
        [self.contacts removeObjectAtIndex:row];
        [self.tableView reloadData];
        [self saveContacts];
    }
}

- (void)saveContacts {
    [[NSUserDefaults standardUserDefaults] setObject:self.contacts forKey:@"SavedContacts"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)tableDoubleClicked:(id)sender {
    NSInteger row = [self.tableView clickedRow];
    if (row >= 0 && row < self.contacts.count) {
        NSDictionary *contact = [self.contacts objectAtIndex:row];
        NSString *number = [contact objectForKey:@"number"];
        [self.numberField setStringValue:number];
        [self makeCall:nil];
    }
}

#pragma mark - NSTableViewDataSource

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return self.contacts.count;
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    NSDictionary *contact = [self.contacts objectAtIndex:row];
    return [contact objectForKey:[tableColumn identifier]];
}

- (void)tableView:(NSTableView *)tableView setObjectValue:(id)object forTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    NSMutableDictionary *contact = [self.contacts objectAtIndex:row];
    [contact setObject:object forKey:[tableColumn identifier]];
    [self saveContacts];
}

#pragma mark - SIPManagerDelegate

- (void)callStateChanged:(NSString *)state {
    [self.statusField setStringValue:state];
    [self.statusBar setStringValue:[NSString stringWithFormat:@" Call: %@", state]];
    
    if ([state isEqualToString:@"Incoming Call"]) {
         [self.callButton setTitle:@"Answer"];
         [self.callButton setEnabled:YES];
         [self.callButton setAction:@selector(answerCall:)];
         [self.hangupButton setEnabled:YES];
    } else if (self.sipManager.isInCall || [state isEqualToString:@"Ringing..."] || [state isEqualToString:@"Calling..."] || [state isEqualToString:@"Connecting..."]) {
        [self.callButton setEnabled:NO];
        [self.hangupButton setEnabled:YES];
        [self.callButton setTitle:@"Call"];
        [self.callButton setAction:@selector(makeCall:)];
    } else {
        [self.callButton setEnabled:YES];
        [self.hangupButton setEnabled:NO];
        [self.callButton setTitle:@"Call"];
        [self.callButton setAction:@selector(makeCall:)];
    }
}

- (void)registrationStateChanged:(NSString *)state {
    if (!self.sipManager.isInCall) {
        [self.statusField setStringValue:state];
    }
    [self.statusBar setStringValue:[NSString stringWithFormat:@" Reg: %@", state]];
    [self.window setTitle:[NSString stringWithFormat:@"Phone - %@", state]];
    
    // Disable call button when not registered
    BOOL isRegistered = [state isEqualToString:@"Registered"];
    [self.callButton setEnabled:isRegistered];
}

- (void)incomingCallFrom:(NSString *)number {
    [self.numberField setStringValue:number];
    [[NSApplication sharedApplication] activateIgnoringOtherApps:YES];
    [self.window makeKeyAndOrderFront:self];

    // Use a persistent lightweight panel for incoming calls to avoid layout churn
    [self showPersistentAlertWithTitle:@"Incoming Call"
                                message:[NSString stringWithFormat:@"Incoming call from %@", number]
                           buttonTitle:@"Answer"
                               handler:^{
                                   [self answerCall:nil];
                               }];
}

- (void)sipManagerDidReceiveError:(NSString *)title message:(NSString *)message {
    // Show persistent lightweight alert to notify the user without creating new NSAlert each time
    [self showPersistentAlertWithTitle:title
                                message:message
                           buttonTitle:@"OK"
                               handler:^{
                                   // No-op handler for OK
                               }];
}

- (void)closeActiveAlert {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.persistentAlertPanel) {
            [self.persistentAlertPanel orderOut:nil];
            self.persistentAlertHandler = nil;
        }
    });
}

@end
