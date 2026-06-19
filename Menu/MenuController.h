/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */


#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import "GNUstepGUI/GSTheme.h"
#import <X11/Xlib.h>
#import <X11/Xatom.h>

@class MenuBarView;
@class AppMenuWidget;
@class MenuProtocolManager;
@class RoundedCornersView;
@class ActionSearchMenuView;
@class StatusItemManager;
@class WindowMonitor;

@interface MenuController : NSObject <NSApplicationDelegate>

@property (nonatomic, strong) NSWindow *menuBar;
@property (nonatomic, assign) NSRect screenFrame;
@property (nonatomic, assign) NSSize screenSize;
@property (nonatomic, strong) MenuBarView *menuBarView;
@property (nonatomic, strong) AppMenuWidget *appMenuWidget;
@property (nonatomic, strong) MenuProtocolManager *protocolManager;
@property (nonatomic, strong) RoundedCornersView *roundedCornersView;
@property (nonatomic, strong) ActionSearchMenuView *actionSearchView;
@property (nonatomic, strong) StatusItemManager *statusItemManager;
@property (nonatomic, strong) NSMenuView *timeMenuView;
@property (nonatomic, strong) NSMenu *timeMenu;
@property (nonatomic, strong) NSMenuItem *timeMenuItem;
@property (nonatomic, strong) NSMenuItem *dateMenuItem;
@property (nonatomic, strong) NSTimer *timeUpdateTimer;
@property (nonatomic, strong) NSDateFormatter *timeFormatter;
@property (nonatomic, strong) NSDateFormatter *dateFormatter;
@property (nonatomic, strong) WindowMonitor *windowMonitor;
@property (nonatomic, assign) unsigned long lastProcessedWindowId;
@property (nonatomic, assign) NSTimeInterval lastProcessedTime;
@property (nonatomic, assign) int dbusFileDescriptor;
@property (nonatomic, strong) NSFileHandle *dbusFileHandle;
@property (nonatomic, strong) NSTimer *dbusPollingTimer;
@property (nonatomic, strong) NSTimer *slideInAnimationTimer;
@property (nonatomic, assign) NSTimeInterval slideInStartTime;
@property (nonatomic, assign) CGFloat slideInStartY;
@property (nonatomic, assign) NSTimeInterval lastActiveWindowScanTime;
@property (nonatomic, strong) NSTimer *windowValidationTimer; // Watchdog timer to hide stale menus
#if MENU_PROFILING
@property (nonatomic, strong) NSTimer *cpuUsageLogTimer;
@property (nonatomic, assign) NSTimeInterval lastCpuUsageSampleWallTime;
@property (nonatomic, assign) NSTimeInterval lastCpuUsageSampleUserTime;
@property (nonatomic, assign) NSTimeInterval lastCpuUsageSampleSystemTime;
#endif

// Track the last-cleared window id and timestamp so we can throttle repeated clears
@property (nonatomic, assign) unsigned long lastClearedWindowId;
@property (nonatomic, assign) NSTimeInterval lastClearedTime;

// Throttle window clear operations globally - when set prevents repeated clears for a short interval
@property (nonatomic, assign) NSTimeInterval lastClearSuppressUntil;

// Track if the last window state was zero (used to detect modal dialog recovery)
@property (nonatomic, assign) BOOL lastWindowStateWasZero;

- (id)init;
- (NSColor *)backgroundColor;
- (NSColor *)transparentColor;
- (void)applyMenuBarDockAndStrutProperties;
- (void)createMenuBar;
- (void)applicationDidFinishLaunching:(NSNotification *)notification;
- (void)applicationWillTerminate:(NSNotification *)notification;
- (void)setupMenuBar;
- (void)updateActiveWindow;
- (void)createProtocolManager;
- (void)initializeProtocols;
- (void)setupWindowMonitoring;
- (void)announceGlobalMenuSupport;
- (void)scanForNewMenus;
- (AppMenuWidget *)appMenuWidget;

- (void)screenParametersChanged:(NSNotification *)notification;
- (void)createTimeMenu;
- (void)updateTimeMenu;
#if MENU_PROFILING
- (void)startCPUUsageLogging;
- (void)stopCPUUsageLogging;
- (void)logCPUUsageSample:(NSTimer *)timer;
#endif

@end
