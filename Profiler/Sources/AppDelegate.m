/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "AppDelegate.h"
#import "ProfilerWindowController.h"

@implementation AppDelegate
{
    ProfilerWindowController *_windowController;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
    (void)notification;
    [self setupMainMenu];
    _windowController = [[ProfilerWindowController alloc] init];
    [_windowController showWindow:self];
}

- (void)setupMainMenu
{
    NSMenu *mainMenu = [[NSMenu alloc] initWithTitle:@"MainMenu"];
    NSString *appName = [[NSProcessInfo processInfo] processName];

    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:appName];
    [appMenu addItemWithTitle:[NSString stringWithFormat:@"About %@", appName]
                       action:@selector(orderFrontStandardAboutPanel:)
                keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:[NSString stringWithFormat:@"Hide %@", appName]
                       action:@selector(hide:)
                keyEquivalent:@"h"];
    [appMenu addItemWithTitle:@"Hide Others"
                       action:@selector(hideOtherApplications:)
                keyEquivalent:@""];
    [appMenu addItemWithTitle:@"Show All"
                       action:@selector(unhideAllApplications:)
                keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:[NSString stringWithFormat:@"Quit %@", appName]
                       action:@selector(terminate:)
                keyEquivalent:@"q"];
    NSMenuItem *appItem = [[NSMenuItem alloc] init];
    [appItem setTitle:appName];
    [mainMenu addItem:appItem];
    [mainMenu setSubmenu:appMenu forItem:appItem];
    [appItem release];

    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
    [fileMenu addItemWithTitle:@"Close"
                        action:@selector(performClose:)
                 keyEquivalent:@"w"];
    NSMenuItem *fileItem = [[NSMenuItem alloc] init];
    [fileItem setTitle:@"File"];
    [mainMenu addItem:fileItem];
    [mainMenu setSubmenu:fileMenu forItem:fileItem];
    [fileItem release];

    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    [editMenu addItemWithTitle:@"Undo" action:@selector(undo:) keyEquivalent:@"z"];
    [editMenu addItemWithTitle:@"Redo" action:@selector(redo:) keyEquivalent:@"Z"];
    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
    [editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
    NSMenuItem *editItem = [[NSMenuItem alloc] init];
    [editItem setTitle:@"Edit"];
    [mainMenu addItem:editItem];
    [mainMenu setSubmenu:editMenu forItem:editItem];
    [editItem release];

    NSMenu *windowMenu = [[NSMenu alloc] initWithTitle:@"Window"];
    [windowMenu addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
    [windowMenu addItemWithTitle:@"Zoom" action:@selector(performZoom:) keyEquivalent:@""];
    [windowMenu addItem:[NSMenuItem separatorItem]];
    [windowMenu addItemWithTitle:@"Bring All to Front"
                         action:@selector(arrangeInFront:)
                  keyEquivalent:@""];
    NSMenuItem *windowItem = [[NSMenuItem alloc] init];
    [windowItem setTitle:@"Window"];
    [mainMenu addItem:windowItem];
    [mainMenu setSubmenu:windowMenu forItem:windowItem];
    [windowItem release];
    [NSApp setWindowsMenu:windowMenu];

    NSMenu *helpMenu = [[NSMenu alloc] initWithTitle:@"Help"];
    NSMenuItem *helpItem = [[NSMenuItem alloc] init];
    [helpItem setTitle:@"Help"];
    [mainMenu addItem:helpItem];
    [mainMenu setSubmenu:helpMenu forItem:helpItem];
    [helpItem release];

    [NSApp setMainMenu:mainMenu];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender
{
    (void)sender;
    return YES;
}

- (void)dealloc
{
    [_windowController release];
    [super dealloc];
}

@end
