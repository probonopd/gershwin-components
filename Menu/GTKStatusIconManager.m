#import "GTKStatusIconManager.h"
#import "TrayView.h"
#import "AppMenuWidget.h"
#import <X11/Xutil.h>
#import <X11/Xatom.h>

// X11 System Tray constants
#define SYSTEM_TRAY_REQUEST_DOCK    0
#define SYSTEM_TRAY_BEGIN_MESSAGE   1
#define SYSTEM_TRAY_CANCEL_MESSAGE  2

// XEmbed constants  
#define XEMBED_EMBEDDED_NOTIFY      0
#define XEMBED_WINDOW_ACTIVATE      1
#define XEMBED_WINDOW_DEACTIVATE    2
#define XEMBED_REQUEST_FOCUS        3
#define XEMBED_FOCUS_IN             4
#define XEMBED_FOCUS_OUT            5
#define XEMBED_FOCUS_NEXT           6
#define XEMBED_FOCUS_PREV           7
#define XEMBED_MODALITY_ON          10
#define XEMBED_MODALITY_OFF         11

@implementation GTKStatusIconManager

- (instancetype)initWithTrayView:(NSView *)trayView
{
    self = [super init];
    if (self) {
        _trayView = [trayView retain];
        _embeddedIcons = [[NSMutableDictionary alloc] init];
        _isConnected = NO;
        _isOwner = NO;
        _screen = 0;
        
        NSLog(@"GTKStatusIconManager: Initialized with tray view");
    }
    return self;
}

- (void)dealloc
{
    [self cleanup];
    [_trayView release];
    [_embeddedIcons release];
    [super dealloc];
}

#pragma mark - MenuProtocolHandler Implementation

- (BOOL)connectToDBus
{
    // GTK StatusIcon uses X11, not D-Bus
    return [self connectToX11];
}

- (BOOL)connectToX11
{
    if (_isConnected) {
        return YES;
    }
    
    _display = XOpenDisplay(NULL);
    if (!_display) {
        NSLog(@"GTKStatusIconManager: Failed to open X11 display");
        return NO;
    }
    
    _screen = DefaultScreen(_display);
    
    // Get required atoms
    _systemTraySelection = XInternAtom(_display, "_NET_SYSTEM_TRAY_S0", False);
    _netSystemTrayOpcode = XInternAtom(_display, "_NET_SYSTEM_TRAY_OPCODE", False);
    _xembedInfo = XInternAtom(_display, "_XEMBED_INFO", False);
    _xembed = XInternAtom(_display, "_XEMBED", False);
    
    _isConnected = YES;
    NSLog(@"GTKStatusIconManager: Connected to X11");
    
    // Try to become system tray owner
    if ([self becomeSystemTrayOwner]) {
        NSLog(@"GTKStatusIconManager: Successfully became system tray owner");
        
        // Start processing X11 events in a separate thread
        [NSThread detachNewThreadSelector:@selector(processSystemTrayEvents) 
                                 toTarget:self 
                               withObject:nil];
    } else {
        NSLog(@"GTKStatusIconManager: Failed to become system tray owner");
    }
    
    return YES;
}

- (BOOL)hasMenuForWindow:(unsigned long)windowId
{
    // GTK StatusIcon items may have popup menus but we don't track them per-window
    return NO;
}

- (NSMenu *)getMenuForWindow:(unsigned long)windowId
{
    return nil;
}

- (void)activateMenuItem:(NSMenuItem *)menuItem forWindow:(unsigned long)windowId
{
    // Not applicable for GTK StatusIcon
}

- (void)registerWindow:(unsigned long)windowId serviceName:(NSString *)serviceName objectPath:(NSString *)objectPath
{
    // GTK StatusIcon windows register themselves via X11 messages
}

- (void)unregisterWindow:(unsigned long)windowId
{
    [self unembedIconWindow:(Window)windowId];
}

- (void)scanForExistingMenuServices
{
    // GTK StatusIcon doesn't have discoverable services like D-Bus protocols
    NSLog(@"GTKStatusIconManager: GTK StatusIcon scanning not applicable");
}

- (NSString *)getMenuServiceForWindow:(unsigned long)windowId
{
    return nil;
}

- (NSString *)getMenuObjectPathForWindow:(unsigned long)windowId
{
    return nil;
}

- (void)cleanup
{
    if (!_isConnected) {
        return;
    }
    
    NSLog(@"GTKStatusIconManager: Cleaning up");
    
    // Unembed all icons
    NSArray *windows = [NSArray arrayWithArray:[_embeddedIcons allKeys]];
    for (NSNumber *windowNum in windows) {
        Window window = (Window)[windowNum unsignedLongValue];
        [self unembedIconWindow:window];
    }
    
    // Release system tray selection if we own it
    if (_isOwner && _display) {
        XSetSelectionOwner(_display, _systemTraySelection, None, CurrentTime);
        _isOwner = NO;
    }
    
    if (_display) {
        XCloseDisplay(_display);
        _display = NULL;
    }
    
    _isConnected = NO;
}

#pragma mark - X11 System Tray Implementation

- (BOOL)becomeSystemTrayOwner
{
    if (!_display) {
        return NO;
    }
    
    // Check if there's already a system tray owner
    Window currentOwner = XGetSelectionOwner(_display, _systemTraySelection);
    if (currentOwner != None) {
        NSLog(@"GTKStatusIconManager: System tray already owned by window %lu", currentOwner);
        return NO;
    }
    
    // Create our system tray window
    _systemTrayWindow = XCreateSimpleWindow(_display, 
                                           DefaultRootWindow(_display),
                                           0, 0, 1, 1, 0, 0, 0);
    
    if (!_systemTrayWindow) {
        NSLog(@"GTKStatusIconManager: Failed to create system tray window");
        return NO;
    }
    
    // Claim the system tray selection
    XSetSelectionOwner(_display, _systemTraySelection, _systemTrayWindow, CurrentTime);
    
    // Verify we got the selection
    Window owner = XGetSelectionOwner(_display, _systemTraySelection);
    if (owner != _systemTrayWindow) {
        NSLog(@"GTKStatusIconManager: Failed to acquire system tray selection");
        XDestroyWindow(_display, _systemTrayWindow);
        _systemTrayWindow = None;
        return NO;
    }
    
    // Send MANAGER client message to announce we're the new system tray
    XEvent event;
    event.xclient.type = ClientMessage;
    event.xclient.window = DefaultRootWindow(_display);
    event.xclient.message_type = XInternAtom(_display, "MANAGER", False);
    event.xclient.format = 32;
    event.xclient.data.l[0] = CurrentTime;
    event.xclient.data.l[1] = _systemTraySelection;
    event.xclient.data.l[2] = _systemTrayWindow;
    event.xclient.data.l[3] = 0;
    event.xclient.data.l[4] = 0;
    
    XSendEvent(_display, DefaultRootWindow(_display), False, StructureNotifyMask, &event);
    XFlush(_display);
    
    _isOwner = YES;
    NSLog(@"GTKStatusIconManager: Became system tray owner with window %lu", _systemTrayWindow);
    
    return YES;
}

- (void)processSystemTrayEvents
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    if (!_display || !_systemTrayWindow) {
        [pool release];
        return;
    }
    
    // Select events on our system tray window
    XSelectInput(_display, _systemTrayWindow, 
                 ClientMessage | StructureNotifyMask | DestroyNotify);
    
    NSLog(@"GTKStatusIconManager: Starting X11 event processing");
    
    while (_isConnected && _display) {
        XEvent event;
        
        // Check for events with a timeout
        if (XPending(_display) > 0) {
            XNextEvent(_display, &event);
            
            if (event.xany.window == _systemTrayWindow) {
                [self handleSystemTrayEvent:&event];
            }
        } else {
            // Sleep briefly to avoid busy waiting
            [NSThread sleepForTimeInterval:0.01];
        }
    }
    
    NSLog(@"GTKStatusIconManager: X11 event processing stopped");
    [pool release];
}

- (void)handleSystemTrayEvent:(XEvent *)event
{
    switch (event->type) {
        case ClientMessage:
            if (event->xclient.message_type == _netSystemTrayOpcode) {
                [self handleSystemTrayOpcode:&event->xclient];
            }
            break;
            
        case DestroyNotify:
            // Icon window was destroyed
            [self handleUndockRequest:event->xdestroywindow.window];
            break;
            
        default:
            break;
    }
}

- (void)handleSystemTrayOpcode:(XClientMessageEvent *)event
{
    unsigned long opcode = event->data.l[1];
    Window iconWindow = event->data.l[2];
    
    switch (opcode) {
        case SYSTEM_TRAY_REQUEST_DOCK:
            NSLog(@"GTKStatusIconManager: Dock request for window %lu", iconWindow);
            [self handleDockRequest:iconWindow];
            break;
            
        case SYSTEM_TRAY_BEGIN_MESSAGE:
            NSLog(@"GTKStatusIconManager: Begin message from window %lu", iconWindow);
            break;
            
        case SYSTEM_TRAY_CANCEL_MESSAGE:
            NSLog(@"GTKStatusIconManager: Cancel message from window %lu", iconWindow);
            break;
            
        default:
            NSLog(@"GTKStatusIconManager: Unknown opcode %lu from window %lu", opcode, iconWindow);
            break;
    }
}

- (void)handleDockRequest:(Window)iconWindow
{
    NSLog(@"GTKStatusIconManager: Handling dock request for window %lu", iconWindow);
    
    // Check if already embedded
    NSNumber *windowKey = [NSNumber numberWithUnsignedLong:iconWindow];
    if ([_embeddedIcons objectForKey:windowKey]) {
        NSLog(@"GTKStatusIconManager: Window %lu already embedded", iconWindow);
        return;
    }
    
    [self embedIconWindow:iconWindow];
}

- (void)handleUndockRequest:(Window)iconWindow
{
    NSLog(@"GTKStatusIconManager: Handling undock request for window %lu", iconWindow);
    [self unembedIconWindow:iconWindow];
}

- (void)embedIconWindow:(Window)iconWindow
{
    if (!_display || iconWindow == None) {
        return;
    }
    
    NSLog(@"GTKStatusIconManager: Embedding icon window %lu", iconWindow);
    
    // Get window attributes
    XWindowAttributes attrs;
    if (XGetWindowAttributes(_display, iconWindow, &attrs) == Success) {
        NSLog(@"GTKStatusIconManager: Window %lu attributes: %dx%d at %d,%d", 
              iconWindow, attrs.width, attrs.height, attrs.x, attrs.y);
    } else {
        NSLog(@"GTKStatusIconManager: Failed to get attributes for window %lu, using defaults", iconWindow);
        // Don't return - try to embed anyway with default size
        attrs.width = 22;
        attrs.height = 22;
    }
    
    // Create GTKStatusIconItem
    GTKStatusIconItem *iconItem = [[GTKStatusIconItem alloc] initWithWindow:iconWindow];
    int iconWidth = (attrs.width > 0 && attrs.width <= 48) ? attrs.width : 22;
    int iconHeight = (attrs.height > 0 && attrs.height <= 48) ? attrs.height : 22;
    [iconItem setWidth:iconWidth];
    [iconItem setHeight:iconHeight];
    
    // Create container view for the icon 
    NSRect containerFrame = NSMakeRect(0, 0, iconWidth, iconHeight);
    ClickableIconView *containerView = [[ClickableIconView alloc] initWithFrame:containerFrame 
                                                                         window:iconWindow 
                                                                        display:_display 
                                                                        manager:self];
    
    // Make sure the view gets displayed and allows X11 content to show through
    [containerView setNeedsDisplay:YES];
    
    // The ClickableIconView will handle X11 embedding when it's added to the window hierarchy
    // No need to call performX11Embedding here
    
    [iconItem setContainerView:containerView];
    
    // Store the mapping
    NSNumber *windowKey = [NSNumber numberWithUnsignedLong:iconWindow];
    [_embeddedIcons setObject:iconItem forKey:windowKey];
    
    // Add to tray view on main thread
    [self performSelectorOnMainThread:@selector(addStatusIconOnMainThread:) 
                           withObject:iconItem 
                        waitUntilDone:NO];
    
    // Send XEMBED_EMBEDDED_NOTIFY to the icon
    [self sendXEmbedMessage:iconWindow message:XEMBED_EMBEDDED_NOTIFY detail:0 data1:_systemTrayWindow data2:0];
    
    NSLog(@"GTKStatusIconManager: Successfully embedded window %lu with size %dx%d", 
          iconWindow, iconWidth, iconHeight);
    
    [iconItem release];
    [containerView release];
}

- (void)unembedIconWindow:(Window)iconWindow
{
    NSNumber *windowKey = [NSNumber numberWithUnsignedLong:iconWindow];
    GTKStatusIconItem *iconItem = [_embeddedIcons objectForKey:windowKey];
    
    if (!iconItem) {
        return;
    }
    
    NSLog(@"GTKStatusIconManager: Unembedding icon window %lu", iconWindow);
    
    // Remove from tray view on main thread
    [self performSelectorOnMainThread:@selector(removeStatusIconOnMainThread:) 
                           withObject:iconItem 
                        waitUntilDone:NO];
    
    [_embeddedIcons removeObjectForKey:windowKey];
}

- (void)sendXEmbedMessage:(Window)window message:(unsigned long)message detail:(unsigned long)detail data1:(unsigned long)data1 data2:(unsigned long)data2
{
    if (!_display) {
        return;
    }
    
    XEvent event;
    event.xclient.type = ClientMessage;
    event.xclient.window = window;
    event.xclient.message_type = _xembed;
    event.xclient.format = 32;
    event.xclient.data.l[0] = CurrentTime;
    event.xclient.data.l[1] = message;
    event.xclient.data.l[2] = detail;
    event.xclient.data.l[3] = data1;
    event.xclient.data.l[4] = data2;
    
    XSendEvent(_display, window, False, 0, &event);
    XFlush(_display);
}

#pragma mark - Icon Management

- (void)addStatusIconOnMainThread:(GTKStatusIconItem *)icon
{
    [self addStatusIcon:icon];
}

- (void)removeStatusIconOnMainThread:(GTKStatusIconItem *)icon
{
    [self removeStatusIcon:icon];
}

- (void)addStatusIcon:(GTKStatusIconItem *)icon
{
    if (!_trayView) {
        NSLog(@"GTKStatusIconManager: No tray view available");
        return;
    }
    if (!icon) {
        NSLog(@"GTKStatusIconManager: Icon is nil");
        return;
    }
    if (![icon containerView]) {
        NSLog(@"GTKStatusIconManager: Icon has no container view");
        return;
    }
    
    NSLog(@"GTKStatusIconManager: Adding status icon to tray view: %@", _trayView);
    NSLog(@"GTKStatusIconManager: Container view frame: %@", NSStringFromRect([[icon containerView] frame]));
    
    // Add container view to tray using TrayView's proper method
    [(TrayView *)_trayView addTrayIconView:[icon containerView]];
    
    NSLog(@"GTKStatusIconManager: Added status icon to tray, subviews count: %lu", 
          (unsigned long)[[_trayView subviews] count]);
}

- (void)removeStatusIcon:(GTKStatusIconItem *)icon
{
    if (!icon || ![icon containerView]) {
        return;
    }

    [(TrayView *)_trayView removeTrayIconView:[icon containerView]];
    
    NSLog(@"GTKStatusIconManager: Removed status icon from tray");
}

- (void)performX11Embedding:(Window)iconWindow inContainer:(NSView *)containerView
{
    // For now, don't do actual X11 embedding as it causes windows to appear separately
    // Instead, we'll rely on the ClickableIconView to capture and display the content
    NSLog(@"GTKStatusIconManager: Skipping X11 embedding for window %lu (would cause separate windows)", iconWindow);
}

- (void)updateTrayLayout
{
    if (!_trayView) {
        return;
    }
    
    NSArray *subviews = [_trayView subviews];
    CGFloat x = 0;
    CGFloat iconSize = 22; // Standard icon size
    CGFloat spacing = 4;
    
    for (NSView *subview in subviews) {
        NSRect frame = NSMakeRect(x, 
                                 (NSHeight([_trayView frame]) - iconSize) / 2,
                                 iconSize,
                                 iconSize);
        [subview setFrame:frame];
        x += iconSize + spacing;
    }
    
    // Update tray view size
    if ([_trayView respondsToSelector:@selector(updateLayout)]) {
        [(id)_trayView updateLayout];
    }
}

// Helper method for main thread dispatch without GCD
- (void)performOnMainThread:(SEL)selector withObject:(id)object
{
    [self performSelectorOnMainThread:selector withObject:object waitUntilDone:NO];
}

@end

#pragma mark - GTKStatusIconItem Implementation

@implementation GTKStatusIconItem

- (instancetype)initWithWindow:(Window)window
{
    self = [super init];
    if (self) {
        _iconWindow = window;
        _width = 22;
        _height = 22;
    }
    return self;
}

- (void)dealloc
{
    [_containerView release];
    [_title release];
    [_tooltip release];
    [super dealloc];
}

- (void)updateGeometry:(NSRect)frame
{
    if (_containerView) {
        [_containerView setFrame:frame];
    }
}

@end
