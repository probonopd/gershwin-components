//
// VNCWindow.h
// Bhyve Assistant - VNC Viewer Window
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import "VNCClient.h"

@interface VNCWindow : NSWindow <VNCClientDelegate>
{
    VNCClient *_vncClient;
    NSImageView *_imageView;
    NSScrollView *_scrollView;
    NSString *_hostname;
    NSInteger _port;
    NSString *_password;
    
    // Display state
    BOOL _connected;
    NSSize _framebufferSize;
    NSImage *_currentImage;
    
    // Input handling
    NSTrackingArea *_trackingArea;
    BOOL _mouseInside;
}

@property (nonatomic, retain) VNCClient *vncClient;
@property (nonatomic, retain) NSString *hostname;
@property (nonatomic, assign) NSInteger port;
@property (nonatomic, retain) NSString *password;
@property (nonatomic, assign) BOOL connected;

// Initialization
- (id)initWithContentRect:(NSRect)contentRect hostname:(NSString *)hostname port:(NSInteger)port;
- (id)initWithContentRect:(NSRect)contentRect hostname:(NSString *)hostname port:(NSInteger)port password:(NSString *)password;

// Connection management
- (BOOL)connectToVNC;
- (void)disconnectFromVNC;

// Display management
- (void)updateDisplay;
- (void)resizeWindowToFitFramebuffer;

@end
