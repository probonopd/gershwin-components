/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * AppMenuWidget — Displays the active application's menu in the global
 * menu bar.  Optimized single-pass update path with coalescing.
 */


#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <X11/Xlib.h>
#import <X11/keysym.h>

@class MenuProtocolManager;
@class WindowSwitchContext;

@interface AppMenuWidget : NSView <NSMenuDelegate>

@property (nonatomic, weak) MenuProtocolManager *protocolManager;
@property (nonatomic, strong) NSMenuView *menuView;
@property (nonatomic, copy)   NSString *currentApplicationName;
@property (nonatomic, assign) unsigned long currentWindowId;
@property (nonatomic, strong) NSMenu *currentMenu;
@property (nonatomic, assign) pid_t currentWindowPID;
@property (nonatomic, assign) BOOL needsRedraw;

/* The system submenu (contains Search, System Preferences, and dynamic application list) */
@property (nonatomic, strong) NSMenu *systemMenu;

/* The System Preferences submenu inside the Command menu.  It holds one item
   per installed prefPane, populated by populatePrefPanesSubmenu (eagerly, so
   GNUstep auto-enabling does not grey out the parent item). */
@property (nonatomic, strong) NSMenu *systemPrefsSubmenu;
@property (nonatomic, assign) BOOL systemPrefsSubmenuPopulated;

/* Cached tree of .app bundles for the system submenu (rebuilt at most every 30s) */
@property (nonatomic, strong) NSDictionary *cachedAppBundleTree;
@property (nonatomic, assign) NSTimeInterval cachedAppBundleTreeTime;
@property (nonatomic, assign) BOOL systemMenuPopulatedFromCache;
@property (nonatomic, assign) NSTimeInterval lastSystemMenuUpdateTime;

/* Coalescing timer for window focus changes */
@property (nonatomic, strong) NSTimer *coalesceTimer;
@property (nonatomic, assign) unsigned long pendingCoalesceWindowId;

/* Single retry timer for menu registration (replaces grace period cascade) */
@property (nonatomic, strong) NSTimer *menuRetryTimer;
@property (nonatomic, assign) unsigned long menuRetryWindowId;
@property (nonatomic, assign) NSUInteger menuRetryCount;

/* Cache of windows we've already determined have no menus (30s TTL).
   Avoids wasting time retrying windows that don't export menus. */
@property (nonatomic, strong) NSMutableDictionary *windowsWithoutMenus;  /* window ID → NSDate */

/* Re-entrance guard */
@property (nonatomic, assign) BOOL isInsideHandleFocusChange;

/* ── Public API (compatible with existing callers) ────────────── */

- (void)updateForActiveWindow;
- (void)updateForActiveWindowId:(unsigned long)windowId;
- (void)clearMenu;
- (void)clearMenuAndHideView;
- (void)displayMenuForWindow:(unsigned long)windowId;
- (void)setupMenuViewWithMenu:(NSMenu *)menu;
- (void)loadMenu:(NSMenu *)menu forWindow:(unsigned long)windowId;
- (void)checkAndDisplayMenuForNewlyRegisteredWindow:(unsigned long)windowId;
- (BOOL)isPlaceholderMenu:(NSMenu *)menu;
- (void)closeActiveWindow:(NSMenuItem *)sender;
- (void)sendAltF4ToWindow:(unsigned long)windowId;

/* System submenu actions */
- (void)openSystemPreferences:(NSMenuItem *)sender;
- (void)openApplicationBundle:(NSMenuItem *)sender;
- (void)openPrefPane:(NSMenuItem *)sender;

/* Populate the System Preferences submenu with one item per installed
   prefPane (lazy: called when the submenu is about to open). */
- (void)populatePrefPanesSubmenu;

/* Build a launcher menu item that also carries a submenu: clicking the item
   performs `action` (targeted at self), and the arrow/hover opens `submenu`
   (may be nil).  `representedObject` is stored for the action.  Shared by the
   Applications folder items and the System Preferences item. */
- (NSMenuItem *)addLauncherItemWithTitle:(NSString *)title
                                  action:(SEL)action
                       representedObject:(id)object
                                 submenu:(NSMenu *)submenu
                                  toMenu:(NSMenu *)menu;

/* Make sure the dynamic Applications submenu (app launchers) is populated so
   it can be searched and displayed even before the Command menu is opened. */
- (void)ensureSystemMenuPopulated;

/* Power actions (shut down / restart / log out) in the Command menu */
- (void)restart:(NSMenuItem *)sender;
- (void)shutDown:(NSMenuItem *)sender;
- (void)logOut:(NSMenuItem *)sender;
- (void)openFolderInWorkspace:(NSMenuItem *)sender;

/* Debug */
- (void)debugLogCurrentMenuState;
- (void)menuItemClicked:(NSMenuItem *)sender;

/* Window validation */
+ (BOOL)isWindowStillValid:(Window)windowId;
+ (BOOL)safelyCheckWindow:(Window)windowId withDisplay:(Display *)display;

/* Error handling */
+ (void)setCurrentWidget:(AppMenuWidget *)widget;
- (void)handleWindowDisappeared:(Window)windowId;

@end
