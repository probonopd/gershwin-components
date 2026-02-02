/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */


#import "MenuUtils.h"
#import <X11/Xlib.h>
#import <X11/Xutil.h>
#import <X11/Xatom.h>

@interface MenuUtils (Private)
+ (NSString *)_getApplicationNameForWindow:(unsigned long)windowId display:(Display *)display;
+ (NSString *)_normalizeAppName:(NSString *)title;
@end

@implementation MenuUtils

static Display *_sharedDisplay = NULL;

+ (Display *)sharedDisplay
{
    if (!_sharedDisplay) {
        _sharedDisplay = XOpenDisplay(NULL);
    }
    return _sharedDisplay;
}

+ (void)cleanup
{
    if (_sharedDisplay) {
        XCloseDisplay(_sharedDisplay);
        _sharedDisplay = NULL;
    }
}

+ (Display *)openDisplay
{
    return [self sharedDisplay];
}

+ (void)closeDisplay:(Display *)display
{
    // If we're using sharedDisplay, we don't close it until cleanup
}

+ (unsigned long)getActiveWindow
{
    Display *display = [self sharedDisplay];
    if (!display) return 0;

    Atom actualType;
    int actualFormat;
    unsigned long nitems, bytesAfter;
    unsigned char *prop = NULL;
    unsigned long activeWindow = 0;

    Atom atom = XInternAtom(display, "_NET_ACTIVE_WINDOW", False);
    if (XGetWindowProperty(display, DefaultRootWindow(display), atom,
                          0, 1, False, XA_WINDOW,
                          &actualType, &actualFormat, &nitems, &bytesAfter,
                          &prop) == 0 && prop) {
        if (nitems > 0) {
            activeWindow = *(Window*)prop;
        }
        XFree(prop);
    }

    // Systematic fix: If the active window ID is reported but the window is NO LONGER VALID
    // or NOT MAPPED, then it's effectively NOT the active window anymore.
    if (activeWindow != 0) {
        XWindowAttributes attrs;
        // XGetWindowAttributes returns non-zero on success
        if (XGetWindowAttributes(display, (Window)activeWindow, &attrs) == 0 ||
            attrs.map_state != IsViewable) {
            activeWindow = 0;
        }
    }

    return activeWindow;
}

// Internal helper that reuses an existing display connection
+ (NSString *)_getApplicationNameForWindow:(unsigned long)windowId display:(Display *)display
{
    if (!display || windowId == 0) return nil;

    // First validate that the window still exists before accessing properties
    XWindowAttributes attrs;
    // Set an error handler? XGetWindowAttributes is reasonably safe if we check return,
    // but a global error handler might be needed if we were really paranoid.
    if (XGetWindowAttributes(display, (Window)windowId, &attrs) != Success) {
        // NSLog(@"MenuUtils: Window 0x%lx no longer exists, skipping name lookup", windowId);
        return nil;
    }

    // Try to get the application name from WM_CLASS first
    XClassHint classHint = {NULL, NULL};
    NSString *className = nil;

    if (XGetClassHint(display, (Window)windowId, &classHint) == Success) {
        if (classHint.res_class != NULL) {
            className = [NSString stringWithUTF8String:classHint.res_class];
        }
        if (classHint.res_class != NULL || classHint.res_name != NULL) {
            char *strings[3] = {classHint.res_class, classHint.res_name, NULL};
            XFreeStringList(strings);
        }
    }

    if (className && [className length] > 0) {
        NSString *normalizedName = [className lowercaseString];
        if ([normalizedName isEqualToString:@"gimp"] ||
            [normalizedName hasPrefix:@"gimp-"]) {
            return @"GIMP";
        } else if ([normalizedName isEqualToString:@"inkscape"]) {
            return @"Inkscape";
        } else if ([normalizedName isEqualToString:@"libreoffice"]) {
            return @"LibreOffice";
        } else if ([normalizedName isEqualToString:@"systempreferences"]) {
            return @"System Preferences";
        } else if ([normalizedName isEqualToString:@"textedit"]) {
            return @"TextEdit";
        }
        return className;
    }

    // Fallback to _NET_WM_NAME (preferred for UTF-8)
    Atom netWmName = XInternAtom(display, "_NET_WM_NAME", False);
    Atom utf8String = XInternAtom(display, "UTF8_STRING", False);
    Atom actualType;
    int actualFormat;
    unsigned long nitems, bytesAfter;
    unsigned char *prop = NULL;

    if (XGetWindowProperty(display, (Window)windowId, netWmName,
                          0, 1024, False, utf8String,
                          &actualType, &actualFormat, &nitems, &bytesAfter,
                          &prop) == Success && prop) {
        NSString *title = [NSString stringWithUTF8String:(char *)prop];
        XFree(prop);
        if (title && [title length] > 0) {
            return [self _normalizeAppName:title];
        }
    }

    // Fallback to WM_NAME
    XTextProperty windowName;
    if (XGetWMName(display, (Window)windowId, &windowName) == Success) {
        NSString *title = nil;
        if (windowName.value) {
            title = [NSString stringWithUTF8String:(char *)windowName.value];
            XFree(windowName.value);
        }

        if (title && [title length] > 0) {
            return [self _normalizeAppName:title];
        }
    }
    
    return nil;
}

+ (NSString *)_normalizeAppName:(NSString *)title
{
    if ([title containsString:@"GIMP"] || [title containsString:@"GNU Image Manipulation Program"]) {
        return @"GIMP";
    }
    if ([title containsString:@"System Preferences"]) {
        return @"System Preferences";
    }
    NSRange dashRange = [title rangeOfString:@" - " options:NSBackwardsSearch];
    if (dashRange.location != NSNotFound) {
        NSString *appName = [title substringFromIndex:dashRange.location + 3];
        if ([appName length] > 0) {
            return appName;
        }
    }
    return title;
}

+ (NSString *)getApplicationNameForWindow:(unsigned long)windowId
{
    // Validate window ID - 0 means no window
    if (windowId == 0) {
        NSLog(@"MenuUtils: Window ID is 0 (no active window), returning nil");
        return nil;
    }

    Display *display = [self openDisplay];
    if (!display) {
        return nil;
    }

    NSString *name = [self _getApplicationNameForWindow:windowId display:display];
    
    [self closeDisplay:display];
    return name;
}

+ (BOOL)isWindowValid:(unsigned long)windowId
{
    if (windowId == 0) return NO;

    Display *display = [self openDisplay];
    if (!display) {
        return NO;
    }
    
    XWindowAttributes attrs;
    if (XGetWindowAttributes(display, (Window)windowId, &attrs) == Success) {
        return YES;
    }
    
    // Low-level check if the window exists using XQueryTree might be more robust
    // but XGetWindowAttributes is usually sufficient.
    NSLog(@"MenuUtils: XGetWindowAttributes failed for 0x%lx", windowId);
    return NO;
}

+ (BOOL)isWindowMapped:(unsigned long)windowId
{
    if (windowId == 0) return NO;

    Display *display = [self openDisplay];
    if (!display) {
        return NO;
    }
    
    XWindowAttributes attrs;
    BOOL mapped = NO;
    if (XGetWindowAttributes(display, (Window)windowId, &attrs) == Success) {
        mapped = (attrs.map_state != IsUnmapped);
        if (!mapped) {
            NSLog(@"MenuUtils: Window 0x%lx is unmapped (state %d)", windowId, attrs.map_state);
        }
    } else {
        NSLog(@"MenuUtils: Failed to get attributes for window 0x%lx", windowId);
    }
    
    [self closeDisplay:display];
    return mapped;
}

+ (BOOL)isDesktopWindow:(unsigned long)windowId
{
    if (windowId == 0) {
        return NO;
    }
    
    Display *display = [self openDisplay];
    if (!display) {
        return NO;
    }
    
    // Check if window has _NET_WM_WINDOW_TYPE_DESKTOP
    Atom actualType;
    int actualFormat;
    unsigned long nitems, bytesAfter;
    unsigned char *prop = NULL;
    BOOL isDesktop = NO;
    
    Atom desktopTypeAtom = XInternAtom(display, "_NET_WM_WINDOW_TYPE_DESKTOP", False);
    Atom windowTypeAtom = XInternAtom(display, "_NET_WM_WINDOW_TYPE", False);
    
    if (XGetWindowProperty(display, (Window)windowId, windowTypeAtom,
                          0, (~0L), False, XA_ATOM,
                          &actualType, &actualFormat, &nitems, &bytesAfter,
                          &prop) == Success && prop) {
        Atom *types = (Atom *)prop;
        for (unsigned long i = 0; i < nitems; i++) {
            if (types[i] == desktopTypeAtom) {
                isDesktop = YES;
                break;
            }
        }
        XFree(prop);
    }
    
    [self closeDisplay:display];
    return isDesktop;
}

+ (NSArray *)getAllWindows
{
    Display *display = [self openDisplay];
    if (!display) {
        return [NSArray array];
    }
    
    Window root = DefaultRootWindow(display);
    Window parent, *children;
    unsigned int nchildren;
    
    NSMutableArray *windows = [NSMutableArray array];
    
    if (XQueryTree(display, root, &root, &parent, &children, &nchildren) == Success) {
        for (unsigned int i = 0; i < nchildren; i++) {
            XWindowAttributes attrs;
            if (XGetWindowAttributes(display, children[i], &attrs) == Success) {
                if (attrs.map_state == IsViewable && attrs.class == InputOutput) {
                    [windows addObject:[NSNumber numberWithUnsignedLong:children[i]]];
                }
            }
        }
        XFree(children);
    }
    
    [self closeDisplay:display]; // Fixed leak
    return windows;
}

+ (NSDictionary *)getAllVisibleWindowApplications
{
    Display *display = [self openDisplay];
    if (!display) {
        return [NSDictionary dictionary];
    }
    
    Window root = DefaultRootWindow(display);
    NSMutableDictionary *windowApps = [NSMutableDictionary dictionary];
    
    // Use _NET_CLIENT_LIST to get all managed windows across the whole tree
    Atom clientListAtom = XInternAtom(display, "_NET_CLIENT_LIST", False);
    Atom actualType;
    int actualFormat;
    unsigned long nitems, bytesAfter;
    unsigned char *prop = NULL;
    
    // Read up to 1024 windows
    if (XGetWindowProperty(display, root, clientListAtom, 0, 1024, False, XA_WINDOW,
                          &actualType, &actualFormat, &nitems, &bytesAfter, &prop) == 0 && prop) {
        Window *winList = (Window *)prop;
        for (unsigned long i = 0; i < nitems; i++) {
            Window w = winList[i];
            XWindowAttributes attrs;
            if (XGetWindowAttributes(display, w, &attrs)) {
                if (attrs.map_state == IsViewable) {
                    NSNumber *key = [NSNumber numberWithUnsignedLong:w];
                    NSString *appName = [self _getApplicationNameForWindow:w display:display];
                    if (appName && [appName length] > 0) {
                        [windowApps setObject:appName forKey:key];
                    }
                }
            }
        }
        XFree(prop);
    } else {
        // Fallback to XQueryTree if _NET_CLIENT_LIST is not available
        Window parent, *children;
        unsigned int nchildren;
        if (XQueryTree(display, root, &root, &parent, &children, &nchildren)) {
            for (unsigned int i = 0; i < nchildren; i++) {
                XWindowAttributes attrs;
                if (XGetWindowAttributes(display, children[i], &attrs)) {
                    if (attrs.map_state == IsViewable) {
                        NSNumber *key = [NSNumber numberWithUnsignedLong:children[i]];
                        NSString *appName = [self _getApplicationNameForWindow:children[i] display:display];
                        if (appName && [appName length] > 0) {
                            [windowApps setObject:appName forKey:key];
                        }
                    }
                }
            }
            if (children) XFree(children);
        }
    }
    
    [self closeDisplay:display];
    return windowApps;
}

+ (unsigned long)findDesktopWindow
{
    Display *display = [self openDisplay];
    if (!display) {
        return 0;
    }
    
    Window root = DefaultRootWindow(display);
    Window parent, *children;
    unsigned int nchildren;
    unsigned long desktopWindow = 0;
    
    // Atoms for checks
    Atom desktopTypeAtom = XInternAtom(display, "_NET_WM_WINDOW_TYPE_DESKTOP", False);
    Atom windowTypeAtom = XInternAtom(display, "_NET_WM_WINDOW_TYPE", False);
    
    if (XQueryTree(display, root, &root, &parent, &children, &nchildren) == Success) {
        for (unsigned int i = 0; i < nchildren; i++) {
            Window w = children[i];
            
            // Check properties
            Atom actualType;
            int actualFormat;
            unsigned long nitems, bytesAfter;
            unsigned char *prop = NULL;
            
            if (XGetWindowProperty(display, w, windowTypeAtom,
                                  0, (~0L), False, XA_ATOM,
                                  &actualType, &actualFormat, &nitems, &bytesAfter,
                                  &prop) == Success && prop) {
                Atom *types = (Atom *)prop;
                for (unsigned long j = 0; j < nitems; j++) {
                    if (types[j] == desktopTypeAtom) {
                        desktopWindow = w;
                        break;
                    }
                }
                XFree(prop);
                
                if (desktopWindow != 0) {
                    break;
                }
            }
        }
        XFree(children);
    }
    
    [self closeDisplay:display];
    return desktopWindow;
}

+ (BOOL)isWindowSkippableAsActive:(unsigned long)windowId
{
    if (windowId == 0) return YES;

    Display *display = [self openDisplay];
    if (!display) return NO;

    BOOL shouldSkip = NO;

    // Get window attributes
    XWindowAttributes attrs;
    if (XGetWindowAttributes(display, (Window)windowId, &attrs) == 0) {
        // Can't get attrs; be conservative and treat as not skippable
        [self closeDisplay:display];
        return NO;
    }

    // Skip override-redirect windows (tooltips, menus from toolkits often set this)
    if (attrs.override_redirect) {
        NSLog(@"MenuUtils: Window %lu has override_redirect - skipping as active", windowId);
        [self closeDisplay:display];
        return YES;
    }

    // Check _MOTIF_WM_HINTS decorations flag (decorations == 0 => undecorated)
    Atom motifAtom = XInternAtom(display, "_MOTIF_WM_HINTS", False);
    if (motifAtom != None) {
        Atom actualType; int actualFormat; unsigned long nitems, bytesAfter;
        unsigned char *prop = NULL;
        if (XGetWindowProperty(display, (Window)windowId, motifAtom,
                              0, 5, False, XA_CARDINAL,
                              &actualType, &actualFormat, &nitems, &bytesAfter,
                              &prop) == Success && prop) {
            long *hints = (long *)prop;
            if (nitems >= 3) {
                long decorations = hints[2];
                if (decorations == 0) {
                    XFree(prop);
                    NSLog(@"MenuUtils: Window %lu has no decorations (_MOTIF_WM_HINTS) - skipping as active", windowId);
                    [self closeDisplay:display];
                    return YES;
                }
            }
            XFree(prop);
        }
    }

    // Check _NET_WM_WINDOW_TYPE for tooltip/popup/menu/notification
    Atom windowTypeAtom = XInternAtom(display, "_NET_WM_WINDOW_TYPE", False);
    Atom tooltipAtom = XInternAtom(display, "_NET_WM_WINDOW_TYPE_TOOLTIP", False);
    Atom popupAtom = XInternAtom(display, "_NET_WM_WINDOW_TYPE_POPUP_MENU", False);
    Atom dropdownAtom = XInternAtom(display, "_NET_WM_WINDOW_TYPE_DROPDOWN_MENU", False);
    Atom notifAtom = XInternAtom(display, "_NET_WM_WINDOW_TYPE_NOTIFICATION", False);
    Atom menuAtom = XInternAtom(display, "_NET_WM_WINDOW_TYPE_MENU", False);

    if (windowTypeAtom != None) {
        Atom actualType; int actualFormat; unsigned long nitems, bytesAfter;
        unsigned char *prop = NULL;
        if (XGetWindowProperty(display, (Window)windowId, windowTypeAtom,
                              0, (~0L), False, XA_ATOM,
                              &actualType, &actualFormat, &nitems, &bytesAfter,
                              &prop) == Success && prop) {
            Atom *types = (Atom *)prop;
            for (unsigned long i = 0; i < nitems; i++) {
                if (types[i] == tooltipAtom || types[i] == popupAtom || types[i] == dropdownAtom || types[i] == notifAtom || types[i] == menuAtom) {
                    XFree(prop);
                    NSLog(@"MenuUtils: Window %lu has skippable _NET_WM_WINDOW_TYPE - skipping as active", windowId);
                    [self closeDisplay:display];
                    return YES;
                }
            }
            XFree(prop);
        }
    }

    [self closeDisplay:display];
    return shouldSkip;
}

+ (pid_t)getWindowPID:(unsigned long)windowId
{ 
    if (windowId == 0) return 0;

    Display *display = [self openDisplay];
    if (!display) return 0;

    Atom pidAtom = XInternAtom(display, "_NET_WM_PID", False);
    if (pidAtom == None) {
        [self closeDisplay:display];
        return 0;
    }

    Atom actualType;
    int actualFormat;
    unsigned long nitems, bytesAfter;
    unsigned char *prop = NULL;
    pid_t pid = 0;

    if (XGetWindowProperty(display, (Window)windowId, pidAtom,
                          0, 1, False, XA_CARDINAL,
                          &actualType, &actualFormat, &nitems, &bytesAfter,
                          &prop) == Success && prop) {
        if (nitems >= 1) {
            if (actualFormat == 32) {
                pid = (pid_t)(*(uint32_t *)prop);
            } else if (actualFormat == 16) {
                pid = (pid_t)(*(uint16_t *)prop);
            } else if (actualFormat == 8) {
                pid = (pid_t)(*(uint8_t *)prop);
            }
        }
        XFree(prop);
    }

    [self closeDisplay:display];
    return pid;
}
        
+ (NSString *)getWindowProperty:(unsigned long)windowId atomName:(NSString *)atomName
{
    Display *display = [self openDisplay];
    if (!display) {
        return nil;
    }

    Atom atom = XInternAtom(display, [atomName UTF8String], False);
    if (atom == None) {
        [self closeDisplay:display];
        return nil;
    }

    Atom actualType;
    int actualFormat;
    unsigned long nitems, bytesAfter;
    unsigned char *prop = NULL;

    if (XGetWindowProperty(display, (Window)windowId, atom,
                          0, 1024, False, AnyPropertyType,
                          &actualType, &actualFormat, &nitems, &bytesAfter,
                          &prop) == Success && prop) {

        NSString *result = nil;
        if (actualType == XA_STRING || actualFormat == 8) {
            result = [NSString stringWithUTF8String:(char *)prop];
        }

        XFree(prop);
        [self closeDisplay:display];
        return result;
    }

    [self closeDisplay:display];
    return nil;
}

+ (NSString*)getWindowMenuService:(unsigned long)windowId
{
    return [self getWindowProperty:windowId atomName:@"_KDE_NET_WM_APPMENU_SERVICE_NAME"];
}

+ (NSString*)getWindowMenuPath:(unsigned long)windowId
{
    return [self getWindowProperty:windowId atomName:@"_KDE_NET_WM_APPMENU_OBJECT_PATH"];
}

+ (BOOL)setWindowMenuService:(NSString*)service path:(NSString*)path forWindow:(unsigned long)windowId
{
    Display *display = [self openDisplay];
    if (!display) {
        return NO;
    }
    
    BOOL success = YES;
    
    // Set the service name property
    if (service) {
        Atom serviceAtom = XInternAtom(display, "_KDE_NET_WM_APPMENU_SERVICE_NAME", False);
        const char *serviceStr = [service UTF8String];
        int result = XChangeProperty(display, (Window)windowId, serviceAtom, XA_STRING, 8,
                                   PropModeReplace, (unsigned char*)serviceStr, strlen(serviceStr));
        if (result != Success) {
            NSLog(@"MenuUtils: Failed to set service property for window %lu", windowId);
            success = NO;
        } else {
            NSLog(@"MenuUtils: Set _KDE_NET_WM_APPMENU_SERVICE_NAME=%@ for window %lu", service, windowId);
        }
    }
    
    // Set the object path property
    if (path) {
        Atom pathAtom = XInternAtom(display, "_KDE_NET_WM_APPMENU_OBJECT_PATH", False);
        const char *pathStr = [path UTF8String];
        int result = XChangeProperty(display, (Window)windowId, pathAtom, XA_STRING, 8,
                                   PropModeReplace, (unsigned char*)pathStr, strlen(pathStr));
        if (result != Success) {
            NSLog(@"MenuUtils: Failed to set path property for window %lu", windowId);
            success = NO;
        } else {
            NSLog(@"MenuUtils: Set _KDE_NET_WM_APPMENU_OBJECT_PATH=%@ for window %lu", path, windowId);
        }
    }
    
    XFlush(display);
    [self closeDisplay:display];
    return success;
}

+ (BOOL)advertiseGlobalMenuSupport
{
    Display *display = [self openDisplay];
    if (!display) {
        return NO;
    }
    
    Window root = DefaultRootWindow(display);
    BOOL success = YES;
    
    // Set _NET_SUPPORTING_WM_CHECK to advertise window manager support
    Atom supportingWmAtom = XInternAtom(display, "_NET_SUPPORTING_WM_CHECK", False);
    if (supportingWmAtom != None) {
        // Create a dummy window for WM identification
        Window dummyWindow = XCreateSimpleWindow(display, root, -100, -100, 1, 1, 0, 0, 0);
        XChangeProperty(display, root, supportingWmAtom, XA_WINDOW, 32,
                       PropModeReplace, (unsigned char*)&dummyWindow, 1);
        XChangeProperty(display, dummyWindow, supportingWmAtom, XA_WINDOW, 32,
                       PropModeReplace, (unsigned char*)&dummyWindow, 1);
        
        // Set WM name
        Atom wmNameAtom = XInternAtom(display, "_NET_WM_NAME", False);
        const char *wmName = "Menu.app Global Menu";
        XChangeProperty(display, dummyWindow, wmNameAtom, XInternAtom(display, "UTF8_STRING", False), 8,
                       PropModeReplace, (unsigned char*)wmName, strlen(wmName));
        
        NSLog(@"MenuUtils: Set _NET_SUPPORTING_WM_CHECK for global menu support");
    }
    
    // Set _NET_SUPPORTED to advertise supported features
    Atom supportedAtom = XInternAtom(display, "_NET_SUPPORTED", False);
    if (supportedAtom != None) {
        Atom supportedFeatures[] = {
            XInternAtom(display, "_NET_WM_NAME", False),
            XInternAtom(display, "_NET_ACTIVE_WINDOW", False),
            XInternAtom(display, "_KDE_NET_WM_APPMENU_SERVICE_NAME", False),
            XInternAtom(display, "_KDE_NET_WM_APPMENU_OBJECT_PATH", False)
        };
        
        XChangeProperty(display, root, supportedAtom, XA_ATOM, 32,
                       PropModeReplace, (unsigned char*)supportedFeatures, 
                       sizeof(supportedFeatures) / sizeof(Atom));
        
        NSLog(@"MenuUtils: Set _NET_SUPPORTED with global menu atoms");
    }
    
    // Set KDE-specific property to indicate global menu support
    Atom kdeMenuAtom = XInternAtom(display, "_KDE_GLOBAL_MENU_AVAILABLE", False);
    if (kdeMenuAtom != None) {
        unsigned long value = 1;
        XChangeProperty(display, root, kdeMenuAtom, XA_CARDINAL, 32,
                       PropModeReplace, (unsigned char*)&value, 1);
        
        NSLog(@"MenuUtils: Set _KDE_GLOBAL_MENU_AVAILABLE=1 on root window");
    }
    
    // Set Unity-specific property for Ubuntu compatibility
    Atom unityMenuAtom = XInternAtom(display, "_UNITY_GLOBAL_MENU", False);
    if (unityMenuAtom != None) {
        unsigned long value = 1;
        XChangeProperty(display, root, unityMenuAtom, XA_CARDINAL, 32,
                       PropModeReplace, (unsigned char*)&value, 1);
        
        NSLog(@"MenuUtils: Set _UNITY_GLOBAL_MENU=1 on root window");
    }
    
    XFlush(display);
    XSync(display, False);
    
    [self closeDisplay:display];
    return success;
}

+ (void)removeGlobalMenuSupport
{
    Display *display = [self openDisplay];
    if (!display) {
        return;
    }
    
    // Remove the global menu properties
    Window root = DefaultRootWindow(display);
    
    Atom kdeMenuAtom = XInternAtom(display, "_KDE_GLOBAL_MENU_AVAILABLE", False);
    if (kdeMenuAtom != None) {
        XDeleteProperty(display, root, kdeMenuAtom);
    }
    
    Atom unityMenuAtom = XInternAtom(display, "_UNITY_GLOBAL_MENU", False);
    if (unityMenuAtom != None) {
        XDeleteProperty(display, root, unityMenuAtom);
    }
    
    XFlush(display);
    [self closeDisplay:display];
    
    NSLog(@"MenuUtils: Removed global menu support properties from root window");
}

@end
