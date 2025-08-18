#import "AppMenuWidget.h"
#import "MenuProtocolManager.h"
#import "MenuUtils.h"
#import <X11/Xlib.h>
#import <X11/Xutil.h>
#import <X11/Xatom.h>

@implementation AppMenuWidget

@synthesize protocolManager = _protocolManager;

- (id)initWithFrame:(NSRect)frameRect
{
    self = [super initWithFrame:frameRect];
    if (self) {
        _menuView = nil;
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
    
    if (!_protocolManager) {
        NSLog(@"AppMenuWidget: No protocol manager available");
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
    // Remove the current menu view if it exists
    if (_menuView) {
        [_menuView removeFromSuperview];
        [_menuView release];
        _menuView = nil;
    }
    
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
    if (![_protocolManager hasMenuForWindow:windowId]) {
        NSLog(@"AppMenuWidget: No registered menu for window %lu, triggering immediate scan", windowId);
        
        // Trigger immediate scan for new menu services
        [_protocolManager scanForExistingMenuServices];
        
        // Check again after immediate scan
        if (![_protocolManager hasMenuForWindow:windowId]) {
            NSLog(@"AppMenuWidget: Still no registered menu for window %lu after immediate scan", windowId);
            return;
        }
    }
    
    NSLog(@"AppMenuWidget: ===== LOADING MENU FROM PROTOCOL MANAGER =====");
    NSLog(@"AppMenuWidget: This is where AboutToShow events should be triggered for submenus");
    
    // Get the menu from protocol manager for registered windows
    NSMenu *menu = [_protocolManager getMenuForWindow:windowId];
    if (!menu) {
        NSLog(@"AppMenuWidget: Failed to get menu for window %lu", windowId);
        return;
    }
    
    // Debug: Log menu details for placeholder detection
    NSLog(@"AppMenuWidget: Menu has %lu items", (unsigned long)[[menu itemArray] count]);
    if ([[menu itemArray] count] > 0) {
        NSMenuItem *firstItem = [[menu itemArray] objectAtIndex:0];
        NSLog(@"AppMenuWidget: First menu item: '%@' (enabled: %@)", [firstItem title], [firstItem isEnabled] ? @"YES" : @"NO");
    }
    
    BOOL isPlaceholder = [self isPlaceholderMenu:menu];
    NSLog(@"AppMenuWidget: isPlaceholderMenu: %@", isPlaceholder ? @"YES" : @"NO");
    
    // If this is a placeholder menu, replace it with a functional File menu
    if (isPlaceholder) {
        NSLog(@"AppMenuWidget: Replacing placeholder menu with File menu containing Close for window %lu", windowId);
        menu = [self createFileMenuWithClose:windowId];
    }
    
    _currentMenu = [menu retain];
    
    NSLog(@"AppMenuWidget: ===== MENU LOADED, SETTING UP VIEW =====");
    NSLog(@"AppMenuWidget: Menu has %lu top-level items", (unsigned long)[[menu itemArray] count]);
    
    // Log each top-level menu item and whether it has submenus
    NSArray *items = [menu itemArray];
    for (NSUInteger i = 0; i < [items count]; i++) {
        NSMenuItem *item = [items objectAtIndex:i];
        NSLog(@"AppMenuWidget: Top-level item %lu: '%@' (has submenu: %@, submenu items: %lu)", 
              i, [item title], [item hasSubmenu] ? @"YES" : @"NO",
              [item hasSubmenu] ? (unsigned long)[[[item submenu] itemArray] count] : 0);
    }
    
    [self setupMenuViewWithMenu:menu];
    
    NSLog(@"AppMenuWidget: Successfully loaded menu with %lu items", (unsigned long)[[menu itemArray] count]);
}

- (void)setupMenuViewWithMenu:(NSMenu *)menu
{
    NSLog(@"AppMenuWidget: Setting up menu view with menu: %@", [menu title]);
    
    // Create a new horizontal menu view that fits within our widget frame
    NSRect menuViewFrame = NSMakeRect(0, 0, [self bounds].size.width, [self bounds].size.height);
    _menuView = [[NSMenuView alloc] initWithFrame:menuViewFrame];
    
    // Configure the menu view for horizontal display (like a menu bar)
    [_menuView setHorizontal:YES];
    [_menuView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    
    // Set the menu for the menu view
    [_menuView setMenu:menu];
    
    // Set ourselves as the delegate of the main menu to catch AboutToShow events
    [menu setDelegate:self];
    NSLog(@"AppMenuWidget: Set AppMenuWidget as delegate for main menu: %@", [menu title]);
    
    // Add comprehensive logging to each menu item
    NSArray *items = [menu itemArray];
    for (NSUInteger i = 0; i < [items count]; i++) {
        NSMenuItem *item = [items objectAtIndex:i];
        NSLog(@"AppMenuWidget: Setting up item %lu: '%@' (submenu: %@)", 
              i, [item title], [item hasSubmenu] ? @"YES" : @"NO");
        
        // Set target and action for logging purposes
        if (![item hasSubmenu]) {
            [item setTarget:self];
            [item setAction:@selector(menuItemClicked:)];
            NSLog(@"AppMenuWidget: Set click action for non-submenu item: '%@'", [item title]);
        }
    }
    
    // Add the menu view to our widget
    [self addSubview:_menuView];
    
    [self setNeedsDisplay:YES];
    
    NSLog(@"AppMenuWidget: Menu view setup complete with %lu menu items", 
          (unsigned long)[[menu itemArray] count]);
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

- (void)checkAndDisplayMenuForNewlyRegisteredWindow:(unsigned long)windowId
{
    // Get the currently active window using X11
    Display *display = XOpenDisplay(NULL);
    if (!display) {
        NSLog(@"AppMenuWidget: Cannot open X11 display for checking active window");
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
    
    // If the newly registered window is the currently active window, display its menu immediately
    if (activeWindow == windowId) {
        NSLog(@"AppMenuWidget: Newly registered window %lu is currently active, displaying menu immediately", windowId);
        _currentWindowId = activeWindow;
        [self displayMenuForWindow:activeWindow];
    } else {
        NSLog(@"AppMenuWidget: Newly registered window %lu is not currently active (active: %lu)", windowId, activeWindow);
    }
}

// Debug method implementation

// MARK: - NSMenuDelegate Methods for Main Menu

- (void)menuWillOpen:(NSMenu *)menu
{
    NSLog(@"AppMenuWidget: ===== MAIN MENU WILL OPEN =====");
    NSLog(@"AppMenuWidget: menuWillOpen called for main menu: '%@'", [menu title] ?: @"(no title)");
    NSLog(@"AppMenuWidget: Main menu object: %@", menu);
    NSLog(@"AppMenuWidget: Main menu has %lu items", (unsigned long)[[menu itemArray] count]);
    NSLog(@"AppMenuWidget: Current window ID: %lu", _currentWindowId);
    NSLog(@"AppMenuWidget: Current application: %@", _currentApplicationName ?: @"(none)");
    NSLog(@"AppMenuWidget: ===== MAIN MENU WILL OPEN COMPLETE =====");
}

- (void)menuDidClose:(NSMenu *)menu
{
    NSLog(@"AppMenuWidget: Main menu did close: '%@'", [menu title] ?: @"(no title)");
}

- (void)menu:(NSMenu *)menu willHighlightItem:(NSMenuItem *)item
{
    if (item) {
        NSLog(@"AppMenuWidget: ===== MAIN MENU ITEM HIGHLIGHT =====");
        NSLog(@"AppMenuWidget: Main menu will highlight item: '%@' (has submenu: %@)", 
              [item title], [item hasSubmenu] ? @"YES" : @"NO");
        
        if ([item hasSubmenu]) {
            NSMenu *submenu = [item submenu];
            id<NSMenuDelegate> submenuDelegate = [submenu delegate];
            NSLog(@"AppMenuWidget: Item has submenu with %lu items", 
                  (unsigned long)[[submenu itemArray] count]);
            NSLog(@"AppMenuWidget: Submenu delegate: %@ (%@)", 
                  submenuDelegate, submenuDelegate ? NSStringFromClass([submenuDelegate class]) : @"nil");
            NSLog(@"AppMenuWidget: THIS IS WHERE ABOUTTOSHOW SHOULD BE TRIGGERED!");
            NSLog(@"AppMenuWidget: If you don't see AboutToShow logging after this, the delegate isn't working");
        }
        NSLog(@"AppMenuWidget: ===== END MAIN MENU ITEM HIGHLIGHT =====");
    } else {
        NSLog(@"AppMenuWidget: Main menu will unhighlight current item");
    }
}

- (BOOL)menu:(NSMenu *)menu updateItem:(NSMenuItem *)item atIndex:(NSInteger)index shouldCancel:(BOOL)shouldCancel
{
    NSLog(@"AppMenuWidget: Main menu update item at index %ld: '%@' (shouldCancel: %@)", 
          (long)index, [item title], shouldCancel ? @"YES" : @"NO");
    return YES; // Allow the update
}

- (NSInteger)numberOfItemsInMenu:(NSMenu *)menu
{
    NSInteger count = [[menu itemArray] count];
    NSLog(@"AppMenuWidget: Main menu numberOfItemsInMenu called, returning: %ld", (long)count);
    return count;
}

- (NSRect)confinementRectForMenu:(NSMenu *)menu onScreen:(NSScreen *)screen
{
    // Return the full screen bounds - no confinement
    NSRect screenFrame = [screen frame];
    NSLog(@"AppMenuWidget: confinementRectForMenu called, returning full screen bounds");
    return screenFrame;
}

// MARK: - Mouse Event Tracking

- (void)mouseEntered:(NSEvent *)theEvent
{
    NSLog(@"AppMenuWidget: ===== MOUSE ENTERED MENU AREA =====");
    NSLog(@"AppMenuWidget: Mouse entered at location: %@", NSStringFromPoint([theEvent locationInWindow]));
    [super mouseEntered:theEvent];
}

- (void)mouseExited:(NSEvent *)theEvent
{
    NSLog(@"AppMenuWidget: ===== MOUSE EXITED MENU AREA =====");
    NSLog(@"AppMenuWidget: Mouse exited at location: %@", NSStringFromPoint([theEvent locationInWindow]));
    [super mouseExited:theEvent];
}

- (void)mouseMoved:(NSEvent *)theEvent
{
    NSPoint location = [theEvent locationInWindow];
    NSPoint localPoint = [self convertPoint:location fromView:nil];
    NSLog(@"AppMenuWidget: Mouse moved to: %@ (local: %@)", NSStringFromPoint(location), NSStringFromPoint(localPoint));
    
    // Check if we're over a specific menu item
    if (_menuView) {
        NSPoint menuViewPoint = [_menuView convertPoint:location fromView:nil];
        NSLog(@"AppMenuWidget: Menu view point: %@", NSStringFromPoint(menuViewPoint));
        
        // Try to determine which menu item we're over
        if ([_menuView respondsToSelector:@selector(itemAtPoint:)]) {
            NSMenuItem *item = [(id)_menuView performSelector:@selector(itemAtPoint:) withObject:[NSValue valueWithPoint:menuViewPoint]];
            if (item) {
                NSLog(@"AppMenuWidget: Mouse over menu item: '%@'", [item title]);
            }
        }
    }
    
    [super mouseMoved:theEvent];
}

- (void)mouseDown:(NSEvent *)theEvent
{
    NSLog(@"AppMenuWidget: ===== MOUSE DOWN IN MENU =====");
    NSPoint location = [theEvent locationInWindow];
    NSPoint localPoint = [self convertPoint:location fromView:nil];
    NSLog(@"AppMenuWidget: Mouse down at: %@ (local: %@)", NSStringFromPoint(location), NSStringFromPoint(localPoint));
    
    if (_menuView) {
        NSPoint menuViewPoint = [_menuView convertPoint:location fromView:nil];
        NSLog(@"AppMenuWidget: Menu view click point: %@", NSStringFromPoint(menuViewPoint));
        
        // Check if we clicked on a menu item
        NSArray *items = [_currentMenu itemArray];
        for (NSUInteger i = 0; i < [items count]; i++) {
            NSMenuItem *item = [items objectAtIndex:i];
            // Try to get the menu item's frame (this is a bit of a hack)
            NSRect itemFrame = NSMakeRect(i * 80, 0, 80, [self bounds].size.height); // Approximate
            if (NSPointInRect(localPoint, itemFrame)) {
                NSLog(@"AppMenuWidget: Clicked on menu item %lu: '%@'", i, [item title]);
                
                if ([item hasSubmenu]) {
                    NSLog(@"AppMenuWidget: Item has submenu - this should trigger AboutToShow!");
                    NSMenu *submenu = [item submenu];
                    id<NSMenuDelegate> delegate = [submenu delegate];
                    NSLog(@"AppMenuWidget: Submenu delegate: %@", delegate);
                    
                    // Manually trigger menuWillOpen to test AboutToShow
                    if (delegate && [delegate respondsToSelector:@selector(menuWillOpen:)]) {
                        NSLog(@"AppMenuWidget: MANUALLY TRIGGERING menuWillOpen for testing...");
                        [delegate menuWillOpen:submenu];
                    }
                }
                break;
            }
        }
        
        // Let the menu view handle the click
        [_menuView mouseDown:theEvent];
        NSLog(@"AppMenuWidget: Forwarded mouse down to menu view");
    }
    
    [super mouseDown:theEvent];
}

- (void)mouseUp:(NSEvent *)theEvent
{
    NSLog(@"AppMenuWidget: ===== MOUSE UP IN MENU =====");
    NSLog(@"AppMenuWidget: Mouse up at: %@", NSStringFromPoint([theEvent locationInWindow]));
    
    if (_menuView) {
        [_menuView mouseUp:theEvent];
        NSLog(@"AppMenuWidget: Forwarded mouse up to menu view");
    }
    
}

// MARK: - Debug Methods

- (void)menuItemClicked:(NSMenuItem *)sender
{
    NSLog(@"AppMenuWidget: ===== MENU ITEM CLICKED =====");
    NSLog(@"AppMenuWidget: Clicked menu item: '%@'", [sender title]);
    NSLog(@"AppMenuWidget: Item tag: %ld", (long)[sender tag]);
    NSLog(@"AppMenuWidget: Item has submenu: %@", [sender hasSubmenu] ? @"YES" : @"NO");
    NSLog(@"AppMenuWidget: ===== END MENU ITEM CLICKED =====");
    
    // Forward to the original action if it exists
    if ([sender respondsToSelector:@selector(representedObject)] && [sender representedObject]) {
        id originalTarget = [sender representedObject];
        if ([originalTarget respondsToSelector:@selector(performSelector:withObject:)]) {
            NSLog(@"AppMenuWidget: Forwarding to original target: %@", originalTarget);
        }
    }
}

- (void)debugLogCurrentMenuState
{
    NSLog(@"AppMenuWidget: ===== DEBUG MENU STATE =====");
    NSLog(@"AppMenuWidget: Current window ID: %lu", _currentWindowId);
    NSLog(@"AppMenuWidget: Current application: %@", _currentApplicationName ?: @"(none)");
    NSLog(@"AppMenuWidget: Current menu: %@", _currentMenu ? [_currentMenu title] : @"(none)");
    
    if (_currentMenu) {
        NSLog(@"AppMenuWidget: Current menu has %lu items", (unsigned long)[[_currentMenu itemArray] count]);
        NSArray *items = [_currentMenu itemArray];
        for (NSUInteger i = 0; i < [items count]; i++) {
            NSMenuItem *item = [items objectAtIndex:i];
            NSLog(@"AppMenuWidget: Item %lu: '%@' (submenu: %@)", 
                  i, [item title], [item hasSubmenu] ? @"YES" : @"NO");
        }
    }
    
    NSLog(@"AppMenuWidget: Menu view: %@", _menuView);
    NSLog(@"AppMenuWidget: Protocol manager: %@", _protocolManager);
    NSLog(@"AppMenuWidget: ===== END DEBUG MENU STATE =====");
}

- (BOOL)isPlaceholderMenu:(NSMenu *)menu
{
    if (!menu || [[menu itemArray] count] == 0) {
        return YES;
    }
    
    // Check if this is the "GTK Application" placeholder menu
    NSArray *items = [menu itemArray];
    if ([items count] == 1) {
        NSMenuItem *firstItem = [items objectAtIndex:0];
        if ([[firstItem title] isEqualToString:@"GTK Application"]) {
            return YES;
        }
    }
    
    return NO;
}

- (NSMenu *)createFileMenuWithClose:(unsigned long)windowId
{
    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
    NSMenuItem *closeItem = [[NSMenuItem alloc] initWithTitle:@"Close" action:@selector(closeWindow:) keyEquivalent:@"w"];
    [closeItem setKeyEquivalentModifierMask:NSCommandKeyMask];
    [closeItem setTarget:self];
    [closeItem setRepresentedObject:[NSNumber numberWithUnsignedLong:windowId]];
    [fileMenu addItem:closeItem];
    [closeItem release];
    
    NSMenu *mainMenu = [[NSMenu alloc] initWithTitle:@"Main Menu"];
    NSMenuItem *fileMenuItem = [[NSMenuItem alloc] initWithTitle:@"File" action:nil keyEquivalent:@""];
    [fileMenuItem setSubmenu:fileMenu];
    [mainMenu addItem:fileMenuItem];
    [fileMenuItem release];
    [fileMenu release];
    
    return [mainMenu autorelease];
}

- (void)closeWindow:(NSMenuItem *)sender
{
    NSNumber *windowIdNumber = [sender representedObject];
    if (!windowIdNumber) {
        NSLog(@"AppMenuWidget: closeWindow called but no window ID in representedObject");
        return;
    }
    
    unsigned long windowId = [windowIdNumber unsignedLongValue];
    NSLog(@"AppMenuWidget: Closing window %lu", windowId);
    
    // Send Alt+F4 to close the window
    [self sendAltF4ToWindow:windowId];
}

- (void)sendAltF4ToWindow:(unsigned long)windowId
{
    Display *display = XOpenDisplay(NULL);
    if (!display) {
        NSLog(@"AppMenuWidget: Failed to open X11 display for window close");
        return;
    }
    
    Window window = (Window)windowId;
    
    // First try to send WM_DELETE_WINDOW message (the polite way)
    Atom wmDeleteWindow = XInternAtom(display, "WM_DELETE_WINDOW", False);
    Atom wmProtocols = XInternAtom(display, "WM_PROTOCOLS", False);
    
    XEvent event;
    memset(&event, 0, sizeof(event));
    event.type = ClientMessage;
    event.xclient.window = window;
    event.xclient.message_type = wmProtocols;
    event.xclient.format = 32;
    event.xclient.data.l[0] = wmDeleteWindow;
    event.xclient.data.l[1] = CurrentTime;
    
    if (XSendEvent(display, window, False, NoEventMask, &event)) {
        NSLog(@"AppMenuWidget: Sent WM_DELETE_WINDOW to window %lu", windowId);
    } else {
        NSLog(@"AppMenuWidget: Failed to send WM_DELETE_WINDOW to window %lu", windowId);
        
        // Fallback: send Alt+F4 key event
        XEvent keyEvent;
        memset(&keyEvent, 0, sizeof(keyEvent));
        
        // Press Alt
        keyEvent.xkey.type = KeyPress;
        keyEvent.xkey.window = window;
        keyEvent.xkey.state = Mod1Mask; // Alt modifier
        keyEvent.xkey.keycode = XKeysymToKeycode(display, XK_F4);
        XSendEvent(display, window, True, KeyPressMask, &keyEvent);
        
        // Release Alt+F4
        keyEvent.xkey.type = KeyRelease;
        XSendEvent(display, window, True, KeyReleaseMask, &keyEvent);
        
        NSLog(@"AppMenuWidget: Sent Alt+F4 key event to window %lu", windowId);
    }
    
    XFlush(display);
    XCloseDisplay(display);
}

- (void)dealloc
{
    [_currentApplicationName release];
    [_currentMenu release];
    [_menuView release];
    [super dealloc];
}

@end
