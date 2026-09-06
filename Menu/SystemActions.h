/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

/* Executes the desktop power actions (shut down, restart, log out) using a
 * single command that is chosen for the operating system that is actually
 * running, instead of trying a long list of fallback commands. */
@interface SystemActions : NSObject

+ (void)executeShutdown;
+ (void)executeRestart;
+ (void)executeLogout;

@end
