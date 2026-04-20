/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "WindowSwitchContext.h"
#import "MenuUtils.h"
#import "MenuProtocolManager.h"
#import <AppKit/AppKit.h>
#import <X11/Xlib.h>
#import <X11/Xutil.h>

@implementation WindowSwitchContext

+ (instancetype)contextForWindow:(unsigned long)windowId
                 protocolManager:(MenuProtocolManager *)pm
{
    if (windowId == 0) {
        return nil;
    }

    WindowSwitchContext *ctx = [[WindowSwitchContext alloc] init];
    ctx.windowId = windowId;

    /* Check if this is a Menu.app-owned window (should be ignored) */
    ctx.isSelfWindow = ([NSApp windowWithWindowNumber:windowId] != nil);
    if (ctx.isSelfWindow) {
        return ctx;
    }

    /* PID — single X11 round-trip */
    ctx.pid = [MenuUtils getWindowPID:windowId];

    /* App name — may require several X11 property reads but done once */
    @try {
        ctx.appName = [MenuUtils getApplicationNameForWindow:windowId];
    } @catch (NSException *exception __attribute__((unused))) {
        ctx.appName = nil;
    }

    /* Window type checks */
    ctx.isDialog  = [MenuUtils isDialogWindow:windowId];
    ctx.isDesktop = [MenuUtils isDesktopWindow:windowId];

    /* Validity — XGetWindowAttributes */
    ctx.isValid = [MenuUtils isWindowValid:windowId] && [MenuUtils isWindowMapped:windowId];

    /* Menu availability — protocol manager lookup */
    ctx.hasRegisteredMenu = [pm hasMenuForWindow:windowId];

    return ctx;
}

@end
