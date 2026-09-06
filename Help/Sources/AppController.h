/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

@class HelpWindowController;

@interface AppController : NSObject <NSApplicationDelegate>
{
  HelpWindowController *_windowController;
}
- (void)showWindow;
@end
