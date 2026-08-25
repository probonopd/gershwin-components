/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

@class DUStorageManager;

// Owns the main window and fans selection changes out to the browser,
// operation area and information panel (SPEC section 30).
@interface DUMainWindowController : NSWindowController

- (instancetype)initWithStorageManager:(DUStorageManager *)manager
    NS_DESIGNATED_INITIALIZER;

// Main-menu actions (the menu is assembled in DUApplicationDelegate and
// targets this controller). Each acts on the current sidebar selection.
- (IBAction)commandNewImageFromDevice:(id)sender;
- (IBAction)commandMount:(id)sender;
- (IBAction)commandUnmount:(id)sender;
- (IBAction)commandEject:(id)sender;
- (IBAction)commandGetInfo:(id)sender;
- (IBAction)commandVerify:(id)sender;
- (IBAction)commandConvert:(id)sender;
- (IBAction)commandBurn:(id)sender;
- (IBAction)commandResize:(id)sender;
- (IBAction)commandRefresh:(id)sender;
- (IBAction)commandToggleSidebar:(id)sender;
- (IBAction)commandClose:(id)sender;
- (IBAction)commandHelp:(id)sender;

// File menu
- (IBAction)commandBlankImage:(id)sender;
- (IBAction)commandImageFromFolder:(id)sender;
- (IBAction)commandOpenDiskImage:(id)sender;

// Images menu
- (IBAction)commandAddChecksum:(id)sender;
- (IBAction)commandVerifyChecksum:(id)sender;
- (IBAction)commandScanImageForRestore:(id)sender;

// View menu
- (IBAction)commandShowAllDevices:(id)sender;
- (IBAction)commandShowOnlyVolumes:(id)sender;
- (IBAction)commandToggleToolbar:(id)sender;
- (IBAction)commandToggleStatusBar:(id)sender;
- (IBAction)commandCustomizeToolbar:(id)sender;

// Application menu
- (IBAction)commandPreferences:(id)sender;

@end
