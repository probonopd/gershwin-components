/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

@interface GlobalShortcutsController : NSObject
{
@public
    NSView *mainView;
    NSTableView *shortcutsTable;
    NSArrayController *shortcutsArrayController;
    NSMutableArray *shortcuts;
    NSButton *addButton;
    NSButton *deleteButton;
    NSTextField *statusLabel;
}

- (id)init;
- (void)dealloc;
- (NSView *)createMainView;
- (void)relayoutWithWidth:(CGFloat)width;
- (void)refreshShortcuts:(NSTimer *)timer;
- (void)addShortcut:(id)sender;
- (void)deleteShortcut:(id)sender;
- (void)editShortcut:(id)sender;
- (void)tableViewSelectionDidChange:(NSNotification *)notification;
- (void)tableDoubleClicked:(id)sender;
- (BOOL)loadShortcutsFromDefaults;
- (BOOL)saveShortcutsToDefaults;
- (void)showAddEditShortcutSheet:(NSMutableDictionary *)shortcut isEditing:(BOOL)editing;
- (BOOL)isValidKeyCombo:(NSString *)keyCombo;

@end
