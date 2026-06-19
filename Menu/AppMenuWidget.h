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
