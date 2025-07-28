/*
 * Copyright (c) 2005 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <PreferencePanes/PreferencePanes.h>

@class StartupDiskController;

@interface StartupDiskPane : NSPreferencePane
{
    StartupDiskController *startupDiskController;
    NSTimer *refreshTimer;
}

@end
