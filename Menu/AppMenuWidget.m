#import "AppMenuWidget.h"
#import "DBusMenuImporter.h"
#import "MenuUtils.h"
#import <X11/Xlib.h>
#import <X11/Xutil.h>
#import <X11/Xatom.h>

@implementation AppMenuWidget

@synthesize dbusMenuImporter = _dbusMenuImporter;

- (id)initWithFrame:(NSRect)frameRect
{
    self = [super initWithFrame:frameRect];
    if (self) {
        _menuButtons = [[NSMutableArray alloc] init];
        _currentApplicationName = nil;
        _currentWindowId = 0;
        _currentMenu = nil;
        
        NSLog(@"AppMenuWidget: Initialized with frame %.0f,%.0f %.0fx%.0f", 
              frameRect.origin.x, frameRect.origin.y, frameRect.size.width, frameRect.size.height);
    }
    return self;
}

- (void)updateForActiveWindow
{
    if (!_dbusMenuImporter) {
        return;
    }
    
    // Get the active window using X11
    Display *display = XOpenDisplay(NULL);
    if (!display) {
        NSLog(@"AppMenuWidget: Cannot open X11 display");
        return;
    }
    
    Window root = DefaultRootWindow(display);
    Window activeWindow = 0;
    Atom actualType;
    int actualFormat;
    unsigned long nitems, bytesAfter;
    unsigned char *prop = NULL;
    
    // Get _NET_ACTIVE_WINDOW property
    Atom activeWindowAtom = XInternAtom(display, "_NET_ACTIVE_WINDOW", False);
    if (XGetWindowProperty(display, root, activeWindowAtom,
                          0, 1, False, AnyPropertyType,
                          &actualType, &actualFormat, &nitems, &bytesAfter,
                          &prop) == Success && prop) {
        activeWindow = *(Window*)prop;
        XFree(prop);
    }
    
    XCloseDisplay(display);
    
    if (activeWindow != _currentWindowId) {
        NSLog(@"AppMenuWidget: Active window changed from %lu to %lu", _currentWindowId, activeWindow);
        _currentWindowId = activeWindow;
        [self displayMenuForWindow:activeWindow];
    }
}

- (void)clearMenu
{
    // Remove all existing menu buttons
    for (NSButton *button in _menuButtons) {
        [button removeFromSuperview];
    }
    [_menuButtons removeAllObjects];
    
    [_currentMenu release];
    _currentMenu = nil;
    
    [_currentApplicationName release];
    _currentApplicationName = nil;
    
    [self setNeedsDisplay:YES];
}

- (void)displayMenuForWindow:(unsigned long)windowId
{
    [self clearMenu];
    
    if (windowId == 0) {
        return;
    }
    
    // Get application name for this window
    NSString *appName = [MenuUtils getApplicationNameForWindow:windowId];
    if (appName && [appName length] > 0) {
        [_currentApplicationName release];
        _currentApplicationName = [appName retain];
        NSLog(@"AppMenuWidget: Window %lu belongs to application: %@", windowId, appName);
    }
    
    NSLog(@"AppMenuWidget: Displaying menu for window %lu", windowId);
    
    // Check if this window has a DBus menu registered
    if (![_dbusMenuImporter hasMenuForWindow:windowId]) {
        NSLog(@"DBusMenuImporter: No registered DBus menu for window %lu, checking for menus...", windowId);
        
        // For windows without registered menus, don't show any fallback menu
        // This prevents showing fake menus for applications like Chrome/VS Code
        // that don't export DBus menus
        NSLog(@"AppMenuWidget: No menu available for window %lu", windowId);
        return;
    }
    
    // Get the menu from DBus for registered windows
    NSMenu *menu = [_dbusMenuImporter getMenuForWindow:windowId];
    if (!menu) {
        NSLog(@"AppMenuWidget: Failed to get menu for window %lu", windowId);
        return;
    }
    
    _currentMenu = [menu retain];
    [self createMenuButtonsFromMenu:menu];
    
    NSLog(@"AppMenuWidget: Successfully loaded menu with %lu items", (unsigned long)[[menu itemArray] count]);
}

- (void)createMenuButtonsFromMenu:(NSMenu *)menu
{
    CGFloat xOffset = 0;
    NSArray *menuItems = [menu itemArray];
    
    for (NSMenuItem *menuItem in menuItems) {
        if ([menuItem isSeparatorItem]) {
            continue;
        }
        
        NSString *title = [menuItem title];
        if (!title || [title length] == 0) {
            continue;
        }
        
        NSButton *button = [self createMenuButtonWithTitle:title action:@selector(menuButtonClicked:)];
        [button setTag:[menuItems indexOfObject:menuItem]]; // Use tag instead of representedObject
        
        // Position the button
        NSSize buttonSize = [button frame].size;
        [button setFrame:NSMakeRect(xOffset, 2, buttonSize.width, 20)];
        [self addSubview:button];
        [_menuButtons addObject:button];
        
        xOffset += buttonSize.width + 4; // 4px spacing between buttons
        
        NSLog(@"AppMenuWidget: Added menu button '%@' at x=%.0f", title, xOffset - buttonSize.width - 4);
    }
    
    [self setNeedsDisplay:YES];
}

- (NSButton *)createMenuButtonWithTitle:(NSString *)title action:(SEL)action
{
    NSButton *button = [[NSButton alloc] init];
    [button setTitle:title];
    [button setButtonType:NSMomentaryPushInButton];
    [button setBezelStyle:NSTexturedRoundedBezelStyle];
    [button setBordered:NO];
    [button setTarget:self];
    [button setAction:action];
    
    // Configure appearance
    NSFont *font = [NSFont systemFontOfSize:13.0];
    [button setFont:font];
    
    // Calculate size based on title
    NSDictionary *attributes = [NSDictionary dictionaryWithObject:font forKey:NSFontAttributeName];
    NSSize titleSize = [title sizeWithAttributes:attributes];
    [button setFrame:NSMakeRect(0, 0, titleSize.width + 16, 20)]; // 16px padding
    
    return [button autorelease];
}

- (void)menuButtonClicked:(id)sender
{
    NSButton *button = (NSButton *)sender;
    NSInteger tag = [button tag];
    
    if (!_currentMenu || tag < 0 || tag >= (NSInteger)[[_currentMenu itemArray] count]) {
        NSLog(@"AppMenuWidget: Invalid menu item tag: %ld", (long)tag);
        return;
    }
    
    NSMenuItem *menuItem = [[_currentMenu itemArray] objectAtIndex:tag];
    
    NSLog(@"AppMenuWidget: Menu button clicked: '%@'", [menuItem title]);
    
    // If the menu item has a submenu, show it as a popup
    NSMenu *submenu = [menuItem submenu];
    if (submenu) {
        NSPoint buttonFrame = [button frame].origin;
        // Remove unused variable warning
        (void)buttonFrame;
        
        // Show the submenu as a popup
        [NSMenu popUpContextMenu:submenu 
                       withEvent:[NSApp currentEvent] 
                         forView:self];
    } else {
        // Execute the menu item action through DBus
        [_dbusMenuImporter activateMenuItem:menuItem forWindow:_currentWindowId];
    }
}

- (void)drawRect:(NSRect)dirtyRect
{
    // Draw application name if we have one
    if (_currentApplicationName && [_currentApplicationName length] > 0) {
        NSDictionary *attributes = [NSDictionary dictionaryWithObjectsAndKeys:
                                   [NSFont boldSystemFontOfSize:11.0], NSFontAttributeName,
                                   [NSColor colorWithCalibratedWhite:0.3 alpha:1.0], NSForegroundColorAttributeName,
                                   nil];
        
        NSSize textSize = [_currentApplicationName sizeWithAttributes:attributes];
        NSPoint textPoint = NSMakePoint(4, ([self bounds].size.height - textSize.height) / 2);
        
        [_currentApplicationName drawAtPoint:textPoint withAttributes:attributes];
    }
}

- (void)dealloc
{
    [_menuButtons release];
    [_currentApplicationName release];
    [_currentMenu release];
    [super dealloc];
}

@end
