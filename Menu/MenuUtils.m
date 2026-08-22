/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */


#import "MenuUtils.h"
#import <X11/Xlib.h>
#import <X11/Xutil.h>
#import <X11/Xatom.h>
#import <dispatch/dispatch.h>

@interface MenuUtils (Private)
+ (NSString *)_getApplicationNameForWindow:(unsigned long)windowId display:(Display *)display;
+ (NSString *)_normalizeAppName:(NSString *)title;
@end

@implementation MenuUtils

static Display *_sharedDisplay = NULL;
static dispatch_once_t _sharedDisplayOnce;

+ (Display *)sharedDisplay
{
    dispatch_once(&_sharedDisplayOnce, ^{
        _sharedDisplay = XOpenDisplay(NULL);
        if (!_sharedDisplay) {
            NSDebugLLog(@"gwcomp", @"MenuUtils: Failed to open shared X11 display");
        }
    });
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

+ (unsigned long)getActiveWindowFresh
{
    /* Fresh connection so the poll can run from any thread - see isWindowValid:. */
    Display *display = XOpenDisplay(NULL);
    if (!display) return 0;

    unsigned long activeWindow = 0;
    Atom atom = XInternAtom(display, "_NET_ACTIVE_WINDOW", False);
    Atom actualType;
    int actualFormat;
    unsigned long nitems, bytesAfter;
    unsigned char *prop = NULL;
    if (XGetWindowProperty(display, DefaultRootWindow(display), atom,
                          0, 1, False, XA_WINDOW,
                          &actualType, &actualFormat, &nitems, &bytesAfter,
                          &prop) == 0 && prop) {
        if (nitems > 0) {
            activeWindow = *(Window*)prop;
        }
        XFree(prop);
    }
    XCloseDisplay(display);
    return activeWindow;
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
        NSDebugLLog(@"gwcomp", @"MenuUtils: Window ID is 0 (no active window), returning nil");
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

    /* Use a FRESH display connection: the shared display is touched from
     * several threads (WindowMonitor, watchdog, importers), and a
     * cross-thread interleave can make XGetWindowAttributes spuriously fail
     * on it for perfectly valid windows - which the menu watchdog then took
     * as "app closed" and cleared the menu (and the app's shortcuts). */
    Display *display = XOpenDisplay(NULL);
    if (!display) {
        return NO;
    }
    
    XWindowAttributes attrs;
    BOOL ok = (XGetWindowAttributes(display, (Window)windowId, &attrs) == Success);
    XCloseDisplay(display);
    return ok;
}

+ (BOOL)isWindowMapped:(unsigned long)windowId
{
    if (windowId == 0) return NO;

    /* Fresh connection per call - see isWindowValid: for why the shared
     * display cannot be trusted for these checks. */
    Display *display = XOpenDisplay(NULL);
    if (!display) {
        return NO;
    }
    
    XWindowAttributes attrs;
    BOOL mapped = NO;
    if (XGetWindowAttributes(display, (Window)windowId, &attrs) == Success) {
        // Require IsViewable: window AND all ancestors must be mapped.
        // IsUnviewable (window mapped but an ancestor is not) is treated as not visible.
        mapped = (attrs.map_state == IsViewable);
    } else {
        // XGetWindowAttributes failure does NOT mean the window is unmapped.
        // It can fail due to X11 thread-safety issues with shared Display connections,
        // or transient server states. Assume mapped (safe default) and let the caller
        // use isWindowValid for definitive existence checks.
        mapped = YES;
    }
    
    XCloseDisplay(display);
    return mapped;
}

+ (BOOL)isRealApplicationWindow:(unsigned long)windowId
{
    if (windowId == 0) return NO;

    Display *display = [self openDisplay];
    if (!display) return NO;

    XWindowAttributes attrs;
    BOOL real = NO;
    if (XGetWindowAttributes(display, (Window)windowId, &attrs) == Success) {
        /* Mapped (window and ancestors) and not an override-redirect popup. */
        if (attrs.map_state == IsViewable && !attrs.override_redirect) {
            /* WM-managed, or a GNUstep window.  Chromium keeps internal helper
             * windows that look like normal toplevels (viewable, NORMAL type)
             * but are neither WM-managed nor GNUstep - they must not be treated
             * as app windows, otherwise the menu chases them and clears. */
            BOOL managed = NO;
            Atom wmStateAtom = XInternAtom(display, "WM_STATE", True);
            if (wmStateAtom != None) {
                Atom t2; int f2; unsigned long n2, b2; unsigned char *p2 = NULL;
                if (XGetWindowProperty(display, (Window)windowId, wmStateAtom, 0, 1,
                                       False, AnyPropertyType, &t2, &f2, &n2, &b2,
                                       &p2) == Success && p2) {
                    managed = YES;
                    XFree(p2);
                }
            }
            if (!managed) {
                Atom gsAtom = XInternAtom(display, "_GNUSTEP_WM_ATTR", True);
                if (gsAtom != None) {
                    Atom t3; int f3; unsigned long n3, b3; unsigned char *p3 = NULL;
                    if (XGetWindowProperty(display, (Window)windowId, gsAtom, 0, 1,
                                           False, AnyPropertyType, &t3, &f3, &n3, &b3,
                                           &p3) == Success && p3) {
                        managed = YES;
                        XFree(p3);
                    }
                }
            }
            if (managed) {
                /* _NET_WM_WINDOW_TYPE: accept normal/dialog/utility or absent. */
                Atom wmTypeAtom = XInternAtom(display, "_NET_WM_WINDOW_TYPE", True);
                Atom wmTypeNormal = XInternAtom(display, "_NET_WM_WINDOW_TYPE_NORMAL", False);
                Atom wmTypeDialog = XInternAtom(display, "_NET_WM_WINDOW_TYPE_DIALOG", False);
                Atom wmTypeUtility = XInternAtom(display, "_NET_WM_WINDOW_TYPE_UTILITY", False);
                BOOL typeOK = YES;
                if (wmTypeAtom != None) {
                    Atom actualType; int actualFormat;
                    unsigned long nItems, bytesAfter;
                    unsigned char *prop = NULL;
                    if (XGetWindowProperty(display, (Window)windowId, wmTypeAtom, 0, 16,
                                           False, XA_ATOM, &actualType, &actualFormat,
                                           &nItems, &bytesAfter, &prop) == Success) {
                        if (prop && nItems > 0) {
                            Atom first = ((Atom *)prop)[0];
                            typeOK = (first == wmTypeNormal || first == wmTypeDialog
                                      || first == wmTypeUtility);
                        }
                        if (prop) XFree(prop);
                    }
                }
                real = typeOK;
            }
        }
    }

    [self closeDisplay:display];
    return real;
}

+ (BOOL)isDesktopWindow:(unsigned long)windowId
{
    if (windowId == 0) {
        return NO;
    }
    
    /* Fresh connection - see isWindowValid:. */
    Display *display = XOpenDisplay(NULL);
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
    
    XCloseDisplay(display);
    return isDesktop;
}

+ (BOOL)isDialogWindow:(unsigned long)windowId
{
    // Detects dialog/transient windows where the app menu should stay on the owner app.
    if (windowId == 0) {
        return NO;
    }

    // Use a dedicated display connection for this probe to avoid contention with
    // other X11 users of the shared display (WindowMonitor, render path, etc.).
    Display *display = XOpenDisplay(NULL);
    if (!display) {
        return NO;
    }
    
    Atom actualType;
    int actualFormat;
    unsigned long nitems, bytesAfter;
    unsigned char *prop = NULL;
    BOOL isDialog = NO;
    
    // Dialog/transient window type atoms
    Atom dialogTypeAtom = XInternAtom(display, "_NET_WM_WINDOW_TYPE_DIALOG", False);
    Atom utilityTypeAtom = XInternAtom(display, "_NET_WM_WINDOW_TYPE_UTILITY", False);
    Atom splashTypeAtom = XInternAtom(display, "_NET_WM_WINDOW_TYPE_SPLASH", False);
    Atom toolbarTypeAtom = XInternAtom(display, "_NET_WM_WINDOW_TYPE_TOOLBAR", False);
    Atom menuTypeAtom = XInternAtom(display, "_NET_WM_WINDOW_TYPE_MENU", False);
    Atom windowTypeAtom = XInternAtom(display, "_NET_WM_WINDOW_TYPE", False);
    Atom transientForAtom = XInternAtom(display, "WM_TRANSIENT_FOR", False);
    Atom netWmStateAtom = XInternAtom(display, "_NET_WM_STATE", False);
    Atom netWmStateModalAtom = XInternAtom(display, "_NET_WM_STATE_MODAL", False);
    
    // Check _NET_WM_WINDOW_TYPE for known transient/dialog classes.
    if (XGetWindowProperty(display, (Window)windowId, windowTypeAtom,
                          0, (~0L), False, XA_ATOM,
                          &actualType, &actualFormat, &nitems, &bytesAfter,
                          &prop) == Success && prop) {
        Atom *types = (Atom *)prop;
        for (unsigned long i = 0; i < nitems; i++) {
            if (types[i] == dialogTypeAtom ||
                types[i] == utilityTypeAtom ||
                types[i] == splashTypeAtom ||
                types[i] == toolbarTypeAtom ||
                types[i] == menuTypeAtom) {
                isDialog = YES;
                break;
            }
        }
        XFree(prop);
    }

    // WM_TRANSIENT_FOR is a strong signal for dialogs/help/about windows.
    if (!isDialog) {
        Window transientOwner = 0;
        if (XGetWindowProperty(display, (Window)windowId, transientForAtom,
                               0, 1, False, XA_WINDOW,
                               &actualType, &actualFormat, &nitems, &bytesAfter,
                               &prop) == Success && prop) {
            if (nitems >= 1) {
                transientOwner = *((Window *)prop);
            }
            XFree(prop);
            if (transientOwner != 0) {
                isDialog = YES;
            }
        }
    }

    // Some WMs annotate modal state via _NET_WM_STATE_MODAL.
    if (!isDialog) {
        if (XGetWindowProperty(display, (Window)windowId, netWmStateAtom,
                               0, (~0L), False, XA_ATOM,
                               &actualType, &actualFormat, &nitems, &bytesAfter,
                               &prop) == Success && prop) {
            Atom *states = (Atom *)prop;
            for (unsigned long i = 0; i < nitems; i++) {
                if (states[i] == netWmStateModalAtom) {
                    isDialog = YES;
                    break;
                }
            }
            XFree(prop);
        }
    }
    
    // Fallback heuristic using WM_CLASS for help/about/preferences style windows.
    if (!isDialog) {
        Atom wmClassAtom = XInternAtom(display, "WM_CLASS", False);
        if (XGetWindowProperty(display, (Window)windowId, wmClassAtom,
                              0, 256, False, XA_STRING,
                              &actualType, &actualFormat, &nitems, &bytesAfter,
                              &prop) == Success && prop) {
            NSString *classText = [[NSString alloc] initWithBytes:prop
                                                            length:nitems
                                                          encoding:NSISOLatin1StringEncoding];
            NSString *lowerClass = [classText lowercaseString];
            if ([lowerClass rangeOfString:@"dialog"].location != NSNotFound ||
                [lowerClass rangeOfString:@"about"].location != NSNotFound ||
                [lowerClass rangeOfString:@"help"].location != NSNotFound ||
                [lowerClass rangeOfString:@"preferences"].location != NSNotFound ||
                [lowerClass rangeOfString:@"settings"].location != NSNotFound ||
                [lowerClass rangeOfString:@"warning"].location != NSNotFound ||
                [lowerClass rangeOfString:@"error"].location != NSNotFound) {
                isDialog = YES;
            }
            XFree(prop);
        }
    }
    
    XCloseDisplay(display);
    return isDialog;
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
                /* Skip override-redirect windows: dropdown menus, popups and
                 * tooltips are transient, churn constantly while being
                 * opened/closed, and are never menu-bar or menu-service hosts.
                 * Not querying them avoids both wasted work and the stale-XID
                 * races that produce BadWindow errors. */
                if (attrs.map_state == IsViewable && attrs.class == InputOutput
                    && !attrs.override_redirect) {
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
            unsigned long val = *((unsigned long *)prop);
            pid = (pid_t)val;
        }
        XFree(prop);
    }

    [self closeDisplay:display];
    return pid;
}

#pragma mark - Gershwin root-window active-application properties

+ (pid_t)getActiveApplicationPID
{
    Display *display = [self sharedDisplay];
    if (!display) return 0;

    Atom atom = XInternAtom(display, "_GERSHWIN_ACTIVE_APP", False);
    if (atom == None) return 0;

    Atom actualType;
    int actualFormat;
    unsigned long nitems, bytesAfter;
    unsigned char *prop = NULL;
    pid_t pid = 0;

    if (XGetWindowProperty(display, DefaultRootWindow(display), atom,
                           0, 1, False, XA_CARDINAL,
                           &actualType, &actualFormat, &nitems, &bytesAfter,
                           &prop) == Success && prop) {
        if (nitems >= 1 && actualFormat == 32) {
            unsigned int *value = (unsigned int *)prop;
            pid = (pid_t)*value;
        }
        XFree(prop);
    }
    return pid;
}

+ (NSArray *)getMenuApps
{
    Display *display = [self sharedDisplay];
    if (!display) return @[];

    Atom atom = XInternAtom(display, "_GERSHWIN_MENU_APPS", False);
    if (atom == None) return @[];

    Atom actualType;
    int actualFormat;
    unsigned long nitems, bytesAfter;
    unsigned char *prop = NULL;
    NSMutableArray *result = [NSMutableArray array];

    if (XGetWindowProperty(display, DefaultRootWindow(display), atom,
                           0, 4096, False, XA_CARDINAL,
                           &actualType, &actualFormat, &nitems, &bytesAfter,
                           &prop) == Success && prop) {
        if (actualFormat == 32) {
            // XGetWindowProperty returns format-32 data as an array of long
            long *values = (long *)prop;
            for (unsigned long i = 0; i < nitems; i++) {
                [result addObject:@(values[i])];
            }
        }
        XFree(prop);
    }
    return result;
}

+ (void)setMenuApps:(NSArray *)pids
{
    Display *display = [self sharedDisplay];
    if (!display) return;

    Atom atom = XInternAtom(display, "_GERSHWIN_MENU_APPS", False);
    if (atom == None) return;

    NSUInteger count = [pids count];
    long *values = NULL;
    if (count > 0) {
        // XChangeProperty with format 32 copies an array of long
        values = (long *)calloc(count, sizeof(long));
        if (!values) return;
        for (NSUInteger i = 0; i < count; i++) {
            id obj = [pids objectAtIndex:i];
            values[i] = (long)[obj longValue];
        }
    }
    XChangeProperty(display, DefaultRootWindow(display), atom, XA_CARDINAL, 32,
                    PropModeReplace, (const unsigned char *)values, (int)count);
    if (values) free(values);
    XFlush(display);
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
            NSDebugLLog(@"gwcomp", @"MenuUtils: Failed to set service property for window %lu", windowId);
            success = NO;
        } else {
            NSDebugLLog(@"gwcomp", @"MenuUtils: Set _KDE_NET_WM_APPMENU_SERVICE_NAME=%@ for window %lu", service, windowId);
        }
    }
    
    // Set the object path property
    if (path) {
        Atom pathAtom = XInternAtom(display, "_KDE_NET_WM_APPMENU_OBJECT_PATH", False);
        const char *pathStr = [path UTF8String];
        int result = XChangeProperty(display, (Window)windowId, pathAtom, XA_STRING, 8,
                                   PropModeReplace, (unsigned char*)pathStr, strlen(pathStr));
        if (result != Success) {
            NSDebugLLog(@"gwcomp", @"MenuUtils: Failed to set path property for window %lu", windowId);
            success = NO;
        } else {
            NSDebugLLog(@"gwcomp", @"MenuUtils: Set _KDE_NET_WM_APPMENU_OBJECT_PATH=%@ for window %lu", path, windowId);
        }
    }
    
    XFlush(display);
    [self closeDisplay:display];
    return success;
}

+ (BOOL)windowIndicatesMenuSupport:(unsigned long)windowId
{
    if (windowId == 0) return NO;

    // Canonical/KDE-style: app stores BOTH its D-Bus service name AND the object path.
    // A service name alone is not enough — the window may simply be inheriting the
    // property from its parent process.
    if ([self getWindowMenuService:windowId] != nil &&
        [self getWindowMenuPath:windowId] != nil) return YES;

    // GTK apps advertise via BOTH _GTK_UNIQUE_BUS_NAME and _GTK_MENUBAR_OBJECT_PATH.
    // Transient/child windows (dialogs, file choosers) often carry _GTK_UNIQUE_BUS_NAME
    // from the parent process but do NOT set _GTK_MENUBAR_OBJECT_PATH because they
    // don't export their own menu.  Requiring both prevents a false-positive that
    // would cause a needless 2-second wait on every dialog focus change.
    if ([self getWindowProperty:windowId atomName:@"_GTK_UNIQUE_BUS_NAME"] != nil &&
        [self getWindowProperty:windowId atomName:@"_GTK_MENUBAR_OBJECT_PATH"] != nil) return YES;

    // GNUstep apps are identified by _GNUSTEP_WM_ATTR on the window
    if ([self getWindowProperty:windowId atomName:@"_GNUSTEP_WM_ATTR"] != nil) return YES;

    return NO;
}

+ (void)mergeNetSupportedAtoms:(const Atom *)atoms
                         count:(unsigned long)count
                         onRoot:(Window)root
                       display:(Display *)display
{
    Atom supportedAtom = XInternAtom(display, "_NET_SUPPORTED", False);
    if (supportedAtom == None || atoms == NULL || count == 0) {
        return;
    }

    // Read what the window manager already advertised: _NET_SUPPORTED belongs to
    // the WM, and a plain PropModeReplace here would drop the entries it relies
    // on (e.g. the _WINDOW_BIRTH_ANIMATION / _WINDOW_CLOSE_ANIMATION protocol),
    // silently disabling features for other clients.
    Atom actualType = None;
    int actualFormat = 0;
    unsigned long numItems = 0, bytesAfter = 0;
    unsigned char *propData = NULL;
    if (XGetWindowProperty(display, root, supportedAtom, 0, ~0L, False,
                           XA_ATOM, &actualType, &actualFormat, &numItems,
                           &bytesAfter, &propData) != Success) {
        return;
    }
    if (actualFormat != 32 || numItems == 0 || propData == NULL) {
        if (propData) XFree(propData);
        // No list to preserve: just publish our atoms.
        XChangeProperty(display, root, supportedAtom, XA_ATOM, 32,
                        PropModeReplace, (unsigned char *)atoms, count);
        return;
    }

    Atom *existing = (Atom *)propData;
    NSUInteger maxTotal = numItems + count;
    Atom merged[maxTotal];
    NSUInteger total = 0;
    for (unsigned long i = 0; i < numItems; i++) {
        merged[total++] = existing[i];
    }
    for (unsigned long i = 0; i < count; i++) {
        BOOL alreadyThere = NO;
        for (unsigned long j = 0; j < numItems; j++) {
            if (existing[j] == atoms[i]) { alreadyThere = YES; break; }
        }
        if (!alreadyThere) {
            merged[total++] = atoms[i];
        }
    }
    XFree(propData);

    XChangeProperty(display, root, supportedAtom, XA_ATOM, 32,
                    PropModeReplace, (unsigned char *)merged, total);
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
        
        NSDebugLLog(@"gwcomp", @"MenuUtils: Set _NET_SUPPORTING_WM_CHECK for global menu support");
    }
    
    // Advertise our global-menu atoms by merging them into the WM-owned
    // _NET_SUPPORTED property, never replacing it.
    Atom supportedFeatures[] = {
        XInternAtom(display, "_NET_WM_NAME", False),
        XInternAtom(display, "_NET_ACTIVE_WINDOW", False),
        XInternAtom(display, "_KDE_NET_WM_APPMENU_SERVICE_NAME", False),
        XInternAtom(display, "_KDE_NET_WM_APPMENU_OBJECT_PATH", False)
    };
    [self mergeNetSupportedAtoms:supportedFeatures
                           count:sizeof(supportedFeatures) / sizeof(Atom)
                           onRoot:root
                         display:display];
    
    NSDebugLLog(@"gwcomp", @"MenuUtils: Merged global menu atoms into _NET_SUPPORTED");
    
    // Set KDE-specific property to indicate global menu support
    Atom kdeMenuAtom = XInternAtom(display, "_KDE_GLOBAL_MENU_AVAILABLE", False);
    if (kdeMenuAtom != None) {
        unsigned long value = 1;
        XChangeProperty(display, root, kdeMenuAtom, XA_CARDINAL, 32,
                       PropModeReplace, (unsigned char*)&value, 1);
        
        NSDebugLLog(@"gwcomp", @"MenuUtils: Set _KDE_GLOBAL_MENU_AVAILABLE=1 on root window");
    }
    
    // Set Unity-specific property for Ubuntu compatibility
    Atom unityMenuAtom = XInternAtom(display, "_UNITY_GLOBAL_MENU", False);
    if (unityMenuAtom != None) {
        unsigned long value = 1;
        XChangeProperty(display, root, unityMenuAtom, XA_CARDINAL, 32,
                       PropModeReplace, (unsigned char*)&value, 1);
        
        NSDebugLLog(@"gwcomp", @"MenuUtils: Set _UNITY_GLOBAL_MENU=1 on root window");
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
    
    NSDebugLLog(@"gwcomp", @"MenuUtils: Removed global menu support properties from root window");
}

@end
