/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "WindowMonitor.h"
#import "MenuUtils.h"
#import "MenuController.h"
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
        
        NSLog(@"WindowMonitor: Initialized");
    }
    return self;
}

- (void)dealloc
{
    [self stopMonitoring];
}

- (BOOL)startMonitoring
{
    if (_monitoring) {
        NSLog(@"WindowMonitor: Already monitoring");
        return YES;
    }

    NSLog(@"WindowMonitor: Starting event-driven monitoring using GCD");

    // Initialize all X11 operations on the dedicated serial queue to ensure
    // the Display is only used from one thread (avoids Xlib thread-safety issues)
    __block BOOL initSuccess = NO;
    dispatch_sync(_x11Queue, ^{
        // Open X11 display on the X11 queue thread
        _display = XOpenDisplay(NULL);
        if (!_display) {
            NSLog(@"WindowMonitor: ERROR - Cannot open X11 display");
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
        NSLog(@"WindowMonitor: X11 file descriptor: %d", x11Fd);

        // Create GCD dispatch source for X11 file descriptor on the same queue
        _x11EventSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, x11Fd, 0, _x11Queue);
        if (!_x11EventSource) {
            NSLog(@"WindowMonitor: ERROR - Failed to create dispatch source");
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
            NSLog(@"WindowMonitor: Dispatch source cancelled");
        });

        // Start monitoring
        dispatch_resume(_x11EventSource);

        initSuccess = YES;
    });

    if (!initSuccess) return NO;

    _monitoring = YES;
    NSLog(@"WindowMonitor: Monitoring started - event-driven, zero-polling");

    // Get initial active window (runs on the X11 queue)
    dispatch_async(_x11Queue, ^{
        [self checkInitialActiveWindow];
    });

    return YES;
}

- (void)processX11Events
{
    if (!_display) return;
    
    // TIGHT-LOOP GUARD: Cap the number of events processed per invocation
    // to prevent unbounded spinning when events arrive faster than processing
    static const int MAX_EVENTS_PER_BATCH = 50;
    int eventsProcessed = 0;
    
    int totalPendingAtEntry = XPending(_display);
    (void)totalPendingAtEntry; // suppress unused warning when NSDebugLog is compiled out

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
                NSLog(@"WindowMonitor: Active window %lu destroyed/unmapped - checking for new active window", affected);
                [self checkActiveWindow];
            }
        }
    }
    
    if (eventsProcessed > 0) {
        NSDebugLog(@"WindowMonitor: Processed %d X11 event(s) in batch (had %d pending at entry)",
                   eventsProcessed, totalPendingAtEntry);
    }
    if (eventsProcessed >= MAX_EVENTS_PER_BATCH && XPending(_display) > 0) {
        NSLog(@"WindowMonitor: Hit event batch limit (%d), %d events still pending - will process on next fd-ready",
              MAX_EVENTS_PER_BATCH, XPending(_display));
    }
}

- (void)checkInitialActiveWindow
{
    if (!_display) return;
    
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
        
        if (canGetAttrs && attrs.map_state == IsUnmapped) {
            NSLog(@"WindowMonitor: Initial active window %lu is unmapped", newActiveWindow);
            newActiveWindow = 0;
        } else if (!canGetAttrs) {
            NSLog(@"WindowMonitor: Cannot get attributes for initial window %lu - trusting WM", newActiveWindow);
        }
        
        // Select StructureNotifyMask only (no PropertyChangeMask — see checkActiveWindow comment)
        if (newActiveWindow != 0) {
            XSelectInput(_display, (Window)newActiveWindow, StructureNotifyMask);
        }
    }
    
    if (newActiveWindow != _currentActiveWindow) {
        _currentActiveWindow = newActiveWindow;
        
        NSDictionary *userInfo = @{@"windowId": @(newActiveWindow)};
        [self performSelectorOnMainThread:@selector(_postWindowNotification:)
                               withObject:userInfo
                            waitUntilDone:NO];
    }
}

- (void)checkActiveWindow
{
    if (!_display) return;
    
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

    if (newActiveWindow != 0) {
        XWindowAttributes attrs;
        BOOL canGetAttrs = XGetWindowAttributes(_display, (Window)newActiveWindow, &attrs);
        
        if (canGetAttrs && attrs.map_state == IsUnmapped) {
            NSLog(@"WindowMonitor: Active window %lu is unmapped - treating as no active window", newActiveWindow);
            newActiveWindow = 0;
        } else if (!canGetAttrs) {
            NSLog(@"WindowMonitor: Cannot get attributes for active window %lu - trusting WM report anyway", newActiveWindow);
        }
        
        // Select StructureNotifyMask only — NOT PropertyChangeMask.
        // PropertyChangeMask causes a torrent of events whenever the focused app
        // updates any X11 property (page title, loading progress, state hints …).
        // Those events are never acted on by processX11Events (which only handles
        // _NET_ACTIVE_WINDOW changes on the root window), so subscribing to them
        // wastes CPU waking the GCD dispatch source for no reason.
        if (newActiveWindow != 0) {
            XSelectInput(_display, (Window)newActiveWindow, StructureNotifyMask);
        }
    }
    
    if (newActiveWindow != _currentActiveWindow) {
        NSLog(@"WindowMonitor: Active window changed from %lu to %lu", _currentActiveWindow, newActiveWindow);
        _currentActiveWindow = newActiveWindow;
        
        NSDictionary *userInfo = @{@"windowId": @(newActiveWindow)};
        [self performSelectorOnMainThread:@selector(_postWindowNotification:)
                               withObject:userInfo
                            waitUntilDone:NO];
    }
}

- (void)stopMonitoring
{
    if (!_monitoring) return;
    
    if (_x11EventSource) {
        dispatch_source_cancel(_x11EventSource);
        _x11EventSource = NULL;
    }
    
    if (_display) {
        XCloseDisplay(_display);
        _display = NULL;
    }
    
    _monitoring = NO;
    NSLog(@"WindowMonitor: Stopped monitoring");
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
