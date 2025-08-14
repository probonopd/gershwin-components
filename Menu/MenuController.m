#import "MenuController.h"
#import "MenuBarView.h"
#import "AppMenuWidget.h"
#import "DBusMenuImporter.h"

@implementation MenuController

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
    NSLog(@"MenuController: Application did finish launching");
    
    // Initialize DBus menu importer first
    NSLog(@"MenuController: Creating DBusMenuImporter...");
    _dbusMenuImporter = [[DBusMenuImporter alloc] init];
    
    NSLog(@"MenuController: Attempting to connect to DBus...");
    if (![_dbusMenuImporter connectToDBus]) {
        NSLog(@"MenuController: Failed to connect to DBus - continuing anyway");
    } else {
        NSLog(@"MenuController: DBus menu importer initialized successfully");
        
        // Set up timer to process DBus messages
        [NSTimer scheduledTimerWithTimeInterval:0.1
                                        target:self
                                      selector:@selector(processDBusMessages:)
                                      userInfo:nil
                                       repeats:YES];
    }
    
    NSLog(@"MenuController: Setting up menu bar...");
    [self setupMenuBar];
    
    // Set up timer to monitor active window changes
    _updateTimer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                    target:self
                                                  selector:@selector(updateActiveWindow:)
                                                  userInfo:nil
                                                   repeats:YES];
    
    // Listen for window focus changes
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(windowDidBecomeKey:)
                                                 name:NSWindowDidBecomeKeyNotification
                                               object:nil];
    
    NSLog(@"MenuController: Application setup complete");
}

- (void)processDBusMessages:(NSTimer *)timer
{
    // Process incoming DBus messages
    if (_dbusMenuImporter && [[_dbusMenuImporter valueForKey:@"_dbusConnection"] isConnected]) {
        [[_dbusMenuImporter valueForKey:@"_dbusConnection"] processMessages];
    }
}

- (void)applicationWillTerminate:(NSNotification *)notification
{
    NSLog(@"MenuController: Application will terminate");
    
    [_updateTimer invalidate];
    [_updateTimer release];
    _updateTimer = nil;
    
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    
    [_dbusMenuImporter release];
    _dbusMenuImporter = nil;
}

- (void)setupMenuBar
{
    NSScreen *screen = [NSScreen mainScreen];
    NSRect screenRect = [screen frame];
    
    // Create menu bar window at top of screen
    NSRect menuRect = NSMakeRect(0, screenRect.size.height - 24, screenRect.size.width, 24);
    
    _menuWindow = [[NSWindow alloc] initWithContentRect:menuRect
                                              styleMask:NSBorderlessWindowMask
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    
    [_menuWindow setLevel:NSMainMenuWindowLevel + 1];
    [_menuWindow setOpaque:NO];
    [_menuWindow setHasShadow:NO];
    [_menuWindow setCanHide:NO];
    [_menuWindow setCollectionBehavior:NSWindowCollectionBehaviorCanJoinAllSpaces |
                                       NSWindowCollectionBehaviorStationary];
    
    // Create menu bar view
    _menuBarView = [[MenuBarView alloc] initWithFrame:NSMakeRect(0, 0, menuRect.size.width, 24)];
    [_menuWindow setContentView:_menuBarView];
    
    // Create app menu widget
    _appMenuWidget = [[AppMenuWidget alloc] initWithFrame:NSMakeRect(20, 0, 400, 24)];
    [_appMenuWidget setDbusMenuImporter:_dbusMenuImporter];
    [_menuBarView addSubview:_appMenuWidget];
    
    [_menuWindow makeKeyAndOrderFront:nil];
    
    NSLog(@"MenuController: Menu bar setup complete at %.0f,%.0f %.0fx%.0f", 
          menuRect.origin.x, menuRect.origin.y, menuRect.size.width, menuRect.size.height);
}

- (void)updateActiveWindow:(NSTimer *)timer
{
    // Get the currently active window and update app menu
    if (_appMenuWidget) {
        [_appMenuWidget updateForActiveWindow];
    }
}

- (void)windowDidBecomeKey:(NSNotification *)notification
{
    NSLog(@"MenuController: Window did become key: %@", [[notification object] title]);
    [self updateActiveWindow:nil];
}

- (void)dealloc
{
    [_menuWindow release];
    [_menuBarView release];
    [_appMenuWidget release];
    [_dbusMenuImporter release];
    [super dealloc];
}

@end
