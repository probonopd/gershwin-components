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
@synthesize vncDelegate = _vncDelegate;

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
    [self makeFirstResponder:self];  // Make window the first responder for keyboard events
    
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
    
    // Make window invisible when disconnecting
    [self orderOut:nil];
    
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
        // Always update the image to avoid missing frames
        [_currentImage release];
        _currentImage = [newImage retain];
        
        // Update on main thread but don't wait to avoid blocking
        [self performSelectorOnMainThread:@selector(setImageOnMainThread:)
                               withObject:_currentImage
                            waitUntilDone:NO];
        
        // Update framebuffer size only when needed
        NSSize imageSize = [newImage size];
        if (!NSEqualSizes(_framebufferSize, imageSize)) {
            _framebufferSize = imageSize;
            [self performSelectorOnMainThread:@selector(resizeWindowToFitFramebuffer)
                                   withObject:nil
                                waitUntilDone:NO];
        }
    }
}

- (void)setImageOnMainThread:(NSImage *)image
{
    [_imageView setImage:image];
    [_imageView setNeedsDisplay:YES];
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
    
    NSUInteger keyCode = [event keyCode];
    NSUInteger modifierFlags = [event modifierFlags];
    
    // Handle special keys with proper VNC key codes
    BOOL specialKeyHandled = YES;
    uint32_t vncKeyCode = 0;
    
    switch (keyCode) {
        case 36: // Return/Enter
            vncKeyCode = 0xFF0D;
            break;
        case 48: // Tab - critical for navigation
            vncKeyCode = 0xFF09;
            break;
        case 51: // Backspace
            vncKeyCode = 0xFF08;
            break;
        case 53: // Escape
            vncKeyCode = 0xFF1B;
            break;
        case 123: // Left Arrow
            vncKeyCode = 0xFF51;
            break;
        case 124: // Right Arrow
            vncKeyCode = 0xFF53;
            break;
        case 125: // Down Arrow
            vncKeyCode = 0xFF54;
            break;
        case 126: // Up Arrow
            vncKeyCode = 0xFF52;
            break;
        case 122: // F1
            vncKeyCode = 0xFFBE;
            break;
        case 120: // F2
            vncKeyCode = 0xFFBF;
            break;
        case 99: // F3
            vncKeyCode = 0xFFC0;
            break;
        case 118: // F4
            vncKeyCode = 0xFFC1;
            break;
        case 96: // F5
            vncKeyCode = 0xFFC2;
            break;
        case 97: // F6
            vncKeyCode = 0xFFC3;
            break;
        case 98: // F7
            vncKeyCode = 0xFFC4;
            break;
        case 100: // F8
            vncKeyCode = 0xFFC5;
            break;
        case 101: // F9
            vncKeyCode = 0xFFC6;
            break;
        case 109: // F10
            vncKeyCode = 0xFFC7;
            break;
        case 103: // F11
            vncKeyCode = 0xFFC8;
            break;
        case 111: // F12
            vncKeyCode = 0xFFC9;
            break;
        case 49: // Space
            vncKeyCode = 0x0020;
            break;
        case 117: // Delete (Forward Delete)
            vncKeyCode = 0xFFFF;
            break;
        case 116: // Page Up
            vncKeyCode = 0xFF55;
            break;
        case 121: // Page Down
            vncKeyCode = 0xFF56;
            break;
        case 115: // Home
            vncKeyCode = 0xFF50;
            break;
        case 119: // End
            vncKeyCode = 0xFF57;
            break;
        default:
            specialKeyHandled = NO;
            break;
    }
    
    if (specialKeyHandled && vncKeyCode != 0) {
        // Send special key immediately
        [_vncClient sendKeyboardEvent:vncKeyCode pressed:YES];
    } else {
        // Handle regular characters - use charactersIgnoringModifiers for better handling
        NSString *characters = [event charactersIgnoringModifiers];
        if ([characters length] > 0) {
            for (NSUInteger i = 0; i < [characters length]; i++) {
                unichar character = [characters characterAtIndex:i];
                // Convert to upper case if shift is pressed and it's a letter
                if ((modifierFlags & NSShiftKeyMask) && character >= 'a' && character <= 'z') {
                    character = character - 'a' + 'A';
                }
                [_vncClient sendKeyboardEvent:character pressed:YES];
            }
        }
    }
}

- (void)keyUp:(NSEvent *)event
{
    if (!_connected || !_vncClient) {
        [super keyUp:event];
        return;
    }
    
    NSUInteger keyCode = [event keyCode];
    NSUInteger modifierFlags = [event modifierFlags];
    
    // Handle special keys with proper VNC key codes
    BOOL specialKeyHandled = YES;
    uint32_t vncKeyCode = 0;
    
    switch (keyCode) {
        case 36: // Return/Enter
            vncKeyCode = 0xFF0D;
            break;
        case 48: // Tab - handled in keyDown with immediate keyup
            return;
        case 51: // Backspace
            vncKeyCode = 0xFF08;
            break;
        case 53: // Escape
            vncKeyCode = 0xFF1B;
            break;
        case 123: // Left Arrow
            vncKeyCode = 0xFF51;
            break;
        case 124: // Right Arrow
            vncKeyCode = 0xFF53;
            break;
        case 125: // Down Arrow
            vncKeyCode = 0xFF54;
            break;
        case 126: // Up Arrow
            vncKeyCode = 0xFF52;
            break;
        case 122: // F1
            vncKeyCode = 0xFFBE;
            break;
        case 120: // F2
            vncKeyCode = 0xFFBF;
            break;
        case 99: // F3
            vncKeyCode = 0xFFC0;
            break;
        case 118: // F4
            vncKeyCode = 0xFFC1;
            break;
        case 96: // F5
            vncKeyCode = 0xFFC2;
            break;
        case 97: // F6
            vncKeyCode = 0xFFC3;
            break;
        case 98: // F7
            vncKeyCode = 0xFFC4;
            break;
        case 100: // F8
            vncKeyCode = 0xFFC5;
            break;
        case 101: // F9
            vncKeyCode = 0xFFC6;
            break;
        case 109: // F10
            vncKeyCode = 0xFFC7;
            break;
        case 103: // F11
            vncKeyCode = 0xFFC8;
            break;
        case 111: // F12
            vncKeyCode = 0xFFC9;
            break;
        case 49: // Space
            vncKeyCode = 0x0020;
            break;
        case 117: // Delete (Forward Delete)
            vncKeyCode = 0xFFFF;
            break;
        case 116: // Page Up
            vncKeyCode = 0xFF55;
            break;
        case 121: // Page Down
            vncKeyCode = 0xFF56;
            break;
        case 115: // Home
            vncKeyCode = 0xFF50;
            break;
        case 119: // End
            vncKeyCode = 0xFF57;
            break;
        default:
            specialKeyHandled = NO;
            break;
    }
    
    if (specialKeyHandled && vncKeyCode != 0) {
        // Send special key release
        [_vncClient sendKeyboardEvent:vncKeyCode pressed:NO];
    } else {
        // Handle regular characters - use charactersIgnoringModifiers for consistency
        NSString *characters = [event charactersIgnoringModifiers];
        if ([characters length] > 0) {
            for (NSUInteger i = 0; i < [characters length]; i++) {
                unichar character = [characters characterAtIndex:i];
                // Convert to upper case if shift is pressed and it's a letter
                if ((modifierFlags & NSShiftKeyMask) && character >= 'a' && character <= 'z') {
                    character = character - 'a' + 'A';
                }
                [_vncClient sendKeyboardEvent:character pressed:NO];
            }
        }
    }
}

- (void)flagsChanged:(NSEvent *)event
{
    if (!_connected || !_vncClient) {
        [super flagsChanged:event];
        return;
    }
    
    NSUInteger currentFlags = [event modifierFlags];
    static NSUInteger previousFlags = 0;
    
    // Check for Control key changes
    if ((currentFlags & NSControlKeyMask) != (previousFlags & NSControlKeyMask)) {
        BOOL pressed = (currentFlags & NSControlKeyMask) != 0;
        [_vncClient sendKeyboardEvent:0xFFE3 pressed:pressed]; // Left Control
    }
    
    // Check for Alt key changes
    if ((currentFlags & NSAlternateKeyMask) != (previousFlags & NSAlternateKeyMask)) {
        BOOL pressed = (currentFlags & NSAlternateKeyMask) != 0;
        [_vncClient sendKeyboardEvent:0xFFE9 pressed:pressed]; // Left Alt
    }
    
    // Check for Shift key changes
    if ((currentFlags & NSShiftKeyMask) != (previousFlags & NSShiftKeyMask)) {
        BOOL pressed = (currentFlags & NSShiftKeyMask) != 0;
        [_vncClient sendKeyboardEvent:0xFFE1 pressed:pressed]; // Left Shift
    }
    
    // Check for Command key changes
    if ((currentFlags & NSCommandKeyMask) != (previousFlags & NSCommandKeyMask)) {
        BOOL pressed = (currentFlags & NSCommandKeyMask) != 0;
        [_vncClient sendKeyboardEvent:0xFFEB pressed:pressed]; // Left Meta/Cmd
    }
    
    previousFlags = currentFlags;
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

- (void)windowWillClose:(NSNotification *)notification
{
    NSLog(@"VNCWindow: Window closing, notifying delegate");
    if (_vncDelegate && [_vncDelegate respondsToSelector:@selector(vncWindowWillClose:)]) {
        [_vncDelegate vncWindowWillClose:self];
    }
    [self disconnectFromVNC];
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
