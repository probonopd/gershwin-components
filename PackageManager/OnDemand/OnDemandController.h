/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * OnDemandController — Controller for the OnDemand installer app.
 * Manages the progress window and orchestrates install/launch flow.
 */

#import <Cocoa/Cocoa.h>
#import <Foundation/Foundation.h>
#import <PackageManager/GWPackageManager.h>
#import <PackageManager/GWPackageInstallSpec.h>

@class ODLogWindowController;

@interface OnDemandController : NSObject <NSApplicationDelegate, GWInstallProgressHandler>
{
  NSWindow *_window;
  NSProgressIndicator *_progressBar;
  NSTextField *_statusField;
  NSButton *_cancelButton;
  NSImageView *_iconView;
  NSButton *_installButton;
  NSTextField *_descriptionField;

  GWPackageManager *_pm;
  GWPackageInstallSpec *_spec;
  NSString *_plistPath;
  NSString *_appName;
  BOOL _dpkgRetried;
  ODLogWindowController *_logController;

  /* Direct install mode */
  NSString *_directFilePath;
  NSString *_directFormat;
  NSArray  *_extractedFiles;
  BOOL     _isDirectInstall;
  NSString *_launchPath;
}

// Read the install plist from the app bundle
- (BOOL)setupFromPlist;

// Handle a package file directly (e.g., double-click on .deb)
- (BOOL)setupFromFile:(NSString *)path;

// Check if the target command is already available without showing a window
- (BOOL)commandIsAvailable;

// Launch the command and exit the app (no GUI shown)
- (BOOL)launchAndExit;

// Show an error dialog
- (void)showError:(NSString *)message;

// Show the progress window
- (void)showWindow;

// Install packages then launch (call after showWindow)
- (void)performInstallAndLaunch;

// Show the installer log window
- (void)showLog:(id)sender;

// Show the About dialog
- (void)showAbout:(id)sender;

@end
