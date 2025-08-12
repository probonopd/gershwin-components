#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <GSAssistantFramework.h>
#import <GSAssistantUtilities.h>
#import "SystemSetupSteps.h"

@interface SystemSetupAppDelegate : NSObject <NSApplicationDelegate>
@end

@implementation SystemSetupAppDelegate
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    NSLog(@"SystemSetupAssistant: Last window closed, terminating application");
    return YES;
}
@end

@interface SystemSetupDelegate : NSObject <GSAssistantWindowDelegate>
@end

@implementation SystemSetupDelegate

- (void)assistantWindowWillFinish:(GSAssistantWindow *)window {
    NSLog(@"System setup assistant will finish");
}

- (void)assistantWindowDidFinish:(GSAssistantWindow *)window {
    NSLog(@"System setup assistant finished");
    [NSApp terminate:nil];
}

- (BOOL)assistantWindow:(GSAssistantWindow *)window shouldCancelWithConfirmation:(BOOL)showConfirmation {
    if (showConfirmation) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Cancel Setup?";
        alert.informativeText = @"Are you sure you want to cancel the setup? Any progress will be lost.";
        [alert addButtonWithTitle:NSLocalizedString(@"Cancel Setup", @"")];
        [alert addButtonWithTitle:NSLocalizedString(@"Continue Setup", @"")];
        alert.alertStyle = NSWarningAlertStyle;
        
        NSModalResponse response = [alert runModal];
        return response == NSAlertFirstButtonReturn;
    }
    return YES;
}

@end

@interface SystemSetupAssistant : NSObject
+ (void)showSetupAssistant;
@end

@implementation SystemSetupAssistant

+ (void)showSetupAssistant {
    NSLog(@"[SystemSetupAssistant] Starting showSetupAssistant");
    SystemSetupDelegate *delegate = [[SystemSetupDelegate alloc] init];
    NSLog(@"[SystemSetupAssistant] Created delegate: %@", delegate);
    
    // Build the assistant using the builder
    NSLog(@"[SystemSetupAssistant] Creating builder...");
    GSAssistantBuilder *builder = [GSAssistantBuilder builder];
    NSLog(@"[SystemSetupAssistant] Created builder: %@", builder);
    
    NSLog(@"[SystemSetupAssistant] Setting layout style to installer...");
    [builder withLayoutStyle:GSAssistantLayoutStyleInstaller];
    
    NSLog(@"[SystemSetupAssistant] Setting title...");
    [builder withTitle:NSLocalizedString(@"System Setup Assistant", @"")];
    
    NSLog(@"[SystemSetupAssistant] Setting icon...");
    [builder withIcon:[NSImage imageNamed:@"NSApplicationIcon"]];
    
    NSLog(@"[SystemSetupAssistant] Adding user info step...");
    SSUserInfoStep *userInfoStep = [[SSUserInfoStep alloc] init];
    [builder addStep:userInfoStep];
    [userInfoStep release];
    
    NSLog(@"[SystemSetupAssistant] Adding preferences step...");
    SSPreferencesStep *preferencesStep = [[SSPreferencesStep alloc] init];
    [builder addStep:preferencesStep];
    [preferencesStep release];
    
    NSLog(@"[SystemSetupAssistant] Adding progress step...");
    [builder addProgressStep:@"Applying Settings" 
           description:@"Please wait while we apply your settings..."];
    
    NSLog(@"[SystemSetupAssistant] Adding completion step...");
    [builder addCompletionWithMessage:@"Setup completed successfully! Your system is now ready to use." 
           success:YES];
    
    NSLog(@"[SystemSetupAssistant] Building assistant...");
    GSAssistantWindow *assistant = [builder build];
    NSLog(@"[SystemSetupAssistant] Built assistant: %@", assistant);
    
    NSLog(@"[SystemSetupAssistant] Setting delegate...");
    assistant.delegate = delegate;
    
    NSLog(@"[SystemSetupAssistant] Showing window...");
    [assistant showWindow:nil];
    NSLog(@"[SystemSetupAssistant] Making window key and front...");
    [assistant.window makeKeyAndOrderFront:nil];
    NSLog(@"[SystemSetupAssistant] Assistant window should now be visible");
}

@end

// Main application entry point
int main(int argc, const char * argv[]) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        
        // Set up application delegate to ensure proper termination
        SystemSetupAppDelegate *appDelegate = [[SystemSetupAppDelegate alloc] init];
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
        [SystemSetupAssistant showSetupAssistant];
        
        [NSApp run];
        
        [appDelegate release];
    }
    return 0;
}
