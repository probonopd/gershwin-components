#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

@class StatusNotifierManager;

/**
 * TrayView
 * 
 * NSView subclass that displays system tray icons on the right side of Menu.app
 * Manages layout and interaction with StatusNotifierItems
 */
@interface TrayView : NSView
{
    StatusNotifierManager *_statusNotifierManager;
    NSMutableArray *_trayIconViews;
    CGFloat _iconSize;
    CGFloat _iconSpacing;
    BOOL _isSetup;
}

@property (nonatomic, readonly) StatusNotifierManager *statusNotifierManager;
@property (nonatomic, assign) CGFloat iconSize;
@property (nonatomic, assign) CGFloat iconSpacing;

// Initialization
- (instancetype)initWithFrame:(NSRect)frame;

// Setup
- (void)setupStatusNotifierSupport;
- (void)tearDown;

// Icon management
- (void)addTrayIconView:(NSView *)iconView;
- (void)removeTrayIconView:(NSView *)iconView;
- (void)updateLayout;

// Size calculation
- (CGFloat)preferredWidth;
- (NSSize)intrinsicContentSize;

@end

/**
 * TrayIconView
 * 
 * Individual tray icon view that displays a StatusNotifierItem
 */
@interface TrayIconView : NSView
{
    NSImageView *_imageView;
    NSString *_serviceName;
    NSString *_itemId;
    NSString *_title;
    NSImage *_icon;
    NSMenu *_contextMenu;
    BOOL _isHighlighted;
}

@property (nonatomic, copy) NSString *serviceName;
@property (nonatomic, copy) NSString *itemId;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, retain) NSImage *icon;
@property (nonatomic, retain) NSMenu *contextMenu;

// Initialization
- (instancetype)initWithFrame:(NSRect)frame serviceName:(NSString *)serviceName itemId:(NSString *)itemId;

// Updates
- (void)updateIcon:(NSImage *)icon;
- (void)updateContextMenu:(NSMenu *)menu;
- (void)updateTitle:(NSString *)title;

// Interaction
- (void)handleLeftClick:(NSEvent *)event;
- (void)handleRightClick:(NSEvent *)event;
- (void)handleMiddleClick:(NSEvent *)event;

@end
