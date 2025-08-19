#import <AppKit/AppKit.h>
#import <X11/Xlib.h>

@class GTKStatusIconManager;

/**
 * ClickableIconView
 * 
 * A custom NSView that handles mouse clicks and forwards them to embedded X11 windows
 * for tray icon functionality.
 */
@interface ClickableIconView : NSView
{
    Window _embeddedWindow;
    Window _containerWindow;
    Display *_display;
    GTKStatusIconManager *_manager;
    NSTimer *_updateTimer;
    
    // X11 event monitoring
    BOOL _eventMonitoringActive;
    NSThread *_eventMonitorThread;
    
    // Content comparison for detecting actual visual changes
    unsigned char *_lastContentChecksum;
    int _lastContentWidth;
    int _lastContentHeight;
}

@property (assign) Window embeddedWindow;
@property (assign) Display *display;
@property (retain) GTKStatusIconManager *manager;

- (instancetype)initWithFrame:(NSRect)frame window:(Window)window display:(Display *)display manager:(GTKStatusIconManager *)manager;
- (void)performDeferredEmbedding;
- (void)forwardMouseEvent:(NSEvent *)event;

@end
