#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import "MenuProtocolManager.h"
#import "ClickableIconView.h"
#import <X11/Xlib.h>
#import <X11/Xatom.h>

@class GTKStatusIconItem;

/**
 * GTKStatusIconManager
 * 
 * Manages GTK StatusIcon (legacy X11 system tray) for Menu.app
 * Supports applications using Gtk.StatusIcon() like networkmgr
 * Implements the X11 System Tray protocol (XEmbed)
 */
@interface GTKStatusIconManager : NSObject <MenuProtocolHandler>
{
    Display *_display;
    Window _systemTrayWindow;
    Atom _systemTraySelection;
    Atom _netSystemTrayOpcode;
    Atom _xembedInfo;
    Atom _xembed;
    NSMutableDictionary *_embeddedIcons; // window -> GTKStatusIconItem
    NSView *_trayView;
    AppMenuWidget *_appMenuWidget;
    BOOL _isConnected;
    BOOL _isOwner;
    int _screen;
}

@property (nonatomic, retain) NSView *trayView;
@property (nonatomic, assign) AppMenuWidget *appMenuWidget;

// Initialization
- (instancetype)initWithTrayView:(NSView *)trayView;

// MenuProtocolHandler implementation
- (BOOL)connectToDBus;
- (BOOL)hasMenuForWindow:(unsigned long)windowId;
- (NSMenu *)getMenuForWindow:(unsigned long)windowId;
- (void)activateMenuItem:(NSMenuItem *)menuItem forWindow:(unsigned long)windowId;
- (void)registerWindow:(unsigned long)windowId serviceName:(NSString *)serviceName objectPath:(NSString *)objectPath;
- (void)unregisterWindow:(unsigned long)windowId;
- (void)scanForExistingMenuServices;
- (NSString *)getMenuServiceForWindow:(unsigned long)windowId;
- (NSString *)getMenuObjectPathForWindow:(unsigned long)windowId;
- (void)cleanup;

// X11 System Tray implementation
- (BOOL)becomeSystemTrayOwner;
- (void)processSystemTrayEvents;
- (void)handleDockRequest:(Window)iconWindow;
- (void)handleUndockRequest:(Window)iconWindow;
- (void)embedIconWindow:(Window)iconWindow;
- (void)unembedIconWindow:(Window)iconWindow;

// Icon management
- (void)addStatusIcon:(GTKStatusIconItem *)icon;
- (void)removeStatusIcon:(GTKStatusIconItem *)icon;
- (void)updateTrayLayout;
- (void)performX11Embedding:(Window)iconWindow inContainer:(NSView *)containerView;

@end

/**
 * GTKStatusIconItem
 * 
 * Represents an embedded GTK StatusIcon in our system tray
 */
@interface GTKStatusIconItem : NSObject
{
    Window _iconWindow;
    NSView *_containerView;
    NSString *_title;
    NSString *_tooltip;
    CGFloat _width;
    CGFloat _height;
}

@property (nonatomic, assign) Window iconWindow;
@property (nonatomic, retain) NSView *containerView;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *tooltip;
@property (nonatomic, assign) CGFloat width;
@property (nonatomic, assign) CGFloat height;

- (instancetype)initWithWindow:(Window)window;
- (void)updateGeometry:(NSRect)frame;

@end
