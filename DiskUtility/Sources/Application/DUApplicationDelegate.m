/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUApplicationDelegate.h"

#import "DUMainWindowController.h"
#import "DUPreferencesController.h"
#import "DUBackendFactory.h"
#import "DUDeviceMonitor.h"
#import "DUOperationManager.h"
#import "DUStorageManager.h"

@interface DUApplicationDelegate ()
@property (nonatomic, strong, readwrite) DUStorageManager *storageManager;
@property (nonatomic, strong, readwrite) DUMainWindowController *windowController;
@property (nonatomic, strong) DUDeviceMonitor *deviceMonitor;
@end

@implementation DUApplicationDelegate

- (void)applicationWillFinishLaunching:(NSNotification *)notification
{
    (void)notification;
    [DUPreferencesController registerDefaults];
    [self buildAppMenu];

    // Service construction order follows ARCHITECTURE.md section 95.
    NSError *error = nil;
    id backend = [DUBackendFactory backendWithError:&error];
    DUOperationManager *operationManager = [[DUOperationManager alloc] init];
    self.storageManager =
        [[DUStorageManager alloc] initWithBackend:backend
                                  operationManager:operationManager];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
    (void)notification;
    self.windowController =
        [[DUMainWindowController alloc]
            initWithStorageManager:self.storageManager];
    [self.windowController showWindow:nil];

    // Initial discovery must not block the UI (ARCHITECTURE.md 95); the
    // monitor publishes the result through the topology notification.
    NSThread *worker = [[NSThread alloc]
        initWithBlock:^{
            @autoreleasepool {
                [self.storageManager refreshWithError:NULL];
            }
        }];
    worker.name = @"DU-initial-discovery";
    [worker start];

    self.deviceMonitor =
        [[DUDeviceMonitor alloc]
            initWithStorageManager:self.storageManager];
    [self.deviceMonitor start];
}

- (NSApplicationTerminateReply)applicationShouldTerminate:
        (NSApplication *)sender
{
    (void)sender;
    // Shutdown ordering per ARCHITECTURE.md section 96.
    [self.deviceMonitor stop];
    self.deviceMonitor = nil;

    [self.storageManager.operationManager cancelAllOperations];
    return NSTerminateNow;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:
        (NSApplication *)sender
{
    (void)sender;
    return YES;
}

#pragma mark - Menu

- (void)buildAppMenu
{
    NSMenu *menubar = [[NSMenu alloc] init];

    NSMenuItem *appItem =
        [[NSMenuItem alloc] initWithTitle:@"Disk Utility"
                                    action:nil
                             keyEquivalent:@""];
    NSMenu *appMenu = [[NSMenu alloc] init];
    [appMenu addItemWithTitle:NSLocalizedString(@"About Disk Utility", nil)
                       action:@selector(orderFrontStandardAboutPanel:)
                keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:NSLocalizedString(@"Hide Disk Utility", nil)
                       action:@selector(hide:)
                keyEquivalent:@"h"];
    [appMenu addItemWithTitle:NSLocalizedString(@"Quit Disk Utility", nil)
                       action:@selector(terminate:)
                keyEquivalent:@"q"];
    appItem.submenu = appMenu;
    [menubar addItem:appItem];

    NSMenuItem *editItem =
        [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Edit", nil)
                                    action:nil
                             keyEquivalent:@""];
    NSMenu *editMenu = [[NSMenu alloc] init];
    [editMenu addItemWithTitle:NSLocalizedString(@"Cut", nil)
                        action:@selector(cut:)
                 keyEquivalent:@"x"];
    [editMenu addItemWithTitle:NSLocalizedString(@"Copy", nil)
                        action:@selector(copy:)
                 keyEquivalent:@"c"];
    [editMenu addItemWithTitle:NSLocalizedString(@"Paste", nil)
                        action:@selector(paste:)
                 keyEquivalent:@"v"];
    [editMenu addItemWithTitle:NSLocalizedString(@"Select All", nil)
                        action:@selector(selectAll:)
                 keyEquivalent:@"a"];
    editItem.submenu = editMenu;
    [menubar addItem:editItem];

    NSApp.mainMenu = menubar;
}

@end
