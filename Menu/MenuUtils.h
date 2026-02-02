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
+ (BOOL)isWindowSkippableAsActive:(unsigned long)windowId;
+ (BOOL)isDesktopWindow:(unsigned long)windowId;
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

@end
