#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <GSAssistantFramework.h>
#import <GSAssistantUtilities.h>
#import "InstallationSteps.h"

@interface InstallationAppDelegate : NSObject <NSApplicationDelegate>
@end

@implementation InstallationAppDelegate
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    NSLog(@"InstallationAssistant: Last window closed, terminating application");
    return YES;
}
@end

@interface InstallationDelegate : NSObject <GSAssistantWindowDelegate>
@end

@implementation InstallationDelegate

- (void)assistantWindowWillFinish:(GSAssistantWindow *)window {
    NSLog(@"Installation assistant will finish");
}

- (void)assistantWindowDidFinish:(GSAssistantWindow *)window {
    NSLog(@"Installation assistant finished");
    [NSApp terminate:nil];
}

- (BOOL)assistantWindow:(GSAssistantWindow *)window shouldCancelWithConfirmation:(BOOL)showConfirmation {
    if (showConfirmation) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Cancel Installation?";
        alert.informativeText = @"Are you sure you want to cancel the installation?";
        [alert addButtonWithTitle:@"Cancel Installation"];
        [alert addButtonWithTitle:@"Continue Installation"];
        alert.alertStyle = NSWarningAlertStyle;
        
        NSModalResponse response = [alert runModal];
        return response == NSAlertFirstButtonReturn;
    }
    return YES;
}

@end

@interface InstallationAssistant : NSObject
+ (void)showInstallationAssistant;
@end

@implementation InstallationAssistant

+ (void)showInstallationAssistant {
    NSLog(@"[InstallationAssistant] Starting showInstallationAssistant");
    InstallationDelegate *delegate = [[InstallationDelegate alloc] init];
    NSLog(@"[InstallationAssistant] Created delegate: %@", delegate);
    
    // Create license view
    NSLog(@"[InstallationAssistant] Creating license view...");
    NSView *licenseView = [self createLicenseView];
    NSLog(@"[InstallationAssistant] Created license view: %@ with frame: %@", licenseView, NSStringFromRect(licenseView.frame));
    
    // Create destination view
    NSLog(@"[InstallationAssistant] Creating destination view...");
    NSView *destinationView = [self createDestinationView];
    NSLog(@"[InstallationAssistant] Created destination view: %@ with frame: %@", destinationView, NSStringFromRect(destinationView.frame));
    
    // Create options view
    NSLog(@"[InstallationAssistant] Creating options view...");
    NSView *optionsView = [self createInstallOptionsView];
    NSLog(@"[InstallationAssistant] Created options view: %@ with frame: %@", optionsView, NSStringFromRect(optionsView.frame));
    
    // Create software selection view
    NSLog(@"[InstallationAssistant] Creating software selection view...");
    NSView *softwareView = [self createSoftwareSelectionView];
    NSLog(@"[InstallationAssistant] Created software selection view: %@ with frame: %@", softwareView, NSStringFromRect(softwareView.frame));
    
    NSLog(@"[InstallationAssistant] Creating builder...");
    GSAssistantBuilder *builder = [GSAssistantBuilder builder];
    NSLog(@"[InstallationAssistant] Created builder: %@", builder);
    
    NSLog(@"[InstallationAssistant] Setting layout style to installer...");
    [builder withLayoutStyle:GSAssistantLayoutStyleInstaller];
    
    NSLog(@"[InstallationAssistant] Setting title...");
    [builder withTitle:@"Software Installation"];
    
    NSLog(@"[InstallationAssistant] Setting icon...");
    [builder withIcon:[NSImage imageNamed:@"NSApplicationIcon"]];
    
    NSLog(@"[InstallationAssistant] Adding introduction...");
    [builder addIntroductionWithMessage:@"Install Gershwin system components and applications."
           features:@[@"Review software license",
                     @"Choose installation location",
                     @"Select components to install"]];
    
    NSLog(@"[InstallationAssistant] Adding license step...");
    IALicenseStep *licenseStep = [[IALicenseStep alloc] init];
    [builder addStep:licenseStep];
    [licenseStep release];
    
    NSLog(@"[InstallationAssistant] Adding destination step...");
    IADestinationStep *destinationStep = [[IADestinationStep alloc] init];
    [builder addStep:destinationStep];
    [destinationStep release];
    
    NSLog(@"[InstallationAssistant] Adding options step...");
    IAOptionsStep *optionsStep = [[IAOptionsStep alloc] init];
    [builder addStep:optionsStep];
    [optionsStep release];
    
    NSLog(@"[InstallationAssistant] Adding progress step...");
    [builder addProgressStep:@"Installing" 
           description:@"Installing software components..."];
    
    NSLog(@"[InstallationAssistant] Adding completion step...");
    [builder addCompletionWithMessage:@"Installation completed successfully!" 
           success:YES];
    
    NSLog(@"[InstallationAssistant] Building assistant...");
    GSAssistantWindow *assistant = [builder build];
    NSLog(@"[InstallationAssistant] Built assistant: %@", assistant);
    
    NSLog(@"[InstallationAssistant] Setting delegate...");
    assistant.delegate = delegate;
    
    NSLog(@"[InstallationAssistant] Showing window...");
    [assistant showWindow:nil];
    NSLog(@"[InstallationAssistant] Making window key and front...");
    [assistant.window makeKeyAndOrderFront:nil];
    NSLog(@"[InstallationAssistant] Assistant window should now be visible");
}

+ (NSView *)createLicenseView {
    NSView *container = [[NSView alloc] init];
    
    // License text
    NSTextField *licenseLabel = [GSAssistantUIHelper createTitleLabelWithText:@"Software License Agreement"];
    
    NSScrollView *scrollView = [[NSScrollView alloc] init];
    scrollView.hasVerticalScroller = YES;
    scrollView.hasHorizontalScroller = NO;
    scrollView.autohidesScrollers = NO;
    
    NSTextView *textView = [[NSTextView alloc] init];
    textView.editable = NO;
    textView.string = @"GERSHWIN SOFTWARE LICENSE AGREEMENT\n\n"
                      @"This software is provided 'AS IS' without warranty of any kind. "
                      @"By installing this software, you agree to the following terms:\n\n"
                      @"1. You may use this software for personal and commercial purposes.\n"
                      @"2. You may redistribute the software under the same license terms.\n"
                      @"3. You may modify the software for your own use.\n"
                      @"4. The authors are not liable for any damages resulting from use.\n\n"
                      @"This software includes components from the GNUstep project and other "
                      @"open source projects. See the individual component licenses for details.\n\n"
                      @"Copyright (c) 2025 Gershwin Project Contributors\n"
                      @"All rights reserved.";
    
    scrollView.documentView = textView;
    
    // Agreement checkbox
    NSButton *agreeCheck = [GSAssistantUIHelper createCheckboxWithTitle:@"I agree to the license terms"];
    
    // Create layout
    NSArray *views = @[licenseLabel, scrollView, agreeCheck];
    NSView *stackView = [GSAssistantUIHelper createVerticalStackViewWithViews:views spacing:12.0];
    
    [container addSubview:stackView];
    [GSAssistantUIHelper addStandardConstraintsToView:stackView inContainer:container];
    
    return container;
}

+ (NSView *)createDestinationView {
    NSView *container = [[NSView alloc] init];
    
    // Destination selection
    NSTextField *destLabel = [GSAssistantUIHelper createTitleLabelWithText:@"Installation Location:"];
    
    NSTextField *pathField = [GSAssistantUIHelper createInputFieldWithPlaceholder:@"/Applications"];
    pathField.stringValue = @"/Applications";
    
    NSButton *browseButton = [[NSButton alloc] init];
    browseButton.title = @"Browse...";
    browseButton.bezelStyle = NSRoundedBezelStyle;
    
    // Disk space info
    NSTextField *spaceLabel = [GSAssistantUIHelper createDescriptionLabelWithText:@"Required Space: 150 MB"];
    NSTextField *availableLabel = [GSAssistantUIHelper createDescriptionLabelWithText:@"Available Space: 2.5 GB"];
    
    // Installation options
    NSTextField *optionsLabel = [GSAssistantUIHelper createTitleLabelWithText:@"Installation Options:"];
    NSButton *createShortcutCheck = [GSAssistantUIHelper createCheckboxWithTitle:@"Create desktop shortcuts"];
    NSButton *addToPathCheck = [GSAssistantUIHelper createCheckboxWithTitle:@"Add to system PATH"];
    [createShortcutCheck setState:NSOnState];
    [addToPathCheck setState:NSOnState];
    
    // Create horizontal layout for path and browse button
    NSView *pathContainer = [GSAssistantUIHelper createHorizontalStackViewWithViews:@[pathField, browseButton] spacing:8.0];
    
    // Create layout
    NSArray *views = @[destLabel, pathContainer, spaceLabel, availableLabel, 
                      optionsLabel, createShortcutCheck, addToPathCheck];
    NSView *stackView = [GSAssistantUIHelper createVerticalStackViewWithViews:views spacing:8.0];
    
    [container addSubview:stackView];
    [GSAssistantUIHelper addStandardConstraintsToView:stackView inContainer:container];
    
    return container;
}

+ (NSView *)createInstallOptionsView {
    NSView *container = [[NSView alloc] init];
    
    // Component selection
    NSTextField *componentsLabel = [GSAssistantUIHelper createTitleLabelWithText:@"Components to Install:"];
    
    NSButton *coreCheck = [GSAssistantUIHelper createCheckboxWithTitle:@"Gershwin Core System (Required)"];
    [coreCheck setState:NSOnState];
    coreCheck.enabled = NO; // Required component
    
    NSButton *appsCheck = [GSAssistantUIHelper createCheckboxWithTitle:@"Standard Applications"];
    [appsCheck setState:NSOnState];
    
    NSButton *devsCheck = [GSAssistantUIHelper createCheckboxWithTitle:@"Development Tools"];
    [devsCheck setState:NSOffState];
    
    NSButton *gamesCheck = [GSAssistantUIHelper createCheckboxWithTitle:@"Games and Entertainment"];
    [gamesCheck setState:NSOffState];
    
    NSButton *docsCheck = [GSAssistantUIHelper createCheckboxWithTitle:@"Documentation and Examples"];
    [docsCheck setState:NSOnState];
    
    // Installation type
    NSTextField *typeLabel = [GSAssistantUIHelper createTitleLabelWithText:@"Installation Type:"];
    NSButton *typicalRadio = [GSAssistantUIHelper createRadioButtonWithTitle:@"Typical Installation"];
    NSButton *customRadio = [GSAssistantUIHelper createRadioButtonWithTitle:@"Custom Installation"];
    NSButton *minimalRadio = [GSAssistantUIHelper createRadioButtonWithTitle:@"Minimal Installation"];
    [typicalRadio setState:NSOnState];
    
    // Size information
    NSTextField *sizeLabel = [GSAssistantUIHelper createDescriptionLabelWithText:@"Total Size: 147 MB"];
    
    // Create layout
    NSArray *views = @[componentsLabel, coreCheck, appsCheck, devsCheck, gamesCheck, docsCheck,
                      typeLabel, typicalRadio, customRadio, minimalRadio, sizeLabel];
    NSView *stackView = [GSAssistantUIHelper createVerticalStackViewWithViews:views spacing:8.0];
    
    [container addSubview:stackView];
    [GSAssistantUIHelper addStandardConstraintsToView:stackView inContainer:container];
    
    return container;
}

+ (NSView *)createSoftwareSelectionView {
    NSLog(@"[InstallationAssistant] Creating software selection view container...");
    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300)];
    NSLog(@"[InstallationAssistant] Container created with frame: %@", NSStringFromRect(container.frame));
    
    // Software package checkboxes
    NSLog(@"[InstallationAssistant] Creating development tools checkbox...");
    NSButton *devToolsCheck = [[NSButton alloc] initWithFrame:NSMakeRect(24, 260, 250, 20)];
    [devToolsCheck setButtonType:NSSwitchButton];
    devToolsCheck.title = @"Development Tools (GCC, Make, etc.)";
    devToolsCheck.state = NSOnState;
    NSLog(@"[InstallationAssistant] Development tools checkbox created: %@", devToolsCheck);
    
    NSLog(@"[InstallationAssistant] Creating desktop environment checkbox...");
    NSButton *desktopCheck = [[NSButton alloc] initWithFrame:NSMakeRect(20, 230, 250, 20)];
    [desktopCheck setButtonType:NSSwitchButton];
    desktopCheck.title = @"Desktop Environment (GNOME/KDE)";
    desktopCheck.state = NSOnState;
    NSLog(@"[InstallationAssistant] Desktop environment checkbox created: %@", desktopCheck);
    
    NSLog(@"[InstallationAssistant] Creating multimedia checkbox...");
    NSButton *multimediaCheck = [[NSButton alloc] initWithFrame:NSMakeRect(24, 200, 250, 20)];
    [multimediaCheck setButtonType:NSSwitchButton];
    multimediaCheck.title = @"Multimedia Codecs and Players";
    NSLog(@"[InstallationAssistant] Multimedia checkbox created: %@", multimediaCheck);
    
    // Add all subviews
    NSLog(@"[InstallationAssistant] Adding subviews to container...");
    [container addSubview:devToolsCheck];
    NSLog(@"[InstallationAssistant] Added development tools checkbox");
    [container addSubview:desktopCheck];
    NSLog(@"[InstallationAssistant] Added desktop environment checkbox");
    [container addSubview:multimediaCheck];
    NSLog(@"[InstallationAssistant] Added multimedia checkbox");
    
    NSLog(@"[InstallationAssistant] Container now has %lu subviews", (unsigned long)container.subviews.count);
    NSLog(@"[InstallationAssistant] Software selection view creation complete");
    
    return container;
}
@end

// Main application entry point
int main(int argc, const char * argv[]) {
    // Silence unused parameter warnings
    (void)argc;
    (void)argv;
    @autoreleasepool {
        [NSApplication sharedApplication];
        
        // Set up application delegate to ensure proper termination
        InstallationAppDelegate *appDelegate = [[InstallationAppDelegate alloc] init];
        [NSApp setDelegate:appDelegate];
        
        // Create menu bar
        NSMenu *mainMenu = [[NSMenu alloc] init];
        NSMenuItem *appMenuItem = [[NSMenuItem alloc] init];
        [mainMenu addItem:appMenuItem];
        [NSApp setMainMenu:mainMenu];
        
        NSMenu *appMenu = [[NSMenu alloc] init];
        NSMenuItem *quitMenuItem = [[NSMenuItem alloc] initWithTitle:@"Quit" action:@selector(terminate:) keyEquivalent:@"q"];
        [appMenu addItem:quitMenuItem];
        [appMenuItem setSubmenu:appMenu];
        
        // Show the assistant immediately
        [InstallationAssistant showInstallationAssistant];
        
        [NSApp run];
        
        [appDelegate release];
    }
    return 0;
}
