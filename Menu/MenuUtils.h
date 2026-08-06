/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */


#import <Foundation/Foundation.h>
#import <X11/Xlib.h>

@interface MenuUtils : NSObject

+ (Display *)sharedDisplay;
+ (void)cleanup;

+ (NSString *)getApplicationNameForWindow:(unsigned long)windowId;
+ (BOOL)isWindowValid:(unsigned long)windowId;
+ (BOOL)isWindowMapped:(unsigned long)windowId;
+ (BOOL)isDesktopWindow:(unsigned long)windowId;
+ (BOOL)isDialogWindow:(unsigned long)windowId;
// True for a real top-level application window per ICCCM/EWMH: viewable, not
// override-redirect, and with a normal/dialog/utility _NET_WM_WINDOW_TYPE (or
// no type at all).  Window-manager-internal windows (tooltips, menus, docks,
// notifications) and Chromium's internal helper windows that Chromium marks as
// non-normal are excluded, so the global menu does not chase them.
+ (BOOL)isRealApplicationWindow:(unsigned long)windowId;
// Read _NET_ACTIVE_WINDOW on a fresh connection (safe from any thread).
+ (unsigned long)getActiveWindowFresh;
+ (NSArray *)getAllWindows;
+ (unsigned long)getActiveWindow;
+ (NSString *)getWindowProperty:(unsigned long)windowId atomName:(NSString *)atomName;
+ (NSString*)getWindowMenuService:(unsigned long)windowId;
+ (NSString*)getWindowMenuPath:(unsigned long)windowId;
+ (BOOL)setWindowMenuService:(NSString*)service path:(NSString*)path forWindow:(unsigned long)windowId;
+ (NSDictionary *)getAllVisibleWindowApplications;
+ (unsigned long)findDesktopWindow;
+ (pid_t)getWindowPID:(unsigned long)windowId;
+ (BOOL)advertiseGlobalMenuSupport;
+ (void)removeGlobalMenuSupport;

/* Merge the given atoms into the root window's _NET_SUPPORTED property.
 * _NET_SUPPORTED is owned by the window manager; this appends the global-menu
 * atoms without dropping the entries the WM advertised (e.g. the window
 * animation protocol atoms), which a plain PropModeReplace would clobber. */
+ (void)mergeNetSupportedAtoms:(const Atom *)atoms
                         count:(unsigned long)count
                         onRoot:(Window)root
                       display:(Display *)display;

/**
 * Returns YES if the window has any X11 property that indicates it intends to
 * export an application menu (GTK _GTK_UNIQUE_BUS_NAME, Canonical/KDE
 * _KDE_NET_WM_APPMENU_SERVICE_NAME, or GNUstep _GNUSTEP_WM_ATTR).
 * Used to decide whether to wait for a menu to appear after a window switch.
 */
+ (BOOL)windowIndicatesMenuSupport:(unsigned long)windowId;

@end
