/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "WindowMonitor.h"
#import "MenuUtils.h"
#import "MenuController.h"
#import "MenuProfiler.h"
#import <Foundation/Foundation.h>
#import <X11/Xlib.h>
#import <dispatch/dispatch.h>
#import <X11/Xatom.h>
#import <X11/Xutil.h>

@interface WindowMonitor ()
{
    Display *_display;
    Window _rootWindow;
    Atom _netActiveWindowAtom;
    Atom _gstepAppAtom;
    unsigned long _currentActiveWindow;
    BOOL _monitoring;
    BOOL _stopMonitoring;
}
- (void)_postWindowNotification:(NSDictionary *)userInfo;
@end

@implementation WindowMonitor

NSString * const WindowMonitorActiveWindowChangedNotification = @"WindowMonitorActiveWindowChangedNotification";


- (void)_postWindowNotification:(NSDictionary *)userInfo
{
    [[NSNotificationCenter defaultCenter] 
        postNotificationName:WindowMonitorActiveWindowChangedNotification
        object:self
        userInfo:userInfo];
}

+ (instancetype)sharedMonitor
{
    static WindowMonitor *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _display = NULL;
        _rootWindow = 0;
        _netActiveWindowAtom = 0;
        _gstepAppAtom = 0;
        _currentActiveWindow = 0;
        _monitoring = NO;
        _stopMonitoring = NO;
        
        NSDebugLLog(@"gwcomp", @"WindowMonitor: Initialized");
    }
    return self;
}

- (void)dealloc
{
    [self stopMonitoring];
}

- (BOOL)startMonitoring
{
    MENU_PROFILE_BEGIN(startMonitoring);

    if (_monitoring) {
        NSDebugLLog(@"gwcomp", @"WindowMonitor: Already monitoring");
        MENU_PROFILE_END(startMonitoring);
        return YES;
    }

    /* Plain event-loop thread on its OWN X connection.  No GCD: a dispatch
     * read-source on an Xlib fd has been observed to stop firing after a
     * while, leaving the menu stuck on the previously active app. */
    _monitoring = YES;
    _stopMonitoring = NO;
    [NSThread detachNewThreadSelector: @selector(x11EventLoop:)
                            toTarget: self
                          withObject: nil];

    MENU_PROFILE_END(startMonitoring);
    return YES;
}

- (void)x11EventLoop:(id)unused
{
    @autoreleasepool {
        _display = XOpenDisplay(NULL);
        if (!_display) {
            NSLog(@"WindowMonitor: Cannot open X display for event loop");
            _monitoring = NO;
            return;
        }
        _rootWindow = DefaultRootWindow(_display);
        _netActiveWindowAtom = XInternAtom(_display, "_NET_ACTIVE_WINDOW", False);
        _gstepAppAtom = XInternAtom(_display, "_GNUSTEP_WM_ATTR", False);
        XSelectInput(_display, _rootWindow, PropertyChangeMask | SubstructureNotifyMask);
        XSync(_display, False);

        NSLog(@"WindowMonitor: Event loop started on own connection");
        [self checkInitialActiveWindow];

        while (!_stopMonitoring) {
            XEvent event;
            XNextEvent(_display, &event);
            if (event.type == PropertyNotify
                && event.xproperty.window == _rootWindow
                && event.xproperty.atom == _netActiveWindowAtom) {
                [self checkActiveWindow];
            } else if (event.type == DestroyNotify || event.type == UnmapNotify) {
                Window affected = (event.type == DestroyNotify)
                    ? event.xdestroywindow.window : event.xunmap.window;
                if (affected != 0 && affected == _currentActiveWindow) {
                    [self checkActiveWindow];
                }
            }
        }

        XCloseDisplay(_display);
        _display = NULL;
        _monitoring = NO;
        NSLog(@"WindowMonitor: Event loop stopped");
    }
}

- (void)checkInitialActiveWindow
{
    MENU_PROFILE_BEGIN(checkInitialActiveWindow);

    if (!_display) {
        MENU_PROFILE_END(checkInitialActiveWindow);
        return;
    }
    
    Atom actualType;
    int actualFormat;
    unsigned long nitems, bytesAfter;
    unsigned char *prop = NULL;
    unsigned long newActiveWindow = 0;
    
    if (XGetWindowProperty(_display, _rootWindow, _netActiveWindowAtom,
                          0, 1, False, XA_WINDOW,
                          &actualType, &actualFormat, &nitems, &bytesAfter,
                          &prop) == 0 && prop) {
        newActiveWindow = *(Window*)prop;
        XFree(prop);
    }

    // Same logic as checkActiveWindow - trust WM unless window is explicitly unmapped
    if (newActiveWindow != 0) {
        XWindowAttributes attrs;
        BOOL canGetAttrs = XGetWindowAttributes(_display, (Window)newActiveWindow, &attrs);
        
        if (canGetAttrs && attrs.map_state != IsViewable) {
            // Require IsViewable: reject both IsUnmapped and IsUnviewable (mapped but ancestor unmapped).
            NSDebugLLog(@"gwcomp", @"WindowMonitor: Initial active window %lu is not viewable (map_state %d)", newActiveWindow, attrs.map_state);
            newActiveWindow = 0;
        } else if (!canGetAttrs) {
            NSDebugLLog(@"gwcomp", @"WindowMonitor: Cannot get attributes for initial window %lu - trusting WM", newActiveWindow);
        }
        
        if (newActiveWindow != 0) {
            XSelectInput(_display, (Window)newActiveWindow, StructureNotifyMask | PropertyChangeMask);
        }
    }
    
    // Same ICCCM/EWMH filter as checkActiveWindow - ignore internal windows.
    if (newActiveWindow != 0
        && ![MenuUtils isDesktopWindow:newActiveWindow]
        && ![MenuUtils isRealApplicationWindow:newActiveWindow]) {
        NSDebugLLog(@"gwcomp", @"WindowMonitor: Initial active window %lu is not a real app window - ignoring", newActiveWindow);
        newActiveWindow = 0;
    }
    
    if (newActiveWindow != _currentActiveWindow) {
        _currentActiveWindow = newActiveWindow;
        
        NSDictionary *userInfo = @{@"windowId": @(newActiveWindow)};
        [self performSelectorOnMainThread:@selector(_postWindowNotification:)
                               withObject:userInfo
                            waitUntilDone:NO];
    }

    MENU_PROFILE_END(checkInitialActiveWindow);
}

- (void)checkActiveWindow
{

    MENU_PROFILE_BEGIN(checkActiveWindow);

    if (!_display) {
        MENU_PROFILE_END(checkActiveWindow);
        return;
    }
    
    Atom actualType;
    int actualFormat;
    unsigned long nitems, bytesAfter;
    unsigned char *prop = NULL;
    unsigned long newActiveWindow = 0;
    
    if (XGetWindowProperty(_display, _rootWindow, _netActiveWindowAtom,
                          0, 1, False, XA_WINDOW,
                          &actualType, &actualFormat, &nitems, &bytesAfter,
                          &prop) == 0 && prop) {
        newActiveWindow = *(Window*)prop;
        XFree(prop);
    }

    // FIX: Don't report window==0 unless X11 truly says there's no active window
    // If XGetWindowProperty returns a window ID, trust it - even if we can't query its attributes
    // Window attributes can fail during WM operations (reparenting, etc) but the window is still valid
    if (newActiveWindow != 0) {
        XWindowAttributes attrs;
        // Try to get attributes, but don't reject the window if this fails
        // The window manager set this as active, so trust it
        BOOL canGetAttrs = XGetWindowAttributes(_display, (Window)newActiveWindow, &attrs);
        
        if (canGetAttrs && attrs.map_state != IsViewable) {
            // Require IsViewable: reject both IsUnmapped (minimized/hidden) and
            // IsUnviewable (mapped but an ancestor is not). Neither can have focus.
            NSDebugLLog(@"gwcomp", @"WindowMonitor: Active window %lu is not viewable (map_state %d) - treating as no active window", newActiveWindow, attrs.map_state);
            newActiveWindow = 0;
        } else if (!canGetAttrs) {
            // Can't get attributes - might be during WM operation
            // Only ignore if we get a BadWindow error, otherwise keep it
            // For now, trust the window manager's report
            NSDebugLLog(@"gwcomp", @"WindowMonitor: Cannot get attributes for active window %lu - trusting WM report anyway", newActiveWindow);
        }
        
        // Select for events on this window if we can
        if (newActiveWindow != 0) {
            XSelectInput(_display, (Window)newActiveWindow, StructureNotifyMask | PropertyChangeMask);
        }
    }
    
    // ICCCM/EWMH filter: window-manager-internal windows (tooltips, menus,
    // popups, docks) and Chromium's internal helper windows must not be
    // treated as the active app window.  When one of them grabs the focus,
    // keep showing the previous app's menu (and its shortcuts) instead of
    // clearing to system-only.  The desktop is still reported as-is so the
    // menu can go to its system-only state.
    if (newActiveWindow != 0
        && ![MenuUtils isDesktopWindow:newActiveWindow]
        && ![MenuUtils isRealApplicationWindow:newActiveWindow]) {
        NSDebugLLog(@"gwcomp", @"WindowMonitor: Active window %lu is not a real app window - keeping current %lu", newActiveWindow, _currentActiveWindow);
        newActiveWindow = _currentActiveWindow;
    }
    
    if (newActiveWindow != _currentActiveWindow) {
        NSDebugLLog(@"gwcomp", @"WindowMonitor: Active window changed from %lu to %lu", _currentActiveWindow, newActiveWindow);

        _currentActiveWindow = newActiveWindow;
        
        NSDictionary *userInfo = @{@"windowId": @(newActiveWindow)};
        [self performSelectorOnMainThread:@selector(_postWindowNotification:)
                               withObject:userInfo
                            waitUntilDone:NO];
    } else {
        // Window hasn't changed - suppress notification to avoid spam
        // This can happen during WM operations or when we check after a window closes
    }

    MENU_PROFILE_END(checkActiveWindow);
}

- (void)stopMonitoring
{
    if (!_monitoring) return;

    /* Signal the event-loop thread to exit; it owns _display and closes it. */
    _stopMonitoring = YES;
    if (_display) {
        /* Wake the thread out of XNextEvent with a client message. */
        XEvent e;
        memset(&e, 0, sizeof(e));
        e.type = ClientMessage;
        e.xclient.window = _rootWindow;
        e.xclient.message_type = _netActiveWindowAtom;
        XSendEvent(_display, _rootWindow, False,
                   SubstructureRedirectMask | SubstructureNotifyMask, &e);
        XSync(_display, False);
    }
    for (int i = 0; i < 100 && _monitoring; i++) {
        [NSThread sleepForTimeInterval:0.02];
    }
    NSDebugLLog(@"gwcomp", @"WindowMonitor: Stopped monitoring");
}

// Compatibility Accessors
- (Display *)display { return _display; }
- (Window)rootWindow { return _rootWindow; }
- (BOOL)isGNUstepWindow:(unsigned long)windowId {
    if (!_display || windowId == 0) return NO;
    
    Atom actualType;
    int actualFormat;
    unsigned long nitems, bytesAfter;
    unsigned char *prop = NULL;
    BOOL isGNUstep = NO;
    
    if (XGetWindowProperty(_display, (Window)windowId, _gstepAppAtom,
                          0, 1, False, AnyPropertyType,
                          &actualType, &actualFormat, &nitems, &bytesAfter,
                          &prop) == Success && prop) {
        isGNUstep = YES;
        XFree(prop);
    }
    
    return isGNUstep;
}

- (unsigned long)currentActiveWindow
{
    return _currentActiveWindow;
}

- (unsigned long)getActiveWindow
{
    return _currentActiveWindow;
}

@end
