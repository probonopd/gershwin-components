#import "MenuUtils.h"
#import <X11/Xlib.h>
#import <X11/Xutil.h>
#import <X11/Xatom.h>

@implementation MenuUtils

+ (NSString *)getApplicationNameForWindow:(unsigned long)windowId
{
    Display *display = XOpenDisplay(NULL);
    if (!display) {
        return nil;
    }
    
    XTextProperty windowName;
    if (XGetWMName(display, (Window)windowId, &windowName) == Success) {
        NSString *name = nil;
        if (windowName.value) {
            name = [NSString stringWithUTF8String:(char *)windowName.value];
            XFree(windowName.value);
        }
        XCloseDisplay(display);
        return name;
    }
    
    XCloseDisplay(display);
    return nil;
}

+ (BOOL)isWindowValid:(unsigned long)windowId
{
    Display *display = XOpenDisplay(NULL);
    if (!display) {
        return NO;
    }
    
    XWindowAttributes attrs;
    BOOL valid = (XGetWindowAttributes(display, (Window)windowId, &attrs) == Success);
    
    XCloseDisplay(display);
    return valid;
}

+ (NSArray *)getAllWindows
{
    Display *display = XOpenDisplay(NULL);
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
    
    XCloseDisplay(display);
    return windows;
}

+ (unsigned long)getActiveWindow
{
    Display *display = XOpenDisplay(NULL);
    if (!display) {
        return 0;
    }
    
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
                          &prop) == Success && prop) {
        activeWindow = *(Window*)prop;
        XFree(prop);
    }
    
    XCloseDisplay(display);
    return activeWindow;
}

+ (NSString *)getWindowProperty:(unsigned long)windowId atomName:(NSString *)atomName
{
    Display *display = XOpenDisplay(NULL);
    if (!display) {
        return nil;
    }
    
    Atom atom = XInternAtom(display, [atomName UTF8String], False);
    if (atom == None) {
        XCloseDisplay(display);
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
        XCloseDisplay(display);
        return result;
    }
    
    XCloseDisplay(display);
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
    Display *display = XOpenDisplay(NULL);
    if (!display) {
        NSLog(@"MenuUtils: Failed to open X11 display");
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
