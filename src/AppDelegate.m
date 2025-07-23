#import "AppDelegate.h"
#import "BootConfigController.h"

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSLog(@"Application did finish launching");
    
    // Force the application to become active immediately
    [[NSApplication sharedApplication] activateIgnoringOtherApps:YES];
    
    [self createMainWindow];
    
    // Create the menu system AFTER the controller is created
    [self createMenu];
    
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
    
    [mainWindow setTitle:@"Boot Environments"];
    
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
    
    // Create Application menu (first menu)
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"BootEnvironments"];
    NSMenuItem *aboutItem = [[NSMenuItem alloc] initWithTitle:@"About Boot Environments" 
                                                       action:@selector(showAbout:) 
                                                keyEquivalent:@""];
    [aboutItem setTarget:self];
    [appMenu addItem:aboutItem];
    
    [appMenu addItem:[NSMenuItem separatorItem]];
    
    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"Quit Boot Environments" 
                                                      action:@selector(quitApplication:) 
                                               keyEquivalent:@"q"];
    [quitItem setTarget:self];
    [appMenu addItem:quitItem];
    
    NSMenuItem *appMenuItem = [[NSMenuItem alloc] initWithTitle:@"BootEnvironments" action:nil keyEquivalent:@""];
    [appMenuItem setSubmenu:appMenu];
    [mainMenu addItem:appMenuItem];
    
    // Create Boot Environment menu
    NSMenu *bootMenu = [[NSMenu alloc] initWithTitle:@"Boot Environment"];
    
    NSMenuItem *createItem = [[NSMenuItem alloc] initWithTitle:@"Create Boot Environment..." 
                                                        action:@selector(createConfiguration:) 
                                                 keyEquivalent:@"n"];
    [createItem setTarget:bootConfigController];
    [bootMenu addItem:createItem];
    
    NSMenuItem *editItem = [[NSMenuItem alloc] initWithTitle:@"Edit Boot Environment..." 
                                                      action:@selector(editConfiguration:) 
                                               keyEquivalent:@"e"];
    [editItem setTarget:bootConfigController];
    [bootMenu addItem:editItem];
    
    [bootMenu addItem:[NSMenuItem separatorItem]];
    
    NSMenuItem *deleteItem = [[NSMenuItem alloc] initWithTitle:@"Delete Boot Environment" 
                                                        action:@selector(deleteConfiguration:) 
                                                 keyEquivalent:@"d"];
    [deleteItem setTarget:bootConfigController];
    [bootMenu addItem:deleteItem];
    
    [bootMenu addItem:[NSMenuItem separatorItem]];
    
    NSMenuItem *setActiveItem = [[NSMenuItem alloc] initWithTitle:@"Set Active Boot Environment" 
                                                           action:@selector(setActiveConfiguration:) 
                                                    keyEquivalent:@"a"];
    [setActiveItem setTarget:bootConfigController];
    [bootMenu addItem:setActiveItem];
    
    NSMenuItem *bootMenuItem = [[NSMenuItem alloc] initWithTitle:@"Boot Environment" action:nil keyEquivalent:@""];
    [bootMenuItem setSubmenu:bootMenu];
    [mainMenu addItem:bootMenuItem];
    
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
    [alert setMessageText:@"Boot Environments"];
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
