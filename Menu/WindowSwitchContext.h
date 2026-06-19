/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * WindowSwitchContext — Caches all X11/PID/app state for a single
 * window-switch event so that expensive X11 round-trips are performed
 * at most once per focus change.
 */

#import <Foundation/Foundation.h>
#import <sys/types.h>

@class MenuProtocolManager;

@interface WindowSwitchContext : NSObject

@property (nonatomic, assign) unsigned long windowId;
@property (nonatomic, assign) pid_t pid;
@property (nonatomic, copy)   NSString *appName;
@property (nonatomic, assign) BOOL isDialog;
@property (nonatomic, assign) BOOL isDesktop;
@property (nonatomic, assign) BOOL isSelfWindow;
@property (nonatomic, assign) BOOL hasRegisteredMenu;
@property (nonatomic, assign) BOOL isValid;

/*
 * Build a fully-populated context for the given window ID.
 * Performs all X11 queries once and caches the results.
 * Returns nil only if windowId is 0.
 */
+ (instancetype)contextForWindow:(unsigned long)windowId
                 protocolManager:(MenuProtocolManager *)pm;

@end
