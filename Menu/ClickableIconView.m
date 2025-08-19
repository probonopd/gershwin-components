#import "ClickableIconView.h"
#import "GTKStatusIconManager.h"
#import <X11/Xlib.h>
#import <X11/Xutil.h>
#import <X11/extensions/Xrender.h>
#import <unistd.h>

@implementation ClickableIconView

@synthesize embeddedWindow = _embeddedWindow;
@synthesize display = _display;
@synthesize manager = _manager;

- (instancetype)initWithFrame:(NSRect)frame window:(Window)window display:(Display *)display manager:(GTKStatusIconManager *)manager
{
    self = [super initWithFrame:frame];
    if (self) {
        _embeddedWindow = window;
        _display = display;
        _manager = manager;
        _updateTimer = nil;
        _eventMonitoringActive = NO;
        _eventMonitorThread = nil;
        _lastContentChecksum = NULL;
        _lastContentWidth = 0;
        _lastContentHeight = 0;
        
        NSLog(@"ClickableIconView: Created clickable view for window %lu with frame: %@", window, NSStringFromRect(frame));
    }
    return self;
}

- (void)drawRect:(NSRect)dirtyRect
{
    NSLog(@"ClickableIconView: Drawing rect %@ for window %lu", NSStringFromRect(dirtyRect), _embeddedWindow);
    
    // No border - just let the embedded icon show through cleanly
    NSLog(@"ClickableIconView: Clean display for embedded window %lu", _embeddedWindow);
}

- (void)mouseDown:(NSEvent *)event
{
    NSLog(@"ClickableIconView: Mouse down event for window %lu", _embeddedWindow);
    [self forwardMouseEvent:event];
}

- (void)rightMouseDown:(NSEvent *)event
{
    NSLog(@"ClickableIconView: Right mouse down event for window %lu", _embeddedWindow);
    [self forwardMouseEvent:event];
}

- (void)mouseEntered:(NSEvent *)event
{
    NSLog(@"ClickableIconView: Mouse entered for window %lu", _embeddedWindow);
    // Forward hover events to the embedded window
    [self forwardMouseEvent:event];
}

- (void)mouseExited:(NSEvent *)event
{
    NSLog(@"ClickableIconView: Mouse exited for window %lu", _embeddedWindow);
    // Forward hover events to the embedded window  
    [self forwardMouseEvent:event];
}

- (void)forwardMouseEvent:(NSEvent *)event
{
    if (!_display || _embeddedWindow == None) {
        return;
    }
    
    // Get the click location within our view
    NSPoint localPoint = [self convertPoint:[event locationInWindow] fromView:nil];
    
    int button = ([event type] == NSRightMouseDown) ? 3 : 1;
    
    NSLog(@"ClickableIconView: Forwarding mouse event (button %d) at local point (%.0f,%.0f) to window %lu", 
          button, localPoint.x, localPoint.y, _embeddedWindow);
    
    // Send events directly to the embedded window
    XEvent x11Event;
    memset(&x11Event, 0, sizeof(XEvent));
    
    x11Event.type = ButtonPress;
    x11Event.xbutton.window = _embeddedWindow;
    x11Event.xbutton.root = DefaultRootWindow(_display);
    x11Event.xbutton.subwindow = None;
    x11Event.xbutton.time = CurrentTime;
    x11Event.xbutton.x = (int)localPoint.x;
    x11Event.xbutton.y = (int)localPoint.y;
    x11Event.xbutton.x_root = (int)localPoint.x;
    x11Event.xbutton.y_root = (int)localPoint.y;
    x11Event.xbutton.state = 0;
    x11Event.xbutton.button = button;
    x11Event.xbutton.same_screen = True;
    
    // Send the button press event
    Status status = XSendEvent(_display, _embeddedWindow, False, ButtonPressMask, &x11Event);
    XFlush(_display);
    
    NSLog(@"ClickableIconView: Sent ButtonPress event to window %lu, status: %d", _embeddedWindow, status);
    
    // Send ButtonRelease
    x11Event.type = ButtonRelease;
    status = XSendEvent(_display, _embeddedWindow, False, ButtonReleaseMask, &x11Event);
    XFlush(_display);
    
    NSLog(@"ClickableIconView: Sent ButtonRelease event to window %lu, status: %d", _embeddedWindow, status);
}

- (void)performDeferredEmbedding
{
    NSLog(@"ClickableIconView: Performing deferred X11 embedding for window %lu", _embeddedWindow);
    
    if (!_display || _embeddedWindow == None) {
        NSLog(@"ClickableIconView: Invalid display or window for embedding");
        return;
    }
    
    // Get the NSView's position on screen
    NSRect viewFrame = [self frame];
    NSRect screenFrame = [[[self window] screen] frame];
    
    // Convert NSView coordinates to X11 screen coordinates
    NSPoint viewOrigin = [self convertPoint:NSZeroPoint toView:nil];
    NSPoint screenPoint = [[self window] convertBaseToScreen:viewOrigin];
    
    int x11X = (int)screenPoint.x;
    int x11Y = (int)(screenFrame.size.height - screenPoint.y - viewFrame.size.height);
    
    NSLog(@"ClickableIconView: NSView screen position: %d,%d size: %.0fx%.0f", 
          x11X, x11Y, viewFrame.size.width, viewFrame.size.height);
    
    // Scale to menu height with 2px padding (1px on each side)
    int iconSize = viewFrame.size.height - 2; // Menu height minus 2px total padding
    int offsetX = (viewFrame.size.width - iconSize) / 2;  // Center horizontally if view is wider
    int offsetY = 1; // 1px padding from top
    
    // Create a dedicated container window positioned over our NSView
    _containerWindow = XCreateSimpleWindow(_display, DefaultRootWindow(_display),
                                          x11X + offsetX, x11Y + offsetY, 
                                          iconSize, iconSize,
                                          0, 0, 0);
    
    if (_containerWindow == None) {
        NSLog(@"ClickableIconView: Failed to create container window");
        return;
    }
    
    // Set window attributes for transparency and positioning
    XSetWindowAttributes attrs;
    attrs.override_redirect = True;
    attrs.background_pixmap = ParentRelative;  // Transparent background
    attrs.border_pixel = 0;
    attrs.save_under = False;
    
    XChangeWindowAttributes(_display, _containerWindow, 
                           CWOverrideRedirect | CWBackPixmap | CWBorderPixel | CWSaveUnder, &attrs);
    
    // Map the container window
    XMapWindow(_display, _containerWindow);
    XFlush(_display);
    
    NSLog(@"ClickableIconView: Created container window %lu at %d,%d", _containerWindow, x11X + offsetX, x11Y + offsetY);
    
    // Reparent the tray icon to our container window
    XUnmapWindow(_display, _embeddedWindow);
    XFlush(_display);
    
    int result = XReparentWindow(_display, _embeddedWindow, _containerWindow, 0, 0);
    NSLog(@"ClickableIconView: XReparentWindow result: %d", result);
    
    // Resize the embedded window to fit the icon size (menu height - 2px)
    XMoveResizeWindow(_display, _embeddedWindow, 0, 0, iconSize, iconSize);
    
    // Map the embedded window
    XMapWindow(_display, _embeddedWindow);
    XFlush(_display);
    
    // Apply initial grayscale filter and set up content change monitoring
    [self applyGrayscaleFilter];
    [self setupContentChangeMonitoring];
    
    // Schedule a second grayscale application to catch any delayed content loading
    [self performSelector:@selector(applyGrayscaleFilter) withObject:nil afterDelay:1.0];
    
    // Verify the parent relationship
    Window root, parent;
    Window *children;
    unsigned int nchildren;
    if (XQueryTree(_display, _embeddedWindow, &root, &parent, &children, &nchildren)) {
        if (children) XFree(children);
        NSLog(@"ClickableIconView: After reparenting - window %lu parent: %lu (container: %lu)", 
              _embeddedWindow, parent, _containerWindow);
    }
    
    NSLog(@"ClickableIconView: X11 reparenting completed for window %lu", _embeddedWindow);
}

- (void)applyGrayscaleFilter
{
    if (!_display || _embeddedWindow == None || _containerWindow == None) {
        return;
    }
    
    NSLog(@"ClickableIconView: Applying grayscale filter to window %lu", _embeddedWindow);
    
    // Get window attributes for the embedded icon
    XWindowAttributes attrs;
    if (!XGetWindowAttributes(_display, _embeddedWindow, &attrs)) {
        NSLog(@"ClickableIconView: Failed to get window attributes for grayscale conversion");
        return;
    }
    
    // Capture the current window content
    XImage *originalImage = XGetImage(_display, _embeddedWindow, 0, 0, attrs.width, attrs.height, AllPlanes, ZPixmap);
    if (!originalImage) {
        NSLog(@"ClickableIconView: Failed to capture window image for grayscale conversion");
        return;
    }
    
    NSLog(@"ClickableIconView: Captured image %dx%d for grayscale conversion", attrs.width, attrs.height);
    
    // Get the color depth to handle different color formats
    int depth = attrs.depth;
    
    // Convert the image to grayscale pixel by pixel
    for (int y = 0; y < attrs.height; y++) {
        for (int x = 0; x < attrs.width; x++) {
            unsigned long pixel = XGetPixel(originalImage, x, y);
            
            if (depth >= 24) {
                // True color - extract RGB components
                unsigned char r, g, b;
                
                if (depth == 32) {
                    // ARGB format
                    r = (pixel >> 16) & 0xFF;
                    g = (pixel >> 8) & 0xFF;
                    b = pixel & 0xFF;
                } else {
                    // RGB format
                    r = (pixel >> 16) & 0xFF;
                    g = (pixel >> 8) & 0xFF;
                    b = pixel & 0xFF;
                }
                
                // Convert to grayscale using luminance formula (0% saturation)
                unsigned char gray = (unsigned char)(0.299 * r + 0.587 * g + 0.114 * b);
                
                // Create new pixel with grayscale value, preserving alpha if present
                unsigned long grayPixel;
                if (depth == 32) {
                    // Preserve alpha channel
                    unsigned char alpha = (pixel >> 24) & 0xFF;
                    grayPixel = (alpha << 24) | (gray << 16) | (gray << 8) | gray;
                } else {
                    grayPixel = (gray << 16) | (gray << 8) | gray;
                }
                
                // Set the grayscale pixel back
                XPutPixel(originalImage, x, y, grayPixel);
            }
        }
    }
    
    // Put the grayscale image back to the window
    GC gc = XCreateGC(_display, _embeddedWindow, 0, NULL);
    XPutImage(_display, _embeddedWindow, gc, originalImage, 0, 0, 0, 0, attrs.width, attrs.height);
    XFreeGC(_display, gc);
    XDestroyImage(originalImage);
    
    XFlush(_display);
    
    NSLog(@"ClickableIconView: Successfully applied grayscale conversion to window %lu", _embeddedWindow);
}

- (void)setupContentChangeMonitoring
{
    if (!_display || _embeddedWindow == None) {
        return;
    }
    
    // Stop any existing monitoring
    if (_eventMonitoringActive) {
        [self stopContentChangeMonitoring];
    }
    
    // Monitor the embedded window for content changes using event masks
    XSelectInput(_display, _embeddedWindow, ExposureMask | StructureNotifyMask | PropertyChangeMask);
    
    NSLog(@"ClickableIconView: Set up event-driven content change monitoring for window %lu", _embeddedWindow);
    
    // Start dedicated event monitoring thread
    _eventMonitoringActive = YES;
    _eventMonitorThread = [[NSThread alloc] initWithTarget:self 
                                                  selector:@selector(eventMonitoringThread) 
                                                    object:nil];
    [_eventMonitorThread start];
    
    NSLog(@"ClickableIconView: Started event-driven monitoring thread");
}

- (void)stopContentChangeMonitoring
{
    if (_eventMonitoringActive) {
        _eventMonitoringActive = NO;
        
        if (_eventMonitorThread) {
            // Cancel the thread and wait for it to finish
            [_eventMonitorThread cancel];
            while (![_eventMonitorThread isFinished]) {
                [NSThread sleepForTimeInterval:0.01];
            }
            [_eventMonitorThread release];
            _eventMonitorThread = nil;
        }
        
        NSLog(@"ClickableIconView: Stopped event monitoring");
    }
}

- (void)eventMonitoringThread
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    NSLog(@"ClickableIconView: Event monitoring thread started for window %lu", _embeddedWindow);
    
    while (_eventMonitoringActive && ![[NSThread currentThread] isCancelled]) {
        @try {
            BOOL shouldCheckContent = NO;
            
            // Check for events without blocking for too long
            XEvent event;
            if (XCheckWindowEvent(_display, _embeddedWindow, ExposureMask | StructureNotifyMask | PropertyChangeMask, &event)) {
                if (event.type == Expose) {
                    NSLog(@"ClickableIconView: Expose event detected for window %lu", _embeddedWindow);
                    shouldCheckContent = YES;
                } else if (event.type == ConfigureNotify) {
                    NSLog(@"ClickableIconView: ConfigureNotify event detected for window %lu", _embeddedWindow);
                    shouldCheckContent = YES;
                } else if (event.type == PropertyNotify) {
                    NSLog(@"ClickableIconView: PropertyNotify event detected for window %lu", _embeddedWindow);
                    shouldCheckContent = YES;
                }
            }
            
            // Also do periodic content checks to catch changes we might miss
            static NSTimeInterval lastContentCheck = 0;
            NSTimeInterval currentTime = [[NSDate date] timeIntervalSince1970];
            if (currentTime - lastContentCheck >= 2.0) {  // Check every 2 seconds as fallback
                shouldCheckContent = YES;
                lastContentCheck = currentTime;
            }
            
            if (shouldCheckContent) {
                // Check if content actually changed visually
                if ([self hasContentActuallyChanged]) {
                    NSLog(@"ClickableIconView: Visual content change detected for window %lu, applying grayscale", _embeddedWindow);
                    // Apply grayscale on the main thread
                    [self performSelectorOnMainThread:@selector(applyGrayscaleFilter) 
                                           withObject:nil 
                                        waitUntilDone:NO];
                }
            }
            
            // Small sleep to prevent excessive CPU usage
            [NSThread sleepForTimeInterval:0.1];
            
        } @catch (NSException *exception) {
            NSLog(@"ClickableIconView: Exception in event monitoring thread: %@", exception);
            break;
        }
    }
    
    NSLog(@"ClickableIconView: Event monitoring thread ending for window %lu", _embeddedWindow);
    [pool drain];
}

- (void)viewDidMoveToWindow
{
    [super viewDidMoveToWindow];
    
    // When the view is added to a window, schedule the X11 embedding
    if ([self window]) {
        NSLog(@"ClickableIconView: View added to window, scheduling deferred embedding");
        [self performSelector:@selector(performDeferredEmbedding) withObject:nil afterDelay:0.1];
    }
}

- (void)dealloc
{
    // Stop event monitoring
    [self stopContentChangeMonitoring];
    
    if (_updateTimer) {
        [_updateTimer invalidate];
        [_updateTimer release];
        _updateTimer = nil;
    }
    
    // Free content checksum memory
    if (_lastContentChecksum) {
        free(_lastContentChecksum);
        _lastContentChecksum = NULL;
    }
    
    [_manager release];
    [super dealloc];
}

- (BOOL)hasContentActuallyChanged
{
    if (!_display || _embeddedWindow == None) {
        return NO;
    }
    
    // Get window attributes
    XWindowAttributes attrs;
    if (!XGetWindowAttributes(_display, _embeddedWindow, &attrs)) {
        return NO;
    }
    
    // Capture current window content
    XImage *currentImage = XGetImage(_display, _embeddedWindow, 0, 0, attrs.width, attrs.height, AllPlanes, ZPixmap);
    if (!currentImage) {
        return NO;
    }
    
    // Calculate a simple checksum of the current content
    unsigned int currentChecksum = 0;
    
    for (int y = 0; y < attrs.height; y++) {
        for (int x = 0; x < attrs.width; x++) {
            unsigned long pixel = XGetPixel(currentImage, x, y);
            // Simple checksum - sum of all pixel values
            currentChecksum += (unsigned int)pixel;
        }
    }
    
    BOOL contentChanged = NO;
    
    // Check if this is the first time or if dimensions changed
    if (!_lastContentChecksum || _lastContentWidth != attrs.width || _lastContentHeight != attrs.height) {
        contentChanged = YES;
        NSLog(@"ClickableIconView: Content dimensions changed or first check for window %lu (%dx%d)", _embeddedWindow, attrs.width, attrs.height);
    } else {
        // Compare current checksum with stored checksum
        unsigned int *storedChecksum = (unsigned int*)_lastContentChecksum;
        if (*storedChecksum != currentChecksum) {
            contentChanged = YES;
            NSLog(@"ClickableIconView: Content checksum changed for window %lu (old: %u, new: %u)", _embeddedWindow, *storedChecksum, currentChecksum);
        }
    }
    
    // Update stored checksum and dimensions
    if (contentChanged) {
        if (_lastContentChecksum) {
            free(_lastContentChecksum);
        }
        _lastContentChecksum = malloc(sizeof(unsigned int));
        *((unsigned int*)_lastContentChecksum) = currentChecksum;
        _lastContentWidth = attrs.width;
        _lastContentHeight = attrs.height;
    }
    
    XDestroyImage(currentImage);
    return contentChanged;
}

@end
