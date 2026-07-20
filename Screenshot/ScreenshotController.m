/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */


#import "ScreenshotController.h"
#import "ScreenshotCapture.h"
#import "AppearanceMetrics.h"
#import <AppKit/NSApplication.h>
#import <AppKit/NSWindow.h>
#import <AppKit/NSPanel.h>
#import <AppKit/NSButton.h>
#import <AppKit/NSTextField.h>
#import <AppKit/NSProgressIndicator.h>
#import <AppKit/NSAlert.h>
#import <AppKit/NSSavePanel.h>
#import <AppKit/NSPasteboard.h>
#import <Foundation/NSProcessInfo.h>
#import <Foundation/NSFileManager.h>
#import <Foundation/NSTimer.h>
#import <Foundation/NSTask.h>
#import <unistd.h>

@implementation ScreenshotController

@synthesize mainWindow;
@synthesize statusLabel;
@synthesize windowButton;
@synthesize areaButton;
@synthesize fullScreenButton;
@synthesize saveButton;
@synthesize copyButton;
@synthesize delayField;
@synthesize progressIndicator;

- (id)init {
    self = [super init];
    if (self) {
        currentMode = ScreenshotModeFullScreen;
        lastSavedPath = nil;
        capturedImage = nil;
        capturedImagePNG = nil;
        countdownTimer = nil;
        delayCountdown = 0;
    }
    return self;
}

- (NSString *)findTool:(NSString *)name
{
    NSString *pathEnv = [[[NSProcessInfo processInfo] environment] objectForKey:@"PATH"];
    if (!pathEnv) return nil;
    for (NSString *dir in [pathEnv componentsSeparatedByString:@":"]) {
        NSString *full = [dir stringByAppendingPathComponent:name];
        if ([[NSFileManager defaultManager] isExecutableFileAtPath:full])
            return full;
    }
    return nil;
}

- (void)dealloc {
    [lastSavedPath release];
    [capturedImage release];
    [capturedImagePNG release];
    if (countdownTimer) {
        [countdownTimer invalidate];
        [countdownTimer release];
    }
    [ScreenshotCapture cleanupX11];
    [super dealloc];
}

- (void)createUI {
    // Create main menu
    NSMenu *mainMenu = [[NSMenu alloc] initWithTitle:@"MainMenu"];
    
    // Application menu
    NSMenuItem *appMenuItem = [[NSMenuItem alloc] initWithTitle:@"Screenshot" action:NULL keyEquivalent:@""];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"Screenshot"];
    [appMenu addItemWithTitle:@"About Screenshot" action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Quit" action:@selector(terminate:) keyEquivalent:@"q"];
    [appMenuItem setSubmenu:appMenu];
    [mainMenu addItem:appMenuItem];
    [appMenu release];
    [appMenuItem release];
    
    [[NSApplication sharedApplication] setMainMenu:mainMenu];
    [mainMenu release];
    
    // Calculate window dimensions following metrics guidelines
    // All spacing must be multiples of 4px and follow the dialog layout rules
    CGFloat windowWidth = METRICS_WIN_MIN_WIDTH;
    
    // Build layout from bottom to top to calculate total height needed
    // Bottom margin: METRICS_CONTENT_BOTTOM_MARGIN (20px)
    CGFloat totalHeight = METRICS_CONTENT_BOTTOM_MARGIN;
    
    // Delay field: 16px label height + progress indicator
    totalHeight += METRICS_SPACE_16;  // Spacing from buttons to delay control
    totalHeight += METRICS_TEXT_INPUT_FIELD_HEIGHT;  // Input field height (22px)
    
    // Buttons row: METRICS_BUTTON_HEIGHT (20px)
    totalHeight += METRICS_SPACE_16;  // Spacing between primary control groups
    totalHeight += METRICS_BUTTON_HEIGHT;  // Button height
    
    // Mode selection label
    totalHeight += METRICS_SPACE_8;  // Spacing between label and buttons
    totalHeight += 14.0;  // Label height
    
    // Status label
    totalHeight += METRICS_SPACE_20;  // Spacing between control groups
    totalHeight += 16.0;  // Status label height
    
    // Top margin: METRICS_CONTENT_TOP_MARGIN (15px)
    totalHeight += METRICS_CONTENT_TOP_MARGIN;
    
    CGFloat windowHeight = totalHeight;
    
    NSRect windowFrame = NSMakeRect(0, 0, windowWidth, windowHeight);
    mainWindow = [[NSWindow alloc] initWithContentRect:windowFrame
                                             styleMask:NSTitledWindowMask | NSClosableWindowMask | NSMiniaturizableWindowMask
                                               backing:NSBackingStoreBuffered
                                                 defer:NO];
    [mainWindow setTitle:@"Screenshot"];
    [mainWindow setDelegate:self];
    [mainWindow setHidesOnDeactivate:NO];
    [mainWindow setLevel:NSNormalWindowLevel];

    // Tell X11 WM this is a normal app window, not a dialog/utility
    x11_set_window_type_normal([mainWindow windowRef]);
    
    NSView *contentView = [mainWindow contentView];
    
    // Build layout from top to bottom
    // Start with top margin
    CGFloat currentY = windowHeight - METRICS_CONTENT_TOP_MARGIN - 16.0;
    CGFloat contentWidth = windowWidth - (2 * METRICS_CONTENT_SIDE_MARGIN);
    
    // Create status label
    NSRect statusFrame = NSMakeRect(METRICS_CONTENT_SIDE_MARGIN, currentY, contentWidth, 16);
    statusLabel = [[NSTextField alloc] initWithFrame:statusFrame];
    [statusLabel setStringValue:@"Ready to take screenshot"];
    [statusLabel setEditable:NO];
    [statusLabel setSelectable:NO];
    [statusLabel setBezeled:NO];
    [statusLabel setDrawsBackground:NO];
    [statusLabel setFont:METRICS_FONT_SYSTEM_REGULAR_13];
    [contentView addSubview:statusLabel];
    
    // Spacing between control groups (20px)
    currentY -= METRICS_SPACE_20 + 14.0;
    
    // Create mode selection label
    NSRect modeLabelFrame = NSMakeRect(METRICS_CONTENT_SIDE_MARGIN, currentY, contentWidth, 14);
    NSTextField *modeLabel = [[NSTextField alloc] initWithFrame:modeLabelFrame];
    [modeLabel setStringValue:@"Select capture mode:"];
    [modeLabel setEditable:NO];
    [modeLabel setSelectable:NO];
    [modeLabel setBezeled:NO];
    [modeLabel setDrawsBackground:NO];
    [modeLabel setFont:METRICS_FONT_SYSTEM_REGULAR_13];
    [contentView addSubview:modeLabel];
    [modeLabel release];
    
    // Spacing between label and buttons (8px per metrics)
    currentY -= METRICS_SPACE_8 + METRICS_BUTTON_HEIGHT;
    
    // Create buttons for screenshot mode
    // Using METRICS_BUTTON_HORIZ_INTERSPACE (10px) between buttons per HIG
    // Distribute three buttons evenly across available width
    CGFloat btnHeight = METRICS_BUTTON_HEIGHT;
    CGFloat btnWidth = (contentWidth - (2 * METRICS_BUTTON_HORIZ_INTERSPACE)) / 3.0;
    CGFloat spacing = METRICS_BUTTON_HORIZ_INTERSPACE;
    CGFloat startX = METRICS_CONTENT_SIDE_MARGIN;
    
    NSRect windowBtnFrame = NSMakeRect(startX, currentY, btnWidth, btnHeight);
    windowButton = [[NSButton alloc] initWithFrame:windowBtnFrame];
    [windowButton setTitle:@"Window"];
    [windowButton setButtonType:NSMomentaryLight];
    [windowButton setTarget:self];
    [windowButton setAction:@selector(takeWindowScreenshot:)];
    [windowButton setEnabled:YES];
    [contentView addSubview:windowButton];
    
    NSRect areaBtnFrame = NSMakeRect(startX + btnWidth + spacing, currentY, btnWidth, btnHeight);
    areaButton = [[NSButton alloc] initWithFrame:areaBtnFrame];
    [areaButton setTitle:@"Area"];
    [areaButton setButtonType:NSMomentaryLight];
    [areaButton setTarget:self];
    [areaButton setAction:@selector(takeAreaScreenshot:)];
    [contentView addSubview:areaButton];
    
    NSRect fullScreenBtnFrame = NSMakeRect(startX + 2 * (btnWidth + spacing), currentY, btnWidth, btnHeight);
    fullScreenButton = [[NSButton alloc] initWithFrame:fullScreenBtnFrame];
    [fullScreenButton setTitle:@"Full Screen"];
    [fullScreenButton setButtonType:NSMomentaryLight];
    [fullScreenButton setTarget:self];
    [fullScreenButton setAction:@selector(takeFullScreenScreenshot:)];
    [contentView addSubview:fullScreenButton];
    
    // Spacing between primary control groups (16px per metrics for mixed control dialogs)
    currentY -= METRICS_SPACE_16 + METRICS_TEXT_INPUT_FIELD_HEIGHT;
    
    // Create delay field label and input
    // Text input field height per metrics: 22px
    // Use baseline-aligned layout for label and control
    CGFloat labelWidth = 110.0;
    CGFloat delayFieldY = currentY;
    
    NSRect delayLabelFrame = NSMakeRect(METRICS_CONTENT_SIDE_MARGIN, delayFieldY + 3, labelWidth, 16);
    NSTextField *delayLabel = [[NSTextField alloc] initWithFrame:delayLabelFrame];
    [delayLabel setStringValue:@"Delay (seconds):"];
    [delayLabel setEditable:NO];
    [delayLabel setSelectable:NO];
    [delayLabel setBezeled:NO];
    [delayLabel setDrawsBackground:NO];
    [delayLabel setFont:METRICS_FONT_SYSTEM_REGULAR_13];
    [contentView addSubview:delayLabel];
    [delayLabel release];
    
    // Place input field with METRICS_SPACE_8 (8px) gap from label text per metrics
    NSRect delayFieldFrame = NSMakeRect(METRICS_CONTENT_SIDE_MARGIN + labelWidth + METRICS_SPACE_8, 
                                        delayFieldY, 50, METRICS_TEXT_INPUT_FIELD_HEIGHT);
    delayField = [[NSTextField alloc] initWithFrame:delayFieldFrame];
    [delayField setIntValue:0];
    [delayField setFont:METRICS_FONT_SYSTEM_REGULAR_13];
    [contentView addSubview:delayField];
    
    // Create progress indicator (positioned at right side, vertically centered with delay field)
    NSRect progressFrame = NSMakeRect(windowWidth - METRICS_CONTENT_SIDE_MARGIN - 20, 
                                      delayFieldY + (METRICS_TEXT_INPUT_FIELD_HEIGHT - 16.0) / 2.0, 16, 16);
    progressIndicator = [[NSProgressIndicator alloc] initWithFrame:progressFrame];
    [progressIndicator setStyle:NSProgressIndicatorSpinningStyle];
    [progressIndicator setHidden:YES];
    [contentView addSubview:progressIndicator];
    
    // Initialize mode
    [self setScreenshotMode:ScreenshotModeFullScreen];
}

#pragma mark - Window Delegate Methods

- (BOOL)windowShouldClose:(id)sender {
    [[NSApplication sharedApplication] terminate:self];
    return YES;
}

#pragma mark - Application Delegate Methods

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    // Check if we were launched with command line arguments
    NSArray *arguments = [[NSProcessInfo processInfo] arguments];
    
    if ([arguments count] > 1) {
        [self handleCommandLineArguments];
        return;
    }
    
    // Initialize X11 system
    if (![ScreenshotCapture initializeX11]) {
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:@"Screenshot Error"];
        [alert setInformativeText:@"Failed to initialize screenshot system. Make sure X11 is running."];
        [alert setAlertStyle:NSCriticalAlertStyle];
        [alert runModal];
        [alert release];
        
        [[NSApplication sharedApplication] terminate:self];
        return;
    }
    
    // Set up the application delegate
    [[NSApplication sharedApplication] setDelegate:self];
    
    // Create the UI programmatically
    [self createUI];
    
    // Show main window
    if (mainWindow) {
        [mainWindow makeKeyAndOrderFront:self];
    }
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [capturedImagePNG release];
    capturedImagePNG = nil;
    [ScreenshotCapture cleanupX11];
}

- (BOOL)application:(NSApplication *)application openFile:(NSString *)filename {
    // Handle file opening requests
    return NO;
}

#pragma mark - Screenshot Actions

- (IBAction)takeWindowScreenshot:(id)sender {
    NSDebugLLog(@"gwcomp", @"=== takeWindowScreenshot started ===");
    [self setScreenshotMode:ScreenshotModeWindow];
    
    // Use the delayed selection flow (which lets user click on window to capture)
    int delay = [delayField intValue];
    NSDebugLLog(@"gwcomp", @"Performing window screenshot with delay=%d", delay);
    [self performDelayedSelection:delay mode:ScreenshotModeWindow];
}

- (IBAction)takeAreaScreenshot:(id)sender {
    [self setScreenshotMode:ScreenshotModeArea];
    [self performScreenshotWithMode:ScreenshotModeArea];
}

- (IBAction)takeFullScreenScreenshot:(id)sender {
    [self setScreenshotMode:ScreenshotModeFullScreen];
    [self performScreenshotWithMode:ScreenshotModeFullScreen];
}

- (void)performScreenshotWithMode:(ScreenshotMode)mode {
    int delay = [delayField intValue];
    
    // For window and area selection modes, delay happens BEFORE selection on live screen
    // (the selection functions work on the live screen, not on a captured image)
    if (mode == ScreenshotModeWindow || mode == ScreenshotModeArea) {
        [self performDelayedSelection:delay mode:mode];
        return;
    }
    
    // For fullscreen mode, hide window, wait for it to be completely hidden, then proceed with capture
    [self updateStatus:@"Taking screenshot..."];
    [self showProgressIndicator:YES];
    
    // Hide the main window before fullscreen capture
    BOOL windowWasVisible = NO;
    if (mainWindow && [mainWindow isVisible]) {
        [mainWindow orderOut:self];
        windowWasVisible = YES;
    }
    
    // Wait 250ms for window to be completely hidden before taking screenshot
    if (windowWasVisible) {
        usleep(250000);
    }
    
    CaptureRect rect = {0, 0, 0, 0};
    [self captureScreenshotWithRect:rect mode:mode delay:delay];
}

- (void)performDelayedSelection:(int)delay mode:(ScreenshotMode)mode {
    currentMode = mode;
    
    if (delay <= 0) {
        // No delay, proceed directly with selection
        [self performSelectionOnLiveScreen];
        return;
    }
    
    delayCountdown = delay;
    [self updateCountdownDisplay];
    
    // Create and schedule the countdown timer
    if (countdownTimer) {
        [countdownTimer invalidate];
        [countdownTimer release];
    }
    
    countdownTimer = [[NSTimer scheduledTimerWithTimeInterval:1.0
                                                       target:self
                                                     selector:@selector(updateCountdownDisplay)
                                                     userInfo:nil
                                                      repeats:YES] retain];
}

- (void)updateCountdownDisplay {
    if (delayCountdown > 0) {
        [self updateStatus:[NSString stringWithFormat:@"Selection begins in %d seconds...", delayCountdown]];
        delayCountdown--;
    } else {
        // Timer expired, perform selection
        if (countdownTimer) {
            [countdownTimer invalidate];
            [countdownTimer release];
            countdownTimer = nil;
        }
        [self performSelectionOnLiveScreen];
    }
}

- (void)performSelectionOnLiveScreen {
    [self updateStatus:@"Taking screenshot..."];
    [self showProgressIndicator:YES];
    
    CaptureRect rect = {0, 0, 0, 0};
    
    // Get selection rectangle for window/area modes from the live screen
    if (currentMode == ScreenshotModeWindow) {
        // Hide the main window while the user selects a window so it doesn't get captured
        BOOL windowWasVisible = (mainWindow && [mainWindow isVisible]);
        if (windowWasVisible) {
            [mainWindow orderOut:self];
            // Give the window manager more time to unmap the window before grabbing pointer
            usleep(250000); // 250ms - needed for X11 pointer grab to succeed
        }

        rect = [ScreenshotCapture selectWindow];

        [self showProgressIndicator:NO];
        if (rect.width == 0 || rect.height == 0) {
            [self updateStatus:@"Window selection cancelled or failed"];
            NSAlert *alert = [[NSAlert alloc] init];
            [alert setMessageText:@"Window Selection Failed"];
            [alert setInformativeText:@"Unable to select window. This may be due to an X11 error. Check the terminal for details."];
            [alert setAlertStyle:NSWarningAlertStyle];
            [alert runModal];
            [alert release];
            [mainWindow makeKeyAndOrderFront:self];
            return;
        }
    } else if (currentMode == ScreenshotModeArea) {
        // Hide the main window while the user selects an area so it doesn't get captured
        BOOL windowWasVisible = (mainWindow && [mainWindow isVisible]);
        if (windowWasVisible) {
            [mainWindow orderOut:self];
            // Give the window manager more time to unmap the window before grabbing pointer
            usleep(250000); // 250ms - needed for X11 pointer grab to succeed
        }

        rect = [ScreenshotCapture selectArea];

        [self showProgressIndicator:NO];
        if (rect.width == 0 || rect.height == 0) {
            [self updateStatus:@"Area selection cancelled or failed"];
            NSAlert *alert = [[NSAlert alloc] init];
            [alert setMessageText:@"Area Selection Failed"];
            [alert setInformativeText:@"Unable to select area. This may be due to an X11 error. Check the terminal for details."];
            [alert setAlertStyle:NSWarningAlertStyle];
            [alert runModal];
            [alert release];
            [mainWindow makeKeyAndOrderFront:self];
            return;
        }
    }
    
    // Perform the capture with the selected rect
    [self captureScreenshotWithRect:rect mode:currentMode delay:0];
}

- (void)captureScreenshotWithRect:(CaptureRect)rect mode:(ScreenshotMode)mode delay:(int)delay {
    NSDebugLLog(@"gwcomp", @"=== captureScreenshotWithRect called: rect=(%d,%d,%d,%d), mode=%d, delay=%d ===", 
          rect.x, rect.y, rect.width, rect.height, mode, delay);
    
    CaptureMode captureMode;
    
    switch (mode) {
        case ScreenshotModeWindow:
            captureMode = CaptureWindow;
            break;
        case ScreenshotModeArea:
            captureMode = CaptureArea;
            break;
        case ScreenshotModeFullScreen:
        default:
            captureMode = CaptureFullScreen;
            break;
    }
    
    // Capture the image
    NSDebugLLog(@"gwcomp", @"Calling captureImageWithMode");
    NSImage *image = [ScreenshotCapture captureImageWithMode:captureMode delay:delay rect:rect];
    NSDebugLLog(@"gwcomp", @"captureImageWithMode returned: image=%@", image);
    
    // Flash the screen after capture for visual feedback
    if (captureMode == CaptureFullScreen || captureMode == CaptureArea || captureMode == CaptureWindow) {
        NSDebugLLog(@"gwcomp", @"Flashing fullscreen");
        [self flashScreenFullscreen];
    }
    
    [self showProgressIndicator:NO];
    
    if (image) {
        [capturedImage release];
        capturedImage = [image retain];
        
        // Generate PNG data once and reuse for both save and clipboard operations
        [self generatePNGData];
        
        [self updateStatus:@"Screenshot captured successfully"];
        
        // Show alert with save/copy options
        [self showPostCaptureDialog];

        // Restore window after user dismissed post-capture dialog
        if (mainWindow) {
            [mainWindow makeKeyAndOrderFront:self];
        }
    } else {
        // Restore window after failure
        if (mainWindow) {
            [mainWindow makeKeyAndOrderFront:self];
        }
        [self updateStatus:@"Failed to capture screenshot"];
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:@"Screenshot Failed"];
        [alert setInformativeText:@"Unable to capture screenshot. This may be due to an X11 error or insufficient permissions. Please try again."];
        [alert setAlertStyle:NSWarningAlertStyle];
        [alert runModal];
        [alert release];
    }
}

- (void)showPostCaptureDialog {
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:@"Screenshot Captured"];
    [alert setInformativeText:@"What would you like to do with the screenshot?"];
    [alert addButtonWithTitle:@"Save to File"];
    [alert addButtonWithTitle:@"Copy to Clipboard"];
    [alert addButtonWithTitle:@"Copy text (OCR)"];
    [alert addButtonWithTitle:@"Cancel"];
    [alert setAlertStyle:NSInformationalAlertStyle];
    
    NSInteger response = [alert runModal];
    [alert release];
    
    if (response == NSAlertFirstButtonReturn) {
        // Save to file
        [self showSavePanel];
    } else if (response == NSAlertSecondButtonReturn) {
        // Copy to clipboard - show window and stay open
        if ([self copyImageToClipboardAndReturnSuccess]) {
            [self updateStatus:@"Screenshot copied to clipboard"];
            if (mainWindow) [mainWindow makeKeyAndOrderFront:self];
        } else {
            NSAlert *errorAlert = [[NSAlert alloc] init];
            [errorAlert setMessageText:@"Copy Failed"];
            [errorAlert setInformativeText:@"Unable to put image data on clipboard."];
            [errorAlert setAlertStyle:NSWarningAlertStyle];
            [errorAlert runModal];
            [errorAlert release];
            if (mainWindow) [mainWindow makeKeyAndOrderFront:self];
        }
    } else if (response == NSAlertThirdButtonReturn) {
        // OCR
        [self performOCRAndCopyToClipboard];
        if (mainWindow) [mainWindow makeKeyAndOrderFront:self];
    } else {
        // Cancel - stay open for next capture
        [self updateStatus:@"Ready to take screenshot"];
    }
}

- (IBAction)saveScreenshot:(id)sender {
    if (!capturedImage) {
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:@"No Screenshot"];
        [alert setInformativeText:@"Please take a screenshot first."];
        [alert setAlertStyle:NSWarningAlertStyle];
        [alert runModal];
        [alert release];
        return;
    }
    
    [self showSavePanel];
}



- (BOOL)copyImageToClipboardAndReturnSuccess {
    NSDebugLLog(@"gwcomp", @"=== Copy to Clipboard Started ===");
    
    if (!capturedImagePNG) {
        NSDebugLLog(@"gwcomp", @"ERROR: No PNG data available to copy");
        return NO;
    }
    
    NSDebugLLog(@"gwcomp", @"PNG data size: %lu bytes", (unsigned long)[capturedImagePNG length]);
    
    // Set GNUstep pasteboard for clipboard
    NSDebugLLog(@"gwcomp", @"Setting GNUstep pasteboard");
    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
    if (!pasteboard) {
        NSDebugLLog(@"gwcomp", @"ERROR: Failed to get pasteboard");
        return NO;
    }
    
    NSDebugLLog(@"gwcomp", @"Declaring PNG type on pasteboard");
    NSArray *types = [NSArray arrayWithObject:NSPasteboardTypePNG];
    
    @try {
        [pasteboard declareTypes:types owner:nil];
        NSDebugLLog(@"gwcomp", @"Declared NSPasteboardTypePNG");
    } @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"EXCEPTION in declareTypes: %@", exception);
        return NO;
    }
    
    NSDebugLLog(@"gwcomp", @"Setting PNG data on pasteboard");
    @try {
        BOOL pngSuccess = [pasteboard setData:capturedImagePNG forType:NSPasteboardTypePNG];
        NSDebugLLog(@"gwcomp", @"PNG setData result: %d", pngSuccess);
        
        if (pngSuccess) {
            NSDebugLLog(@"gwcomp", @"=== Copy to Clipboard Completed Successfully ===");
            return YES;
        } else {
            NSDebugLLog(@"gwcomp", @"ERROR: Failed to set PNG data on pasteboard");
            return NO;
        }
    } @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"EXCEPTION in setData: %@", exception);
        return NO;
    }
}

- (void)performOCRAndCopyToClipboard {
    if (!capturedImagePNG) {
        [self updateStatus:@"No screenshot data for OCR"];
        return;
    }
    NSString *tesseract = [self findTool:@"tesseract"];
    if (!tesseract) {
        NSAlert *a = [[NSAlert alloc] init];
        [a setMessageText:@"Tesseract not found"];
        [a setInformativeText:@"Install tesseract with your package manager:\n\n"
            @"  Debian/Ubuntu:  sudo apt install tesseract-ocr\n"
            @"  Arch:           sudo pacman -S tesseract\n"
            @"  FreeBSD:        sudo pkg install tesseract\n"
            @"  OpenBSD:        doas pkg_add tesseract"];
        [a addButtonWithTitle:@"OK"];
        [a runModal];
        [a release];
        [self updateStatus:@"OCR failed — tesseract not installed"];
        return;
    }

    // Write PNG to a temp file
    NSString *tmp = NSTemporaryDirectory();
    NSString *tmpPath = [tmp stringByAppendingPathComponent:@"screenshot_ocr.png"];
    if (![capturedImagePNG writeToFile:tmpPath atomically:NO]) {
        [self updateStatus:@"OCR failed — could not write temp file"];
        return;
    }

    // Run: tesseract <input> stdout 2>/dev/null
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:tesseract];
    [task setArguments:@[tmpPath, @"stdout"]];

    NSPipe *outPipe = [NSPipe pipe];
    [task setStandardOutput:outPipe];
    [task setStandardError:[NSFileHandle fileHandleWithNullDevice]];

    @try {
        [task launch];
        [task waitUntilExit];
    } @catch (NSException *e) {
        [[NSFileManager defaultManager] removeItemAtPath:tmpPath error:NULL];
        [task release];
        [self updateStatus:@"OCR failed"];
        return;
    }

    // Read OCR output
    NSData *outData = [[outPipe fileHandleForReading] readDataToEndOfFile];
    NSString *text = [[[NSString alloc] initWithData:outData
                                            encoding:NSUTF8StringEncoding] autorelease];
    [[NSFileManager defaultManager] removeItemAtPath:tmpPath error:NULL];
    [task release];

    if (!text || [text length] == 0) {
        [self updateStatus:@"OCR returned no text"];
        return;
    }

    // Trim trailing newline
    if ([text hasSuffix:@"\n"])
        text = [text substringToIndex:[text length] - 1];

    // Copy text to clipboard
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb declareTypes:[NSArray arrayWithObject:NSStringPboardType] owner:nil];
    if ([pb setString:text forType:NSStringPboardType]) {
        [self updateStatus:[NSString stringWithFormat:@"OCR: %lu chars copied",
                            (unsigned long)[text length]]];
    } else {
        [self updateStatus:@"OCR failed — clipboard error"];
    }
}

- (void)flashScreenFullscreen {
    // Create a full-screen white window for flash effect
    NSRect screenFrame = [[NSScreen mainScreen] frame];
    NSWindow *flashWindow = [[NSWindow alloc] initWithContentRect:screenFrame
                                                         styleMask:NSBorderlessWindowMask
                                                           backing:NSBackingStoreBuffered
                                                             defer:NO];
    if (!flashWindow) return;
    
    [flashWindow setBackgroundColor:[NSColor whiteColor]];
    [flashWindow setLevel:NSScreenSaverWindowLevel + 1];
    [flashWindow setOpaque:YES];
    [flashWindow setIgnoresMouseEvents:YES];
    
    // Show the flash window
    [flashWindow orderFrontRegardless];
    [flashWindow display];
    
    // Process events to ensure window is rendered
    NSDate *endTime = [NSDate dateWithTimeIntervalSinceNow:0.25];
    while ([endTime timeIntervalSinceNow] > 0) {
        NSEvent *event = [[NSApplication sharedApplication] nextEventMatchingMask:NSAnyEventMask 
                                                                         untilDate:[NSDate dateWithTimeIntervalSinceNow:0.01] 
                                                                            inMode:NSDefaultRunLoopMode 
                                                                           dequeue:YES];
        if (event) {
            [[NSApplication sharedApplication] sendEvent:event];
        }
    }
    
    // Remove and clean up the flash window
    [flashWindow orderOut:nil];
    [flashWindow release];
}

- (void)flashScreenInRect:(CaptureRect)rect {
    // Create a white window only in the selected area
    NSRect flashRect = NSMakeRect(rect.x, rect.y, rect.width, rect.height);
    NSWindow *flashWindow = [[NSWindow alloc] initWithContentRect:flashRect
                                                         styleMask:NSBorderlessWindowMask
                                                           backing:NSBackingStoreBuffered
                                                             defer:NO];
    if (!flashWindow) return;
    
    [flashWindow setBackgroundColor:[NSColor whiteColor]];
    [flashWindow setLevel:NSScreenSaverWindowLevel + 1];
    [flashWindow setOpaque:YES];
    [flashWindow setIgnoresMouseEvents:YES];
    
    // Show the flash window
    [flashWindow orderFrontRegardless];
    [flashWindow display];
    
    // Process events to ensure window is rendered
    NSDate *endTime = [NSDate dateWithTimeIntervalSinceNow:0.25];
    while ([endTime timeIntervalSinceNow] > 0) {
        NSEvent *event = [[NSApplication sharedApplication] nextEventMatchingMask:NSAnyEventMask 
                                                                         untilDate:[NSDate dateWithTimeIntervalSinceNow:0.01] 
                                                                            inMode:NSDefaultRunLoopMode 
                                                                           dequeue:YES];
        if (event) {
            [[NSApplication sharedApplication] sendEvent:event];
        }
    }
    
    // Remove and clean up the flash window
    [flashWindow orderOut:nil];
    [flashWindow release];
}


#pragma mark - Utility Methods

- (void)updateStatus:(NSString *)status {
    if (statusLabel) {
        [statusLabel setStringValue:status];
    } else {
        NSDebugLLog(@"gwcomp", @"Screenshot: %@", status);
    }
}

- (void)showProgressIndicator:(BOOL)show {
    if (progressIndicator) {
        if (show) {
            [progressIndicator startAnimation:self];
            [progressIndicator setHidden:NO];
        } else {
            [progressIndicator stopAnimation:self];
            [progressIndicator setHidden:YES];
        }
    }
}

- (void)setScreenshotMode:(ScreenshotMode)mode {
    currentMode = mode;
    
    // Update UI to reflect current mode
    if (windowButton && areaButton && fullScreenButton) {
        [windowButton setState:(mode == ScreenshotModeWindow) ? NSOnState : NSOffState];
        [areaButton setState:(mode == ScreenshotModeArea) ? NSOnState : NSOffState];
        [fullScreenButton setState:(mode == ScreenshotModeFullScreen) ? NSOnState : NSOffState];
    }
}

- (NSString *)generateDefaultFileName {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    [formatter setDateFormat:@"yyyy-MM-dd-HHmmss"];
    NSString *dateString = [formatter stringFromDate:[NSDate date]];
    [formatter release];
    
    NSString *filename = [NSString stringWithFormat:@"Screenshot-%@.png", dateString];
    
    // Get desktop path
    NSArray *desktopPaths = NSSearchPathForDirectoriesInDomains(NSDesktopDirectory, NSUserDomainMask, YES);
    if ([desktopPaths count] > 0) {
        NSString *desktopPath = [desktopPaths objectAtIndex:0];
        return [desktopPath stringByAppendingPathComponent:filename];
    }
    
    return filename;
}

- (void)generatePNGData {
    if (!capturedImage) {
        NSDebugLLog(@"gwcomp", @"ERROR: Cannot generate PNG data - no captured image");
        return;
    }
    
    NSDebugLLog(@"gwcomp", @"Generating PNG data from captured image");
    NSData *imageData = [capturedImage TIFFRepresentation];
    NSBitmapImageRep *bitmap = [NSBitmapImageRep imageRepWithData:imageData];
    
    if (!bitmap) {
        NSDebugLLog(@"gwcomp", @"ERROR: Failed to create bitmap from TIFF");
        return;
    }
    
    NSData *pngData = [bitmap representationUsingType:NSPNGFileType properties:nil];
    if (!pngData) {
        NSDebugLLog(@"gwcomp", @"ERROR: Failed to get PNG representation");
        return;
    }
    
    [capturedImagePNG release];
    capturedImagePNG = [pngData retain];
    NSDebugLLog(@"gwcomp", @"PNG data generated: %lu bytes", (unsigned long)[capturedImagePNG length]);
}

- (BOOL)saveImageToFile:(NSString *)filepath {
    if (!capturedImagePNG) {
        NSDebugLLog(@"gwcomp", @"ERROR: No PNG data available to save");
        return NO;
    }
    
    NSDebugLLog(@"gwcomp", @"Saving PNG data to file: %@", filepath);
    return [capturedImagePNG writeToFile:filepath atomically:YES];
}

- (void)showSavePanel {
    NSSavePanel *panel = [NSSavePanel savePanel];
    [panel setAllowedFileTypes:[NSArray arrayWithObject:@"png"]];
    [panel setCanCreateDirectories:YES];
    
    // Generate default filename and set it
    NSString *defaultPath = [self generateDefaultFileName];
    [panel setNameFieldStringValue:[defaultPath lastPathComponent]];
    
    NSString *directory = [defaultPath stringByDeletingLastPathComponent];
    if (directory && [directory length] > 0) {
        [panel setDirectoryURL:[NSURL fileURLWithPath:directory]];
    }
    
    NSInteger result = [panel runModal];
    if (result == NSFileHandlingPanelOKButton) {
        NSString *filepath = [[panel URL] path];
        if ([self saveImageToFile:filepath]) {
            [lastSavedPath release];
            lastSavedPath = [filepath retain];
            [self updateStatus:[NSString stringWithFormat:@"Saved to: %@", [filepath lastPathComponent]]];
        } else {
            NSAlert *alert = [[NSAlert alloc] init];
            [alert setMessageText:@"Save Failed"];
            [alert setInformativeText:@"Unable to save screenshot to the specified location."];
            [alert setAlertStyle:NSWarningAlertStyle];
            [alert runModal];
            [alert release];
        }
    } else {
        // Cancel save - stay open
        [self updateStatus:@"Save cancelled"];
    }
}

#pragma mark - Command Line Handling

- (void)handleCommandLineArguments {
    // Hide the main window so we have a clean screenshot
    [mainWindow orderOut:nil];
    
    NSArray *arguments = [[NSProcessInfo processInfo] arguments];
    
    // Parse arguments
    BOOL showHelp = NO;
    NSString *outputFile = nil;
    int delay = 0;
    ScreenshotMode mode = ScreenshotModeFullScreen;
    
    for (int i = 1; i < [arguments count]; i++) {
        NSString *arg = [arguments objectAtIndex:i];
        
        if ([arg isEqualToString:@"-h"] || [arg isEqualToString:@"--help"]) {
            showHelp = YES;
            break;
        } else if ([arg isEqualToString:@"-a"] || [arg isEqualToString:@"--area"]) {
            mode = ScreenshotModeArea;
        } else if ([arg isEqualToString:@"-s"] || [arg isEqualToString:@"--screen"]) {
            mode = ScreenshotModeScreen;
        } else if ([arg isEqualToString:@"-w"] || [arg isEqualToString:@"--window"]) {
            mode = ScreenshotModeWindow;
        } else if ([arg isEqualToString:@"-d"] || [arg isEqualToString:@"--delay"]) {
            if (i + 1 < [arguments count]) {
                delay = [[arguments objectAtIndex:++i] intValue];
            }
        } else if ([arg isEqualToString:@"-o"] || [arg isEqualToString:@"--output"]) {
            if (i + 1 < [arguments count]) {
                outputFile = [arguments objectAtIndex:++i];
            }
        } else if (![arg hasPrefix:@"-"] && !outputFile) {
            outputFile = arg;
        }
    }
    
    if (showHelp) {
        [self printUsageAndExit];
        return;
    }
    
    // Store parameters for delayed execution
    currentMode = mode;
    if (outputFile) {
        [lastSavedPath release];
        lastSavedPath = [outputFile copy];
    }
    
    // Apply delay before any interaction
    if (delay > 0) {
        [self performSelector:@selector(executeCommandLineScreenshot) 
                   withObject:nil 
                   afterDelay:delay];
    } else {
        [self executeCommandLineScreenshot];
    }
}

- (void)executeCommandLineScreenshot {
    CaptureMode captureMode;
    CaptureRect rect = {0, 0, 0, 0};
    
    switch (currentMode) {
        case ScreenshotModeWindow:
            captureMode = CaptureWindow;
            rect = [ScreenshotCapture selectWindow];
            if (rect.width == 0 || rect.height == 0) {
                exit(1);
            }
            break;
        case ScreenshotModeArea:
            captureMode = CaptureArea;
            rect = [ScreenshotCapture selectArea];
            if (rect.width == 0 || rect.height == 0) {
                exit(1);
            }
            break;
        case ScreenshotModeScreen:
            captureMode = CaptureFullScreen;
            break;
        case ScreenshotModeFullScreen:
        default:
            captureMode = CaptureFullScreen;
            break;
    }
    
    NSString *outputFile = lastSavedPath;
    if (!outputFile) {
        outputFile = [self generateDefaultFileName];
    }
    
    [ScreenshotCapture captureScreenshotWithMode:captureMode 
                                                      filename:outputFile 
                                                         delay:0
                                                          rect:rect];
    
    // Flash the screen after capture
    if (captureMode == CaptureFullScreen || captureMode == CaptureArea) {
        [self flashScreenFullscreen];
        // Give event loop time to process the flash
        usleep(500000);
    }
    
    // Exit after flash completes
    exit(0);
}

- (void)printUsageAndExit {
    printf("Screenshot - GNUstep Screenshot Application\n\n");
    printf("Usage: Screenshot [options] [output-file]\n\n");
    printf("Options:\n");
    printf("  -h, --help         Show this help message\n");
    printf("  -a, --area         Select area to screenshot\n");
    printf("  -w, --window       Select window to screenshot\n");
    printf("  -s, --screen       Capture the whole screen\n");
    printf("  -d, --delay SEC    Wait SEC seconds before taking screenshot\n");
    printf("  -o, --output FILE  Save screenshot to FILE\n");
    printf("\n");
    printf("If no options are specified, a full screen screenshot will be taken and saved.\n");
    printf("If no output file is specified, a default name will be generated.\n");
    
    exit(0);
}

- (void)exitApp {
    [[NSApplication sharedApplication] terminate:self];
}

#pragma mark - Timer and Delay Handling

@end