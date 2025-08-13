//
// VNCWindow.m
// Bhyve Assistant - VNC Viewer Window
//

#import "VNCWindow.h"

@implementation VNCWindow

@synthesize vncClient = _vncClient;
@synthesize hostname = _hostname;
@synthesize port = _port;
@synthesize password = _password;
@synthesize connected = _connected;

#pragma mark - Initialization

- (id)initWithContentRect:(NSRect)contentRect hostname:(NSString *)hostname port:(NSInteger)port
{
    return [self initWithContentRect:contentRect hostname:hostname port:port password:nil];
}

- (id)initWithContentRect:(NSRect)contentRect hostname:(NSString *)hostname port:(NSInteger)port password:(NSString *)password
{
    self = [super initWithContentRect:contentRect
                            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                              backing:NSBackingStoreBuffered
                                defer:NO];
    
    if (self) {
        _hostname = [hostname copy];
        _port = port;
        _password = [password copy];
        _connected = NO;
        _framebufferSize = NSZeroSize;
        _currentImage = nil;
        _mouseInside = NO;
        
        [self setTitle:[NSString stringWithFormat:NSLocalizedString(@"VNC: %@:%ld", @"VNC window title"), hostname, (long)port]];
        [self setMinSize:NSMakeSize(320, 240)];
        [self setDelegate:self];
        
        [self setupVNCClient];
        [self setupUserInterface];
        [self setupEventHandling];
    }
    
    return self;
}

- (void)dealloc
{
    [self disconnectFromVNC];
    [_hostname release];
    [_password release];
    [_currentImage release];
    [super dealloc];
}

#pragma mark - Setup Methods

- (void)setupVNCClient
{
    _vncClient = [[VNCClient alloc] init];
    [_vncClient setDelegate:self];
}

- (void)setupUserInterface
{
    NSRect contentRect = [[self contentView] bounds];
    
    // Create image view for VNC display - NO SCROLL VIEW for no scrollbars
    _imageView = [[NSImageView alloc] initWithFrame:contentRect];
    [_imageView setImageScaling:NSImageScaleProportionallyUpOrDown]; // Maintain 1:1 pixel ratio
    [_imageView setImageAlignment:NSImageAlignCenter];
    [_imageView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [_imageView setFocusRingType:NSFocusRingTypeNone];
    
    // Add to content view directly (no scroll view for no scrollbars)
    [[self contentView] addSubview:_imageView];
    
    // Set placeholder image
    NSImage *placeholderImage = [[NSImage alloc] initWithSize:NSMakeSize(640, 480)];
    [placeholderImage lockFocus];
    [[NSColor blackColor] setFill];
    NSRectFill(NSMakeRect(0, 0, 640, 480));
    
    // Draw connection message
    NSString *message = NSLocalizedString(@"Connecting to VNC server...", @"VNC connection message");
    NSDictionary *attributes = @{
        NSForegroundColorAttributeName: [NSColor whiteColor],
        NSFontAttributeName: [NSFont systemFontOfSize:16]
    };
    NSSize textSize = [message sizeWithAttributes:attributes];
    NSPoint textPoint = NSMakePoint((640 - textSize.width) / 2, (480 - textSize.height) / 2);
    [message drawAtPoint:textPoint withAttributes:attributes];
    
    [placeholderImage unlockFocus];
    [_imageView setImage:placeholderImage];
    [placeholderImage release];
}

- (void)setupEventHandling
{
    // Make window accept key events
    [self setAcceptsMouseMovedEvents:YES];
    [self makeFirstResponder:_imageView];
    
    // Create tracking area for mouse events - using older API
    _trackingArea = [[NSTrackingArea alloc] 
        initWithRect:[_imageView bounds]
             options:NSTrackingMouseEnteredAndExited | NSTrackingMouseMoved | NSTrackingActiveInKeyWindow
               owner:self
            userInfo:nil];
    
    // Add tracking area to view - check if method exists
    if ([_imageView respondsToSelector:@selector(addTrackingArea:)]) {
        [_imageView performSelector:@selector(addTrackingArea:) withObject:_trackingArea];
    }
}

#pragma mark - Connection Management

- (BOOL)connectToVNC
{
    if (_connected) {
        NSLog(@"VNCWindow: Already connected");
        return YES;
    }
    
    NSLog(@"VNCWindow: Connecting to %@:%ld", _hostname, (long)_port);
    
    BOOL result = [_vncClient connectToHost:_hostname port:_port password:_password];
    if (!result) {
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:NSLocalizedString(@"VNC Connection Failed", @"VNC error title")];
        [alert setInformativeText:NSLocalizedString(@"Failed to connect to VNC server. Please check that the server is running and the address is correct.", @"VNC connection error")];
        [alert runModal];
        [alert release];
    }
    
    return result;
}

- (void)disconnectFromVNC
{
    NSLog(@"VNCWindow: Disconnecting from VNC");
    
    if (_vncClient) {
        [_vncClient setDelegate:nil];
        [_vncClient disconnect];
        [_vncClient release];
        _vncClient = nil;
    }
    
    _connected = NO;
}

#pragma mark - Display Management

- (void)updateDisplay
{
    if (!_vncClient || !_connected) {
        return;
    }
    
    NSImage *newImage = [_vncClient framebufferImage];
    if (newImage) {
        [_currentImage release];
        _currentImage = [newImage retain];
        [_imageView setImage:_currentImage];
        
        // Update framebuffer size
        NSSize imageSize = [newImage size];
        if (!NSEqualSizes(_framebufferSize, imageSize)) {
            _framebufferSize = imageSize;
            [self resizeWindowToFitFramebuffer];
        }
    }
}

- (void)resizeWindowToFitFramebuffer
{
    if (NSEqualSizes(_framebufferSize, NSZeroSize)) {
        return;
    }
    
    NSLog(@"VNCWindow: Resizing window to fit framebuffer: %.0fx%.0f", _framebufferSize.width, _framebufferSize.height);
    
    // Calculate new window size (1:1 pixel ratio)
    NSSize windowSize = _framebufferSize;
    
    // Add space for title bar
    NSRect contentRect = NSMakeRect(0, 0, windowSize.width, windowSize.height);
    NSRect windowRect = [self frameRectForContentRect:contentRect];
    
    // Get current window position
    NSRect currentFrame = [self frame];
    windowRect.origin = currentFrame.origin;
    
    // Ensure window fits on screen
    NSScreen *screen = [self screen];
    if (screen) {
        NSRect screenFrame = [screen visibleFrame];
        
        // Scale down if necessary to fit screen
        if (windowRect.size.width > screenFrame.size.width) {
            CGFloat scale = screenFrame.size.width / windowRect.size.width;
            windowRect.size.width = screenFrame.size.width;
            windowRect.size.height *= scale;
        }
        
        if (windowRect.size.height > screenFrame.size.height) {
            CGFloat scale = screenFrame.size.height / windowRect.size.height;
            windowRect.size.height = screenFrame.size.height;
            windowRect.size.width *= scale;
        }
        
        // Center on screen if needed
        if (NSMaxX(windowRect) > NSMaxX(screenFrame)) {
            windowRect.origin.x = screenFrame.origin.x + (screenFrame.size.width - windowRect.size.width) / 2;
        }
        if (NSMaxY(windowRect) > NSMaxY(screenFrame)) {
            windowRect.origin.y = screenFrame.origin.y + (screenFrame.size.height - windowRect.size.height) / 2;
        }
    }
    
    [self setFrame:windowRect display:YES animate:YES];
}

#pragma mark - Event Handling

- (void)keyDown:(NSEvent *)event
{
    if (!_connected || !_vncClient) {
        [super keyDown:event];
        return;
    }
    
    // Convert NSEvent to VNC key code
    NSString *characters = [event characters];
    if ([characters length] > 0) {
        unichar character = [characters characterAtIndex:0];
        [_vncClient sendKeyboardEvent:character pressed:YES];
    }
    
    // Handle special keys
    NSUInteger keyCode = [event keyCode];
    switch (keyCode) {
        case 36: // Return
            [_vncClient sendKeyboardEvent:0xFF0D pressed:YES];
            break;
        case 48: // Tab
            [_vncClient sendKeyboardEvent:0xFF09 pressed:YES];
            break;
        case 51: // Backspace
            [_vncClient sendKeyboardEvent:0xFF08 pressed:YES];
            break;
        case 53: // Escape
            [_vncClient sendKeyboardEvent:0xFF1B pressed:YES];
            break;
        case 123: // Left Arrow
            [_vncClient sendKeyboardEvent:0xFF51 pressed:YES];
            break;
        case 124: // Right Arrow
            [_vncClient sendKeyboardEvent:0xFF53 pressed:YES];
            break;
        case 125: // Down Arrow
            [_vncClient sendKeyboardEvent:0xFF54 pressed:YES];
            break;
        case 126: // Up Arrow
            [_vncClient sendKeyboardEvent:0xFF52 pressed:YES];
            break;
    }
}

- (void)keyUp:(NSEvent *)event
{
    if (!_connected || !_vncClient) {
        [super keyUp:event];
        return;
    }
    
    // Convert NSEvent to VNC key code
    NSString *characters = [event characters];
    if ([characters length] > 0) {
        unichar character = [characters characterAtIndex:0];
        [_vncClient sendKeyboardEvent:character pressed:NO];
    }
    
    // Handle special keys
    NSUInteger keyCode = [event keyCode];
    switch (keyCode) {
        case 36: // Return
            [_vncClient sendKeyboardEvent:0xFF0D pressed:NO];
            break;
        case 48: // Tab
            [_vncClient sendKeyboardEvent:0xFF09 pressed:NO];
            break;
        case 51: // Backspace
            [_vncClient sendKeyboardEvent:0xFF08 pressed:NO];
            break;
        case 53: // Escape
            [_vncClient sendKeyboardEvent:0xFF1B pressed:NO];
            break;
        case 123: // Left Arrow
            [_vncClient sendKeyboardEvent:0xFF51 pressed:NO];
            break;
        case 124: // Right Arrow
            [_vncClient sendKeyboardEvent:0xFF53 pressed:NO];
            break;
        case 125: // Down Arrow
            [_vncClient sendKeyboardEvent:0xFF54 pressed:NO];
            break;
        case 126: // Up Arrow
            [_vncClient sendKeyboardEvent:0xFF52 pressed:NO];
            break;
    }
}

- (void)mouseDown:(NSEvent *)event
{
    if (!_connected || !_vncClient) {
        [super mouseDown:event];
        return;
    }
    
    NSPoint location = [event locationInWindow];
    NSPoint imagePoint = [_imageView convertPoint:location fromView:nil];
    
    // Convert to VNC coordinates
    NSSize imageSize = [_imageView bounds].size;
    if (_framebufferSize.width > 0 && _framebufferSize.height > 0) {
        imagePoint.x = (imagePoint.x / imageSize.width) * _framebufferSize.width;
        imagePoint.y = (imagePoint.y / imageSize.height) * _framebufferSize.height;
    }
    
    [_vncClient sendMouseButtonEvent:1 pressed:YES position:imagePoint];
}

- (void)mouseUp:(NSEvent *)event
{
    if (!_connected || !_vncClient) {
        [super mouseUp:event];
        return;
    }
    
    NSPoint location = [event locationInWindow];
    NSPoint imagePoint = [_imageView convertPoint:location fromView:nil];
    
    // Convert to VNC coordinates
    NSSize imageSize = [_imageView bounds].size;
    if (_framebufferSize.width > 0 && _framebufferSize.height > 0) {
        imagePoint.x = (imagePoint.x / imageSize.width) * _framebufferSize.width;
        imagePoint.y = (imagePoint.y / imageSize.height) * _framebufferSize.height;
    }
    
    [_vncClient sendMouseButtonEvent:1 pressed:NO position:imagePoint];
}

- (void)rightMouseDown:(NSEvent *)event
{
    if (!_connected || !_vncClient) {
        [super rightMouseDown:event];
        return;
    }
    
    NSPoint location = [event locationInWindow];
    NSPoint imagePoint = [_imageView convertPoint:location fromView:nil];
    
    // Convert to VNC coordinates
    NSSize imageSize = [_imageView bounds].size;
    if (_framebufferSize.width > 0 && _framebufferSize.height > 0) {
        imagePoint.x = (imagePoint.x / imageSize.width) * _framebufferSize.width;
        imagePoint.y = (imagePoint.y / imageSize.height) * _framebufferSize.height;
    }
    
    [_vncClient sendMouseButtonEvent:3 pressed:YES position:imagePoint];
}

- (void)rightMouseUp:(NSEvent *)event
{
    if (!_connected || !_vncClient) {
        [super rightMouseUp:event];
        return;
    }
    
    NSPoint location = [event locationInWindow];
    NSPoint imagePoint = [_imageView convertPoint:location fromView:nil];
    
    // Convert to VNC coordinates
    NSSize imageSize = [_imageView bounds].size;
    if (_framebufferSize.width > 0 && _framebufferSize.height > 0) {
        imagePoint.x = (imagePoint.x / imageSize.width) * _framebufferSize.width;
        imagePoint.y = (imagePoint.y / imageSize.height) * _framebufferSize.height;
    }
    
    [_vncClient sendMouseButtonEvent:3 pressed:NO position:imagePoint];
}

- (void)mouseMoved:(NSEvent *)event
{
    if (!_connected || !_vncClient || !_mouseInside) {
        return;
    }
    
    NSPoint location = [event locationInWindow];
    NSPoint imagePoint = [_imageView convertPoint:location fromView:nil];
    
    // Convert to VNC coordinates
    NSSize imageSize = [_imageView bounds].size;
    if (_framebufferSize.width > 0 && _framebufferSize.height > 0) {
        imagePoint.x = (imagePoint.x / imageSize.width) * _framebufferSize.width;
        imagePoint.y = (imagePoint.y / imageSize.height) * _framebufferSize.height;
    }
    
    [_vncClient sendMouseMoveEvent:imagePoint];
}

- (void)mouseEntered:(NSEvent *)event
{
    _mouseInside = YES;
}

- (void)mouseExited:(NSEvent *)event
{
    _mouseInside = NO;
}

#pragma mark - Window Delegate

- (BOOL)windowShouldClose:(id)sender
{
    [self disconnectFromVNC];
    return YES;
}

- (BOOL)acceptsFirstResponder
{
    return YES;
}

- (BOOL)canBecomeKeyWindow
{
    return YES;
}

#pragma mark - VNCClient Delegate

- (void)vncClient:(VNCClient *)client didConnect:(BOOL)success
{
    NSLog(@"VNCWindow: VNC connection result: %@", success ? @"SUCCESS" : @"FAILED");
    
    if (success) {
        _connected = YES;
        [self updateDisplay];
        
        // Request initial framebuffer update
        [_vncClient requestFullFramebufferUpdate];
    } else {
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:NSLocalizedString(@"VNC Connection Failed", @"VNC error title")];
        [alert setInformativeText:NSLocalizedString(@"Could not connect to the VNC server. Please ensure the server is running and accessible.", @"VNC connection failed message")];
        [alert runModal];
        [alert release];
    }
}

- (void)vncClient:(VNCClient *)client didDisconnect:(NSString *)reason
{
    NSLog(@"VNCWindow: VNC disconnected: %@", reason);
    _connected = NO;
    
    // Show disconnected image
    NSImage *disconnectedImage = [[NSImage alloc] initWithSize:NSMakeSize(640, 480)];
    [disconnectedImage lockFocus];
    [[NSColor darkGrayColor] setFill];
    NSRectFill(NSMakeRect(0, 0, 640, 480));
    
    NSString *message = NSLocalizedString(@"VNC Connection Lost", @"VNC disconnected message");
    NSDictionary *attributes = @{
        NSForegroundColorAttributeName: [NSColor whiteColor],
        NSFontAttributeName: [NSFont systemFontOfSize:16]
    };
    NSSize textSize = [message sizeWithAttributes:attributes];
    NSPoint textPoint = NSMakePoint((640 - textSize.width) / 2, (480 - textSize.height) / 2);
    [message drawAtPoint:textPoint withAttributes:attributes];
    
    [disconnectedImage unlockFocus];
    [_imageView setImage:disconnectedImage];
    [disconnectedImage release];
}

- (void)vncClient:(VNCClient *)client didReceiveError:(NSString *)error
{
    NSLog(@"VNCWindow: VNC error: %@", error);
    
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:NSLocalizedString(@"VNC Error", @"VNC error title")];
    [alert setInformativeText:error];
    [alert runModal];
    [alert release];
}

- (void)vncClient:(VNCClient *)client framebufferDidUpdate:(NSRect)rect
{
    // Update display on main thread
    [self performSelectorOnMainThread:@selector(updateDisplay)
                           withObject:nil
                        waitUntilDone:NO];
}

@end
