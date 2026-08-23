/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */


#ifndef ScreenshotController_h
#define ScreenshotController_h

#import <AppKit/AppKit.h>

typedef enum {
    ScreenshotModeWindow,
    ScreenshotModeArea,
    ScreenshotModeFullScreen,
    ScreenshotModeScreen
} ScreenshotMode;

@interface ScreenshotController : NSObject
{
    NSWindow *mainWindow;
    NSTextField *statusLabel;
    NSButton *windowButton;
    NSButton *areaButton;
    NSButton *fullScreenButton;
    NSButton *saveButton;
    NSButton *copyButton;
    NSButton *titleCheckButton;
    NSButton *shadowCheckButton;
    NSTextField *delayField;
    NSProgressIndicator *progressIndicator;
    
    ScreenshotMode currentMode;
    BOOL includeTitle;
    BOOL includeShadow;
    NSString *lastSavedPath;
    NSImage *capturedImage;
    NSData *capturedImagePNG;
    
    NSTimer *countdownTimer;
    int delayCountdown;
    NSWindow *prefsWindow;
}

// UI Properties
@property (retain) NSWindow *mainWindow;
@property (retain) NSTextField *statusLabel;
@property (retain) NSButton *windowButton;
@property (retain) NSButton *areaButton;
@property (retain) NSButton *fullScreenButton;
@property (retain) NSButton *saveButton;
@property (retain) NSButton *copyButton;
- (NSButton *)copyButton __attribute__((objc_method_family(none)));
@property (retain) NSButton *titleCheckButton;
@property (retain) NSButton *shadowCheckButton;
@property (retain) NSTextField *delayField;
@property (retain) NSProgressIndicator *progressIndicator;
@property (retain) NSWindow *prefsWindow;

// UI Creation
- (void)createUI;
- (void)showPreferences:(id)sender;

// Application delegate methods
- (void)applicationDidFinishLaunching:(NSNotification *)notification;
- (void)applicationWillTerminate:(NSNotification *)notification;
- (BOOL)application:(NSApplication *)application openFile:(NSString *)filename;

// Screenshot actions
- (IBAction)takeWindowScreenshot:(id)sender;
- (IBAction)takeAreaScreenshot:(id)sender;
- (IBAction)takeFullScreenScreenshot:(id)sender;
- (IBAction)saveScreenshot:(id)sender;
- (IBAction)toggleIncludeTitle:(id)sender;
- (IBAction)toggleIncludeShadow:(id)sender;

// Utility methods
- (void)updateStatus:(NSString *)status;
- (void)showProgressIndicator:(BOOL)show;
- (void)setScreenshotMode:(ScreenshotMode)mode;
- (NSString *)generateDefaultFileName;
- (void)generatePNGData;
- (BOOL)saveImageToFile:(NSString *)filepath;
- (void)showSavePanel;

// Timer and delay handling
- (void)performDelayedSelection:(int)delay mode:(ScreenshotMode)mode;
- (void)updateCountdownDisplay;
- (void)performSelectionOnLiveScreen;

// Command line handling
- (void)handleCommandLineArguments;
- (void)printUsageAndExit;

@end

#endif /* ScreenshotController_h */