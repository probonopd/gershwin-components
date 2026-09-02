/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <GSAssistantFramework.h>
#import "InstallationSteps.h"

@interface InstallationAppDelegate : NSObject <NSApplicationDelegate>
@end

@implementation InstallationAppDelegate
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    (void)sender;
    return YES;
}
@end

@interface InstallationDelegate : NSObject <GSAssistantWindowDelegate,
                                            IADiskSelectionDelegate,
                                            IAInstallProgressDelegate,
                                            IAInstallTypeDelegate>
{
    @public
    IADiskInfo *_selectedDisk;
    NSString *_imageSourcePath;
    IAInstallProgressStep *_progressStep;
    IAConfirmStep *_confirmStep;
    GSAssistantWindow *_assistantWindow;
    IALogWindowController *_logWindowController;
    BOOL _installSucceeded;
}
@end

@implementation InstallationDelegate

- (void)dealloc
{
    [_selectedDisk release];
    [_imageSourcePath release];
    [_logWindowController release];
    /* _progressStep, _confirmStep, _assistantWindow are not owned */
    [super dealloc];
}

- (void)assistantWindowDidFinish:(GSAssistantWindow *)window {
    (void)window;
    if (_installSucceeded) {
        NSDebugLLog(@"gwcomp", @"InstallationDelegate: assistantWindowDidFinish - restarting system");
        NSTask *task = [[NSTask alloc] init];
        [task setLaunchPath:@"/usr/bin/env"];
        [task setArguments:@[@"sudo", @"-n", @"shutdown", @"-r", @"now"]];
        @try {
            [task launch];
        } @catch (NSException *ex) {
            NSDebugLLog(@"gwcomp", @"InstallationDelegate: restart failed: %@", ex);
        }
        [task release];
    }
    [NSApp terminate:nil];
}

- (BOOL)assistantWindow:(GSAssistantWindow *)window shouldCancelWithConfirmation:(BOOL)showConfirmation {
    (void)window;
    if (showConfirmation) {
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:NSLocalizedString(@"Cancel Installation?", @"")];
        [alert setInformativeText:NSLocalizedString(@"Are you sure you want to cancel?", @"")];
        [alert addButtonWithTitle:NSLocalizedString(@"Cancel", @"")];
        [alert addButtonWithTitle:NSLocalizedString(@"Continue", @"")];
        [alert setAlertStyle:NSWarningAlertStyle];
        NSModalResponse response = [alert runModal];
        [alert release];
        return response == NSAlertFirstButtonReturn;
    }
    return YES;
}

- (void)assistantWindow:(GSAssistantWindow *)window willShowStep:(id<GSAssistantStepProtocol>)step
{
    (void)window;
    /* Update the confirm step with the currently selected disk */
    if (_confirmStep && step == (id<GSAssistantStepProtocol>)_confirmStep) {
        NSDebugLLog(@"gwcomp", @"InstallationDelegate: updating confirm step with disk %@", _selectedDisk.devicePath);
        [_confirmStep updateWithDisk:_selectedDisk];
    }
}

- (void)assistantWindow:(GSAssistantWindow *)window didShowStep:(id<GSAssistantStepProtocol>)step
{
    (void)window;
    /* Auto-start installation when the progress step becomes visible */
    if (_progressStep && step == (id<GSAssistantStepProtocol>)_progressStep) {
        NSDebugLLog(@"gwcomp", @"InstallationDelegate: progress step appeared, starting installation to %@",
              _selectedDisk.devicePath);
        [_progressStep startInstallationToDisk:_selectedDisk source:_imageSourcePath];
    }
}

- (void)diskSelectionStep:(id)step didSelectDisk:(IADiskInfo *)disk {
    (void)step;
    [_selectedDisk release];
    _selectedDisk = [disk retain];
    NSDebugLLog(@"gwcomp", @"InstallationDelegate: disk selected: %@", _selectedDisk.devicePath);
}

- (void)installTypeStep:(id)step didSelectImageSource:(NSString *)imageSourcePath {
    (void)step;
    [_imageSourcePath release];
    _imageSourcePath = [imageSourcePath copy];
    NSDebugLLog(@"gwcomp", @"InstallationDelegate: image source path set to %@", _imageSourcePath ?: @"(none)");
}

- (void)installProgressDidFinish:(BOOL)success {
    NSDebugLLog(@"gwcomp", @"InstallationDelegate: installation finished, success=%d", success);
    _installSucceeded = success;
    if (success && _assistantWindow) {
        [_assistantWindow goToNextStep];
    } else if (!success && _assistantWindow) {
        NSString *msg = NSLocalizedString(
            @"An error occurred during installation.\n\nPlease check the log for details.",
            @"");
        GSCompletionStep *errorStep = [[GSCompletionStep alloc]
            initWithCompletionMessage:msg success:NO];
        errorStep.title = NSLocalizedString(@"Installation Failed", @"");
        errorStep.customContinueTitle = NSLocalizedString(@"Close", @"");
        errorStep.hideNavigationButtons = NO;

        [_assistantWindow.steps removeAllObjects];
        [_assistantWindow addStep:errorStep];
        [_assistantWindow goToStepAtIndex:0];
        [errorStep release];
    }
}

- (void)showLog:(id)sender {
    (void)sender;
    if (_logWindowController) {
        [[_logWindowController window] makeKeyAndOrderFront:nil];
    }
}

@end

int main(int argc, const char *argv[]) {
    (void)argc;
    (void)argv;
    @autoreleasepool {
        [NSApplication sharedApplication];
        
        InstallationAppDelegate *appDelegate = [[InstallationAppDelegate alloc] init];
        [NSApp setDelegate:appDelegate];
        
        NSMenu *mainMenu = [[NSMenu alloc] init];
        
        /* === Application (Apple) Menu - populate the existing app-name menu === */
        NSString *appName = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleDisplayName"];
        if (!appName) appName = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleName"];
        if (!appName) appName = [[NSProcessInfo processInfo] processName];
        NSMenuItem *appMenuItem = [[NSMenuItem alloc] initWithTitle:appName
                                                             action:nil
                                                      keyEquivalent:@""];
        [mainMenu addItem:appMenuItem];
        NSMenu *appMenu = [[NSMenu alloc] initWithTitle:appName];
        [appMenu addItemWithTitle:NSLocalizedString(@"About Installer", @"")
                           action:@selector(orderFrontStandardAboutPanel:)
                    keyEquivalent:@""];
        [appMenu addItem:[NSMenuItem separatorItem]];
        [appMenu addItemWithTitle:NSLocalizedString(@"Hide Installer", @"")
                           action:@selector(hide:)
                    keyEquivalent:@"h"];
        NSMenuItem *hideOthersItem = (NSMenuItem *)[appMenu addItemWithTitle:NSLocalizedString(@"Hide Others", @"")
                                                       action:@selector(hideOtherApplications:)
                                                keyEquivalent:@"h"];
        [hideOthersItem setKeyEquivalentModifierMask:(NSCommandKeyMask | NSAlternateKeyMask)];
        [appMenu addItemWithTitle:NSLocalizedString(@"Show All", @"")
                           action:@selector(unhideAllApplications:)
                    keyEquivalent:@""];
        [appMenu addItem:[NSMenuItem separatorItem]];
        [appMenu addItemWithTitle:NSLocalizedString(@"Quit Installer", @"")
                           action:@selector(terminate:)
                    keyEquivalent:@"q"];
        [appMenuItem setSubmenu:appMenu];
        
        /* === Edit Menu === */
        NSMenuItem *editMenuItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Edit", @"")
                                                              action:nil
                                                       keyEquivalent:@""];
        [mainMenu addItem:editMenuItem];
        NSMenu *editMenu = [[NSMenu alloc] initWithTitle:NSLocalizedString(@"Edit", @"")];
        [editMenu addItemWithTitle:NSLocalizedString(@"Cut", @"")
                            action:@selector(cut:) keyEquivalent:@"x"];
        [editMenu addItemWithTitle:NSLocalizedString(@"Copy", @"")
                            action:@selector(copy:) keyEquivalent:@"c"];
        [editMenu addItemWithTitle:NSLocalizedString(@"Paste", @"")
                            action:@selector(paste:) keyEquivalent:@"v"];
        [editMenu addItemWithTitle:NSLocalizedString(@"Select All", @"")
                            action:@selector(selectAll:) keyEquivalent:@"a"];
        [editMenuItem setSubmenu:editMenu];
        
        /* === Window Menu === */
        NSMenuItem *windowMenuItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Window", @"")
                                                                action:nil
                                                         keyEquivalent:@""];
        [mainMenu addItem:windowMenuItem];
        NSMenu *windowMenu = [[NSMenu alloc] initWithTitle:NSLocalizedString(@"Window", @"")];
        [windowMenu addItemWithTitle:NSLocalizedString(@"Minimize", @"")
                              action:@selector(performMiniaturize:)
                       keyEquivalent:@"m"];
        [windowMenu addItemWithTitle:NSLocalizedString(@"Zoom", @"")
                              action:@selector(performZoom:)
                       keyEquivalent:@""];
        [windowMenu addItem:[NSMenuItem separatorItem]];
        NSMenuItem *logMenuItem = (NSMenuItem *)[windowMenu addItemWithTitle:NSLocalizedString(@"Installer Log", @"")
                                                       action:@selector(showLog:)
                                                keyEquivalent:@"L"];
        [windowMenu addItem:[NSMenuItem separatorItem]];
        [windowMenu addItemWithTitle:NSLocalizedString(@"Bring All to Front", @"")
                              action:@selector(arrangeInFront:)
                       keyEquivalent:@""];
        [windowMenuItem setSubmenu:windowMenu];
        [NSApp setWindowsMenu:windowMenu];
        
        [NSApp setMainMenu:mainMenu];
        /* GNUstep may insert an empty application-name placeholder at index 0.
           If present, populate that placeholder with our application menu and
           remove the duplicate item we previously added. */
        if ([mainMenu numberOfItems] > 0) {
            NSMenuItem *firstItem = [mainMenu itemAtIndex:0];
            NSMenuItem *secondItem = ([mainMenu numberOfItems] > 1) ? [mainMenu itemAtIndex:1] : nil;
            if (firstItem && (([firstItem submenu] == nil) || ([[firstItem submenu] numberOfItems] == 0))) {
                [firstItem setTitle:appName];
                [firstItem setSubmenu:appMenu];
                if (secondItem && [secondItem submenu] == appMenu) {
                    [mainMenu removeItemAtIndex:1];
                }
            }
        }

        InstallationDelegate *delegate = [[InstallationDelegate alloc] init];
        
        /* Normally we would check for an image-based installation source here and
         * offer a page to choose between clone and image mode, but it is
         * temporarily disabled.  The code is left commented out for future use. */
        /*
        NSString *imageSource = IACheckImageSourceAvailable();
        BOOL imageAvailable = (imageSource != nil && [imageSource length] > 0);
        NSDebugLLog(@"gwcomp", @"Image source available: %@ (%@)", imageAvailable ? @"YES" : @"NO",
              imageSource ?: @"none");
        IAInstallTypeStep *installTypeStep = nil;
        if (imageAvailable) {
            installTypeStep = [[IAInstallTypeStep alloc] init];
            [installTypeStep setDelegate:delegate];
            [installTypeStep setImageSource:imageSource];
        }
        */
        IAWelcomeStep *welcomeStep = [[IAWelcomeStep alloc] init];
        IALicenseStep *licenseStep = nil;
        if ([GSLocalizedContentManager hasLicenseContent]) {
            licenseStep = [[IALicenseStep alloc] init];
        }
        IADiskSelectionStep *diskStep = [[IADiskSelectionStep alloc] init];
        IAConfirmStep *confirmStep = [[IAConfirmStep alloc] init];
        IAInstallProgressStep *progressStep = [[IAInstallProgressStep alloc] init];

        /* Use framework's GSCompletionStep for the success/restart page */
        NSString *completionMsg = NSLocalizedString(
            @"The operating system has been installed successfully.\nPlease restart your computer to boot from the new disk.",
            @"");
        GSCompletionStep *completionStep = [[GSCompletionStep alloc]
            initWithCompletionMessage:completionMsg success:YES];
        completionStep.title = NSLocalizedString(@"Finished", @"");
        completionStep.stepDescription = NSLocalizedString(@"Installation complete", @"");
        completionStep.customContinueTitle = NSLocalizedString(@"Restart", @"");
        completionStep.hideNavigationButtons = NO;

        /* Create log window controller */
        IALogWindowController *logWC = [[IALogWindowController alloc] init];

        [diskStep setDelegate:delegate];
        [progressStep setDelegate:delegate];
        [progressStep setLogWindowController:logWC];
        delegate->_progressStep = progressStep;
        delegate->_confirmStep = confirmStep;
        delegate->_logWindowController = logWC;

        /* Wire Installer Log menu item to delegate */
        [logMenuItem setTarget:delegate];
        
        GSAssistantBuilder *builder = [GSAssistantBuilder builder];
        [builder withTitle:NSLocalizedString(@"Install Operating System", @"")];
        [builder withIcon:[NSImage imageNamed:@"NSComputer"]];
        [builder allowingCancel:YES];
        
        [builder addStep:welcomeStep];
        if (licenseStep) {
            [builder addStep:licenseStep];
        }
        /*
        if (installTypeStep) {
            [builder addStep:installTypeStep];
        }
        */
        [builder addStep:diskStep];
        [builder addStep:confirmStep];
        [builder addStep:progressStep];
        [builder addStep:completionStep];
        
        GSAssistantWindow *assistant = [builder build];
        [assistant setDelegate:delegate];
        delegate->_assistantWindow = assistant;
        [[assistant window] makeKeyAndOrderFront:nil];
        
        [NSApp run];
        
        [appDelegate release];
    }
    return 0;
}
