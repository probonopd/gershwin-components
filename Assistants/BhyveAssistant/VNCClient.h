//
// VNCClient.h
// Bhyve Assistant - VNC Client using libvncclient
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

@class VNCClient;

@protocol VNCClientDelegate <NSObject>
@optional
- (void)vncClient:(VNCClient *)client didConnect:(BOOL)success;
- (void)vncClient:(VNCClient *)client didDisconnect:(NSString *)reason;
- (void)vncClient:(VNCClient *)client didReceiveError:(NSString *)error;
- (void)vncClient:(VNCClient *)client framebufferDidUpdate:(NSRect)rect;
@end

@interface VNCClient : NSObject
{
    void *_rfbClient;  // rfbClient pointer from libvncclient
    NSString *_hostname;
    NSInteger _port;
    NSString *_password;
    BOOL _connected;
    BOOL _connecting;
    
    // Framebuffer data
    NSInteger _width;
    NSInteger _height;
    NSInteger _depth;
    unsigned char *_framebuffer;
    NSSize _framebufferSize;
    
    // Threading
    NSThread *_connectionThread;
    BOOL _shouldStop;
    
    // Delegate
    id<VNCClientDelegate> _delegate;
}

@property (nonatomic, retain) NSString *hostname;
@property (nonatomic, assign) NSInteger port;
@property (nonatomic, retain) NSString *password;
@property (nonatomic, assign) BOOL connected;
@property (nonatomic, assign) BOOL connecting;
@property (nonatomic, assign) NSInteger width;
@property (nonatomic, assign) NSInteger height;
@property (nonatomic, assign) NSInteger depth;
@property (nonatomic, assign) id<VNCClientDelegate> delegate;

// Connection management
- (BOOL)connectToHost:(NSString *)hostname port:(NSInteger)port;
- (BOOL)connectToHost:(NSString *)hostname port:(NSInteger)port password:(NSString *)password;
- (void)disconnect;

// Input handling
- (void)sendKeyboardEvent:(NSUInteger)key pressed:(BOOL)pressed;
- (void)sendMouseEvent:(NSPoint)position buttons:(NSUInteger)buttonMask;
- (void)sendMouseMoveEvent:(NSPoint)position;
- (void)sendMouseButtonEvent:(NSUInteger)button pressed:(BOOL)pressed position:(NSPoint)position;

// Framebuffer access
- (NSData *)framebufferData;
- (NSImage *)framebufferImage;
- (void)requestFramebufferUpdate:(NSRect)rect incremental:(BOOL)incremental;
- (void)requestFullFramebufferUpdate;

// Utility
+ (BOOL)isLibVNCClientAvailable;

@end
