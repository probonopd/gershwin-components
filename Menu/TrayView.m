#import "TrayView.h"
#import "StatusNotifierManager.h"
#import <X11/Xlib.h>

@implementation TrayView

- (instancetype)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        _trayIconViews = [[NSMutableArray alloc] init];
        _iconSize = 22.0; // Standard tray icon size
        _iconSpacing = 4.0;
        _isSetup = NO;
        
        // Set up view properties
        [self setAutoresizingMask:NSViewMinXMargin | NSViewMaxYMargin | NSViewMinYMargin];
        
        NSLog(@"TrayView: Initialized with frame: %@", NSStringFromRect(frame));
    }
    return self;
}

- (void)dealloc
{
    [self tearDown];
    [_trayIconViews release];
    [_statusNotifierManager release];
    [super dealloc];
}

- (void)setupStatusNotifierSupport
{
    if (_isSetup) {
        NSLog(@"TrayView: StatusNotifier support already setup");
        return;
    }
    
    NSLog(@"TrayView: Setting up StatusNotifier support");
    
    // Create StatusNotifierManager with ourselves as the tray view
    _statusNotifierManager = [[StatusNotifierManager alloc] initWithTrayView:self];
    
    // Connect to D-Bus and start hosting
    if ([_statusNotifierManager connectToDBus]) {
        NSLog(@"TrayView: StatusNotifier support initialized successfully");
        _isSetup = YES;
        
        // Listen for notifications about tray icon changes
        [[NSNotificationCenter defaultCenter] 
         addObserver:self
            selector:@selector(_handleTrayIconAdded:)
                name:@"TrayIconAdded"
              object:nil];
        
        [[NSNotificationCenter defaultCenter] 
         addObserver:self
            selector:@selector(_handleTrayIconRemoved:)
                name:@"TrayIconRemoved"
              object:nil];
    } else {
        NSLog(@"TrayView: Failed to initialize StatusNotifier support");
        [_statusNotifierManager release];
        _statusNotifierManager = nil;
    }
}

- (void)tearDown
{
    if (!_isSetup) {
        return;
    }
    
    NSLog(@"TrayView: Tearing down StatusNotifier support");
    
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    
    [_statusNotifierManager cleanup];
    [_statusNotifierManager release];
    _statusNotifierManager = nil;
    
    // Remove all tray icon views
    NSArray *views = [NSArray arrayWithArray:_trayIconViews];
    for (NSView *view in views) {
        [self removeTrayIconView:view];
    }
    
    _isSetup = NO;
}

#pragma mark - Icon Management

- (void)addTrayIconView:(NSView *)iconView
{
    if ([_trayIconViews containsObject:iconView]) {
        return;
    }
    
    [_trayIconViews addObject:iconView];
    [self addSubview:iconView];
    [self updateLayout];
    
    NSLog(@"TrayView: Added tray icon view (total: %lu)", (unsigned long)[_trayIconViews count]);
}

- (void)removeTrayIconView:(NSView *)iconView
{
    if (![_trayIconViews containsObject:iconView]) {
        return;
    }
    
    [_trayIconViews removeObject:iconView];
    [iconView removeFromSuperview];
    [self updateLayout];
    
    NSLog(@"TrayView: Removed tray icon view (total: %lu)", (unsigned long)[_trayIconViews count]);
}

- (void)updateLayout
{
    CGFloat x = 0;
    
    for (NSView *iconView in _trayIconViews) {
        NSRect frame = NSMakeRect(x, 
                                 (NSHeight([self frame]) - _iconSize) / 2, 
                                 _iconSize, 
                                 _iconSize);
        [iconView setFrame:frame];
        x += _iconSize + _iconSpacing;
    }
    
    // Update our frame to fit all icons
    NSRect currentFrame = [self frame];
    CGFloat preferredWidth = [self preferredWidth];
    
    if (currentFrame.size.width != preferredWidth) {
        currentFrame.size.width = preferredWidth;
        [self setFrame:currentFrame];
        
        // Notify parent that our size changed
        [[self superview] setNeedsLayout:YES];
    }
    
    [self setNeedsDisplay:YES];
}

- (CGFloat)preferredWidth
{
    if ([_trayIconViews count] == 0) {
        return 0;
    }
    
    return ([_trayIconViews count] * _iconSize) + (([_trayIconViews count] - 1) * _iconSpacing);
}

- (NSSize)intrinsicContentSize
{
    return NSMakeSize([self preferredWidth], _iconSize);
}

#pragma mark - Drawing

- (void)drawRect:(NSRect)dirtyRect
{
    // Draw subtle background for tray area
    [[NSColor colorWithCalibratedWhite:0.0 alpha:0.05] set];
    NSRectFill(dirtyRect);
    
    // Draw separator line on the left if we have icons
    if ([_trayIconViews count] > 0) {
        [[NSColor colorWithCalibratedWhite:0.0 alpha:0.2] set];
        NSRect separatorRect = NSMakeRect(0, 2, 1, NSHeight([self frame]) - 4);
        NSRectFill(separatorRect);
    }
}

#pragma mark - Notification Handlers

- (void)_handleTrayIconAdded:(NSNotification *)notification
{
    NSDictionary *userInfo = [notification userInfo];
    NSString *serviceName = [userInfo objectForKey:@"serviceName"];
    NSString *itemId = [userInfo objectForKey:@"itemId"];
    
    if (serviceName && itemId) {
        // Create a new TrayIconView for this item
        NSRect iconFrame = NSMakeRect(0, 0, _iconSize, _iconSize);
        TrayIconView *iconView = [[TrayIconView alloc] initWithFrame:iconFrame 
                                                         serviceName:serviceName 
                                                              itemId:itemId];
        
        [self addTrayIconView:iconView];
        [iconView release];
        
        NSLog(@"TrayView: Added tray icon for %@:%@", serviceName, itemId);
    }
}

- (void)_handleTrayIconRemoved:(NSNotification *)notification
{
    NSDictionary *userInfo = [notification userInfo];
    NSString *serviceName = [userInfo objectForKey:@"serviceName"];
    NSString *itemId = [userInfo objectForKey:@"itemId"];
    
    if (serviceName && itemId) {
        // Find and remove the corresponding TrayIconView
        TrayIconView *viewToRemove = nil;
        for (TrayIconView *iconView in _trayIconViews) {
            if ([iconView isKindOfClass:[TrayIconView class]] &&
                [[iconView serviceName] isEqualToString:serviceName] &&
                [[iconView itemId] isEqualToString:itemId]) {
                viewToRemove = iconView;
                break;
            }
        }
        
        if (viewToRemove) {
            [self removeTrayIconView:viewToRemove];
            NSLog(@"TrayView: Removed tray icon for %@:%@", serviceName, itemId);
        }
    }
}

@end

#pragma mark - TrayIconView Implementation

@implementation TrayIconView

- (instancetype)initWithFrame:(NSRect)frame serviceName:(NSString *)serviceName itemId:(NSString *)itemId
{
    self = [super initWithFrame:frame];
    if (self) {
        _serviceName = [serviceName copy];
        _itemId = [itemId copy];
        _isHighlighted = NO;
        
        // Create image view
        _imageView = [[NSImageView alloc] initWithFrame:[self bounds]];
        [_imageView setImageScaling:NSImageScaleProportionallyUpOrDown];
        [_imageView setImageAlignment:NSImageAlignCenter];
        [self addSubview:_imageView];
        
        // Set up tracking area for mouse events
        [self _setupTrackingArea];
        
        NSLog(@"TrayIconView: Created for %@:%@", serviceName, itemId);
    }
    return self;
}

- (void)dealloc
{
    [_serviceName release];
    [_itemId release];
    [_title release];
    [_icon release];
    [_contextMenu release];
    [_imageView release];
    [super dealloc];
}

- (void)_setupTrackingArea
{
    // GNUstep doesn't have tracking areas - we'll handle mouse events differently
    // For now, this is a no-op
}

- (void)resizeSubviewsWithOldSize:(NSSize)oldSize
{
    [super resizeSubviewsWithOldSize:oldSize];
    [_imageView setFrame:[self bounds]];
    [self _setupTrackingArea];
}

#pragma mark - Updates

- (void)updateIcon:(NSImage *)icon
{
    [_icon release];
    _icon = [icon retain];
    [_imageView setImage:icon];
    [self setNeedsDisplay:YES];
}

- (void)updateContextMenu:(NSMenu *)menu
{
    [_contextMenu release];
    _contextMenu = [menu retain];
}

- (void)updateTitle:(NSString *)title
{
    [_title release];
    _title = [title copy];
    [self setToolTip:title];
}

#pragma mark - Drawing

- (void)drawRect:(NSRect)dirtyRect
{
    if (_isHighlighted) {
        // Draw highlight background
        [[NSColor colorWithCalibratedWhite:1.0 alpha:0.1] set];
        NSRectFill([self bounds]);
    }
}

- (void)mouseDown:(NSEvent *)event
{
    // Remove unused variables
    if ([event buttonNumber] == 0) { // Left click
        [self handleLeftClick:event];
    } else if ([event buttonNumber] == 1) { // Right click
        [self handleRightClick:event];
    } else if ([event buttonNumber] == 2) { // Middle click
        [self handleMiddleClick:event];
    }
}

- (void)rightMouseDown:(NSEvent *)event
{
    [self handleRightClick:event];
}

- (void)otherMouseDown:(NSEvent *)event
{
    if ([event buttonNumber] == 2) { // Middle click
        [self handleMiddleClick:event];
    }
}

#pragma mark - Interaction

- (void)handleLeftClick:(NSEvent *)event
{
    NSPoint locationInWindow = [event locationInWindow];
    NSPoint screenLocation = [[self window] convertRectToScreen:NSMakeRect(locationInWindow.x, locationInWindow.y, 0, 0)].origin;
    
    NSLog(@"TrayIconView: Left click on %@:%@ at screen location (%f, %f)", 
          _serviceName, _itemId, screenLocation.x, screenLocation.y);
    
    // Send Activate signal to the StatusNotifierItem
    [[NSNotificationCenter defaultCenter] 
     postNotificationName:@"TrayIconActivate"
                   object:self
                 userInfo:@{
                     @"serviceName": _serviceName,
                     @"itemId": _itemId,
                     @"x": @((int)screenLocation.x),
                     @"y": @((int)screenLocation.y)
                 }];
}

- (void)handleRightClick:(NSEvent *)event
{
    NSPoint locationInWindow = [event locationInWindow];
    NSPoint screenLocation = [[self window] convertRectToScreen:NSMakeRect(locationInWindow.x, locationInWindow.y, 0, 0)].origin;
    
    NSLog(@"TrayIconView: Right click on %@:%@ at screen location (%f, %f)", 
          _serviceName, _itemId, screenLocation.x, screenLocation.y);
    
    if (_contextMenu) {
        // Show context menu
        [NSMenu popUpContextMenu:_contextMenu withEvent:event forView:self];
    } else {
        // Send ContextMenu signal to the StatusNotifierItem
        [[NSNotificationCenter defaultCenter] 
         postNotificationName:@"TrayIconContextMenu"
                       object:self
                     userInfo:@{
                         @"serviceName": _serviceName,
                         @"itemId": _itemId,
                         @"x": @((int)screenLocation.x),
                         @"y": @((int)screenLocation.y)
                     }];
    }
}

- (void)handleMiddleClick:(NSEvent *)event
{
    NSPoint locationInWindow = [event locationInWindow];
    NSPoint screenLocation = [[self window] convertRectToScreen:NSMakeRect(locationInWindow.x, locationInWindow.y, 0, 0)].origin;
    
    NSLog(@"TrayIconView: Middle click on %@:%@ at screen location (%f, %f)", 
          _serviceName, _itemId, screenLocation.x, screenLocation.y);
    
    // Send SecondaryActivate signal to the StatusNotifierItem
    [[NSNotificationCenter defaultCenter] 
     postNotificationName:@"TrayIconSecondaryActivate"
                   object:self
                 userInfo:@{
                     @"serviceName": _serviceName,
                     @"itemId": _itemId,
                     @"x": @((int)screenLocation.x),
                     @"y": @((int)screenLocation.y)
                 }];
}

- (void)scrollWheel:(NSEvent *)event
{
    CGFloat deltaY = [event deltaY];
    
    NSLog(@"TrayIconView: Scroll on %@:%@ deltaY=%f", _serviceName, _itemId, deltaY);
    
    // Send Scroll signal to the StatusNotifierItem
    [[NSNotificationCenter defaultCenter] 
     postNotificationName:@"TrayIconScroll"
                   object:self
                 userInfo:@{
                     @"serviceName": _serviceName,
                     @"itemId": _itemId,
                     @"delta": @((int)deltaY),
                     @"orientation": @"vertical"
                 }];
}

@end
