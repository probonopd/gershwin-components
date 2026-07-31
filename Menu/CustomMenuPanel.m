/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */


#import "CustomMenuPanel.h"
#import <GNUstepGUI/GSTheme.h>
#import <objc/runtime.h>

@implementation MenuGradientView

- (void)drawRect:(NSRect)dirtyRect
{
    // Draw exactly what the theme draws for a horizontal menu bar: the vertical
    // gradient from bright grey to mid grey plus the bright top line.
    [[GSTheme theme] drawMenuRect:[self bounds]
                           inView:self
                     isHorizontal:YES
                        itemCells:@[]];
}

- (BOOL)isOpaque
{
    return NO;
}

@end

@implementation CustomMenuPanel
@end

@implementation CustomMenuView
@end

static IMP original_NSView_windowIMP = NULL;
static BOOL wrappingInProgress = NO;

static BOOL IsMainMenuBarWindow(NSWindow *window)
{
    if (window == nil) {
        return NO;
    }
    // The main menu bar window is titled "Menu" (see MenuController) and is
    // exactly the theme's menu bar height.  Dropdown popups and dialogs are
    // taller and have different titles, so they are never wrapped.
    if (![[window title] isEqualToString:@"Menu"]) {
        return NO;
    }
    if (fabs([window frame].size.height - [[GSTheme theme] menuBarHeight]) > 1.0) {
        return NO;
    }
    return YES;
}

/* Swizzled replacement for -[NSView window]. */
@interface NSView (MenuGradientHook)
- (NSWindow *)gw_menuGradientWindow;
@end

@implementation NSView (MenuGradientHook)

- (NSWindow *)gw_menuGradientWindow
{
    NSWindow *window = nil;
    if (original_NSView_windowIMP) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Wcast-function-type-mismatch"
        window = ((NSWindow * (*)(id, SEL))original_NSView_windowIMP)(self, @selector(window));
        #pragma clang diagnostic pop
    }

    // Only the main menu bar window gets the themed gradient background.  All
    // other windows (popup menus, dialogs, ...) keep standard theme rendering.
    if (!wrappingInProgress && window && IsMainMenuBarWindow(window)
        && ![[window contentView] isKindOfClass:[MenuGradientView class]])
    {
        wrappingInProgress = YES;
        @try {
            NSRect contentBounds = [[window contentView] bounds];
            MenuGradientView *gradientView = [[MenuGradientView alloc] initWithFrame:contentBounds];
            [gradientView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

            NSView *contentView = [window contentView];
            [contentView setFrame:contentBounds];
            [contentView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

            // Put the gradient view behind the existing content view.
            [contentView removeFromSuperview];
            [window setContentView:gradientView];
            [gradientView addSubview:contentView];

            NSDebugLLog(@"gwcomp", @"CustomMenuPanel: Applied menu bar gradient background to main menu window %@", window);
        } @finally {
            wrappingInProgress = NO;
        }
    }

    return window;
}

@end

void HookNSMenuPanelCreation(void)
{
    // Hook -[NSView window] so the first access from a view in the main menu bar
    // window wraps that window's content view with a MenuGradientView.  Only the
    // main menu bar window matches IsMainMenuBarWindow, so popup menus and
    // dialogs are left untouched.
    Class menuViewClass = NSClassFromString(@"NSMenuView");
    if (!menuViewClass) {
        NSDebugLLog(@"gwcomp", @"CustomMenuPanel: Warning: NSMenuView class not found for window hook");
        return;
    }

    Method originalWindowMethod = class_getInstanceMethod(menuViewClass, @selector(window));
    Method hookedWindowMethod = class_getInstanceMethod([NSView class], @selector(gw_menuGradientWindow));
    if (!originalWindowMethod || !hookedWindowMethod) {
        NSDebugLLog(@"gwcomp", @"CustomMenuPanel: Warning: could not find window methods for hook");
        return;
    }

    original_NSView_windowIMP = method_getImplementation(originalWindowMethod);
    method_exchangeImplementations(originalWindowMethod, hookedWindowMethod);
    NSDebugLLog(@"gwcomp", @"CustomMenuPanel: Installed main menu window gradient hook");
}
