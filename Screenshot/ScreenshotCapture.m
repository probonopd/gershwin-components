/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */


#import "ScreenshotCapture.h"
#import <AppKit/NSBitmapImageRep.h>
#import <GNUstepGUI/GSTheme.h>

// Optional theme methods (implemented by some themes, e.g. Eau); queried
// with respondsToSelector: like the window manager does.
@interface NSObject (ScreenshotThemeCornerRadii)
- (CGFloat)titlebarCornerRadius;
- (CGFloat)windowBottomCornerRadius;
@end
#import <AppKit/NSImage.h>
#import <Foundation/NSPathUtilities.h>
#import <Foundation/NSDate.h>
#import <Foundation/NSDateFormatter.h>

// Import the C interface
extern int x11_init(void);
extern void x11_cleanup(void);
extern unsigned char* x11_capture_data(CaptureMode mode, int delay, CaptureRect* rect,
                                         int include_shadow,
                                         int* width, int* height, int* bytes_per_pixel);
extern void x11_free_data(unsigned char* data);
extern CaptureRect x11_select_window_title(int include_title);
extern CaptureRect x11_select_area(void);
extern CaptureRect x11_get_active_window(void);
extern void x11_set_corner_radii(float top, float bottom);

@implementation ScreenshotCapture

+ (BOOL)initializeX11 {
    return x11_init() == 1;
}

+ (void)cleanupX11 {
    x11_cleanup();
}

+ (NSString *)captureScreenshotWithMode:(CaptureMode)mode 
                               filename:(NSString *)filename 
                                  delay:(int)delay 
                                   rect:(CaptureRect)rect {
    return [self captureScreenshotWithMode:mode filename:filename delay:delay
                                      rect:rect includeShadow:NO];
}

+ (NSString *)captureScreenshotWithMode:(CaptureMode)mode
                               filename:(NSString *)filename
                                  delay:(int)delay
                                   rect:(CaptureRect)rect
                          includeShadow:(BOOL)includeShadow {
    // Capture image first
    NSImage *image = [self captureImageWithMode:mode delay:delay rect:rect
                                  includeShadow:includeShadow];
    if (!image) {
        return nil;
    }
    
    // Generate filename if not provided
    NSString *filepath = filename;
    if (!filepath || [filepath length] == 0) {
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        [formatter setDateFormat:@"yyyy-MM-dd-HHmmss"];
        NSString *dateString = [formatter stringFromDate:[NSDate date]];
        [formatter release];
        
        NSString *defaultName = [NSString stringWithFormat:@"Screenshot-%@.png", dateString];
        NSArray *desktopPaths = NSSearchPathForDirectoriesInDomains(NSDesktopDirectory, NSUserDomainMask, YES);
        if ([desktopPaths count] > 0) {
            NSString *desktopPath = [desktopPaths objectAtIndex:0];
            filepath = [desktopPath stringByAppendingPathComponent:defaultName];
        } else {
            filepath = defaultName;
        }
    }
    
    // Convert to PNG and save
    NSData *imageData = [image TIFFRepresentation];
    NSBitmapImageRep *bitmap = [NSBitmapImageRep imageRepWithData:imageData];
    if (!bitmap) {
        return nil;
    }
    
    NSData *pngData = [bitmap representationUsingType:NSPNGFileType properties:nil];
    if (!pngData) {
        return nil;
    }
    
    if ([pngData writeToFile:filepath atomically:YES]) {
        return filepath;
    }
    
    return nil;
}

+ (NSImage *)captureImageWithMode:(CaptureMode)mode 
                            delay:(int)delay 
                             rect:(CaptureRect)rect {
    return [self captureImageWithMode:mode delay:delay rect:rect includeShadow:NO];
}

+ (NSImage *)captureImageWithMode:(CaptureMode)mode
                            delay:(int)delay
                             rect:(CaptureRect)rect
                    includeShadow:(BOOL)includeShadow {
    CaptureRect* c_rect = (rect.width > 0 && rect.height > 0) ? &rect : NULL;
    int width, height, bytes_per_pixel;

    // Match the WM's rounded corners: radii come from the current theme
    id theme = [GSTheme theme];
    float topR = 0.0f, bottomR = 0.0f;
    if ([theme respondsToSelector:@selector(titlebarCornerRadius)])
        topR = [theme titlebarCornerRadius];
    if ([theme respondsToSelector:@selector(windowBottomCornerRadius)])
        bottomR = [theme windowBottomCornerRadius];
    x11_set_corner_radii(topR, bottomR);

    unsigned char* data = x11_capture_data((int)mode, delay, c_rect,
                                           includeShadow ? 1 : 0,
                                           &width, &height, &bytes_per_pixel);
    if (!data) {
        return nil;
    }
    
    // Copy the data since NSBitmapImageRep might not take ownership
    int dataLength = width * height * bytes_per_pixel;
    unsigned char* dataCopy = malloc(dataLength);
    if (!dataCopy) {
        x11_free_data(data);
        return nil;
    }
    memcpy(dataCopy, data, dataLength);
    
    // Create NSBitmapImageRep from the raw data
    // Pass NULL for planes to let it allocate, then copy our data
    NSBitmapImageRep* bitmap = [[NSBitmapImageRep alloc] 
        initWithBitmapDataPlanes:NULL
                      pixelsWide:width
                      pixelsHigh:height
                   bitsPerSample:8
                 samplesPerPixel:4
                        hasAlpha:YES
                        isPlanar:NO
                  colorSpaceName:NSCalibratedRGBColorSpace
                    bitmapFormat:NSAlphaNonpremultipliedBitmapFormat
                     bytesPerRow:width * bytes_per_pixel
                    bitsPerPixel:32];
    
    if (!bitmap) {
        free(dataCopy);
        x11_free_data(data);
        return nil;
    }
    
    // Copy our data into the bitmap's buffer
    unsigned char* bitmapData = [bitmap bitmapData];
    memcpy(bitmapData, dataCopy, dataLength);
    
    // Create NSImage from the bitmap
    NSImage* image = [[NSImage alloc] init];
    [image addRepresentation:bitmap];
    [bitmap release];
    
    free(dataCopy);
    x11_free_data(data);
    return [image autorelease];
}

+ (CaptureRect)selectWindow {
    return [self selectWindowWithTitle:NO];
}

+ (CaptureRect)selectWindowWithTitle:(BOOL)includeTitle {
    return x11_select_window_title(includeTitle ? 1 : 0);
}

+ (CaptureRect)selectArea {
    return x11_select_area();
}

+ (CaptureRect)getActiveWindow {
    return x11_get_active_window();
}

@end