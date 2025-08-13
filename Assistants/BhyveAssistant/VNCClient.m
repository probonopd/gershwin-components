//
// VNCClient.m  
// Bhyve Assistant - VNC Client using libvncclient
//

#import "VNCClient.h"
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>
#import <errno.h>
#import <dlfcn.h>

// libvncclient includes
#include <rfb/rfbclient.h>

@implementation VNCClient

@synthesize hostname = _hostname;
@synthesize port = _port;
@synthesize password = _password;
@synthesize connected = _connected;
@synthesize connecting = _connecting;
@synthesize width = _width;
@synthesize height = _height;
@synthesize depth = _depth;
@synthesize delegate = _delegate;

#pragma mark - Initialization

- (id)init
{
    self = [super init];
    if (self) {
        _rfbClient = NULL;
        _hostname = nil;
        _port = 5900;
        _password = nil;
        _connected = NO;
        _connecting = NO;
        _width = 0;
        _height = 0;
        _depth = 0;
        _framebuffer = NULL;
        _framebufferSize = NSZeroSize;
        _connectionThread = nil;
        _shouldStop = NO;
        _delegate = nil;
    }
    return self;
}

- (void)dealloc
{
    [self disconnect];
    [_hostname release];
    [_password release];
    [super dealloc];
}

#pragma mark - Class Methods

+ (BOOL)isLibVNCClientAvailable
{
    // Try to load libvncclient
    void *handle = dlopen("libvncclient.so", RTLD_LAZY);
    if (!handle) {
        handle = dlopen("/usr/local/lib/libvncclient.so", RTLD_LAZY);
    }
    if (!handle) {
        handle = dlopen("/usr/lib/libvncclient.so", RTLD_LAZY);
    }
    
    if (handle) {
        dlclose(handle);
        return YES;
    }
    
    NSLog(@"VNCClient: libvncclient not found. Install libvncserver package.");
    return NO;
}

#pragma mark - libvncclient Callbacks

// Callback for password authentication
static char *VNCGetPassword(rfbClient *client)
{
    VNCClient *vncClient = (VNCClient *)rfbClientGetClientData(client, NULL);
    if (vncClient && vncClient->_password) {
        const char *password = [vncClient->_password UTF8String];
        return strdup(password);
    }
    return NULL;
}

// Callback for framebuffer size changes
static rfbBool VNCMallocFrameBuffer(rfbClient *client)
{
    VNCClient *vncClient = (VNCClient *)rfbClientGetClientData(client, NULL);
    if (!vncClient) {
        return FALSE;
    }
    
    NSLog(@"VNCClient: Framebuffer size: %dx%d, depth: %d, bpp: %d",
          client->width, client->height, client->format.depth, client->format.bitsPerPixel);
    
    // Free old framebuffer
    if (vncClient->_framebuffer) {
        free(vncClient->_framebuffer);
        vncClient->_framebuffer = NULL;
    }
    
    // Update size information
    vncClient->_width = client->width;
    vncClient->_height = client->height;
    vncClient->_depth = client->format.bitsPerPixel;
    vncClient->_framebufferSize = NSMakeSize(client->width, client->height);
    
    // Allocate new framebuffer
    int bytesPerPixel = client->format.bitsPerPixel / 8;
    size_t bufferSize = client->width * client->height * bytesPerPixel;
    
    vncClient->_framebuffer = (unsigned char *)malloc(bufferSize);
    if (!vncClient->_framebuffer) {
        NSLog(@"VNCClient: Failed to allocate framebuffer of size %zu", bufferSize);
        return FALSE;
    }
    
    client->frameBuffer = vncClient->_framebuffer;
    
    // Accept the server's pixel format instead of forcing our own
    // The server reported: "shift red 16 green 8 blue 0" which is RGB format
    // Let's use the server's format and handle color conversion in the image creation
    NSLog(@"VNCClient: Using server pixel format - red:%d green:%d blue:%d",
          client->format.redShift, client->format.greenShift, client->format.blueShift);
    
    // Don't call SetFormatAndEncodings() to avoid changing the server's format
    
    // Notify delegate on main thread
    if (vncClient->_delegate && [vncClient->_delegate respondsToSelector:@selector(vncClient:framebufferDidUpdate:)]) {
        NSRect fullRect = NSMakeRect(0, 0, client->width, client->height);
        [vncClient performSelectorOnMainThread:@selector(notifyFramebufferUpdate:)
                                    withObject:[NSValue valueWithRect:fullRect]
                                 waitUntilDone:NO];
    }
    
    return TRUE;
}

// Callback for framebuffer updates
static void VNCGotFrameBufferUpdate(rfbClient *client, int x, int y, int w, int h)
{
    VNCClient *vncClient = (VNCClient *)rfbClientGetClientData(client, NULL);
    if (!vncClient) {
        return;
    }
    
    // Notify delegate on main thread
    if (vncClient->_delegate && [vncClient->_delegate respondsToSelector:@selector(vncClient:framebufferDidUpdate:)]) {
        NSRect updateRect = NSMakeRect(x, y, w, h);
        [vncClient performSelectorOnMainThread:@selector(notifyFramebufferUpdate:)
                                    withObject:[NSValue valueWithRect:updateRect]
                                 waitUntilDone:NO];
    }
}

// Log callback with more detailed error information
static void VNCLog(const char *format, ...)
{
    va_list args;
    va_start(args, format);
    
    char buffer[1024];
    vsnprintf(buffer, sizeof(buffer), format, args);
    NSLog(@"VNCClient libvncclient: %s", buffer);
    
    va_end(args);
}

// Error callback
static void VNCErr(const char *format, ...)
{
    va_list args;
    va_start(args, format);
    
    char buffer[1024];
    vsnprintf(buffer, sizeof(buffer), format, args);
    NSLog(@"VNCClient libvncclient ERROR: %s", buffer);
    
    va_end(args);
}

#pragma mark - Connection Management

- (BOOL)connectToHost:(NSString *)hostname port:(NSInteger)port
{
    return [self connectToHost:hostname port:port password:nil];
}

- (BOOL)connectToHost:(NSString *)hostname port:(NSInteger)port password:(NSString *)password
{
    if (_connecting || _connected) {
        NSLog(@"VNCClient: Already connecting or connected");
        return NO;
    }
    
    if (![VNCClient isLibVNCClientAvailable]) {
        if (_delegate && [_delegate respondsToSelector:@selector(vncClient:didReceiveError:)]) {
            [_delegate vncClient:self didReceiveError:@"libvncclient not available"];
        }
        return NO;
    }
    
    [_hostname release];
    _hostname = [hostname copy];
    _port = port;
    [_password release];
    _password = [password copy];
    
    _connecting = YES;
    _shouldStop = NO;
    
    // Start connection in background thread
    _connectionThread = [[NSThread alloc] initWithTarget:self 
                                               selector:@selector(connectionThreadMain:) 
                                                 object:nil];
    [_connectionThread start];
    
    return YES;
}

- (void)disconnect
{
    NSLog(@"VNCClient: Disconnecting...");
    
    _shouldStop = YES;
    _connecting = NO;
    
    // Close VNC connection
    if (_rfbClient) {
        rfbClient *client = (rfbClient *)_rfbClient;
        rfbClientCleanup(client);
        _rfbClient = NULL;
    }
    
    // Wait for connection thread to finish
    if (_connectionThread && ![_connectionThread isFinished]) {
        [_connectionThread cancel];
        // Give thread time to finish gracefully
        for (int i = 0; i < 10 && ![_connectionThread isFinished]; i++) {
            [NSThread sleepForTimeInterval:0.1];
        }
    }
    [_connectionThread release];
    _connectionThread = nil;
    
    // Free framebuffer
    if (_framebuffer) {
        free(_framebuffer);
        _framebuffer = NULL;
    }
    
    _connected = NO;
    _width = 0;
    _height = 0;
    _depth = 0;
    _framebufferSize = NSZeroSize;
    
    // Notify delegate
    if (_delegate && [_delegate respondsToSelector:@selector(vncClient:didDisconnect:)]) {
        [self performSelectorOnMainThread:@selector(notifyDisconnect:)
                               withObject:@"User requested disconnect"
                            waitUntilDone:NO];
    }
}

#pragma mark - Connection Thread

- (void)connectionThreadMain:(id)object
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    NSLog(@"VNCClient: Starting connection to %@:%ld", _hostname, (long)_port);
    
    // Initialize libvncclient
    rfbClientLog = VNCLog;
    rfbClientErr = VNCErr;
    
    _rfbClient = rfbGetClient(8, 3, 4); // 8 bits per sample, 3 samples per pixel, 4 bytes per pixel
    if (!_rfbClient) {
        NSLog(@"VNCClient: Failed to create RFB client");
        [self notifyConnectionResult:NO error:@"Failed to create RFB client"];
        goto cleanup;
    }
    
    rfbClient *client = (rfbClient *)_rfbClient;
    
    // Set up client data and callbacks
    rfbClientSetClientData(client, NULL, self);
    client->GetPassword = VNCGetPassword;
    client->MallocFrameBuffer = VNCMallocFrameBuffer;
    client->GotFrameBufferUpdate = VNCGotFrameBufferUpdate;
    
    // Configure client settings for better compatibility
    client->canHandleNewFBSize = TRUE;
    client->format.depth = 24;
    client->format.bitsPerPixel = 32;
    client->format.trueColour = TRUE;
    
    // Connection parameters - ensure we use IPv4 address
    client->serverHost = strdup([_hostname UTF8String]);
    client->serverPort = (int)_port;
    
    NSLog(@"VNCClient: Attempting to connect to %s:%d", client->serverHost, client->serverPort);
    
    // Add connection timeout handling
    int connectResult = 0;
    for (int attempt = 0; attempt < 3; attempt++) {
        if (_shouldStop) {
            NSLog(@"VNCClient: Connection cancelled before attempt %d", attempt + 1);
            [self notifyConnectionResult:NO error:@"Connection cancelled"];
            goto cleanup;
        }
        
        NSLog(@"VNCClient: Connection attempt %d/3", attempt + 1);
        
        // Try to connect
        connectResult = rfbInitClient(client, NULL, NULL);
        if (connectResult) {
            NSLog(@"VNCClient: Connection successful on attempt %d", attempt + 1);
            break;
        }
        
        NSLog(@"VNCClient: Connection attempt %d failed, waiting before retry...", attempt + 1);
        if (attempt < 2) { // Don't sleep after the last attempt
            sleep(2);
        }
    }
    
    if (!connectResult) {
        NSLog(@"VNCClient: All connection attempts failed");
        [self notifyConnectionResult:NO error:@"Failed to connect to VNC server after multiple attempts"];
        goto cleanup;
    }
    
    NSLog(@"VNCClient: Successfully connected to %@:%ld", _hostname, (long)_port);
    _connected = YES;
    _connecting = NO;
    
    [self notifyConnectionResult:YES error:nil];
    
    // Main message loop
    int maxFd;
    fd_set readfds;
    struct timeval timeout;
    
    while (!_shouldStop && _connected) {
        // Set up file descriptor set
        FD_ZERO(&readfds);
        FD_SET(client->sock, &readfds);
        maxFd = client->sock + 1;
        
        // Timeout for select
        timeout.tv_sec = 0;
        timeout.tv_usec = 100000; // 100ms timeout
        
        int result = select(maxFd, &readfds, NULL, NULL, &timeout);
        
        if (result < 0) {
            if (errno == EINTR) {
                continue; // Interrupted by signal, try again
            }
            NSLog(@"VNCClient: select() error: %s", strerror(errno));
            break;
        }
        
        if (result > 0 && FD_ISSET(client->sock, &readfds)) {
            // Handle RFB messages
            int msgResult = HandleRFBServerMessage(client);
            if (msgResult == FALSE) {
                NSLog(@"VNCClient: HandleRFBServerMessage failed");
                break;
            }
        }
        
        // Small delay to prevent busy waiting
        usleep(1000); // 1ms
    }
    
cleanup:
    NSLog(@"VNCClient: Connection thread ending");
    
    if (_rfbClient) {
        rfbClient *client = (rfbClient *)_rfbClient;
        if (client->serverHost) {
            free(client->serverHost);
            client->serverHost = NULL;
        }
        rfbClientCleanup(client);
        _rfbClient = NULL;
    }
    
    _connected = NO;
    _connecting = NO;
    
    if (!_shouldStop) {
        // Unexpected disconnection
        [self notifyConnectionResult:NO error:@"Connection lost"];
    }
    
    [pool release];
}

- (void)notifyConnectionResult:(BOOL)success error:(NSString *)error
{
    if (_delegate) {
        [self performSelectorOnMainThread:@selector(notifyConnectionOnMainThread:)
                               withObject:@{@"success": @(success), @"error": error ? error : @""}
                            waitUntilDone:NO];
    }
}

#pragma mark - Input Handling

- (void)sendKeyboardEvent:(NSUInteger)key pressed:(BOOL)pressed
{
    if (!_connected || !_rfbClient) {
        return;
    }
    
    rfbClient *client = (rfbClient *)_rfbClient;
    SendKeyEvent(client, (uint32_t)key, pressed ? TRUE : FALSE);
}

- (void)sendMouseEvent:(NSPoint)position buttons:(NSUInteger)buttonMask
{
    if (!_connected || !_rfbClient) {
        return;
    }
    
    rfbClient *client = (rfbClient *)_rfbClient;
    
    // Convert position to VNC coordinates (flip Y axis)
    int x = (int)position.x;
    int y = (int)(_height - position.y); // Flip Y coordinate
    
    // Clamp to framebuffer bounds
    if (x < 0) x = 0;
    if (y < 0) y = 0;
    if (x >= _width) x = _width - 1;
    if (y >= _height) y = _height - 1;
    
    SendPointerEvent(client, x, y, (int)buttonMask);
}

- (void)sendMouseMoveEvent:(NSPoint)position
{
    [self sendMouseEvent:position buttons:0];
}

- (void)sendMouseButtonEvent:(NSUInteger)button pressed:(BOOL)pressed position:(NSPoint)position
{
    if (!_connected || !_rfbClient) {
        return;
    }
    
    static NSUInteger currentButtonMask = 0;
    
    if (pressed) {
        currentButtonMask |= (1 << (button - 1));
    } else {
        currentButtonMask &= ~(1 << (button - 1));
    }
    
    [self sendMouseEvent:position buttons:currentButtonMask];
}

#pragma mark - Framebuffer Access

- (NSData *)framebufferData
{
    if (!_framebuffer || _width == 0 || _height == 0) {
        return nil;
    }
    
    int bytesPerPixel = _depth / 8;
    size_t bufferSize = _width * _height * bytesPerPixel;
    
    return [NSData dataWithBytes:_framebuffer length:bufferSize];
}

- (NSImage *)framebufferImage
{
    if (!_framebuffer || _width == 0 || _height == 0) {
        return nil;
    }
    
    static unsigned char *staticConvertedBuffer = NULL;
    static size_t staticBufferSize = 0;
    
    int bytesPerPixel = 4; // Always use 32-bit RGBA
    size_t bufferSize = _width * _height * bytesPerPixel;
    
    // Reuse buffer to reduce memory allocation overhead
    if (staticBufferSize != bufferSize) {
        if (staticConvertedBuffer) {
            free(staticConvertedBuffer);
        }
        staticConvertedBuffer = (unsigned char *)malloc(bufferSize);
        staticBufferSize = bufferSize;
    }
    
    if (!staticConvertedBuffer) {
        return nil;
    }
    
    // Fast memory copy and conversion from server's RGB format to RGBA
    uint32_t *sourcePixels = (uint32_t*)_framebuffer;
    uint32_t *destPixels = (uint32_t*)staticConvertedBuffer;
    
    for (int i = 0; i < _width * _height; i++) {
        uint32_t pixel = sourcePixels[i];
        
        // Extract RGB components and reorder for NSBitmapImageRep
        unsigned char red = (pixel >> 16) & 0xFF;
        unsigned char green = (pixel >> 8) & 0xFF;
        unsigned char blue = pixel & 0xFF;
        
        // Pack into RGBA format as a single 32-bit write
        destPixels[i] = (0xFF << 24) | (blue << 16) | (green << 8) | red;
    }
    
    // Create bitmap representation with converted data
    NSBitmapImageRep *bitmapRep = [[NSBitmapImageRep alloc] 
        initWithBitmapDataPlanes:&staticConvertedBuffer
                      pixelsWide:_width
                      pixelsHigh:_height
                   bitsPerSample:8
                 samplesPerPixel:4
                        hasAlpha:YES
                        isPlanar:NO
                  colorSpaceName:NSDeviceRGBColorSpace
                     bytesPerRow:_width * bytesPerPixel
                    bitsPerPixel:32];
    
    if (!bitmapRep) {
        return nil;
    }
    
    // Create NSImage with caching to improve performance
    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(_width, _height)];
    [image setCacheMode:NSImageCacheAlways];
    [image addRepresentation:bitmapRep];
    [bitmapRep release];
    
    return [image autorelease];
}

- (void)requestFramebufferUpdate:(NSRect)rect incremental:(BOOL)incremental
{
    if (!_connected || !_rfbClient) {
        return;
    }
    
    rfbClient *client = (rfbClient *)_rfbClient;
    SendFramebufferUpdateRequest(client, 
                                (int)rect.origin.x, 
                                (int)rect.origin.y,
                                (int)rect.size.width, 
                                (int)rect.size.height,
                                incremental ? TRUE : FALSE);
}

- (void)requestFullFramebufferUpdate
{
    if (_width > 0 && _height > 0) {
        NSRect fullRect = NSMakeRect(0, 0, _width, _height);
        [self requestFramebufferUpdate:fullRect incremental:NO];
    }
}

#pragma mark - Main Thread Callback Helpers

- (void)notifyFramebufferUpdate:(NSValue *)rectValue
{
    NSRect rect = [rectValue rectValue];
    if (_delegate && [_delegate respondsToSelector:@selector(vncClient:framebufferDidUpdate:)]) {
        [_delegate vncClient:self framebufferDidUpdate:rect];
    }
}

- (void)notifyDisconnect:(NSString *)reason
{
    if (_delegate && [_delegate respondsToSelector:@selector(vncClient:didDisconnect:)]) {
        [_delegate vncClient:self didDisconnect:reason];
    }
}

- (void)notifyConnectionOnMainThread:(NSDictionary *)info
{
    BOOL success = [[info objectForKey:@"success"] boolValue];
    NSString *error = [info objectForKey:@"error"];
    
    if (success && [_delegate respondsToSelector:@selector(vncClient:didConnect:)]) {
        [_delegate vncClient:self didConnect:YES];
    } else if (!success) {
        if ([_delegate respondsToSelector:@selector(vncClient:didConnect:)]) {
            [_delegate vncClient:self didConnect:NO];
        }
        if (error && [error length] > 0 && [_delegate respondsToSelector:@selector(vncClient:didReceiveError:)]) {
            [_delegate vncClient:self didReceiveError:error];
        }
    }
}

@end
