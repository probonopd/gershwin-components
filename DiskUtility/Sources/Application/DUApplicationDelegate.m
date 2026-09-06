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
#import "DUProcessRunner.h"

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
    if (![self verifyToolsOrProceed]) {
        [NSApp terminate:self];
        return;
    }
    self.windowController =
        [[DUMainWindowController alloc]
            initWithStorageManager:self.storageManager];
    [self buildMainMenu];
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

#pragma mark - Tool availability

// Resolves every tool the active backend expects from $PATH and warns the
// user about any that are missing, offering to continue with reduced
// functionality. Headless modes (--list/--mock/--test-refresh) skip the
// interactive prompt. Returns NO when the user chooses to quit.
- (BOOL)verifyToolsOrProceed
{
    NSArray<NSString *> *arguments =
        [[NSProcessInfo processInfo] arguments];
    for (NSString *flag in
         @[ @"--list", @"--mock", @"--test-refresh" ]) {
        if ([arguments containsObject:flag]) {
            return YES;
        }
    }

    id<DUStorageBackend> backend = self.storageManager.backend;
    if (![backend respondsToSelector:@selector(expectedToolNames)]) {
        return YES;
    }
    NSArray<NSString *> *expected = [backend expectedToolNames];
    if (expected.count == 0) {
        return YES;
    }

    NSMutableArray<NSString *> *missing = [NSMutableArray array];
    for (NSString *tool in expected) {
        if ([DUProcessRunner executablePathForName:tool] == nil) {
            [missing addObject:tool];
        }
    }
    if (missing.count == 0) {
        return YES;
    }

    NSAlert *alert = [[NSAlert alloc] init];
    [alert setAlertStyle:NSWarningAlertStyle];
    [alert setMessageText:
              NSLocalizedString(@"Some helper tools are missing", nil)];
    NSString *list = [missing componentsJoinedByString:@", "];
    [alert setInformativeText:
              [NSString stringWithFormat:
                  NSLocalizedString(
                      @"The following command-line tools were not found in "
                      @"your PATH: %@. The utility will run with reduced "
                      @"functionality.",
                      nil),
                  list]];
    [alert addButtonWithTitle:NSLocalizedString(@"Continue", nil)];
    [alert addButtonWithTitle:NSLocalizedString(@"Quit", nil)];
    NSInteger result = [alert runModal];
    return result != NSAlertSecondButtonReturn;
}

#pragma mark - Menu

// Mirrors the menu layout the classic disk utility shipped with in the
// 10.4-10.6 era: app, File, Edit, View, Images, Window, Help. Items whose
// backing (backend verb or window feature) is not implemented yet are left
// disabled rather than wired to a stub, so the menu never pretends to do
// something it cannot.
- (void)buildMainMenu
{
    NSMenu *menubar = [[NSMenu alloc] init];

    id target = self.windowController;

    // --- Application menu ---
    NSMenuItem *appItem =
        [[NSMenuItem alloc] initWithTitle:@"Disk Utility"
                                    action:nil
                             keyEquivalent:@""];
    NSMenu *appMenu = [[NSMenu alloc] init];
    [appMenu addItemWithTitle:NSLocalizedString(@"About Disk Utility", nil)
                       action:@selector(orderFrontStandardAboutPanel:)
                keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *prefs = (NSMenuItem *)[appMenu
        addItemWithTitle:NSLocalizedString(@"Preferences…", nil)
                   action:@selector(commandPreferences:)
            keyEquivalent:@","];
    prefs.target = target;
    [appMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *servicesItem =
        (NSMenuItem *)[appMenu addItemWithTitle:NSLocalizedString(@"Services", nil)
                                         action:nil
                                  keyEquivalent:@""];
    NSMenu *servicesMenu = [[NSMenu alloc] init];
    servicesItem.submenu = servicesMenu;
    [NSApp setServicesMenu:servicesMenu];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:NSLocalizedString(@"Hide Disk Utility", nil)
                       action:@selector(hide:)
                keyEquivalent:@"h"];
    [appMenu addItemWithTitle:NSLocalizedString(@"Hide Others", nil)
                       action:@selector(hideOtherApplications:)
                keyEquivalent:@"h"];
    [[appMenu itemWithTitle:NSLocalizedString(@"Hide Others", nil)]
        setKeyEquivalentModifierMask:NSAlternateKeyMask];
    [appMenu addItemWithTitle:NSLocalizedString(@"Show All", nil)
                       action:@selector(unhideAllApplications:)
                keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:NSLocalizedString(@"Quit Disk Utility", nil)
                       action:@selector(terminate:)
                keyEquivalent:@"q"];
    appItem.submenu = appMenu;
    [menubar addItem:appItem];

    // --- New submenu (shared by File and Images) ---
    NSMenu *newSubmenu = [[NSMenu alloc]
        initWithTitle:NSLocalizedString(@"New", nil)];
    // Device imaging is the only source the New Image panel supports today.
    NSMenuItem *newDevice = (NSMenuItem *)[newSubmenu
        addItemWithTitle:NSLocalizedString(@"Disk Image from Device…", nil)
                  action:@selector(commandNewImageFromDevice:)
           keyEquivalent:@"n"];
    newDevice.keyEquivalentModifierMask = NSAlternateKeyMask;
    newDevice.target = target;
    NSMenuItem *newBlank = (NSMenuItem *)[newSubmenu
        addItemWithTitle:NSLocalizedString(@"Blank Disk Image…", nil)
                  action:@selector(commandBlankImage:)
           keyEquivalent:@"n"];
    newBlank.target = target;
    NSMenuItem *newFolder = (NSMenuItem *)[newSubmenu
        addItemWithTitle:NSLocalizedString(@"Disk Image from Folder…", nil)
                  action:@selector(commandImageFromFolder:)
           keyEquivalent:@"n"];
    newFolder.keyEquivalentModifierMask = NSShiftKeyMask;
    newFolder.target = target;

    // --- File menu ---
    NSMenuItem *fileItem =
        [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"File", nil)
                                    action:nil
                             keyEquivalent:@""];
    NSMenu *fileMenu = [[NSMenu alloc] init];
    NSMenuItem *newItem =
        (NSMenuItem *)[fileMenu addItemWithTitle:NSLocalizedString(@"New", nil)
                                         action:nil
                                  keyEquivalent:@""];
    newItem.submenu = newSubmenu;
    NSMenuItem *openImg = (NSMenuItem *)[fileMenu
        addItemWithTitle:NSLocalizedString(@"Open Disk Image…", nil)
                   action:@selector(commandOpenDiskImage:)
            keyEquivalent:@"o"];
    openImg.keyEquivalentModifierMask = NSAlternateKeyMask;
    openImg.target = target;
    [fileMenu addItem:[NSMenuItem separatorItem]];
    [self addCommand:fileMenu
               title:NSLocalizedString(@"Mount", nil)
             selector:@selector(commandMount:)
             keyMask:0
                  key:@""];
    [self addCommand:fileMenu
               title:NSLocalizedString(@"Unmount", nil)
             selector:@selector(commandUnmount:)
             keyMask:0
                  key:@""];
    [self addCommand:fileMenu
               title:NSLocalizedString(@"Eject", nil)
             selector:@selector(commandEject:)
             keyMask:NSCommandKeyMask
                  key:@"e"];
    [fileMenu addItem:[NSMenuItem separatorItem]];
    [self addCommand:fileMenu
               title:NSLocalizedString(@"Get Info", nil)
             selector:@selector(commandGetInfo:)
             keyMask:NSCommandKeyMask
                  key:@"i"];
    [fileMenu addItem:[NSMenuItem separatorItem]];
    [self addCommand:fileMenu
               title:NSLocalizedString(@"Close", nil)
             selector:@selector(commandClose:)
             keyMask:NSCommandKeyMask
                  key:@"w"];
    fileItem.submenu = fileMenu;
    [menubar addItem:fileItem];

    // --- Edit menu (standard text editing; nil target = responder chain) ---
    NSMenuItem *editItem =
        [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Edit", nil)
                                    action:nil
                             keyEquivalent:@""];
    NSMenu *editMenu = [[NSMenu alloc] init];
    [editMenu addItemWithTitle:NSLocalizedString(@"Undo", nil)
                        action:@selector(undo:)
                 keyEquivalent:@"z"];
    [editMenu addItemWithTitle:NSLocalizedString(@"Redo", nil)
                        action:@selector(redo:)
                 keyEquivalent:@"z"];
    [[editMenu itemWithTitle:NSLocalizedString(@"Redo", nil)]
        setKeyEquivalentModifierMask:NSAlternateKeyMask];
    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItemWithTitle:NSLocalizedString(@"Cut", nil)
                        action:@selector(cut:)
                 keyEquivalent:@"x"];
    [editMenu addItemWithTitle:NSLocalizedString(@"Copy", nil)
                        action:@selector(copy:)
                 keyEquivalent:@"c"];
    [editMenu addItemWithTitle:NSLocalizedString(@"Paste", nil)
                        action:@selector(paste:)
                 keyEquivalent:@"v"];
    [editMenu addItemWithTitle:NSLocalizedString(@"Delete", nil)
                        action:@selector(delete:)
                 keyEquivalent:@""];
    [editMenu addItemWithTitle:NSLocalizedString(@"Select All", nil)
                        action:@selector(selectAll:)
                 keyEquivalent:@"a"];
    editItem.submenu = editMenu;
    [menubar addItem:editItem];

    // --- View menu ---
    NSMenuItem *viewItem =
        [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"View", nil)
                                    action:nil
                             keyEquivalent:@""];
    NSMenu *viewMenu = [[NSMenu alloc] init];
    NSMenuItem *showAll = (NSMenuItem *)[viewMenu
        addItemWithTitle:NSLocalizedString(@"Show All Devices", nil)
                   action:@selector(commandShowAllDevices:)
            keyEquivalent:@""];
    showAll.target = target;
    NSMenuItem *showVol = (NSMenuItem *)[viewMenu
        addItemWithTitle:NSLocalizedString(@"Show Only Volumes", nil)
                   action:@selector(commandShowOnlyVolumes:)
            keyEquivalent:@""];
    showVol.target = target;
    [self addCommand:viewMenu
               title:NSLocalizedString(@"Refresh", nil)
             selector:@selector(commandRefresh:)
             keyMask:NSCommandKeyMask
                  key:@"r"];
    [viewMenu addItem:[NSMenuItem separatorItem]];
    [self addCommand:viewMenu
               title:NSLocalizedString(@"Show Sidebar", nil)
             selector:@selector(commandToggleSidebar:)
             keyMask:NSCommandKeyMask | NSControlKeyMask
                  key:@"s"];
    NSMenuItem *hideTB = (NSMenuItem *)[viewMenu
        addItemWithTitle:NSLocalizedString(@"Hide Toolbar", nil)
                   action:@selector(commandToggleToolbar:)
            keyEquivalent:@""];
    hideTB.target = target;
    NSMenuItem *customizeTB = (NSMenuItem *)[viewMenu
        addItemWithTitle:NSLocalizedString(@"Customize Toolbar…", nil)
                   action:@selector(commandCustomizeToolbar:)
            keyEquivalent:@""];
    customizeTB.target = target;
    NSMenuItem *showStatus = (NSMenuItem *)[viewMenu
        addItemWithTitle:NSLocalizedString(@"Show Status Bar", nil)
                   action:@selector(commandToggleStatusBar:)
            keyEquivalent:@""];
    showStatus.target = target;
    viewItem.submenu = viewMenu;
    [menubar addItem:viewItem];

    // --- Images menu ---
    NSMenuItem *imagesItem =
        [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Images", nil)
                                    action:nil
                             keyEquivalent:@""];
    NSMenu *imagesMenu = [[NSMenu alloc] init];
    NSMenuItem *imgNewItem =
        (NSMenuItem *)[imagesMenu addItemWithTitle:NSLocalizedString(@"New", nil)
                                            action:nil
                                     keyEquivalent:@""];
    NSMenu *imgNewSub = [[NSMenu alloc]
        initWithTitle:NSLocalizedString(@"New", nil)];
    NSMenuItem *imgNewDevice = (NSMenuItem *)[imgNewSub
        addItemWithTitle:NSLocalizedString(@"Disk Image from Device…", nil)
                   action:@selector(commandNewImageFromDevice:)
            keyEquivalent:@"n"];
    imgNewDevice.keyEquivalentModifierMask = NSAlternateKeyMask;
    imgNewDevice.target = target;
    NSMenuItem *imgNewBlank = (NSMenuItem *)[imgNewSub
        addItemWithTitle:NSLocalizedString(@"Blank Disk Image…", nil)
                   action:@selector(commandBlankImage:)
            keyEquivalent:@"n"];
    imgNewBlank.target = target;
    NSMenuItem *imgNewFolder = (NSMenuItem *)[imgNewSub
        addItemWithTitle:NSLocalizedString(@"Disk Image from Folder…", nil)
                   action:@selector(commandImageFromFolder:)
            keyEquivalent:@"n"];
    imgNewFolder.keyEquivalentModifierMask = NSShiftKeyMask;
    imgNewFolder.target = target;
    imgNewItem.submenu = imgNewSub;
    [self addCommand:imagesMenu
               title:NSLocalizedString(@"Convert", nil)
             selector:@selector(commandConvert:)
             keyMask:0
                  key:@""];
    [self addCommand:imagesMenu
               title:NSLocalizedString(@"Burn", nil)
             selector:@selector(commandBurn:)
             keyMask:0
                  key:@""];
    [self addCommand:imagesMenu
               title:NSLocalizedString(@"Erase Disc", nil)
             selector:@selector(commandEraseDisc:)
             keyMask:0
                  key:@""];
    [self addCommand:imagesMenu
               title:NSLocalizedString(@"Resize", nil)
             selector:@selector(commandResize:)
             keyMask:0
                  key:@""];
    [self addCommand:imagesMenu
               title:NSLocalizedString(@"Copy Disc…", nil)
             selector:@selector(commandCopyDisc:)
             keyMask:0
                  key:@""];
    [self addCommand:imagesMenu
               title:NSLocalizedString(@"Verify Disc…", nil)
             selector:@selector(commandVerifyDisc:)
             keyMask:0
                  key:@""];
    [imagesMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *addChecksum = (NSMenuItem *)[imagesMenu
        addItemWithTitle:NSLocalizedString(@"Add Checksum", nil)
                   action:@selector(commandAddChecksum:)
            keyEquivalent:@""];
    addChecksum.target = target;
    NSMenuItem *verifyChecksum = (NSMenuItem *)[imagesMenu
        addItemWithTitle:NSLocalizedString(@"Verify Checksum", nil)
                   action:@selector(commandVerifyChecksum:)
            keyEquivalent:@""];
    verifyChecksum.target = target;
    NSMenuItem *scanRestore = (NSMenuItem *)[imagesMenu
        addItemWithTitle:NSLocalizedString(@"Scan Image for Restore…", nil)
                   action:@selector(commandScanImageForRestore:)
            keyEquivalent:@""];
    scanRestore.target = target;
    imagesItem.submenu = imagesMenu;
    [menubar addItem:imagesItem];

    // --- Window menu ---
    NSMenuItem *windowItem =
        [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Window", nil)
                                    action:nil
                             keyEquivalent:@""];
    NSMenu *windowMenu = [[NSMenu alloc] init];
    [windowMenu addItemWithTitle:NSLocalizedString(@"Minimize", nil)
                          action:@selector(performMiniaturize:)
                   keyEquivalent:@"m"];
    [windowMenu addItemWithTitle:NSLocalizedString(@"Zoom", nil)
                          action:@selector(performZoom:)
                   keyEquivalent:@""];
    [windowMenu addItem:[NSMenuItem separatorItem]];
    [windowMenu addItemWithTitle:NSLocalizedString(@"Bring All to Front", nil)
                          action:@selector(arrangeInFront:)
                   keyEquivalent:@""];
    windowItem.submenu = windowMenu;
    [NSApp setWindowsMenu:windowMenu];
    [menubar addItem:windowItem];

    // --- Help menu ---
    NSMenuItem *helpItem =
        [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Help", nil)
                                    action:nil
                             keyEquivalent:@""];
    NSMenu *helpMenu = [[NSMenu alloc] init];
    [helpMenu
        addItemWithTitle:NSLocalizedString(@"Disk Utility Help", nil)
                  action:@selector(commandHelp:)
           keyEquivalent:@"?"];
    helpItem.submenu = helpMenu;
    [menubar addItem:helpItem];

    NSApp.mainMenu = menubar;
}

// Small helper so the repetitive command items stay readable: builds an
// NSMenuItem targeting the window controller with a modifier+key shortcut.
- (void)addCommand:(NSMenu *)menu
             title:(NSString *)title
          selector:(SEL)selector
           keyMask:(NSUInteger)keyMask
                key:(NSString *)key
{
    NSMenuItem *item = (NSMenuItem *)[menu addItemWithTitle:title
                                                     action:selector
                                              keyEquivalent:key];
    item.keyEquivalentModifierMask = keyMask;
    item.target = self.windowController;
}

@end
