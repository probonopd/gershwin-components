/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */


#import <AppKit/AppKit.h>

@class AppMenuWidget;

/**
 * ActionSearchResult - Represents a searchable menu item
 */
@interface ActionSearchResult : NSObject

@property (nonatomic, strong) NSString *title;           // Menu item title
@property (nonatomic, strong) NSString *path;            // Full path like "File ▸ Open"
@property (nonatomic, strong) NSString *keyEquivalent;   // Keyboard shortcut string
@property (nonatomic, assign) NSUInteger modifierMask;   // Modifier keys
@property (nonatomic, strong) NSMenuItem *menuItem;      // Reference to actual menu item
@property (nonatomic, assign) BOOL enabled;              // Whether item is enabled in original menu

/* Kind of result: "menu" (a menu item), "run" (launch an app/command), or
   "goto" (open a folder path).  Run/GoTo results carry the target in `path`. */
@property (nonatomic, copy) NSString *kind;

/* Group for separator placement: "menu", "app", "command" (PATH), or "path".
   Results of the same group are shown contiguously with a separator between
   different groups. */
@property (nonatomic, copy) NSString *group;

- (id)initWithMenuItem:(NSMenuItem *)item path:(NSString *)path;

/* Convenience: build a Run or Go To result.  kind is "run" or "goto". */
+ (instancetype)runResultWithTitle:(NSString *)title target:(NSString *)target;

@end


/**
 * ActionSearchController - Manages the search popup and results menu
 */
@interface ActionSearchController : NSObject <NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate>

@property (nonatomic, strong) NSPanel *searchPanel;
@property (nonatomic, strong) NSTextField *searchField;
@property (nonatomic, strong) NSMenu *resultsMenu;
@property (nonatomic, strong) NSMutableArray *allMenuItems;
@property (nonatomic, strong) NSMutableArray *filteredResults;
@property (nonatomic, weak) AppMenuWidget *appMenuWidget;

+ (instancetype)sharedController;

/**
 * Set the app menu widget reference to access current menus
 */
- (void)setAppMenuWidget:(AppMenuWidget *)widget;

/**
 * Show the search popup at the given screen location
 */
- (void)showSearchPopupAtPoint:(NSPoint)point;

/**
 * Hide the search popup
 */
- (void)hideSearchPopup;

/**
 * Toggle the search popup
 */
- (void)toggleSearchPopupAtPoint:(NSPoint)point;

/**
 * Toggle the search popup (the Action Search).  Called by the global
 * Cmd+Space (Alt+Space) shortcut and the Command menu's "Search..." item.
 */
- (void)toggleSearch:(id)sender;

/**
 * Whether the search field is currently visible in the menu bar
 */
- (BOOL)isSearchVisible;

/**
 * Collect all menu items from the current application menu
 */
- (void)collectMenuItems;

/**
 * Execute the selected action
 */
- (void)executeActionForResult:(ActionSearchResult *)result;

@end


/**
 * ActionSearchMenuView - Menu bar item that triggers the search popup
 */
@interface ActionSearchMenuView : NSView

@property (nonatomic, weak) AppMenuWidget *appMenuWidget;

- (id)initWithFrame:(NSRect)frameRect;
- (void)setAppMenuWidget:(AppMenuWidget *)widget;

@end
