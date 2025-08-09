#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <GSAssistantFramework.h>
#import <GSAssistantUtilities.h>
#import "NetworkSetupSteps.h"

@interface NetworkSetupDelegate : NSObject <GSAssistantWindowDelegate>
@end

@implementation NetworkSetupDelegate

- (void)assistantWindowWillFinish:(GSAssistantWindow *)window {
    NSLog(@"Network setup assistant will finish");
}

- (void)assistantWindowDidFinish:(GSAssistantWindow *)window {
    NSLog(@"Network setup assistant finished");
    [NSApp terminate:nil];
}

- (BOOL)assistantWindow:(GSAssistantWindow *)window shouldCancelWithConfirmation:(BOOL)showConfirmation {
    if (showConfirmation) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Cancel Network Setup?";
        alert.informativeText = @"Are you sure you want to cancel the network setup?";
        [alert addButtonWithTitle:@"Cancel Setup"];
        [alert addButtonWithTitle:@"Continue Setup"];
        alert.alertStyle = NSWarningAlertStyle;
        
        NSModalResponse response = [alert runModal];
        return response == NSAlertFirstButtonReturn;
    }
    return YES;
}

@end

@interface NetworkSetupAssistant : NSObject
+ (void)showNetworkAssistant;
@end

@implementation NetworkSetupAssistant

+ (void)showNetworkAssistant {
    NSLog(@"[NetworkSetupAssistant] Starting showNetworkAssistant");
    NetworkSetupDelegate *delegate = [[NetworkSetupDelegate alloc] init];
    NSLog(@"[NetworkSetupAssistant] Created delegate: %@", delegate);
    
    // Create network configuration form
    NSLog(@"[NetworkSetupAssistant] Creating network config view...");
    NSView *networkConfigView = [self createNetworkConfigView];
    NSLog(@"[NetworkSetupAssistant] Created network config view: %@ with frame: %@", networkConfigView, NSStringFromRect(networkConfigView.frame));
    
    // Create authentication form
    NSLog(@"[NetworkSetupAssistant] Creating auth config view...");
    NSView *authConfigView = [self createAuthConfigView];
    NSLog(@"[NetworkSetupAssistant] Created auth config view: %@ with frame: %@", authConfigView, NSStringFromRect(authConfigView.frame));
    
    // Build the assistant using the builder
    NSLog(@"[NetworkSetupAssistant] Creating builder...");
    GSAssistantBuilder *builder = [GSAssistantBuilder builder];
    NSLog(@"[NetworkSetupAssistant] Created builder: %@", builder);
    
    NSLog(@"[NetworkSetupAssistant] Setting layout style to installer...");
    [builder withLayoutStyle:GSAssistantLayoutStyleInstaller];
    
    NSLog(@"[NetworkSetupAssistant] Setting title...");
    [builder withTitle:@"Network Setup Assistant"];
    
    NSLog(@"[NetworkSetupAssistant] Setting icon...");
    [builder withIcon:[NSImage imageNamed:@"NSApplicationIcon"]];
    
    NSLog(@"[NetworkSetupAssistant] Adding introduction...");
    [builder addIntroductionWithMessage:@"Welcome to the Network Setup Assistant! This tool will help you configure your network settings."
           features:@[@"Configure network interfaces",
                     @"Set up authentication credentials", 
                     @"Test connectivity"]];
    
    NSLog(@"[NetworkSetupAssistant] Adding network config step...");
    NSNetworkConfigStep *networkConfigStep = [[NSNetworkConfigStep alloc] init];
    [builder addStep:networkConfigStep];
    [networkConfigStep release];
    
    NSLog(@"[NetworkSetupAssistant] Adding auth config step...");
    NSAuthConfigStep *authConfigStep = [[NSAuthConfigStep alloc] init];
    [builder addStep:authConfigStep];
    [authConfigStep release];
    
    NSLog(@"[NetworkSetupAssistant] Adding progress step...");
    [builder addProgressStep:@"Applying Network Settings" 
           description:@"Configuring network interfaces..."];
    
    NSLog(@"[NetworkSetupAssistant] Adding completion step...");
    [builder addCompletionWithMessage:@"Network setup completed successfully! Your network is now configured." 
           success:YES];
    
    NSLog(@"[NetworkSetupAssistant] Building assistant...");
    GSAssistantWindow *assistant = [builder build];
    NSLog(@"[NetworkSetupAssistant] Built assistant: %@", assistant);
    
    NSLog(@"[NetworkSetupAssistant] Setting delegate...");
    assistant.delegate = delegate;
    
    NSLog(@"[NetworkSetupAssistant] Showing window...");
    [assistant showWindow:nil];
    NSLog(@"[NetworkSetupAssistant] Making window key and front...");
    [assistant.window makeKeyAndOrderFront:nil];
    NSLog(@"[NetworkSetupAssistant] Assistant window should now be visible");
}

+ (NSView *)createNetworkConfigView {
    NSLog(@"[NetworkSetupAssistant] Creating network config view container...");
    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300)];
    NSLog(@"[NetworkSetupAssistant] Container created with frame: %@", NSStringFromRect(container.frame));
    
    // Interface selection
    NSLog(@"[NetworkSetupAssistant] Creating interface label...");
    NSTextField *interfaceLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 260, 100, 20)];
    interfaceLabel.editable = NO;
    interfaceLabel.selectable = NO;
    interfaceLabel.bordered = NO;
    interfaceLabel.bezeled = NO;
    interfaceLabel.drawsBackground = NO;
    interfaceLabel.backgroundColor = [NSColor clearColor];
    interfaceLabel.stringValue = @"Interface:";
    NSLog(@"[NetworkSetupAssistant] Interface label created: %@", interfaceLabel);
    
    NSLog(@"[NetworkSetupAssistant] Creating interface popup...");
    NSPopUpButton *interfacePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(130, 258, 200, 24)];
    [interfacePopup addItemWithTitle:@"Ethernet (eth0)"];
    [interfacePopup addItemWithTitle:@"Wi-Fi (wlan0)"];
    [interfacePopup addItemWithTitle:@"Loopback (lo)"];
    NSLog(@"[NetworkSetupAssistant] Interface popup created: %@", interfacePopup);
    
    // IP configuration
    NSLog(@"[NetworkSetupAssistant] Creating IP config label...");
    NSTextField *ipLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 220, 100, 20)];
    ipLabel.editable = NO;
    ipLabel.selectable = NO;
    ipLabel.bordered = NO;
    ipLabel.bezeled = NO;
    ipLabel.drawsBackground = NO;
    ipLabel.backgroundColor = [NSColor clearColor];
    ipLabel.stringValue = @"IP Address:";
    NSLog(@"[NetworkSetupAssistant] IP label created: %@", ipLabel);
    
    NSLog(@"[NetworkSetupAssistant] Creating IP field...");
    NSTextField *ipField = [[NSTextField alloc] initWithFrame:NSMakeRect(130, 220, 200, 22)];
    ipField.placeholderString = @"192.168.1.100";
    NSLog(@"[NetworkSetupAssistant] IP field created: %@", ipField);
    
    // Add all subviews
    NSLog(@"[NetworkSetupAssistant] Adding subviews to container...");
    [container addSubview:interfaceLabel];
    NSLog(@"[NetworkSetupAssistant] Added interface label");
    [container addSubview:interfacePopup];
    NSLog(@"[NetworkSetupAssistant] Added interface popup");
    [container addSubview:ipLabel];
    NSLog(@"[NetworkSetupAssistant] Added IP label");
    [container addSubview:ipField];
    NSLog(@"[NetworkSetupAssistant] Added IP field");
    
    NSLog(@"[NetworkSetupAssistant] Container now has %lu subviews", (unsigned long)container.subviews.count);
    NSLog(@"[NetworkSetupAssistant] Network config view creation complete");
    
    return container;
}

+ (NSView *)createWiFiSelectionView {
    NSView *container = [[NSView alloc] init];
    
    // WiFi network selection
    NSTextField *networkLabel = [GSAssistantUIHelper createTitleLabelWithText:@"Available Networks:"];
    NSPopUpButton *networkPopup = [GSAssistantUIHelper createPopUpButtonWithItems:@[
        @"Home-WiFi", @"Office-Guest", @"CoffeeShop-Free", @"MyNetwork-5G", @"Other..."
    ]];
    
    // WiFi password
    NSTextField *passwordLabel = [GSAssistantUIHelper createTitleLabelWithText:@"Password:"];
    NSSecureTextField *passwordField = [GSAssistantUIHelper createSecureFieldWithPlaceholder:@"Network password"];
    
    // Security type
    NSTextField *securityLabel = [GSAssistantUIHelper createTitleLabelWithText:@"Security:"];
    NSPopUpButton *securityPopup = [GSAssistantUIHelper createPopUpButtonWithItems:@[
        @"WPA2/WPA3 Personal", @"WPA Personal", @"WEP", @"None (Open)"
    ]];
    
    // Advanced options
    NSButton *advancedCheck = [GSAssistantUIHelper createCheckboxWithTitle:@"Show advanced options"];
    NSButton *rememberCheck = [GSAssistantUIHelper createCheckboxWithTitle:@"Remember this network"];
    [rememberCheck setState:NSOnState];
    
    // Create layout
    NSArray *views = @[networkLabel, networkPopup, passwordLabel, passwordField, 
                      securityLabel, securityPopup, advancedCheck, rememberCheck];
    NSView *stackView = [GSAssistantUIHelper createVerticalStackViewWithViews:views spacing:8.0];
    
    [container addSubview:stackView];
    [GSAssistantUIHelper addStandardConstraintsToView:stackView inContainer:container];
    
    return container;
}

+ (NSView *)createAuthConfigView {
    NSLog(@"[NetworkSetupAssistant] Creating auth config view container...");
    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300)];
    NSLog(@"[NetworkSetupAssistant] Container created with frame: %@", NSStringFromRect(container.frame));
    
    // Username field
    NSLog(@"[NetworkSetupAssistant] Creating username label...");
    NSTextField *usernameLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 260, 100, 20)];
    usernameLabel.editable = NO;
    usernameLabel.selectable = NO;
    usernameLabel.bordered = NO;
    usernameLabel.bezeled = NO;
    usernameLabel.drawsBackground = NO;
    usernameLabel.backgroundColor = [NSColor clearColor];
    usernameLabel.stringValue = @"Username:";
    NSLog(@"[NetworkSetupAssistant] Username label created: %@", usernameLabel);
    
    NSLog(@"[NetworkSetupAssistant] Creating username field...");
    NSTextField *usernameField = [[NSTextField alloc] initWithFrame:NSMakeRect(130, 260, 200, 22)];
    usernameField.placeholderString = @"Enter network username";
    NSLog(@"[NetworkSetupAssistant] Username field created: %@", usernameField);
    
    // Password field
    NSLog(@"[NetworkSetupAssistant] Creating password label...");
    NSTextField *passwordLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 220, 100, 20)];
    passwordLabel.editable = NO;
    passwordLabel.selectable = NO;
    passwordLabel.bordered = NO;
    passwordLabel.bezeled = NO;
    passwordLabel.drawsBackground = NO;
    passwordLabel.backgroundColor = [NSColor clearColor];
    passwordLabel.stringValue = @"Password:";
    NSLog(@"[NetworkSetupAssistant] Password label created: %@", passwordLabel);
    
    NSLog(@"[NetworkSetupAssistant] Creating password field...");
    NSSecureTextField *passwordField = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(130, 220, 200, 22)];
    passwordField.placeholderString = @"Enter network password";
    NSLog(@"[NetworkSetupAssistant] Password field created: %@", passwordField);
    
    // Add all subviews
    NSLog(@"[NetworkSetupAssistant] Adding subviews to container...");
    [container addSubview:usernameLabel];
    NSLog(@"[NetworkSetupAssistant] Added username label");
    [container addSubview:usernameField];
    NSLog(@"[NetworkSetupAssistant] Added username field");
    [container addSubview:passwordLabel];
    NSLog(@"[NetworkSetupAssistant] Added password label");
    [container addSubview:passwordField];
    NSLog(@"[NetworkSetupAssistant] Added password field");
    
    NSLog(@"[NetworkSetupAssistant] Container now has %lu subviews", (unsigned long)container.subviews.count);
    NSLog(@"[NetworkSetupAssistant] Auth config view creation complete");
    
    return container;
}
@end

// Main application entry point
int main(int argc, const char * argv[]) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        
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
        [NetworkSetupAssistant showNetworkAssistant];
        
        [NSApp run];
    }
    return 0;
}
