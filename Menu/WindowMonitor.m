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
    dispatch_source_t _x11EventSource;
    dispatch_queue_t _x11Queue;
    unsigned long _currentActiveWindow;
    BOOL _monitoring;
}
- (void)_postWindowNotification:(NSDictionary *)userInfo;
@end

@implementation WindowMonitor

NSString * const WindowMonitorActiveWindowChangedNotification = @"WindowMonitorActiveWindowChangedNotification";
static const void *kWindowMonitorQueueKey = &kWindowMonitorQueueKey;

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
        _x11EventSource = NULL;
        _currentActiveWindow = 0;
        _monitoring = NO;
        
        // Create serial queue for X11 operations
        _x11Queue = dispatch_queue_create("org.gnustep.menu.windowmonitor", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(_x11Queue, kWindowMonitorQueueKey, (void *)kWindowMonitorQueueKey, NULL);
        
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

    NSDebugLLog(@"gwcomp", @"WindowMonitor: Starting event-driven monitoring using GCD");

    // Initialize all X11 operations on the dedicated serial queue to ensure
    // the Display is only used from one thread (avoids Xlib thread-safety issues)
    __block BOOL initSuccess = NO;
    dispatch_sync(_x11Queue, ^{
        // Open X11 display on the X11 queue thread
        _display = XOpenDisplay(NULL);
        if (!_display) {
            NSDebugLLog(@"gwcomp", @"WindowMonitor: ERROR - Cannot open X11 display");
            initSuccess = NO;
            return;
        }

        _rootWindow = DefaultRootWindow(_display);

        // Intern required atoms
        _netActiveWindowAtom = XInternAtom(_display, "_NET_ACTIVE_WINDOW", False);
        _gstepAppAtom = XInternAtom(_display, "_GNUSTEP_WM_ATTR", False);

        // Select PropertyChange and Substructure (DestroyNotify) events on root window
        XSelectInput(_display, _rootWindow, PropertyChangeMask | SubstructureNotifyMask);

        int x11Fd = ConnectionNumber(_display);
        NSDebugLLog(@"gwcomp", @"WindowMonitor: X11 file descriptor: %d", x11Fd);

        // Create GCD dispatch source for X11 file descriptor on the same queue
        _x11EventSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, x11Fd, 0, _x11Queue);
        if (!_x11EventSource) {
            NSDebugLLog(@"gwcomp", @"WindowMonitor: ERROR - Failed to create dispatch source");
            XCloseDisplay(_display);
            _display = NULL;
            initSuccess = NO;
            return;
        }

        // Set event handler
        __weak typeof(self) weakSelf = self;
        dispatch_source_set_event_handler(_x11EventSource, ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf processX11Events];
        });

        // Set cancel handler
        dispatch_source_set_cancel_handler(_x11EventSource, ^{
            NSDebugLLog(@"gwcomp", @"WindowMonitor: Dispatch source cancelled");
        });

        // Start monitoring
        dispatch_resume(_x11EventSource);

        initSuccess = YES;
    });

    if (!initSuccess) {
        MENU_PROFILE_END(startMonitoring);
        return NO;
    }

    _monitoring = YES;
    NSDebugLLog(@"gwcomp", @"WindowMonitor: Monitoring started - event-driven, zero-polling");

    // Get initial active window (runs on the X11 queue)
    dispatch_async(_x11Queue, ^{
        [self checkInitialActiveWindow];
    });

    MENU_PROFILE_END(startMonitoring);
    return YES;
}

- (void)processX11Events
{
    MENU_PROFILE_BEGIN(processX11Events);

    if (!_display) {
        MENU_PROFILE_END(processX11Events);
        return;
    }
    
    // TIGHT-LOOP GUARD: Cap the number of events processed per invocation
    // to prevent unbounded spinning when events arrive faster than processing
    static const int MAX_EVENTS_PER_BATCH = 50;
    int eventsProcessed = 0;
    
    // Process pending X11 events (up to MAX_EVENTS_PER_BATCH)
    while (XPending(_display) > 0 && eventsProcessed < MAX_EVENTS_PER_BATCH) {
        XEvent event;
        XNextEvent(_display, &event);
        eventsProcessed++;
        
        if (event.type == PropertyNotify && 
            event.xproperty.window == _rootWindow &&
            event.xproperty.atom == _netActiveWindowAtom) {
            
            [self checkActiveWindow];
        } else if (event.type == DestroyNotify || event.type == UnmapNotify) {
            Window affected = (event.type == DestroyNotify) ? event.xdestroywindow.window : event.xunmap.window;
            if (affected != 0 && affected == _currentActiveWindow) {
                // Window that was active is now gone - check what the new active window is
                NSDebugLLog(@"gwcomp", @"WindowMonitor: Active window %lu destroyed/unmapped - checking for new active window", affected);
                [self checkActiveWindow];
            }
        }
    }
    
    if (eventsProcessed >= MAX_EVENTS_PER_BATCH && XPending(_display) > 0) {
        NSDebugLLog(@"gwcomp", @"WindowMonitor: Hit event batch limit (%d), %d events still pending - will process on next fd-ready",
              MAX_EVENTS_PER_BATCH, XPending(_display));
    }

    MENU_PROFILE_END(processX11Events);
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

    void (^cleanupBlock)(void) = ^{
        if (_x11EventSource) {
            dispatch_source_cancel(_x11EventSource);
            _x11EventSource = NULL;
        }

        if (_display) {
            XCloseDisplay(_display);
            _display = NULL;
        }
    };

    if (dispatch_get_specific(kWindowMonitorQueueKey) != NULL) {
        cleanupBlock();
    } else if (_x11Queue) {
        dispatch_sync(_x11Queue, cleanupBlock);
    } else {
        cleanupBlock();
    }
    
    _monitoring = NO;
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
