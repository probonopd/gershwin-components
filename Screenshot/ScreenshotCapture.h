/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */


 #ifndef ScreenshotCapture_h
#define ScreenshotCapture_h

#import <AppKit/AppKit.h>

// C interface for X11 screenshot functionality
#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    CaptureWindow,
    CaptureArea,
    CaptureFullScreen
} CaptureMode;

typedef struct {
    int x, y, width, height;
} CaptureRect;

// Initialize X11 system
int x11_init(void);

// Cleanup X11 system
void x11_cleanup(void);

// Take screenshot and return path to saved file
// If filename is NULL, a default name will be generated
char* x11_capture(CaptureMode mode, const char* filename, int delay, CaptureRect* rect);

// Take screenshot and return image data (for clipboard/preview)
// include_shadow pads a window capture with the compositor drop shadow
unsigned char* x11_capture_data(CaptureMode mode, int delay, CaptureRect* rect,
                                  int include_shadow,
                                  int* width, int* height, int* bytes_per_pixel);

// Free image data returned by x11_capture_data
void x11_free_data(unsigned char* data);

// Interactive window/area selection
CaptureRect x11_select_window(void);
// Same, but expand the rect to the WM frame (title bar / decorations)
CaptureRect x11_select_window_title(int include_title);
CaptureRect x11_select_area(void);
CaptureRect x11_get_active_window(void);

// Set X11 _NET_WM_WINDOW_TYPE_NORMAL to prevent window disappearing on focus loss
void x11_set_window_type_normal(void *window_ref);

// Theme corner radii used when rounding captured window corners
void x11_set_corner_radii(float top, float bottom);

#ifdef __cplusplus
}
#endif

@interface ScreenshotCapture : NSObject

+ (BOOL)initializeX11;
+ (void)cleanupX11;
+ (NSString *)captureScreenshotWithMode:(CaptureMode)mode 
                               filename:(NSString *)filename 
                                  delay:(int)delay 
                                   rect:(CaptureRect)rect;
+ (NSString *)captureScreenshotWithMode:(CaptureMode)mode
                               filename:(NSString *)filename
                                  delay:(int)delay
                                   rect:(CaptureRect)rect
                          includeShadow:(BOOL)includeShadow;
+ (NSImage *)captureImageWithMode:(CaptureMode)mode 
                            delay:(int)delay 
                             rect:(CaptureRect)rect;
+ (NSImage *)captureImageWithMode:(CaptureMode)mode
                            delay:(int)delay
                             rect:(CaptureRect)rect
                    includeShadow:(BOOL)includeShadow;
+ (CaptureRect)selectWindow;
+ (CaptureRect)selectWindowWithTitle:(BOOL)includeTitle;
+ (CaptureRect)selectArea;
+ (CaptureRect)getActiveWindow;

@end

#endif /* ScreenshotCapture_h */