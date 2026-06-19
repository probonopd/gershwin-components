/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "GlobalShortcutsController.h"
#include <dirent.h>
#include <ctype.h>
#include <string.h>
#if !defined(__linux__)
#include <sys/param.h>
#include <sys/user.h>
#include <sys/sysctl.h>
#endif

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

// Forward declaration
@class ShortcutEditController;

// Will define ShortcutEditWindow after ShortcutEditController interface

@interface ShortcutEditController : NSObject
{
    NSWindow *editWindow;
    NSTextField *keyComboField;
    NSTextField *commandField;
    NSButton *okButton;
    NSButton *cancelButton;
    NSButton *setButton;
    NSMutableDictionary *currentShortcut;
    GlobalShortcutsController *parentController;
    BOOL isEditing;
    BOOL isCapturingKeyCombo;
    NSMutableArray *capturedModifiers;
}

- (id)initWithParent:(GlobalShortcutsController *)parent;
- (void)showSheetForShortcut:(NSMutableDictionary *)shortcut isEditing:(BOOL)editing parentWindow:(NSWindow *)parentWindow;
- (void)okClicked:(id)sender;
- (void)cancelClicked:(id)sender;
- (void)setKeyComboClicked:(id)sender;
- (void)startCapturingKeyCombo;
- (void)stopCapturingKeyCombo;
- (void)handleKeyEvent:(NSEvent *)event;
- (BOOL)isCapturingKeyCombo;
- (NSString *)getModifierKeysFromEvent:(NSEvent *)event;
- (NSString *)getKeyNameFromEvent:(NSEvent *)event;
- (NSString *)convertKeyCodeToName:(unsigned short)keyCode;

@end

// Now define ShortcutEditWindow after we know ShortcutEditController's interface
@interface ShortcutEditWindow : NSWindow
{
    ShortcutEditController *editController;
}
- (void)setEditController:(ShortcutEditController *)controller;
@end

@implementation ShortcutEditWindow

- (void)setEditController:(ShortcutEditController *)controller
{
    editController = controller;
}

- (void)keyDown:(NSEvent *)event
{
    if (editController && [editController isCapturingKeyCombo]) {
        [editController handleKeyEvent:event];
    } else {
        [super keyDown:event];
    }
}

@end

@implementation GlobalShortcutsController

- (id)init
{
    self = [super init];
    if (self) {
        shortcuts = [[NSMutableArray alloc] init];
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
    [self loadShortcutsFromDefaults];
    [shortcutsTable reloadData];
}

- (BOOL)loadShortcutsFromDefaults
{
    [shortcuts removeAllObjects];
    
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    
    // Merge GlobalShortcuts from system and user domains.
    // System-level files (if present) are read first and then user-level entries override them.
    NSMutableDictionary *merged = [NSMutableDictionary dictionary];

    NSArray *systemPaths = @[@"/System/Library/Preferences/GlobalShortcuts.plist",
                             @"/Library/Preferences/GlobalShortcuts.plist"];

    for (NSString *p in systemPaths) {
        NSDictionary *sys = [NSDictionary dictionaryWithContentsOfFile:p];
        if (sys && [sys count] > 0) {
            [merged addEntriesFromDictionary:sys];
        }
    }

    NSDictionary *userDomain = [defaults persistentDomainForName:@"GlobalShortcuts"];
    if (userDomain && [userDomain count] > 0) {
        // User overrides system entries
        [merged addEntriesFromDictionary:userDomain];
    }

    if (!merged || [merged count] == 0) {
        [statusLabel setStringValue:@"No shortcuts configured. Add shortcuts to create GlobalShortcuts domain."];
        return NO;
    }

    // Convert merged dictionary to array of dictionaries for table view
    NSEnumerator *keyEnum = [merged keyEnumerator];
    NSString *keyCombo;
    int shortcutCount = 0;

    while ((keyCombo = [keyEnum nextObject])) {
        NSString *command = [merged objectForKey:keyCombo];
        if (command && [command length] > 0) {
            NSMutableDictionary *shortcut = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                keyCombo, @"keyCombo",
                command, @"command",
                nil];
            [shortcuts addObject:shortcut];
            shortcutCount++;
        }
    }
    
    NSString *status = [NSString stringWithFormat:@"Loaded %d shortcuts. Changes will be applied to Workspace automatically.", 
                       shortcutCount];
    [statusLabel setStringValue:status];
    
    return YES;
}

- (BOOL)saveShortcutsToDefaults
{
    NSMutableDictionary *globalShortcuts = [NSMutableDictionary dictionary];
    NSMutableArray *shortcutsArray = [NSMutableArray array];
    
    // Convert array of dictionaries (user-edited shortcuts) back to key-value dictionary
    for (NSDictionary *shortcut in shortcuts) {
        NSString *keyCombo = [shortcut objectForKey:@"keyCombo"];
        NSString *command = [shortcut objectForKey:@"command"];
        if (keyCombo && command && [keyCombo length] > 0 && [command length] > 0) {
            [globalShortcuts setObject:command forKey:keyCombo];
        }
    }
    
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    
    // Save to primary domain (user overrides system)
    [defaults setPersistentDomain:globalShortcuts forName:@"GlobalShortcuts"];
    [defaults synchronize];
    
    // Build IPC payload from the merged view: system defaults overridden by user entries
    NSMutableDictionary *merged = [NSMutableDictionary dictionary];
    NSArray *systemPaths = @[@"/System/Library/Preferences/GlobalShortcuts.plist",
                             @"/Library/Preferences/GlobalShortcuts.plist"];
    for (NSString *p in systemPaths) {
        NSDictionary *sys = [NSDictionary dictionaryWithContentsOfFile:p];
        if (sys && [sys count] > 0) {
            [merged addEntriesFromDictionary:sys];
        }
    }
    
    // Overlay with user-provided entries (saved to the domain above)
    NSDictionary *userDomain = [defaults persistentDomainForName:@"GlobalShortcuts"];
    if (userDomain && [userDomain count] > 0) {
        [merged addEntriesFromDictionary:userDomain];
    }
    
    // Create IPC array from merged entries
    NSEnumerator *mergedEnum = [merged keyEnumerator];
    NSString *mkey;
    while ((mkey = [mergedEnum nextObject])) {
        NSString *mcommand = [merged objectForKey:mkey];
        if (mcommand && [mcommand length] > 0) {
            NSArray *parts = [mkey componentsSeparatedByString:@"+"];
            NSString *keyStr = [parts lastObject];
            NSMutableArray *modifierParts = [NSMutableArray array];
            for (NSUInteger i = 0; i < [parts count] - 1; i++) {
                [modifierParts addObject:[parts objectAtIndex:i]];
            }
            NSString *modifiersStr = [modifierParts componentsJoinedByString:@"+"];
            NSDictionary *entry = @{
                @"key": mkey,
                @"command": mcommand,
                @"modifiers": modifiersStr ?: @"",
                @"keyStr": keyStr ?: @""
            };
            [shortcutsArray addObject:entry];
        }
    }
    
    // Debug: log what we're about to send
    NSDebugLLog(@"gwcomp", @"GlobalShortcuts: Shortcuts array to send: %@", shortcutsArray);
    
    NSDictionary *userInfo = @{
        @"shortcutCount": @([globalShortcuts count]),
        @"shortcuts": shortcutsArray
    };
    NSDebugLLog(@"gwcomp", @"GlobalShortcuts: UserInfo to send: %@", userInfo);
    
    // Post distributed notification for cross-application communication with shortcuts data
    [[NSDistributedNotificationCenter defaultCenter] 
        postNotificationName:@"GSGlobalShortcutsConfigurationChanged"
                      object:@"GlobalShortcuts"
                    userInfo:userInfo];
    
    NSDebugLLog(@"gwcomp", @"GlobalShortcuts: Saved %lu shortcuts to defaults and posted distributed notification", (unsigned long)[globalShortcuts count]);
    
    return YES;
}

- (pid_t)findProcessByName:(NSString *)processName
{
#if defined(__linux__)
    // Linux implementation using /proc filesystem
    DIR *proc_dir = opendir("/proc");
    if (!proc_dir) {
        return -1;
    }
    
    struct dirent *entry;
    pid_t result = -1;
    
    while ((entry = readdir(proc_dir)) != NULL) {
        // Skip non-numeric entries
        if (!isdigit(entry->d_name[0])) {
            continue;
        }
        
        pid_t pid = atoi(entry->d_name);
        
        // Skip kernel processes and init
        if (pid <= 1) {
            continue;
        }
        
        // Read /proc/PID/stat to get command name
        char stat_path[256];
        snprintf(stat_path, sizeof(stat_path), "/proc/%d/stat", pid);
        
        FILE *stat_file = fopen(stat_path, "r");
        if (!stat_file) {
            continue;
        }
        
        char comm[256];
        int parsed_pid;
        
        // Parse: pid (comm) ...
        if (fscanf(stat_file, "%d (%255[^)])", &parsed_pid, comm) == 2) {
            if (strcmp(comm, [processName UTF8String]) == 0) {
                result = pid;
                fclose(stat_file);
                break;
            }
        }
        
        fclose(stat_file);
    }
    
    closedir(proc_dir);
    return result;
    
#else
    // BSD implementation using sysctl. OpenBSD's KERN_PROC needs a 6-element
    // mib carrying the struct size and element count; FreeBSD uses 3. The
    // command/pid fields are p_* on OpenBSD, ki_* on FreeBSD.
#if defined(__OpenBSD__)
    int mib[6] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0,
                  sizeof(struct kinfo_proc), 0};
    int miblen = 6;
#else
    int mib[3] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL};
    int miblen = 3;
#endif
    size_t size = 0;

    if (sysctl(mib, miblen, NULL, &size, NULL, 0) != 0) {
        return -1;
    }

    struct kinfo_proc *procs = malloc(size);
    if (!procs) {
        return -1;
    }

#if defined(__OpenBSD__)
    mib[5] = (int)(size / sizeof(struct kinfo_proc));
#endif
    if (sysctl(mib, miblen, procs, &size, NULL, 0) != 0) {
        free(procs);
        return -1;
    }

    int numProcs = size / sizeof(struct kinfo_proc);
    pid_t result = -1;

    for (int i = 0; i < numProcs; i++) {
#if defined(__OpenBSD__)
        const char *pcomm = procs[i].p_comm;
        pid_t ppid = procs[i].p_pid;
#else
        const char *pcomm = procs[i].ki_comm;
        pid_t ppid = procs[i].ki_pid;
#endif
        if (strcmp(pcomm, [processName UTF8String]) == 0) {
            result = ppid;
            break;
        }
    }

    free(procs);
    return result;
#endif
}

- (void)updateDaemonStatus
{
    // No longer using separate daemon - Workspace handles global shortcuts directly
    // This method is kept for compatibility but does nothing
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
    // Note: editController will release itself when the sheet ends
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
    NSString *keyPart = nil;
    
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
            keyPart = cleanPart;
        }
    }
    
    // CRITICAL: Require at least one modifier key - no bare keys allowed
    if (!hasModifier) {
        return NO;
    }
    
    // CRITICAL: Reject Tab key to allow proper focus navigation
    if ([keyPart isEqualToString:@"tab"]) {
        return NO;
    }
    
    return hasKey;
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
        isCapturingKeyCombo = NO;
        capturedModifiers = nil;
    }
    return self;
}

- (void)dealloc
{
    if (isCapturingKeyCombo) {
        [self stopCapturingKeyCombo];
    }
    if (capturedModifiers) {
        [capturedModifiers release];
    }
    if (editWindow) {
        [editWindow release];
    }
    if (keyComboField) {
        [keyComboField release];
    }
    if (commandField) {
        [commandField release];
    }
    if (okButton) {
        [okButton release];
    }
    if (cancelButton) {
        [cancelButton release];
    }
    if (setButton) {
        [setButton release];
    }
    if (currentShortcut) {
        [currentShortcut release];
    }
    [super dealloc];
}

- (void)showSheetForShortcut:(NSMutableDictionary *)shortcut isEditing:(BOOL)editing parentWindow:(NSWindow *)parentWindow
{
    // Retain self while sheet is open - will be released when sheet ends
    [self retain];
    
    currentShortcut = [shortcut retain];
    isEditing = editing;
    isCapturingKeyCombo = NO;
    capturedModifiers = [[NSMutableArray alloc] init];
    
    // Create edit window using custom window class
    editWindow = [[ShortcutEditWindow alloc] initWithContentRect:NSMakeRect(0, 0, 500, 150)
                                             styleMask:NSTitledWindowMask
                                               backing:NSBackingStoreBuffered
                                                 defer:NO];
    
    [(ShortcutEditWindow *)editWindow setEditController:self];
    
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
    
    keyComboField = [[NSTextField alloc] initWithFrame:NSMakeRect(150, 100, 180, 22)];
    [keyComboField setStringValue:[currentShortcut objectForKey:@"keyCombo"]];
    [contentView addSubview:keyComboField];
    
    setButton = [[NSButton alloc] init];
    [setButton setTitle:@"Set"];
    [setButton setTarget:self];
    [setButton setAction:@selector(setKeyComboClicked:)];
    [setButton sizeToFit];
    [setButton setFrame:NSMakeRect(340, 100, 60, setButton.frame.size.height)];
    [contentView addSubview:setButton];
    
    // Command label and field
    NSTextField *commandLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 70, 120, 20)];
    [commandLabel setEditable:NO];
    [commandLabel setSelectable:NO];
    [commandLabel setBezeled:NO];
    [commandLabel setDrawsBackground:NO];
    [commandLabel setStringValue:@"Command:"];
    [contentView addSubview:commandLabel];
    [commandLabel release];
    
    commandField = [[NSTextField alloc] initWithFrame:NSMakeRect(150, 70, 250, 22)];
    [commandField setStringValue:[currentShortcut objectForKey:@"command"]];
    [contentView addSubview:commandField];
    
    // Buttons
    cancelButton = [[NSButton alloc] init];
    [cancelButton setTitle:@"Cancel"];
    [cancelButton setTarget:self];
    [cancelButton setAction:@selector(cancelClicked:)];
    [cancelButton sizeToFit];
    [cancelButton setFrame:NSMakeRect(270, 20, 80, cancelButton.frame.size.height)];
    [contentView addSubview:cancelButton];
    
    okButton = [[NSButton alloc] init];
    [okButton setTitle:@"OK"];
    [okButton setTarget:self];
    [okButton setAction:@selector(okClicked:)];
    [okButton setKeyEquivalent:@"\r"];
    [okButton sizeToFit];
    [okButton setFrame:NSMakeRect(360, 20, 80, okButton.frame.size.height)];
    [contentView addSubview:okButton];
    
    [NSApp beginSheet:editWindow modalForWindow:parentWindow modalDelegate:nil didEndSelector:nil contextInfo:nil];
}

- (void)setKeyComboClicked:(id)sender
{
    if (isCapturingKeyCombo) {
        [self stopCapturingKeyCombo];
    } else {
        [self startCapturingKeyCombo];
    }
}

- (void)startCapturingKeyCombo
{
    isCapturingKeyCombo = YES;
    [setButton setTitle:@"Press keys..."];
    [setButton setEnabled:NO];
    [keyComboField setStringValue:@""];
    [capturedModifiers removeAllObjects];
    
    // Temporarily disable all global shortcuts to avoid conflicts
    NSDebugLLog(@"gwcomp", @"GlobalShortcuts: Sending temporary disable notification");
    [[NSDistributedNotificationCenter defaultCenter] 
        postNotificationName:@"GSGlobalShortcutsTemporaryDisable"
                      object:@"GlobalShortcuts"
                    userInfo:nil];
    
    // Make the window the key window and first responder
    [editWindow makeKeyAndOrderFront:nil];
    [editWindow makeFirstResponder:editWindow];
}

- (BOOL)isCapturingKeyCombo
{
    return isCapturingKeyCombo;
}

- (void)stopCapturingKeyCombo
{
    isCapturingKeyCombo = NO;
    [setButton setTitle:@"Set"];
    [setButton setEnabled:YES];
    
    // Re-enable all global shortcuts
    NSDebugLLog(@"gwcomp", @"GlobalShortcuts: Sending re-enable notification");
    [[NSDistributedNotificationCenter defaultCenter] 
        postNotificationName:@"GSGlobalShortcutsReEnable"
                      object:@"GlobalShortcuts"
                    userInfo:nil];
}

- (void)handleKeyEvent:(NSEvent *)event
{
    // Get modifier keys
    NSString *modifiers = [self getModifierKeysFromEvent:event];
    NSString *keyName = [self getKeyNameFromEvent:event];
    
    // Build the key combo string
    NSString *keyCombo = @"";
    if ([modifiers length] > 0) {
        keyCombo = [NSString stringWithFormat:@"%@+%@", modifiers, keyName];
    } else {
        keyCombo = keyName;
    }
    
    [keyComboField setStringValue:keyCombo];
    [self stopCapturingKeyCombo];
}

- (NSString *)getModifierKeysFromEvent:(NSEvent *)event
{
    NSMutableArray *mods = [NSMutableArray array];
    NSUInteger modifiers = [event modifierFlags];
    
    if (modifiers & NSControlKeyMask) {
        [mods addObject:@"ctrl"];
    }
    if (modifiers & NSShiftKeyMask) {
        [mods addObject:@"shift"];
    }
    if (modifiers & NSAlternateKeyMask) {
        [mods addObject:@"alt"];
    }
    if (modifiers & NSCommandKeyMask) {
        [mods addObject:@"cmd"];
    }
    
    return [mods componentsJoinedByString:@"+"];
}

- (NSString *)getKeyNameFromEvent:(NSEvent *)event
{
    unsigned short keyCode = [event keyCode];
    NSString *characters = [event charactersIgnoringModifiers];
    
    // First check if this is a number key (key codes typically 10-19 for 1-9,0)
    // These are X11 key codes, map them to their number values
    if (keyCode >= 10 && keyCode <= 19) {
        // Key codes 10-19 map to 1-9, 0
        if (keyCode == 10) return @"1";
        if (keyCode == 11) return @"2";
        if (keyCode == 12) return @"3";
        if (keyCode == 13) return @"4";
        if (keyCode == 14) return @"5";
        if (keyCode == 15) return @"6";
        if (keyCode == 16) return @"7";
        if (keyCode == 17) return @"8";
        if (keyCode == 18) return @"9";
        if (keyCode == 19) return @"0";
    }
    
    if ([characters length] > 0) {
        unichar charCode = [characters characterAtIndex:0];
        
        // Handle special keys by checking the actual character codes
        if (charCode == NSUpArrowFunctionKey) {
            return @"Up";
        }
        if (charCode == NSDownArrowFunctionKey) {
            return @"Down";
        }
        if (charCode == NSLeftArrowFunctionKey) {
            return @"Left";
        }
        if (charCode == NSRightArrowFunctionKey) {
            return @"Right";
        }
        if (charCode == NSDeleteCharacter) {
            return @"BackSpace";
        }
        if (charCode == NSTabCharacter) {
            return @"Tab";
        }
        if (charCode == NSNewlineCharacter || charCode == NSCarriageReturnCharacter) {
            return @"Return";
        }
        if (charCode == 27) { // Escape
            return @"Escape";
        }
        if (charCode == 32) { // Space
            return @"space";
        }
        
        // For regular printable characters, use them directly
        if ((charCode >= 32 && charCode < 127) || charCode > 160) {
            // Convert to lowercase for consistency with Linux conventions
            NSString *result = [NSString stringWithFormat:@"%c", tolower(charCode)];
            return result;
        }
    }
    
    // Fall back to key code lookup for function keys and special keys
    return [self convertKeyCodeToName:keyCode];
}

- (NSString *)convertKeyCodeToName:(unsigned short)keyCode
{
    // These mappings are for X11/Linux key codes
    // which are different from macOS key codes
    switch (keyCode) {
        // Function keys (X11 key codes)
        case 67: return @"F1";   // XK_F1
        case 68: return @"F2";   // XK_F2
        case 69: return @"F3";   // XK_F3
        case 70: return @"F4";   // XK_F4
        case 71: return @"F5";   // XK_F5
        case 72: return @"F6";   // XK_F6
        case 73: return @"F7";   // XK_F7
        case 74: return @"F8";   // XK_F8
        case 75: return @"F9";   // XK_F9
        case 76: return @"F10";  // XK_F10
        case 95: return @"F11";  // XK_F11
        case 96: return @"F12";  // XK_F12
        
        // Navigation keys
        case 110: return @"Home";      // XK_Home
        case 115: return @"End";       // XK_End
        case 112: return @"Page_Up";   // XK_Page_Up
        case 117: return @"Page_Down"; // XK_Page_Down
        
        // Special keys
        case 9: return @"Escape";      // XK_Escape
        case 23: return @"Tab";        // XK_Tab
        case 36: return @"Return";     // XK_Return
        case 50: return @"Shift_L";    // XK_Shift_L
        case 62: return @"Shift_R";    // XK_Shift_R
        case 37: return @"Control_L";  // XK_Control_L
        case 105: return @"Control_R"; // XK_Control_R
        case 108: return @"Alt_R";     // XK_Alt_R
        case 64: return @"Alt_L";      // XK_Alt_L
        
        // Keypad
        case 79: return @"KP_7";
        case 80: return @"KP_8";
        case 81: return @"KP_9";
        case 83: return @"KP_4";
        case 84: return @"KP_5";
        case 85: return @"KP_6";
        case 87: return @"KP_1";
        case 88: return @"KP_2";
        case 89: return @"KP_3";
        case 90: return @"KP_0";
        case 91: return @"KP_Decimal";
        case 77: return @"KP_Divide";
        case 63: return @"KP_Multiply";
        case 86: return @"KP_Subtract";
        case 92: return @"KP_Add";
        case 104: return @"KP_Enter";
        
        default:
            // For unknown key codes, return the code itself
            return [NSString stringWithFormat:@"0x%x", keyCode];
    }
}

- (void)okClicked:(id)sender
{
    [self stopCapturingKeyCombo];
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
    
    // Check for collision with existing shortcuts (unless we're editing the same one)
    if (!isEditing || ![keyCombo isEqualToString:[currentShortcut objectForKey:@"keyCombo"]]) {
        for (NSDictionary *existingShortcut in parentController->shortcuts) {
            if ([[existingShortcut objectForKey:@"keyCombo"] isEqualToString:keyCombo]) {
                NSString *existingCommand = [existingShortcut objectForKey:@"command"];
                NSAlert *alert = [NSAlert alertWithMessageText:@"Shortcut Already Exists"
                                                 defaultButton:@"Replace"
                                               alternateButton:@"Cancel"
                                                   otherButton:nil
                                     informativeTextWithFormat:@"The shortcut '%@' is already assigned to command:\n\n%@\n\nDo you want to replace it?", keyCombo, existingCommand];
                
                NSInteger result = [alert runModal];
                if (result != NSAlertDefaultReturn) {
                    return; // User cancelled
                }
                
                // Remove the existing shortcut
                [parentController->shortcuts removeObject:existingShortcut];
                break;
            }
        }
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
    editWindow = nil;
    
    [self release];  // Release the extra retain from showSheetForShortcut
}

- (void)cancelClicked:(id)sender
{
    [self stopCapturingKeyCombo];
    [NSApp endSheet:editWindow];
    [editWindow orderOut:nil];
    editWindow = nil;
    
    [self release];  // Release the extra retain from showSheetForShortcut
}

@end
