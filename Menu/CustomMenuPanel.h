/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

@interface MenuGradientView : NSView
@end

@interface CustomMenuPanel : NSPanel
@end

@interface CustomMenuView : NSMenuView
@end

void HookNSMenuPanelCreation(void);
