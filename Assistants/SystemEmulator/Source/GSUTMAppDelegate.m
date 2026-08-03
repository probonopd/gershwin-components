#import "GSUTMAppDelegate.h"
#import "GSUTMMainWindowController.h"
#import "GSUTMAssistant.h"

@implementation GSUTMAppDelegate

@synthesize pendingOpenPath = _pendingOpenPath;

- (void)setupMainMenu
{
    _mainMenu = [[NSMenu alloc] init];
    NSMenuItem *item;
    NSMenu *submenu;

    /* ==== SystemEmulator ==== */
    item = [[NSMenuItem alloc] initWithTitle:@"SystemEmulator" action:NULL keyEquivalent:@""];
    submenu = [[NSMenu alloc] initWithTitle:@"SystemEmulator"];
    [item setSubmenu:submenu];
    [_mainMenu addItem:item];

    item = [[NSMenuItem alloc] initWithTitle:@"About SystemEmulator" action:@selector(showAboutPanel:) keyEquivalent:@""];
    [item setTarget:self]; [submenu addItem:item];

    /* ==== File ==== */
    item = [[NSMenuItem alloc] initWithTitle:@"File" action:NULL keyEquivalent:@""];
    submenu = [[NSMenu alloc] initWithTitle:@"File"];
    [item setSubmenu:submenu];
    [_mainMenu addItem:item];

    item = [[NSMenuItem alloc] initWithTitle:@"New" action:@selector(newVM:) keyEquivalent:@"n"];
    [item setTarget:self]; [submenu addItem:item];
    item = [[NSMenuItem alloc] initWithTitle:@"Open..." action:@selector(openVM:) keyEquivalent:@"o"];
    [item setTarget:self]; [submenu addItem:item];
    item = [[NSMenuItem alloc] initWithTitle:@"Save" action:@selector(saveVM:) keyEquivalent:@"s"];
    [item setTarget:self]; [submenu addItem:item];
    [submenu addItem:[NSMenuItem separatorItem]];
    item = [[NSMenuItem alloc] initWithTitle:@"Close" action:@selector(performClose:) keyEquivalent:@"w"];
    [submenu addItem:item];
    [submenu addItem:[NSMenuItem separatorItem]];
    item = [[NSMenuItem alloc] initWithTitle:@"Quit" action:@selector(quitApp:) keyEquivalent:@"q"];
    [item setTarget:self]; [submenu addItem:item];

    /* ==== Edit ==== */
    item = [[NSMenuItem alloc] initWithTitle:@"Edit" action:NULL keyEquivalent:@""];
    submenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    [item setSubmenu:submenu];
    [_mainMenu addItem:item];

    item = [[NSMenuItem alloc] initWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"]; [submenu addItem:item];
    item = [[NSMenuItem alloc] initWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"]; [submenu addItem:item];
    item = [[NSMenuItem alloc] initWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"]; [submenu addItem:item];
    item = [[NSMenuItem alloc] initWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"]; [submenu addItem:item];

    /* ==== VM ==== */
    item = [[NSMenuItem alloc] initWithTitle:@"VM" action:NULL keyEquivalent:@""];
    submenu = [[NSMenu alloc] initWithTitle:@"VM"];
    [item setSubmenu:submenu];
    [_mainMenu addItem:item];

    item = [[NSMenuItem alloc] initWithTitle:@"Start" action:@selector(startVM:) keyEquivalent:@""];
    [item setTarget:self]; [submenu addItem:item];
    item = [[NSMenuItem alloc] initWithTitle:@"Stop" action:@selector(stopVM:) keyEquivalent:@""];
    [item setTarget:self]; [submenu addItem:item];
    [submenu addItem:[NSMenuItem separatorItem]];
    item = [[NSMenuItem alloc] initWithTitle:@"Console" action:@selector(openConsole:) keyEquivalent:@""];
    [item setTarget:self]; [submenu addItem:item];

    /* ==== Window ==== */
    item = [[NSMenuItem alloc] initWithTitle:@"Window" action:NULL keyEquivalent:@""];
    submenu = [[NSMenu alloc] initWithTitle:@"Window"];
    [item setSubmenu:submenu];
    [_mainMenu addItem:item];

    item = [[NSMenuItem alloc] initWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"]; [submenu addItem:item];
    item = [[NSMenuItem alloc] initWithTitle:@"Zoom" action:@selector(performZoom:) keyEquivalent:@""]; [submenu addItem:item];

    [NSApp setMainMenu:_mainMenu];
    [_mainMenu performSelector:@selector(menuChanged)];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"NSMacintoshMenuDidChangeNotification" object:_mainMenu];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
    NSLog(@"APP: didFinishLaunching");
    [self setupMainMenu];
    _mainController = [[GSUTMMainWindowController alloc] init];
    [_mainController showWindow:nil];

    /* Handle path passed via CLI (from application:openFile:) */
    if (_pendingOpenPath) {
        NSURL *url = [NSURL fileURLWithPath:_pendingOpenPath];
        if ([[NSFileManager defaultManager] fileExistsAtPath:[url path]]) {
            [_mainController loadConfigFromURL:url];
            [_mainController startVM];
        }
        [_pendingOpenPath release];
        _pendingOpenPath = nil;
    }
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender
{
    return NO;
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender
{
    return NSTerminateCancel;
}

- (IBAction)quitApp:(id)sender
{
    [_mainController cleanupVM];
    exit(0);
}

- (BOOL)application:(NSApplication *)app openFile:(NSString *)filename
{
    [_pendingOpenPath release];
    _pendingOpenPath = [filename retain];
    return YES;
}

- (void)applicationWillTerminate:(NSNotification *)notification
{
    [_mainController cleanupVM];
}

- (IBAction)showAboutPanel:(id)sender
{
    [NSApp orderFrontStandardAboutPanel:sender];
}

- (IBAction)newVM:(id)sender
{
    _assistant = [[GSUTMAssistant alloc] initWithOwner:_mainController];
    [_assistant runNewVMAssistant];
}

- (IBAction)openVM:(id)sender
{
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    [panel setTitle:@"Open UTM Bundle or config.plist"];
    [panel setAllowsMultipleSelection:NO];
    [panel setCanChooseDirectories:YES];
    [panel setCanChooseFiles:YES];
    if ([panel runModal] == NSOKButton) {
        [_mainController loadConfigFromURL:[panel URL]];
    }
}

- (IBAction)saveVM:(id)sender
{
    [_mainController saveConfig];
}

- (IBAction)startVM:(id)sender
{
    [_mainController startVM];
}

- (IBAction)stopVM:(id)sender
{
    [_mainController stopVM];
}

- (IBAction)openConsole:(id)sender
{
    [_mainController openConsole:sender];
}

@end
