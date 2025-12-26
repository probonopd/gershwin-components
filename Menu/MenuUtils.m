#import "MenuUtils.h"
#import <X11/Xlib.h>
#import <X11/Xutil.h>
#import <X11/Xatom.h>

// Thread-local storage for X11 error tracking
static __thread BOOL x11_error_occurred = NO;
static __thread int x11_error_code = 0;

// Custom X11 error handler that prevents crashes on BadWindow and other errors
static int handleX11Error(Display *display, XErrorEvent *event)
{
    (void)display;  // Suppress unused parameter warning
    x11_error_occurred = YES;
    x11_error_code = event->error_code;
    
    // Log the error but don't crash
    const char *errorName = "Unknown";
    switch (event->error_code) {
        case BadWindow: errorName = "BadWindow"; break;
        case BadDrawable: errorName = "BadDrawable"; break;
        case BadAccess: errorName = "BadAccess"; break;
        case BadAlloc: errorName = "BadAlloc"; break;
        case BadAtom: errorName = "BadAtom"; break;
        case BadColor: errorName = "BadColor"; break;
        case BadCursor: errorName = "BadCursor"; break;
        case BadFont: errorName = "BadFont"; break;
        case BadGC: errorName = "BadGC"; break;
        case BadMatch: errorName = "BadMatch"; break;
        case BadName: errorName = "BadName"; break;
        case BadPixmap: errorName = "BadPixmap"; break;
        case BadRequest: errorName = "BadRequest"; break;
        case BadValue: errorName = "BadValue"; break;
        default: break;
    }
    
    NSLog(@"MenuUtils: X11 error caught and handled: %s (code %d, request %d, serial %lu)",
          errorName, event->error_code, event->request_code, event->serial);
    
    return 0;  // Return 0 to prevent the default error handler from being called
}

// Helper function to install our error handler and clear error state
static void beginSafeX11Operation(void)
{
    x11_error_occurred = NO;
    x11_error_code = 0;
    XSetErrorHandler(handleX11Error);
}

// Helper function to check if an error occurred during X11 operations
static BOOL checkX11Error(Display *display)
{
    if (display) {
        XSync(display, False);  // Flush pending requests and wait for errors
    }
    return x11_error_occurred;
}

@implementation MenuUtils

+ (NSString *)getApplicationNameForWindow:(unsigned long)windowId
{
    // Validate window ID - 0 means no window
    if (windowId == 0) {
        NSLog(@"MenuUtils: Window ID is 0 (no active window), returning nil");
        return nil;
    }

    Display *display = XOpenDisplay(NULL);
    if (!display) {
        return nil;
    }

    // Install error handler to catch BadWindow errors
    beginSafeX11Operation();

    // First validate that the window still exists before accessing properties
    XWindowAttributes attrs;
    Status result = XGetWindowAttributes(display, (Window)windowId, &attrs);
    
    // Check for errors
    if (checkX11Error(display) || result == 0) {
        NSLog(@"MenuUtils: Window %lu no longer exists or is invalid, skipping property access", windowId);
        XCloseDisplay(display);
        return nil;
    }

    // Try to get the application name from WM_CLASS first
    XClassHint classHint;
    NSString *className = nil;

    if (XGetClassHint(display, (Window)windowId, &classHint) == Success && !checkX11Error(display)) {
        if (classHint.res_class) {
            className = [NSString stringWithUTF8String:classHint.res_class];
            XFree(classHint.res_class);
        }
        if (classHint.res_name) {
            XFree(classHint.res_name);
        }
    }

    if (className && [className length] > 0) {
        // Normalize application names for better cache consistency
        NSString *normalizedName = [className lowercaseString];
        if ([normalizedName isEqualToString:@"gimp"] ||
            [normalizedName hasPrefix:@"gimp-"]) {
            XCloseDisplay(display);
            return @"GIMP";
        } else if ([normalizedName isEqualToString:@"inkscape"]) {
            XCloseDisplay(display);
            return @"Inkscape";
        } else if ([normalizedName isEqualToString:@"libreoffice"]) {
            XCloseDisplay(display);
            return @"LibreOffice";
        }
        XCloseDisplay(display);
        return className;
    }

    // Fallback to window title, try to extract application name
    XTextProperty windowName;
    if (XGetWMName(display, (Window)windowId, &windowName) == Success) {
        NSString *title = nil;
        if (windowName.value) {
            title = [NSString stringWithUTF8String:(char *)windowName.value];
            XFree(windowName.value);
        }
        XCloseDisplay(display);

        // Extract application name from window title
        if (title && [title length] > 0) {
            // Special handling for GIMP windows
            if ([title containsString:@"GIMP"] || [title containsString:@"GNU Image Manipulation Program"]) {
                return @"GIMP";
            }

            // Look for patterns like "Document - AppName" or "Title - AppName"
            NSRange dashRange = [title rangeOfString:@" - " options:NSBackwardsSearch];
            if (dashRange.location != NSNotFound) {
                NSString *appName = [title substringFromIndex:dashRange.location + 3];
                if ([appName length] > 0) {
                    return appName;
                }
            }
            // If no dash pattern, return the whole title as fallback
            return title;
        }
    }
    
    XCloseDisplay(display);
    return nil;
}

+ (BOOL)isWindowValid:(unsigned long)windowId
{
    if (windowId == 0) {
        return NO;
    }
    
    Display *display = XOpenDisplay(NULL);
    if (!display) {
        return NO;
    }
    
    // Install error handler to catch BadWindow errors
    beginSafeX11Operation();
    
    XWindowAttributes attrs;
    Status result = XGetWindowAttributes(display, (Window)windowId, &attrs);
    
    // Check for errors - both explicit failure and X11 error
    BOOL valid = (result != 0) && !checkX11Error(display);
    
    XCloseDisplay(display);
    return valid;
}

+ (NSArray *)getAllWindows
{
    Display *display = XOpenDisplay(NULL);
    if (!display) {
        return [NSArray array];
    }
    
    // Install error handler to catch BadWindow errors
    beginSafeX11Operation();
    
    Window root = DefaultRootWindow(display);
    NSMutableArray *windows = [NSMutableArray array];
    
    // Use _NET_CLIENT_LIST to get all managed windows (proper way for window managers)
    Atom clientListAtom = XInternAtom(display, "_NET_CLIENT_LIST", False);
    Atom actualType;
    int actualFormat;
    unsigned long numClientWindows, bytesAfter;
    Window *clientWindows = NULL;
    
    if (XGetWindowProperty(display, root, clientListAtom, 0, 1024, False, XA_WINDOW,
                          &actualType, &actualFormat, &numClientWindows, &bytesAfter,
                          (unsigned char**)&clientWindows) == Success && clientWindows && !checkX11Error(display)) {
        
        NSLog(@"MenuUtils: Found %lu client windows via _NET_CLIENT_LIST", numClientWindows);
        
        for (unsigned long i = 0; i < numClientWindows; i++) {
            [windows addObject:[NSNumber numberWithUnsignedLong:clientWindows[i]]];
        }
        XFree(clientWindows);
    } else {
        if (clientWindows) XFree(clientWindows);
        
        // Fallback to XQueryTree if _NET_CLIENT_LIST is not available
        NSLog(@"MenuUtils: _NET_CLIENT_LIST not available, falling back to XQueryTree");
        Window parent, *children;
        unsigned int nchildren;
        
        if (XQueryTree(display, root, &root, &parent, &children, &nchildren) == Success && children && !checkX11Error(display)) {
            for (unsigned int i = 0; i < nchildren; i++) {
                // Reset error state for each window check
                x11_error_occurred = NO;
                
                XWindowAttributes attrs;
                if (XGetWindowAttributes(display, children[i], &attrs) == Success && !checkX11Error(display)) {
                    if (attrs.map_state == IsViewable && attrs.class == InputOutput) {
                        [windows addObject:[NSNumber numberWithUnsignedLong:children[i]]];
                    }
                }
            }
            XFree(children);
        }
    }
    
    XCloseDisplay(display);
    return windows;
}

+ (unsigned long)getActiveWindow
{
    Display *display = XOpenDisplay(NULL);
    if (!display) {
        return 0;
    }
    
    // Install error handler to catch errors
    beginSafeX11Operation();
    
    Window root = DefaultRootWindow(display);
    Window activeWindow = 0;
    Atom actualType;
    int actualFormat;
    unsigned long nitems, bytesAfter;
    unsigned char *prop = NULL;
    
    Atom activeWindowAtom = XInternAtom(display, "_NET_ACTIVE_WINDOW", False);
    if (XGetWindowProperty(display, root, activeWindowAtom,
                          0, 1, False, AnyPropertyType,
                          &actualType, &actualFormat, &nitems, &bytesAfter,
                          &prop) == Success && prop && !checkX11Error(display)) {
        activeWindow = *(Window*)prop;
        XFree(prop);
    } else if (prop) {
        XFree(prop);
    }
    
    XCloseDisplay(display);
    return activeWindow;
}

+ (NSString *)getWindowProperty:(unsigned long)windowId atomName:(NSString *)atomName
{
    if (windowId == 0) {
        return nil;
    }
    
    Display *display = XOpenDisplay(NULL);
    if (!display) {
        return nil;
    }
    
    // Install error handler to catch BadWindow errors
    beginSafeX11Operation();
    
    Atom atom = XInternAtom(display, [atomName UTF8String], False);
    if (atom == None || checkX11Error(display)) {
        XCloseDisplay(display);
        return nil;
    }
    
    Atom actualType;
    int actualFormat;
    unsigned long nitems, bytesAfter;
    unsigned char *prop = NULL;
    
    int result = XGetWindowProperty(display, (Window)windowId, atom,
                          0, 1024, False, AnyPropertyType,
                          &actualType, &actualFormat, &nitems, &bytesAfter,
                          &prop);
    
    // Check for X11 errors
    if (checkX11Error(display) || result != Success || !prop) {
        if (prop) XFree(prop);
        XCloseDisplay(display);
        return nil;
    }
    
    NSString *resultStr = nil;
    if (actualType == XA_STRING || actualFormat == 8) {
        resultStr = [NSString stringWithUTF8String:(char *)prop];
    }
    
    XFree(prop);
    XCloseDisplay(display);
    return resultStr;
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
    if (windowId == 0) {
        NSLog(@"MenuUtils: Cannot set menu service for window 0");
        return NO;
    }
    
    Display *display = XOpenDisplay(NULL);
    if (!display) {
        NSLog(@"MenuUtils: Failed to open X11 display");
        return NO;
    }
    
    // Install error handler to catch BadWindow errors
    beginSafeX11Operation();
    
    // First check if window is still valid
    XWindowAttributes attrs;
    if (XGetWindowAttributes(display, (Window)windowId, &attrs) == 0 || checkX11Error(display)) {
        NSLog(@"MenuUtils: Window %lu no longer exists, cannot set menu service", windowId);
        XCloseDisplay(display);
        return NO;
    }
    
    BOOL success = YES;
    
    // Set the service name property
    if (service) {
        Atom serviceAtom = XInternAtom(display, "_KDE_NET_WM_APPMENU_SERVICE_NAME", False);
        const char *serviceStr = [service UTF8String];
        XChangeProperty(display, (Window)windowId, serviceAtom, XA_STRING, 8,
                       PropModeReplace, (unsigned char*)serviceStr, strlen(serviceStr));
        if (checkX11Error(display)) {
            NSLog(@"MenuUtils: Failed to set service property for window %lu (window may have been destroyed)", windowId);
            success = NO;
        } else {
            NSLog(@"MenuUtils: Set _KDE_NET_WM_APPMENU_SERVICE_NAME=%@ for window %lu", service, windowId);
        }
    }
    
    // Set the object path property
    if (path && success) {
        Atom pathAtom = XInternAtom(display, "_KDE_NET_WM_APPMENU_OBJECT_PATH", False);
        const char *pathStr = [path UTF8String];
        XChangeProperty(display, (Window)windowId, pathAtom, XA_STRING, 8,
                       PropModeReplace, (unsigned char*)pathStr, strlen(pathStr));
        if (checkX11Error(display)) {
            NSLog(@"MenuUtils: Failed to set path property for window %lu (window may have been destroyed)", windowId);
            success = NO;
        } else {
            NSLog(@"MenuUtils: Set _KDE_NET_WM_APPMENU_OBJECT_PATH=%@ for window %lu", path, windowId);
        }
    }
    
    XFlush(display);
    XCloseDisplay(display);
    return success;
}

+ (BOOL)advertiseGlobalMenuSupport
{
    Display *display = XOpenDisplay(NULL);
    if (!display) {
        NSLog(@"MenuUtils: Failed to open X11 display for advertising global menu support");
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
    XCloseDisplay(display);
    
    NSLog(@"MenuUtils: Successfully advertised global menu support on root window");
    return success;
}

+ (void)removeGlobalMenuSupport
{
    Display *display = XOpenDisplay(NULL);
    if (!display) {
        return;
    }
    
    Window root = DefaultRootWindow(display);
    
    // Remove the global menu properties
    Atom kdeMenuAtom = XInternAtom(display, "_KDE_GLOBAL_MENU_AVAILABLE", False);
    if (kdeMenuAtom != None) {
        XDeleteProperty(display, root, kdeMenuAtom);
    }
    
    Atom unityMenuAtom = XInternAtom(display, "_UNITY_GLOBAL_MENU", False);
    if (unityMenuAtom != None) {
        XDeleteProperty(display, root, unityMenuAtom);
    }
    
    XFlush(display);
    XCloseDisplay(display);
    
    NSLog(@"MenuUtils: Removed global menu support properties from root window");
}

@end
