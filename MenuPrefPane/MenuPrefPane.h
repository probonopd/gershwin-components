/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <PreferencePanes/PreferencePanes.h>

@class MenuControllerPrefPane;

@interface MenuPrefPane : NSPreferencePane
{
    MenuControllerPrefPane *_controller;
}

@end
