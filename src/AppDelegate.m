#import "AppDelegate.h"
#import "BootConfigController.h"

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSLog(@"Application did finish launching");
    
    // Create the menu system
    [self createMenu];
    
    // Force the application to become active immediately
    [[NSApplication sharedApplication] activateIgnoringOtherApps:YES];
    
    [self createMainWindow];
    
    // Ensure the application is active and window is visible
    NSLog(@"Activating application and bringing window to front");
    [mainWindow makeKeyAndOrderFront:nil];
    [mainWindow orderFrontRegardless];
    
    // Additional attempts to make window visible
    [mainWindow setLevel:NSNormalWindowLevel];
    [mainWindow makeMainWindow];
    [mainWindow display];
    
    // Force focus on the window
    [mainWindow becomeKeyWindow];
    [mainWindow becomeMainWindow];
    
    NSLog(@"Window should now be visible at frame: %@", NSStringFromRect([mainWindow frame]));
    NSLog(@"Window is visible: %@", [mainWindow isVisible] ? @"YES" : @"NO");
    NSLog(@"Window is key: %@", [mainWindow isKeyWindow] ? @"YES" : @"NO");
    NSLog(@"Window is main: %@", [mainWindow isMainWindow] ? @"YES" : @"NO");
    
    // Try bringing window to front after a brief delay
    [self performSelector:@selector(bringWindowToFront) withObject:nil afterDelay:0.1];
}

- (void)bringWindowToFront {
    NSLog(@"Bringing window to front (delayed)");
    [[NSApplication sharedApplication] activateIgnoringOtherApps:YES];
    [mainWindow makeKeyAndOrderFront:nil];
    [mainWindow orderFrontRegardless];
    
    NSLog(@"After delayed activation - Window is visible: %@", [mainWindow isVisible] ? @"YES" : @"NO");
    NSLog(@"After delayed activation - Window is key: %@", [mainWindow isKeyWindow] ? @"YES" : @"NO");
}

- (void)createMainWindow {
    NSLog(@"Creating main window");
    NSRect frame = NSMakeRect(100, 100, 800, 600);
    
    mainWindow = [[NSWindow alloc] 
        initWithContentRect:frame
        styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable)
        backing:NSBackingStoreBuffered
        defer:NO];
    
    NSLog(@"Window created with frame: %@", NSStringFromRect(frame));
    
    [mainWindow setTitle:@"boot environment Manager"];
    
    // Create and setup the boot environment controller
    NSLog(@"Creating boot environment controller");
    bootConfigController = [[BootConfigController alloc] init];
    NSView *contentView = [bootConfigController createMainView];
    [mainWindow setContentView:contentView];
    
    // Center the window and make it visible
    NSLog(@"Centering window and making it visible");
    [mainWindow center];
    [mainWindow makeKeyAndOrderFront:nil];
    
    NSLog(@"Window setup complete");
}

- (void)createMenu {
    NSLog(@"Creating application menu");
    
    // Create the main menu bar
    NSMenu *mainMenu = [[NSMenu alloc] init];
    
    // Create File menu
    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"Quit" 
                                                      action:@selector(quitApplication:) 
                                               keyEquivalent:@"q"];
    [quitItem setTarget:self];
    [fileMenu addItem:quitItem];
    
    NSMenuItem *fileMenuItem = [[NSMenuItem alloc] initWithTitle:@"File" action:nil keyEquivalent:@""];
    [fileMenuItem setSubmenu:fileMenu];
    [mainMenu addItem:fileMenuItem];
    
    // Create Help menu
    NSMenu *helpMenu = [[NSMenu alloc] initWithTitle:@"Help"];
    NSMenuItem *aboutItem = [[NSMenuItem alloc] initWithTitle:@"About FreeBSD boot environment Manager" 
                                                       action:@selector(showAbout:) 
                                                keyEquivalent:@""];
    [aboutItem setTarget:self];
    [helpMenu addItem:aboutItem];
    
    NSMenuItem *helpMenuItem = [[NSMenuItem alloc] initWithTitle:@"Help" action:nil keyEquivalent:@""];
    [helpMenuItem setSubmenu:helpMenu];
    [mainMenu addItem:helpMenuItem];
    
    // Set the main menu
    [[NSApplication sharedApplication] setMainMenu:mainMenu];
    
    NSLog(@"Menu created and set");
}

- (void)quitApplication:(id)sender {
    NSLog(@"Quit menu item selected");
    [[NSApplication sharedApplication] terminate:sender];
}

- (void)showAbout:(id)sender {
    NSLog(@"About menu item selected");
    
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:@"FreeBSD boot environment Manager"];
    [alert setInformativeText:@"A graphical interface for managing FreeBSD boot environments and configurations.\n\nVersion 1.0\n\nBuilt with GNUstep Objective-C framework for managing ZFS boot environments and loader configurations."];
    [alert addButtonWithTitle:@"OK"];
    [alert setAlertStyle:NSInformationalAlertStyle];
    
    [alert runModal];
    [alert release];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

@end
