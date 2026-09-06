/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

//
// RDPClient.m
// Remote Desktop - RDP Client using FreeRDP
//

#import "RDPClient.h"
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>
#import <errno.h>
#import <dlfcn.h>

// When FreeRDP is available we build the real RDP backend; otherwise the
// methods that depend on it become no-ops and isFreeRDPAvailable reports NO,
// so the app still builds and VNC keeps working.
#ifdef HAVE_FREERDP

// FreeRDP includes
#include <freerdp/freerdp.h>
#include <freerdp/constants.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/client/cmdline.h>
#include <freerdp/channels/channels.h>
#include <winpr/wlog.h>

// Custom context structure
typedef struct {
    rdpContext context;
    RDPClient *client;
} RDPCustomContext;

// Suppress deprecation warnings for FreeRDP 3 settings that are still functional
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"

#endif /* HAVE_FREERDP */

@implementation RDPClient

@synthesize hostname = _hostname;
@synthesize port = _port;
@synthesize username = _username;
@synthesize password = _password;
@synthesize domain = _domain;
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
        _rdpContext = NULL;
        _hostname = nil;
        _port = 3389;
        _username = nil;
        _password = nil;
        _domain = nil;
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
    [_username release];
    [_password release];
    [_domain release];
    [super dealloc];
}

#pragma mark - Class Methods

+ (BOOL)isFreeRDPAvailable
{
    // Try to load libfreerdp
    void *handle = dlopen("libfreerdp2.so", RTLD_LAZY);
    if (!handle) {
        handle = dlopen("libfreerdp3.so", RTLD_LAZY);
    }
    if (!handle) {
        handle = dlopen("/usr/local/lib/libfreerdp2.so", RTLD_LAZY);
    }
    if (!handle) {
        handle = dlopen("/usr/lib/libfreerdp2.so", RTLD_LAZY);
    }
    if (!handle) {
        handle = dlopen("/usr/lib/x86_64-linux-gnu/libfreerdp2.so", RTLD_LAZY);
    }
    
    if (handle) {
        dlclose(handle);
        return YES;
    }
    
    NSDebugLLog(@"gwcomp", @"RDPClient: libfreerdp not found. Install freerdp2 package.");
    return NO;
}

#pragma mark - FreeRDP Callbacks

#ifdef HAVE_FREERDP

static BOOL rdp_pre_connect(freerdp *instance)
{
    RDPCustomContext *customContext = (RDPCustomContext *)instance->context;
    (void)customContext; // Unused but kept for consistency
    
    NSDebugLLog(@"gwcomp", @"RDPClient: Pre-connect callback");
    
    rdpSettings *settings = instance->context->settings;
    
    // Set up GDI
    settings->ColorDepth = 32;
    settings->SoftwareGdi = TRUE;
    
    // Request reasonable initial desktop size
    if (settings->DesktopWidth == 0) {
        settings->DesktopWidth = 1024;
    }
    if (settings->DesktopHeight == 0) {
        settings->DesktopHeight = 768;
    }
    
    return TRUE;
}

static BOOL rdp_post_connect(freerdp *instance)
{
    RDPCustomContext *customContext = (RDPCustomContext *)instance->context;
    RDPClient *client = customContext->client;
    
    NSDebugLLog(@"gwcomp", @"RDPClient: Post-connect callback");
    
    rdpGdi *gdi = instance->context->gdi;
    if (!gdi) {
        if (!gdi_init(instance, PIXEL_FORMAT_BGRA32)) {
            NSDebugLLog(@"gwcomp", @"RDPClient: Failed to initialize GDI");
            return FALSE;
        }
        gdi = instance->context->gdi;
    }
    
    client->_width = gdi->width;
    client->_height = gdi->height;
    client->_depth = 32;
    client->_framebufferSize = NSMakeSize(gdi->width, gdi->height);
    
    // Allocate framebuffer
    size_t bufferSize = client->_width * client->_height * 4;
    if (client->_framebuffer) {
        free(client->_framebuffer);
    }
    client->_framebuffer = (unsigned char *)malloc(bufferSize);
    
    if (!client->_framebuffer) {
        NSDebugLLog(@"gwcomp", @"RDPClient: Failed to allocate framebuffer");
        return FALSE;
    }
    
    NSDebugLLog(@"gwcomp", @"RDPClient: Connected with resolution %ldx%ld", (long)client->_width, (long)client->_height);
    
    return TRUE;
}

static void rdp_post_disconnect(freerdp *instance)
{
    RDPCustomContext *customContext = (RDPCustomContext *)instance->context;
    (void)customContext; // Unused but kept for consistency
    
    NSDebugLLog(@"gwcomp", @"RDPClient: Post-disconnect callback");
    
    if (instance->context->gdi) {
        gdi_free(instance);
    }
}

static BOOL rdp_begin_paint(rdpContext *context)
{
    rdpGdi *gdi = context->gdi;
    if (gdi) {
        gdi->primary->hdc->hwnd->invalid->null = TRUE;
    }
    return TRUE;
}

static BOOL rdp_end_paint(rdpContext *context)
{
    RDPCustomContext *customContext = (RDPCustomContext *)context;
    RDPClient *client = customContext->client;
    
    rdpGdi *gdi = context->gdi;
    if (!gdi || !gdi->primary || !gdi->primary->hdc || !gdi->primary->hdc->hwnd) {
        return TRUE;
    }
    
    HGDI_RGN invalid = gdi->primary->hdc->hwnd->invalid;
    if (invalid->null) {
        return TRUE;
    }
    
    // Copy updated region to our framebuffer
    if (client->_framebuffer && gdi->primary_buffer) {
        int x = invalid->x;
        int y = invalid->y;
        int w = invalid->w;
        int h = invalid->h;
        
        // Clamp to valid region
        if (x < 0) x = 0;
        if (y < 0) y = 0;
        if (x + w > client->_width) w = client->_width - x;
        if (y + h > client->_height) h = client->_height - y;
        
        if (w > 0 && h > 0) {
            int bytesPerPixel = 4;
            int stride = client->_width * bytesPerPixel;
            
            for (int row = 0; row < h; row++) {
                unsigned char *src = gdi->primary_buffer + ((y + row) * stride) + (x * bytesPerPixel);
                unsigned char *dst = client->_framebuffer + ((y + row) * stride) + (x * bytesPerPixel);
                memcpy(dst, src, w * bytesPerPixel);
            }
        }
        
        // Notify delegate
        if (client->_delegate && [client->_delegate respondsToSelector:@selector(rdpClient:framebufferDidUpdate:)]) {
            NSRect updateRect = NSMakeRect(x, y, w, h);
            [client performSelectorOnMainThread:@selector(notifyFramebufferUpdate:)
                                     withObject:[NSValue valueWithRect:updateRect]
                                  waitUntilDone:NO];
        }
    }
    
    return TRUE;
}

static BOOL rdp_authenticate(freerdp *instance, char **username, char **password, char **domain)
{
    RDPCustomContext *customContext = (RDPCustomContext *)instance->context;
    RDPClient *client = customContext->client;
    
    NSDebugLLog(@"gwcomp", @"RDPClient: Authentication callback");
    
    // Return credentials if available
    if (client->_username && [client->_username length] > 0) {
        *username = strdup([client->_username UTF8String]);
    }
    if (client->_password && [client->_password length] > 0) {
        *password = strdup([client->_password UTF8String]);
    }
    if (client->_domain && [client->_domain length] > 0) {
        *domain = strdup([client->_domain UTF8String]);
    }
    
    return TRUE;
}

#endif /* HAVE_FREERDP */

#pragma mark - Connection Management

- (BOOL)connectToHost:(NSString *)hostname port:(NSInteger)port
{
    return [self connectToHost:hostname port:port username:nil password:nil domain:nil];
}

- (BOOL)connectToHost:(NSString *)hostname port:(NSInteger)port 
             username:(NSString *)username password:(NSString *)password
{
    return [self connectToHost:hostname port:port username:username password:password domain:nil];
}

- (BOOL)connectToHost:(NSString *)hostname port:(NSInteger)port 
             username:(NSString *)username password:(NSString *)password 
               domain:(NSString *)domain
{
    if (_connecting || _connected) {
        NSDebugLLog(@"gwcomp", @"RDPClient: Already connecting or connected");
        return NO;
    }
    
    if (![RDPClient isFreeRDPAvailable]) {
        if (_delegate && [_delegate respondsToSelector:@selector(rdpClient:didReceiveError:)]) {
            [_delegate rdpClient:self didReceiveError:@"FreeRDP library not available"];
        }
        return NO;
    }
    
    [_hostname release];
    _hostname = [hostname copy];
    _port = port;
    [_username release];
    _username = [username copy];
    [_password release];
    _password = [password copy];
    [_domain release];
    _domain = [domain copy];
    
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
    NSDebugLLog(@"gwcomp", @"RDPClient: Disconnecting...");
    
    _shouldStop = YES;
    _connecting = NO;
    
    // Close RDP connection
    if (_rdpContext) {
#ifdef HAVE_FREERDP
        RDPCustomContext *customContext = (RDPCustomContext *)_rdpContext;
        freerdp *instance = customContext->context.instance;
        
        if (instance) {
            freerdp_disconnect(instance);
            freerdp_context_free(instance);
            freerdp_free(instance);
        }
#endif /* HAVE_FREERDP */
        
        _rdpContext = NULL;
    }
    
    // Wait for connection thread to finish
    if (_connectionThread && ![_connectionThread isFinished]) {
        [_connectionThread cancel];
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
    if (_delegate && [_delegate respondsToSelector:@selector(rdpClient:didDisconnect:)]) {
        [self performSelectorOnMainThread:@selector(notifyDisconnect:)
                               withObject:@"User requested disconnect"
                            waitUntilDone:NO];
    }
}

#pragma mark - Connection Thread

#ifdef HAVE_FREERDP

- (void)connectionThreadMain:(id)object
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    NSDebugLLog(@"gwcomp", @"RDPClient: Starting connection to %@:%ld", _hostname, (long)_port);
    
    // Enable FreeRDP verbose logging
    wLog* root = WLog_GetRoot();
    if (root) {
        WLog_SetLogLevel(root, WLOG_TRACE);
        NSDebugLLog(@"gwcomp", @"RDPClient: FreeRDP verbose logging enabled (TRACE level)");
    } else {
        NSDebugLLog(@"gwcomp", @"RDPClient: WARNING - Could not get wLog root for verbose logging");
    }
    
    // Create FreeRDP instance
    freerdp *instance = freerdp_new();
    if (!instance) {
        NSDebugLLog(@"gwcomp", @"RDPClient: Failed to create FreeRDP instance");
        [self notifyConnectionResult:NO error:@"Failed to create RDP client"];
        goto cleanup;
    }
    
    // Allocate custom context
    instance->ContextSize = sizeof(RDPCustomContext);
    
    if (!freerdp_context_new(instance)) {
        NSDebugLLog(@"gwcomp", @"RDPClient: Failed to create RDP context");
        freerdp_free(instance);
        [self notifyConnectionResult:NO error:@"Failed to create RDP context"];
        goto cleanup;
    }
    
    RDPCustomContext *customContext = (RDPCustomContext *)instance->context;
    customContext->client = self;
    _rdpContext = customContext;
    
    // Set callbacks
    instance->PreConnect = rdp_pre_connect;
    instance->PostConnect = rdp_post_connect;
    instance->PostDisconnect = rdp_post_disconnect;
    instance->Authenticate = rdp_authenticate;
    
    // Set paint callbacks
    instance->context->update->BeginPaint = rdp_begin_paint;
    instance->context->update->EndPaint = rdp_end_paint;
    
    // Configure settings
    rdpSettings *settings = instance->context->settings;
    
    settings->ServerHostname = strdup([_hostname UTF8String]);
    settings->ServerPort = (UINT32)_port;
    
    if (_username && [_username length] > 0) {
        settings->Username = strdup([_username UTF8String]);
    }
    if (_password && [_password length] > 0) {
        settings->Password = strdup([_password UTF8String]);
    }
    if (_domain && [_domain length] > 0) {
        settings->Domain = strdup([_domain UTF8String]);
    }
    
    // Connection settings
    settings->DesktopWidth = 1024;
    settings->DesktopHeight = 768;
    settings->ColorDepth = 32;
    settings->SoftwareGdi = TRUE;
    settings->IgnoreCertificate = TRUE;
    
    NSDebugLLog(@"gwcomp", @"RDPClient: Attempting to connect to %s:%u", settings->ServerHostname, settings->ServerPort);
    
    // Connect
    if (!freerdp_connect(instance)) {
        UINT32 error = freerdp_get_last_error(instance->context);
        NSDebugLLog(@"gwcomp", @"RDPClient: Connection failed with error: 0x%08X", error);
        [self notifyConnectionResult:NO error:[NSString stringWithFormat:@"RDP connection failed (error: 0x%08X)", error]];
        goto cleanup;
    }
    
    NSDebugLLog(@"gwcomp", @"RDPClient: Successfully connected to %@:%ld", _hostname, (long)_port);
    _connected = YES;
    _connecting = NO;
    
    [self notifyConnectionResult:YES error:nil];
    
    // Main event loop
    while (!_shouldStop && _connected) {
        DWORD status = freerdp_check_fds(instance);
        if (!status) {
            if (freerdp_shall_disconnect(instance)) {
                NSDebugLLog(@"gwcomp", @"RDPClient: Server disconnected");
                break;
            }
        }
        
        usleep(10000); // 10ms
    }
    
cleanup:
    NSDebugLLog(@"gwcomp", @"RDPClient: Connection thread ending");
    
    if (_rdpContext) {
        RDPCustomContext *customContext = (RDPCustomContext *)_rdpContext;
        freerdp *instance = customContext->context.instance;
        
        if (instance) {
            if (_connected) {
                freerdp_disconnect(instance);
            }
            freerdp_context_free(instance);
            freerdp_free(instance);
        }
        
        _rdpContext = NULL;
    }
    
    _connected = NO;
    _connecting = NO;
    
    if (!_shouldStop) {
        [self notifyConnectionResult:NO error:@"Connection lost"];
    }
    
    [pool release];
}

#else /* !HAVE_FREERDP */

// RDP backend unavailable at build time: the connect methods already refuse to
// start a connection, so this thread body just reports the failure.
- (void)connectionThreadMain:(id)object
{
    (void)object;
    [self notifyConnectionResult:NO error:@"FreeRDP support was not built in"];
}

#endif /* HAVE_FREERDP */

- (void)notifyConnectionResult:(BOOL)success error:(NSString *)error
{
    if (_delegate) {
        NSDictionary *info = [NSDictionary dictionaryWithObjectsAndKeys:
                              [NSNumber numberWithBool:success], @"success",
                              error ? error : @"", @"error",
                              nil];
        [self performSelectorOnMainThread:@selector(notifyConnectionOnMainThread:)
                               withObject:info
                            waitUntilDone:NO];
    }
}

#pragma mark - Input Handling

#ifdef HAVE_FREERDP

- (void)sendKeyboardEvent:(NSUInteger)key pressed:(BOOL)pressed
{
    if (!_connected || !_rdpContext) {
        return;
    }
    
    RDPCustomContext *customContext = (RDPCustomContext *)_rdpContext;
    freerdp *instance = customContext->context.instance;
    
    if (instance && instance->context->input) {
        // Convert key code to RDP scancode
        UINT16 scancode = (UINT16)(key & 0xFF);
        UINT16 flags = pressed ? KBD_FLAGS_DOWN : KBD_FLAGS_RELEASE;
        
        freerdp_input_send_keyboard_event(instance->context->input, flags, scancode);
    }
}

- (void)sendMouseEvent:(NSPoint)position buttons:(NSUInteger)buttonMask
{
    if (!_connected || !_rdpContext) {
        return;
    }
    
    RDPCustomContext *customContext = (RDPCustomContext *)_rdpContext;
    freerdp *instance = customContext->context.instance;
    
    if (instance && instance->context->input) {
        // Convert position to RDP coordinates (flip Y axis)
        int x = (int)position.x;
        int y = (int)(_height - position.y);
        
        // Clamp to valid range
        if (x < 0) x = 0;
        if (y < 0) y = 0;
        if (x >= _width) x = _width - 1;
        if (y >= _height) y = _height - 1;
        
        UINT16 flags = PTR_FLAGS_MOVE;
        
        if (buttonMask & 1) flags |= PTR_FLAGS_BUTTON1;
        if (buttonMask & 2) flags |= PTR_FLAGS_BUTTON2;
        if (buttonMask & 4) flags |= PTR_FLAGS_BUTTON3;
        
        freerdp_input_send_mouse_event(instance->context->input, flags, x, y);
    }
}

#else /* !HAVE_FREERDP */

- (void)sendKeyboardEvent:(NSUInteger)key pressed:(BOOL)pressed
{
    (void)key;
    (void)pressed;
    if (!_connected || !_rdpContext) {
        return;
    }
}

- (void)sendMouseEvent:(NSPoint)position buttons:(NSUInteger)buttonMask
{
    (void)position;
    (void)buttonMask;
    if (!_connected || !_rdpContext) {
        return;
    }
}

#endif /* HAVE_FREERDP */

- (void)sendMouseMoveEvent:(NSPoint)position
{
    [self sendMouseEvent:position buttons:0];
}

#ifdef HAVE_FREERDP

- (void)sendMouseButtonEvent:(NSUInteger)button pressed:(BOOL)pressed position:(NSPoint)position
{
    if (!_connected || !_rdpContext) {
        return;
    }
    
    RDPCustomContext *customContext = (RDPCustomContext *)_rdpContext;
    freerdp *instance = customContext->context.instance;
    
    if (instance && instance->context->input) {
        int x = (int)position.x;
        int y = (int)(_height - position.y);
        
        if (x < 0) x = 0;
        if (y < 0) y = 0;
        if (x >= _width) x = _width - 1;
        if (y >= _height) y = _height - 1;
        
        UINT16 flags = 0;
        
        switch (button) {
            case 1: flags = PTR_FLAGS_BUTTON1; break;
            case 2: flags = PTR_FLAGS_BUTTON2; break;
            case 3: flags = PTR_FLAGS_BUTTON3; break;
        }
        
        if (pressed) {
            flags |= PTR_FLAGS_DOWN;
        }
        
        freerdp_input_send_mouse_event(instance->context->input, flags, x, y);
    }
}

#else /* !HAVE_FREERDP */

- (void)sendMouseButtonEvent:(NSUInteger)button pressed:(BOOL)pressed position:(NSPoint)position
{
    (void)button;
    (void)pressed;
    (void)position;
    if (!_connected || !_rdpContext) {
        return;
    }
}

#endif /* HAVE_FREERDP */

#pragma mark - Framebuffer Access

- (NSData *)framebufferData
{
    if (!_framebuffer || _width == 0 || _height == 0) {
        return nil;
    }
    
    size_t bufferSize = _width * _height * 4;
    return [NSData dataWithBytes:_framebuffer length:bufferSize];
}

- (NSImage *)framebufferImage
{
    if (!_framebuffer || _width == 0 || _height == 0) {
        return nil;
    }
    
    static unsigned char *staticConvertedBuffer = NULL;
    static size_t staticBufferSize = 0;
    
    size_t bufferSize = _width * _height * 4;
    
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
    
    // Convert from BGRA to RGBA
    uint32_t *sourcePixels = (uint32_t*)_framebuffer;
    uint32_t *destPixels = (uint32_t*)staticConvertedBuffer;
    
    for (int i = 0; i < _width * _height; i++) {
        uint32_t pixel = sourcePixels[i];
        
        unsigned char blue = (pixel >> 0) & 0xFF;
        unsigned char green = (pixel >> 8) & 0xFF;
        unsigned char red = (pixel >> 16) & 0xFF;
        unsigned char alpha = (pixel >> 24) & 0xFF;
        
        destPixels[i] = (alpha << 24) | (blue << 16) | (green << 8) | red;
    }
    
    NSBitmapImageRep *bitmapRep = [[NSBitmapImageRep alloc] 
        initWithBitmapDataPlanes:&staticConvertedBuffer
                      pixelsWide:_width
                      pixelsHigh:_height
                   bitsPerSample:8
                 samplesPerPixel:4
                        hasAlpha:YES
                        isPlanar:NO
                  colorSpaceName:NSDeviceRGBColorSpace
                     bytesPerRow:_width * 4
                    bitsPerPixel:32];
    
    if (!bitmapRep) {
        return nil;
    }
    
    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(_width, _height)];
    [image setCacheMode:NSImageCacheAlways];
    [image addRepresentation:bitmapRep];
    [bitmapRep release];
    
    return [image autorelease];
}

#pragma mark - Main Thread Callback Helpers

- (void)notifyFramebufferUpdate:(NSValue *)rectValue
{
    NSRect rect = [rectValue rectValue];
    if (_delegate && [_delegate respondsToSelector:@selector(rdpClient:framebufferDidUpdate:)]) {
        [_delegate rdpClient:self framebufferDidUpdate:rect];
    }
}

- (void)notifyDisconnect:(NSString *)reason
{
    if (_delegate && [_delegate respondsToSelector:@selector(rdpClient:didDisconnect:)]) {
        [_delegate rdpClient:self didDisconnect:reason];
    }
}

- (void)notifyConnectionOnMainThread:(NSDictionary *)info
{
    BOOL success = [[info objectForKey:@"success"] boolValue];
    NSString *error = [info objectForKey:@"error"];
    
    if (success && [_delegate respondsToSelector:@selector(rdpClient:didConnect:)]) {
        [_delegate rdpClient:self didConnect:YES];
    } else if (!success) {
        if ([_delegate respondsToSelector:@selector(rdpClient:didConnect:)]) {
            [_delegate rdpClient:self didConnect:NO];
        }
        if (error && [error length] > 0 && [_delegate respondsToSelector:@selector(rdpClient:didReceiveError:)]) {
            [_delegate rdpClient:self didReceiveError:error];
        }
    }
}

#ifdef HAVE_FREERDP
#pragma GCC diagnostic pop
#endif

@end
