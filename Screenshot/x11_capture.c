/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */


 #include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <time.h>
#include <math.h>
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/Xatom.h>
#include <X11/cursorfont.h>
#include <X11/extensions/shape.h>

#include "shadow_mask.h"

// Global variables
static Display *disp = NULL;
static Window root;
static Screen *scr = NULL;
static int x11_error_occurred = 0;

// Window picked during the last interactive selection, used by the capture
// stage to query the WM's bounding shape (rounded corners).
static Window last_shape_window = None;

// Theme corner radii; the ObjC layer fills these from GSTheme so we match
// exactly what the window manager rounds.
static float s_top_corner_radius = 0.0f;
static float s_bottom_corner_radius = 0.0f;

void x11_set_corner_radii(float top, float bottom) {
    s_top_corner_radius = top;
    s_bottom_corner_radius = bottom;
}

// X11 Error Handler
static int x11_error_handler(Display *display, XErrorEvent *error) {
    char error_text[256];
    XGetErrorText(display, error->error_code, error_text, sizeof(error_text));
    fprintf(stderr, "X11 Error: %s (error_code=%d, request_code=%d)\n",
            error_text, error->error_code, error->request_code);
    x11_error_occurred = 1;
    return 0;
}

typedef enum {
    CaptureWindow,
    CaptureArea,
    CaptureFullScreen
} CaptureMode;

typedef struct {
    int x, y, width, height;
} CaptureRect;

static int get_window_rect(Display *display, Window window, CaptureRect *rect);

int x11_init(void) {
    disp = XOpenDisplay(NULL);
    if (!disp) {
        return 0;
    }
    
    // Install error handler
    XSetErrorHandler(x11_error_handler);
    x11_error_occurred = 0;
    
    scr = ScreenOfDisplay(disp, DefaultScreen(disp));
    root = RootWindow(disp, DefaultScreen(disp));
    
    return 1;
}

void x11_cleanup(void) {
    if (disp) {
        XCloseDisplay(disp);
        disp = NULL;
    }
}

// Read the EWMH _NET_FRAME_EXTENTS property (decoration sizes around the
// client window).  Published by every EWMH-compliant window manager, so this
// works regardless of which WM is running.
static int get_frame_extents(Display *display, Window window,
                             int *left, int *right, int *top, int *bottom) {
    if (!display || !window) return 0;

    Atom atom = XInternAtom(display, "_NET_FRAME_EXTENTS", True);
    if (atom == None) return 0;

    Atom actual_type;
    int actual_format;
    unsigned long nitems, bytes_after;
    unsigned char *prop = NULL;

    if (XGetWindowProperty(display, window, atom, 0, 4, False, XA_CARDINAL,
                           &actual_type, &actual_format, &nitems,
                           &bytes_after, &prop) != Success)
        return 0;

    int ok = 0;
    // Format 32 properties are returned as array of long, not int32
    if (prop && nitems == 4 && actual_format == 32) {
        long *v = (long *)prop;
        *left = (int)v[0];
        *right = (int)v[1];
        *top = (int)v[2];
        *bottom = (int)v[3];
        ok = 1;
    }
    if (prop) XFree(prop);
    return ok;
}

// Fallback for WMs without _NET_FRAME_EXTENTS: use the geometry of the
// reparenting frame window (the client's immediate parent), which spans the
// decorations.
static int get_parent_frame_rect(Display *display, Window window, CaptureRect *rect) {
    Window root_return, parent_return, *children = NULL;
    unsigned int nchildren;
    if (!XQueryTree(display, window, &root_return, &parent_return,
                    &children, &nchildren))
        return 0;
    if (children) XFree(children);
    if (parent_return == None || parent_return == root_return)
        return 0;
    return get_window_rect(display, parent_return, rect);
}

// Expand a client-area rect to include the WM decorations (title bar etc.)
static void expand_rect_to_frame(Display *display, Window window, CaptureRect *rect) {
    CaptureRect frame;
    int left, right, top, bottom;

    if (get_parent_frame_rect(display, window, &frame)) {
        *rect = frame;
        return;
    }
    if (get_frame_extents(display, window, &left, &right, &top, &bottom)) {
        rect->x -= left;
        rect->y -= top;
        rect->width += left + right;
        rect->height += top + bottom;
    }
    // Neither available: keep the client rect (undecorated or non-EWMH WM)
}

// Get window at pointer position
Window get_window_at_pointer(Display *display, Window root_window) {
    if (!display || !root_window) {
        return 0;
    }
    
    Window root_return, child_return;
    int root_x, root_y, win_x, win_y;
    unsigned int mask_return;
    
    // Reset error flag
    x11_error_occurred = 0;
    
    // Get pointer position
    if (!XQueryPointer(display, root_window, &root_return, &child_return,
                      &root_x, &root_y, &win_x, &win_y, &mask_return)) {
        fprintf(stderr, "XQueryPointer failed\n");
        return root_window;
    }
    
    // Check for errors
    XSync(display, False);
    if (x11_error_occurred) {
        fprintf(stderr, "X11 error in XQueryPointer\n");
        return root_window;
    }
    
    if (child_return == None) {
        return root_window;
    }
    
    // Traverse to find actual window
    Window target = child_return;
    while (1) {
        if (!XQueryPointer(display, target, &root_return, &child_return,
                          &root_x, &root_y, &win_x, &win_y, &mask_return)) {
            break;
        }
        
        // Check for errors
        XSync(display, False);
        if (x11_error_occurred) {
            break;
        }
        
        if (child_return == None) {
            break;
        }
        target = child_return;
    }
    
    return target;
}

// Select a window interactively
Window select_window_interactive(Display *display, Window root_window) {
    if (!display || !root_window) {
        fprintf(stderr, "Invalid display or window\n");
        return 0;
    }
    
    x11_error_occurred = 0;
    
    Cursor cursor = XCreateFontCursor(display, XC_crosshair);
    if (!cursor) {
        fprintf(stderr, "Failed to create cursor\n");
        return 0;
    }
    
    // Flush any pending events and clear error state
    XSync(display, False);
    x11_error_occurred = 0;
    
    fprintf(stderr, "Attempting pointer grab with ButtonPressMask\n");
    
    // Try grabbing with just ButtonPressMask first
    int status = XGrabPointer(display, root_window, False,
                             ButtonPressMask,
                             GrabModeAsync, GrabModeAsync, root_window, cursor, CurrentTime);
    
    // Check both the return status and the error flag
    XSync(display, False);
    
    if (status != GrabSuccess || x11_error_occurred) {
        fprintf(stderr, "Failed to grab pointer: status=%d, x11_error=%d\n", status, x11_error_occurred);
        XFreeCursor(display, cursor);
        return 0;
    }
    
    fprintf(stderr, "Pointer grab succeeded\n");
    
    // Attempt keyboard grab but don't fail if it doesn't work
    int kbd_status = XGrabKeyboard(display, root_window, False, GrabModeAsync, GrabModeAsync, CurrentTime);
    if (kbd_status != GrabSuccess) {
        fprintf(stderr, "Warning: Failed to grab keyboard: status=%d (continuing anyway)\n", kbd_status);
        kbd_status = 0; // Mark as failed so we don't try to ungrab it
    } else {
        fprintf(stderr, "Keyboard grab succeeded\n");
    }
    
    XSync(display, False);  // Ensure all requests are processed
    
    XEvent event;
    Window target = 0;
    int timeout = 0;
    
    while (1) {
        // Timeout after 30 seconds
        if (timeout++ > 300) {
            fprintf(stderr, "Window selection timeout\n");
            target = 0;
            break;
        }
        
        if (XPending(display) == 0) {
            usleep(100000); // 100ms sleep to prevent busy waiting
            continue;
        }
        
        XNextEvent(display, &event);
        
        if (x11_error_occurred) {
            fprintf(stderr, "X11 error occurred during window selection\n");
            target = 0;
            break;
        }
        
        if (event.type == KeyPress) {
            // Check if ESC key was pressed
            KeySym keysym = XLookupKeysym(&event.xkey, 0);
            if (keysym == XK_Escape) {
                fprintf(stderr, "ESC pressed, cancelling selection\n");
                // Cancel selection
                target = 0;
                break;
            }
        } else if (event.type == ButtonPress) {
            fprintf(stderr, "Button %d pressed\n", event.xbutton.button);
            // Check if right mouse button (Button3) was pressed
            if (event.xbutton.button == Button3) {
                // Cancel selection
                fprintf(stderr, "Right click, cancelling selection\n");
                target = 0;
                break;
            } else if (event.xbutton.button == Button1) {
                // Left click - proceed with selection
                fprintf(stderr, "Left click at (%d, %d)\n", event.xbutton.x, event.xbutton.y);
                target = event.xbutton.subwindow;
                if (target == None) {
                    target = root_window;
                } else {
                    target = get_window_at_pointer(display, root_window);
                }
                fprintf(stderr, "Selected window: 0x%lx\n", target);
                break;
            }
        }
    }
    
    if (kbd_status == GrabSuccess) {
        XUngrabKeyboard(display, CurrentTime);
    }
    XUngrabPointer(display, CurrentTime);
    XFreeCursor(display, cursor);
    XFlush(display);
    
    return target;
}

// Get window geometry
int get_window_rect(Display *display, Window window, CaptureRect *rect) {
    if (!display || !window || !rect) {
        fprintf(stderr, "Invalid parameters for get_window_rect\n");
        return 0;
    }
    
    // Reset error flag
    x11_error_occurred = 0;
    
    XWindowAttributes attrs;
    if (!XGetWindowAttributes(display, window, &attrs)) {
        fprintf(stderr, "Failed to get window attributes\n");
        return 0;
    }
    
    // Check for X11 errors after getting attributes
    XSync(display, False);
    if (x11_error_occurred) {
        fprintf(stderr, "X11 error while getting window attributes\n");
        return 0;
    }
    
    // Translate to root coordinates
    Window child;
    int root_x, root_y;
    XTranslateCoordinates(display, window, attrs.root, 0, 0, &root_x, &root_y, &child);
    
    // Check for X11 errors after translation
    XSync(display, False);
    if (x11_error_occurred) {
        fprintf(stderr, "X11 error while translating coordinates\n");
        return 0;
    }
    
    rect->x = root_x;
    rect->y = root_y;
    rect->width = attrs.width;
    rect->height = attrs.height;
    
    return 1;
}

// Get active window using _NET_ACTIVE_WINDOW
Window get_active_window(Display *display, Window root_window) {
    if (!display || !root_window) {
        fprintf(stderr, "Invalid parameters for get_active_window\n");
        return None;
    }
    
    x11_error_occurred = 0;
    
    // Get the _NET_ACTIVE_WINDOW atom
    Atom net_active_window = XInternAtom(display, "_NET_ACTIVE_WINDOW", False);
    if (net_active_window == None) {
        fprintf(stderr, "Failed to get _NET_ACTIVE_WINDOW atom\n");
        return None;
    }
    
    // Get the window property
    Atom type;
    int format;
    unsigned long nitems, bytes_after;
    unsigned char *prop = NULL;
    
    if (XGetWindowProperty(display, root_window, net_active_window, 0, 1, False, 
                          XA_WINDOW, &type, &format, &nitems, &bytes_after, &prop) != Success) {
        fprintf(stderr, "Failed to get _NET_ACTIVE_WINDOW property\n");
        return None;
    }
    
    Window active_window = None;
    if (prop && nitems > 0) {
        active_window = *((Window *)prop);
    }
    
    if (prop) {
        XFree(prop);
    }
    
    if (x11_error_occurred) {
        fprintf(stderr, "X11 error while getting active window\n");
        return None;
    }
    
    return active_window;
}

// Select area interactively
int select_area_interactive(Display *display, Window root_window, CaptureRect *rect) {
    if (!display || !root_window || !rect) {
        fprintf(stderr, "Invalid parameters for area selection\n");
        return 0;
    }
    
    x11_error_occurred = 0;
    
    Cursor cursor = XCreateFontCursor(display, XC_crosshair);
    if (!cursor) {
        fprintf(stderr, "Failed to create cursor\n");
        return 0;
    }
    
    // Flush any pending events
    XSync(display, False);
    
    int status = XGrabPointer(display, root_window, False,
                             ButtonPressMask | ButtonReleaseMask | PointerMotionMask,
                             GrabModeAsync, GrabModeAsync, root_window, cursor, CurrentTime);
    
    if (status != GrabSuccess) {
        fprintf(stderr, "Failed to grab pointer: status=%d\n", status);
        XFreeCursor(display, cursor);
        return 0;
    }
    
    // Also grab keyboard to capture ESC key
    int kbd_status = XGrabKeyboard(display, root_window, False, GrabModeAsync, GrabModeAsync, CurrentTime);
    if (kbd_status != GrabSuccess) {
        fprintf(stderr, "Warning: Failed to grab keyboard\n");
    }
    
    // Cornflower blue color (RGB: 100, 149, 237) — matches original working code
    XColor blue_color;
    Colormap cmap = DefaultColormap(display, DefaultScreen(display));
    blue_color.red = 0x6400;    // 100/255 * 65535
    blue_color.green = 0x9500;  // 149/255 * 65535
    blue_color.blue = 0xED00;   // 237/255 * 65535
    blue_color.flags = DoRed | DoGreen | DoBlue;
    XAllocColor(display, cmap, &blue_color);

    // Single override-redirect translucent blue overlay (original working approach)
    XSetWindowAttributes sel_attrs;
    sel_attrs.override_redirect = True;
    sel_attrs.background_pixel = blue_color.pixel;
    sel_attrs.border_pixel = WhitePixel(display, DefaultScreen(display));

    Window sel_win = XCreateWindow(display, root_window,
                                   0, 0, 1, 1, 1,
                                   CopyFromParent, InputOutput, CopyFromParent,
                                   CWOverrideRedirect | CWBackPixel | CWBorderPixel,
                                   &sel_attrs);
    if (!sel_win) {
        fprintf(stderr, "Failed to create selection window\n");
        if (kbd_status == GrabSuccess) XUngrabKeyboard(display, CurrentTime);
        XUngrabPointer(display, CurrentTime);
        XFreeCursor(display, cursor);
        return 0;
    }
    // 30% opacity via EWMH hint (requires compositor)
    Atom opacity_atom = XInternAtom(display, "_NET_WM_WINDOW_OPACITY", True);
    unsigned long opacity = (unsigned long)(0.3 * 0xFFFFFFFF);
    XChangeProperty(display, sel_win, opacity_atom, XA_CARDINAL, 32,
                   PropModeReplace, (unsigned char *)&opacity, 1);
    // Map when first positioned in motion handler

    XEvent event;
    int start_x = 0, start_y = 0, end_x = 0, end_y = 0;
    int pressed = 0;
    int cancelled = 0;
    int has_rect = 0;
    
    while (1) {
        if (XPending(display) == 0) {
            usleep(10000); // 10ms sleep
            continue;
        }
        
        XNextEvent(display, &event);
        
        if (x11_error_occurred) {
            fprintf(stderr, "X11 error occurred during area selection\n");
            cancelled = 1;
            break;
        }
        
        if (event.type == KeyPress) {
            // Check if ESC key was pressed
            KeySym keysym = XLookupKeysym(&event.xkey, 0);
            if (keysym == XK_Escape) {
                // Cancel selection
                cancelled = 1;
                break;
            }
        } else if (event.type == ButtonPress) {
            // Check if right mouse button (Button3) was pressed
            if (event.xbutton.button == Button3) {
                // Cancel selection
                cancelled = 1;
                break;
            } else if (event.xbutton.button == Button1) {
                // Left click - start selection
                start_x = event.xbutton.x_root;
                start_y = event.xbutton.y_root;
                pressed = 1;
            }
        } else if (event.type == MotionNotify && pressed) {
            // Update current position
            int current_x = event.xmotion.x_root;
            int current_y = event.xmotion.y_root;
            
            // Calculate rectangle bounds
            int rx = (start_x < current_x) ? start_x : current_x;
            int ry = (start_y < current_y) ? start_y : current_y;
            int rw = abs(current_x - start_x);
            int rh = abs(current_y - start_y);

            // Move, resize and show the translucent blue overlay window
            if (rw > 0 && rh > 0) {
                XMoveResizeWindow(display, sel_win, rx, ry, rw, rh);
                XMapWindow(display, sel_win);
                XRaiseWindow(display, sel_win);
                XFlush(display);
                has_rect = 1;
            }
        } else if (event.type == ButtonRelease && pressed) {
            if (event.xbutton.button == Button1) {
                // Left button release - complete selection
                end_x = event.xbutton.x_root;
                end_y = event.xbutton.y_root;
                break;
            }
        }
    }

    // Destroy selection window and wait for server to restore saved pixels
    XDestroyWindow(display, sel_win);
    XSync(display, False);
    if (has_rect) {
        usleep(200000); // 200ms for server to restore save_under pixels
        XSync(display, False);
    }
    
    if (kbd_status == GrabSuccess) {
        XUngrabKeyboard(display, CurrentTime);
    }
    XUngrabPointer(display, CurrentTime);
    XFreeCursor(display, cursor);
    XSync(display, False);
    
    // If cancelled, return failure
    if (cancelled) {
        rect->x = 0;
        rect->y = 0;
        rect->width = 0;
        rect->height = 0;
        return 0;
    }
    
    // Calculate rectangle
    rect->x = (start_x < end_x) ? start_x : end_x;
    rect->y = (start_y < end_y) ? start_y : end_y;
    rect->width = abs(end_x - start_x);
    rect->height = abs(end_y - start_y);
    
    return 1;
}

// Synthesize the final RGBA image locally:
//  - pixels covered by the actual window shape (body minus rounded/shaped
//    corners) are copied opaque from the screen grab,
//  - everything else is either transparent or, when include_shadow is set,
//    a pure black shadow whose alpha is the Gaussian mask (same parameters
//    as the WM compositor).  Rounded-off corner pixels therefore show the
//    shadow fading over a transparent background, never black squares.
static void compose_output(unsigned char *data, int width, int height,
                           CaptureRect body, CaptureRect captured,
                           int include_shadow) {
    unsigned char *cov = calloc(width * height, 1);
    if (!cov)
        return;

    // Body rectangle starts fully covered
    int bx0 = body.x - captured.x;
    int by0 = body.y - captured.y;
    for (int y = by0; y < by0 + body.height; y++) {
        if (y < 0 || y >= height) continue;
        int x0 = bx0 < 0 ? 0 : bx0;
        int x1 = bx0 + body.width > width ? width : bx0 + body.width;
        memset(cov + y * width + x0, 1, x1 - x0);
    }

    // Round the top/bottom corners per the theme radii (matches the way the
    // WM rounds its frames), marking outside pixels uncovered.
    if (s_top_corner_radius > 0) {
        int cr = (int)ceilf(s_top_corner_radius);
        for (int y = by0; y < by0 + cr && y < height; y++) {
            if (y < 0) continue;
            for (int x = bx0; x < bx0 + cr && x < width; x++) {
                if (x < 0) continue;
                int dx = x - (bx0 + cr - 1), dy = y - (by0 + cr);
                if (dx * dx + dy * dy > cr * cr)
                    cov[y * width + x] = 0;
            }
            for (int x = bx0 + body.width - cr; x < bx0 + body.width && x < width; x++) {
                int dx = x - (bx0 + body.width - cr), dy = y - (by0 + cr);
                if (dx * dx + dy * dy > cr * cr)
                    cov[y * width + x] = 0;
            }
        }
    }
    if (s_bottom_corner_radius > 0) {
        int cr = (int)ceilf(s_bottom_corner_radius);
        for (int y = by0 + body.height - cr; y < by0 + body.height && y < height; y++) {
            if (y < 0) continue;
            for (int x = bx0; x < bx0 + cr && x < width; x++) {
                if (x < 0) continue;
                int dx = x - (bx0 + cr - 1), dy = y - (by0 + body.height - 1 - cr);
                if (dx * dx + dy * dy > cr * cr)
                    cov[y * width + x] = 0;
            }
            for (int x = bx0 + body.width - cr; x < bx0 + body.width && x < width; x++) {
                int dx = x - (bx0 + body.width - cr), dy = y - (by0 + body.height - 1 - cr);
                if (dx * dx + dy * dy > cr * cr)
                    cov[y * width + x] = 0;
            }
        }
    }

    // Respect an X11 bounding shape if the WM gave the window one
    if (last_shape_window != None) {
        Bool es;
        int rx, ry;
        unsigned int rw2, rh2;
        int bshaped = 0;
        if (XShapeQueryExtents(disp, last_shape_window, &bshaped,
                               &rx, &ry, &rw2, &rh2,
                               &es, &rx, &ry, &rw2, &rh2) && bshaped) {
            int count, order;
            XRectangle *rects = XShapeGetRectangles(disp, last_shape_window,
                                                    ShapeBounding,
                                                    &count, &order);
            if (rects && count > 0) {
                for (int y = 0; y < height; y++)
                    for (int x = 0; x < width; x++) {
                        int inside = 0;
                        for (int i = 0; i < count; i++) {
                            // Shape rects are relative to the shape window
                            // origin, which is the body origin on the root
                            if (x - bx0 >= rects[i].x &&
                                x - bx0 < rects[i].x + rects[i].width &&
                                y - by0 >= rects[i].y &&
                                y - by0 < rects[i].y + rects[i].height) {
                                inside = 1;
                                break;
                            }
                        }
                        if (!inside)
                            cov[y * width + x] = 0;
                    }
            }
            if (rects) XFree(rects);
        }
    }

    // Shadow mask (may be NULL when shadows are off)
    int mask_w = 0, mask_h = 0;
    uint8_t *mask = NULL;
    int mx0 = 0, my0 = 0;
    if (include_shadow) {
        mask = shadow_make_mask(body.width, body.height, &mask_w, &mask_h);
        // Mask origin: body rect expanded by the same padding that
        // shadow_padding() reports (shadow picture plus fade-out band).
        int pl, pt, pr, pb;
        shadow_padding(&pl, &pt, &pr, &pb);
        mx0 = body.x - pl;
        my0 = body.y - pt;
    }

    unsigned char *out = malloc(width * height * 4);
    if (!out) {
        free(mask);
        free(cov);
        return;
    }

    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
            int idx = (y * width + x) * 4;
            if (cov[y * width + x]) {
                // Window content: opaque, straight from the screen grab
                out[idx + 0] = data[idx + 0];
                out[idx + 1] = data[idx + 1];
                out[idx + 2] = data[idx + 2];
                out[idx + 3] = 0xFF;
            } else {
                uint8_t alpha = 0;
                if (mask) {
                    int rel_x = x + captured.x - mx0;
                    int rel_y = y + captured.y - my0;
                    if (rel_x >= 0 && rel_x < mask_w && rel_y >= 0 && rel_y < mask_h)
                        alpha = mask[rel_y * mask_w + rel_x];
                }
                // Pure black with Gaussian alpha over full transparency
                out[idx + 0] = 0;
                out[idx + 1] = 0;
                out[idx + 2] = 0;
                out[idx + 3] = alpha;
            }
        }
    }
    memcpy(data, out, width * height * 4);
    free(out);
    free(mask);
    free(cov);
}

// Capture screenshot data using X11
unsigned char* x11_capture_data(CaptureMode mode, int delay, CaptureRect* rect,
                                  int include_shadow,
                                  int* width, int* height, int* bytes_per_pixel) {
    if (!disp) {
        if (!x11_init()) {
            return NULL;
        }
    }
    
    // Apply delay if specified
    if (delay > 0) {
        sleep(delay);
    }
    
    CaptureRect capture_rect;
    CaptureRect body_rect = {0, 0, 0, 0};
    int use_shadow_mask = 0;
    
    switch (mode) {
        case CaptureFullScreen:
            capture_rect.x = 0;
            capture_rect.y = 0;
            capture_rect.width = scr->width;
            capture_rect.height = scr->height;
            break;
            
        case CaptureWindow:
            if (rect && rect->width > 0 && rect->height > 0) {
                capture_rect = *rect;
            } else {
                // Interactive window selection
                Window window = select_window_interactive(disp, root);
                if (!window || !get_window_rect(disp, window, &capture_rect)) {
                    return NULL;
                }
            }
            body_rect = capture_rect;

            // Pad the capture rect by the compositor shadow margins so the
            // drop shadow is part of the grabbed pixels.  (No compositor
            // detection: gershwin-windowmanager never owns _NET_WM_CM_S0,
            // and with other WMs the padding is still applied - the alpha
            // mask simply follows our own Gaussian parameters.)
            if (include_shadow) {
                int pl, pt, pr, pb;
                shadow_padding(&pl, &pt, &pr, &pb);
                int nx = capture_rect.x - pl;
                int ny = capture_rect.y - pt;
                int nw = capture_rect.width + pl + pr;
                int nh = capture_rect.height + pt + pb;

                // Keep the padded rect on screen
                if (nx < 0) { nw += nx; nx = 0; }
                if (ny < 0) { nh += ny; ny = 0; }
                if (nx + nw > scr->width) nw = scr->width - nx;
                if (ny + nh > scr->height) nh = scr->height - ny;

                if (nw > 0 && nh > 0) {
                    capture_rect.x = nx;
                    capture_rect.y = ny;
                    capture_rect.width = nw;
                    capture_rect.height = nh;
                    use_shadow_mask = 1;
                }
            }
            break;
            
        case CaptureArea:
            if (rect && rect->width > 0 && rect->height > 0) {
                capture_rect = *rect;
            } else {
                // Interactive area selection
                if (!select_area_interactive(disp, root, &capture_rect)) {
                    return NULL;
                }
            }
            break;
            
        default:
            return NULL;
    }
    
    // Ensure dimensions are valid
    if (capture_rect.width <= 0 || capture_rect.height <= 0) {
        return NULL;
    }
    
    // Capture the screen using XGetImage
    XImage *image = XGetImage(disp, root, capture_rect.x, capture_rect.y,
                              capture_rect.width, capture_rect.height,
                              AllPlanes, ZPixmap);
    
    if (!image) {
        return NULL;
    }
    
    // Convert XImage to RGBA format for GNUstep
    int w = image->width;
    int h = image->height;
    int bpp = 4; // RGBA
    
    unsigned char *data = malloc(w * h * bpp);
    if (!data) {
        XDestroyImage(image);
        return NULL;
    }
    
    // Get the visual information
    Visual *visual = DefaultVisual(disp, DefaultScreen(disp));
    int depth = DefaultDepth(disp, DefaultScreen(disp));
    
    fprintf(stderr, "Display depth: %d, byte_order: %d, bitmap_bit_order: %d\n", 
            depth, ImageByteOrder(disp), BitmapBitOrder(disp));
    fprintf(stderr, "Red mask: 0x%lx, Green mask: 0x%lx, Blue mask: 0x%lx\n",
            visual->red_mask, visual->green_mask, visual->blue_mask);
    
    // Calculate the number of bits to shift for proper 8-bit normalization
    int red_shift = 0, green_shift = 0, blue_shift = 0;
    int red_bits = 0, green_bits = 0, blue_bits = 0;
    unsigned long mask;
    
    // Find shift and bit count for red
    mask = visual->red_mask;
    while (mask && !(mask & 1)) { mask >>= 1; red_shift++; }
    while (mask & 1) { mask >>= 1; red_bits++; }
    
    // Find shift and bit count for green
    mask = visual->green_mask;
    while (mask && !(mask & 1)) { mask >>= 1; green_shift++; }
    while (mask & 1) { mask >>= 1; green_bits++; }
    
    // Find shift and bit count for blue
    mask = visual->blue_mask;
    while (mask && !(mask & 1)) { mask >>= 1; blue_shift++; }
    while (mask & 1) { mask >>= 1; blue_bits++; }
    
    fprintf(stderr, "Red: shift=%d bits=%d, Green: shift=%d bits=%d, Blue: shift=%d bits=%d\n",
            red_shift, red_bits, green_shift, green_bits, blue_shift, blue_bits);
    
    // Convert image data to RGBA
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            unsigned long pixel = XGetPixel(image, x, y);
            int offset = (y * w + x) * bpp;
            
            // Extract and normalize RGB components
            unsigned long r_val = (pixel & visual->red_mask) >> red_shift;
            unsigned long g_val = (pixel & visual->green_mask) >> green_shift;
            unsigned long b_val = (pixel & visual->blue_mask) >> blue_shift;
            
            // Normalize to 8 bits (scale from red_bits/green_bits/blue_bits to 8 bits)
            if (red_bits < 8) {
                r_val = (r_val << (8 - red_bits)) | (r_val >> (2 * red_bits - 8));
            } else if (red_bits > 8) {
                r_val >>= (red_bits - 8);
            }
            
            if (green_bits < 8) {
                g_val = (g_val << (8 - green_bits)) | (g_val >> (2 * green_bits - 8));
            } else if (green_bits > 8) {
                g_val >>= (green_bits - 8);
            }
            
            if (blue_bits < 8) {
                b_val = (b_val << (8 - blue_bits)) | (b_val >> (2 * blue_bits - 8));
            } else if (blue_bits > 8) {
                b_val >>= (blue_bits - 8);
            }
            
            data[offset + 0] = (unsigned char)r_val;  // R
            data[offset + 1] = (unsigned char)g_val;  // G
            data[offset + 2] = (unsigned char)b_val;  // B
            data[offset + 3] = 0xFF;                  // A (fully opaque)
        }
    }
    
    if (mode == CaptureWindow)
        compose_output(data, w, h, body_rect, capture_rect,
                       use_shadow_mask ? 1 : 0);

    *width = w;
    *height = h;
    *bytes_per_pixel = bpp;
    
    XDestroyImage(image);
    return data;
}

void x11_free_data(unsigned char* data) {
    if (data) {
        free(data);
    }
}

CaptureRect x11_select_window_title(int include_title);

CaptureRect x11_select_window(void) {
    return x11_select_window_title(0);
}

// Interactive window selection; optionally expand to the WM frame so the
// title bar and decorations are part of the capture rect.
CaptureRect x11_select_window_title(int include_title) {
    CaptureRect rect = {0, 0, 0, 0};

    if (!disp) {
        if (!x11_init()) {
            fprintf(stderr, "Failed to initialize X11\n");
            return rect;
        }
    }

    x11_error_occurred = 0;

    Window window = select_window_interactive(disp, root);

    // Check for errors or cancellation
    if (x11_error_occurred || window == 0) {
        fprintf(stderr, "Window selection failed or cancelled\n");
        return rect;  // Return zero rect
    }

    if (!get_window_rect(disp, window, &rect)) {
        fprintf(stderr, "Failed to get window geometry\n");
        rect.x = rect.y = rect.width = rect.height = 0;
        return rect;
    }

    // Remember the window whose bounding shape matches the capture body:
    // the WM frame when we include decorations, else the client itself.
    Window frame = None;
    Window root_return, parent_return, *children = NULL;
    unsigned int nchildren;
    if (XQueryTree(disp, window, &root_return, &parent_return,
                   &children, &nchildren)) {
        if (children) XFree(children);
        if (parent_return != None && parent_return != root_return)
            frame = parent_return;
    }
    last_shape_window = (include_title && frame != None) ? frame : window;

    if (include_title)
        expand_rect_to_frame(disp, window, &rect);

    return rect;
}

CaptureRect x11_select_area(void) {
    CaptureRect rect = {0, 0, 0, 0};
    
    if (!disp) {
        if (!x11_init()) {
            fprintf(stderr, "Failed to initialize X11\n");
            return rect;
        }
    }
    
    x11_error_occurred = 0;
    
    int result = select_area_interactive(disp, root, &rect);
    
    // Check for errors or cancellation
    if (x11_error_occurred || result == 0) {
        fprintf(stderr, "Area selection failed or cancelled\n");
        rect.x = rect.y = rect.width = rect.height = 0;
    }
    
    return rect;
}

CaptureRect x11_get_active_window(void) {
    CaptureRect rect = {0, 0, 0, 0};
    
    if (!disp) {
        if (!x11_init()) {
            fprintf(stderr, "Failed to initialize X11\n");
            return rect;
        }
    }
    
    x11_error_occurred = 0;
    
    Window active_window = get_active_window(disp, root);
    
    if (x11_error_occurred || active_window == None) {
        fprintf(stderr, "Failed to get active window\n");
        return rect;  // Return zero rect
    }
    
    if (!get_window_rect(disp, active_window, &rect)) {
        fprintf(stderr, "Failed to get active window geometry\n");
        rect.x = rect.y = rect.width = rect.height = 0;
    }
    
    return rect;
}

char* x11_capture(CaptureMode mode, const char* filename, int delay, CaptureRect* rect) {
    // This function is kept for compatibility but not fully implemented
    // The actual image saving is done in Objective-C using GNUstep's NSImage
    return NULL;
}

// Set _NET_WM_WINDOW_TYPE to _NET_WM_WINDOW_TYPE_NORMAL on a given X11 window
// Prevents X11 window managers from hiding the window on focus loss
void x11_set_window_type_normal(void *window_ref) {
    if (!disp) return;
    Window xid = (Window)(uintptr_t)window_ref;
    if (xid == None) return;

    Atom wm_type = XInternAtom(disp, "_NET_WM_WINDOW_TYPE", False);
    Atom normal = XInternAtom(disp, "_NET_WM_WINDOW_TYPE_NORMAL", False);
    if (wm_type != None && normal != None) {
        XChangeProperty(disp, xid, wm_type, XA_ATOM, 32,
                       PropModeReplace, (unsigned char *)&normal, 1);
        XSync(disp, False);
    }
}