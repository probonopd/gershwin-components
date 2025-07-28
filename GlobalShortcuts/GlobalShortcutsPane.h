/*
 * Copyright (c) 2005 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <PreferencePanes/PreferencePanes.h>

@class GlobalShortcutsController;

@interface GlobalShortcutsPane : NSPreferencePane
{
    GlobalShortcutsController *shortcutsController;
    NSTimer *refreshTimer;
}

@end
