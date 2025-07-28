/*
 * Copyright (c) 2005 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <PreferencePanes/PreferencePanes.h>

@class BootConfigController;

@interface BootEnvironmentPane : NSPreferencePane
{
    BootConfigController *bootConfigController;
    NSTimer *refreshTimer;
}

@end
