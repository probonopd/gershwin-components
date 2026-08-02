/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "X11DisplayManager.h"
#import "DisplayController.h"

#import <X11/Xlib.h>
#import <X11/extensions/Xrandr.h>
#import <stdlib.h>

@implementation X11DisplayManager

- (id)init
{
    self = [super init];
    if (self) {
        _display = NULL;
        _screen = 0;
        _root = 0;
    }
    return self;
}

- (void)dealloc
{
    [self disconnect];
    [super dealloc];
}

- (BOOL)connect
{
    if (_display) return YES;

    // Get DISPLAY from the actual process environment
    const char *dpyName = getenv("DISPLAY");
    if (!dpyName) dpyName = ":0";
    NSDebugLog(@"X11DisplayManager: opening display '%s'", dpyName);
    _display = XOpenDisplay(dpyName);
    if (!_display) {
        NSDebugLog(@"X11DisplayManager: XOpenDisplay(\"%s\") failed", dpyName);
        return NO;
    }
    _screen = DefaultScreen((Display *)_display);
    _root = RootWindow((Display *)_display, _screen);

    NSDebugLog(@"X11DisplayManager: connected to X11 display");
    return YES;
}

- (void)disconnect
{
    if (_display) {
        XCloseDisplay((Display *)_display);
        _display = NULL;
    }
}

- (BOOL)isAvailable
{
    if (!_display) {
        [self connect];
    }
    return _display != NULL;
}

#pragma mark - Query

- (NSArray<DisplayInfo *> *)listOutputs
{
    if (![self connect]) return nil;

    Display *dpy = (Display *)_display;
    XRRScreenResources *res = XRRGetScreenResourcesCurrent(dpy, _root);
    if (!res) {
        NSDebugLog(@"X11DisplayManager: XRRGetScreenResourcesCurrent failed");
        return nil;
    }

    NSMutableArray *result = [NSMutableArray array];

    for (int i = 0; i < res->noutput; i++) {
        XRROutputInfo *oi = XRRGetOutputInfo(dpy, res, res->outputs[i]);
        if (!oi) continue;

        BOOL connected = (oi->connection == RR_Connected);
        NSString *outputName = [[[NSString alloc] initWithBytes:oi->name
                                                         length:oi->nameLen
                                                       encoding:NSUTF8StringEncoding] autorelease];

        // Collect all available resolution strings for this output
        NSMutableArray *availRes = [NSMutableArray array];
        for (int m = 0; m < oi->nmode; m++) {
            for (int j = 0; j < res->nmode; j++) {
                if (res->modes[j].id == oi->modes[m]) {
                    NSString *r = [NSString stringWithFormat:@"%dx%d",
                                             res->modes[j].width,
                                             res->modes[j].height];
                    if (![availRes containsObject:r]) {
                        [availRes addObject:r];
                    }
                    break;
                }
            }
        }

        DisplayInfo *di = [[DisplayInfo alloc] init];
        [di setOutput:outputName];
        [di setName:outputName];
        [di setIsConnected:connected];
        [di setIsPrimary:NO];
        [di setCurrentResolutionString:nil];
        [di setAvailableResolutions:availRes];

        if (connected && oi->crtc && oi->nmode > 0) {
            XRRCrtcInfo *ci = XRRGetCrtcInfo(dpy, res, oi->crtc);
            if (ci) {
                [di setFrame:NSMakeRect(ci->x, ci->y, ci->width, ci->height)];
                [di setResolution:NSMakeSize(ci->width, ci->height)];

                // Find the current mode info
                for (int j = 0; j < res->nmode; j++) {
                    if (res->modes[j].id == ci->mode) {
                        NSString *resStr = [NSString stringWithFormat:@"%dx%d",
                                                     res->modes[j].width,
                                                     res->modes[j].height];
                        [di setCurrentResolutionString:resStr];
                        break;
                    }
                }

                XRRFreeCrtcInfo(ci);
            }

            // Check primary — the X server tracks this per-output
            if (res->noutput > 0 && res->outputs[i] == XRRGetOutputPrimary(dpy, _root)) {
                [di setIsPrimary:YES];
            }

            [result addObject:di];
        } else if (connected) {
            // Connected but no CRTC yet — give it defaults so it appears in the UI
            [di setResolution:NSMakeSize(1920, 1080)];
            [di setFrame:NSMakeRect(0, 0, 1920, 1080)];
            if ([availRes count] == 0) {
                [availRes addObject:@"1920x1080"];
            }
            [result addObject:di];
        }

        [di release];
        XRRFreeOutputInfo(oi);
    }

    XRRFreeScreenResources(res);

    // If no display was marked primary, mark the first one
    BOOL hasPrimary = NO;
    for (DisplayInfo *d in result) {
        if ([d isPrimary]) { hasPrimary = YES; break; }
    }
    if (!hasPrimary && [result count] > 0) {
        [[result objectAtIndex:0] setIsPrimary:YES];
    }

    return result;
}

#pragma mark - Mode / Position

- (BOOL)setMode:(NSString *)output
          mode:(NSString *)modeId
    positionX:(int)x
    positionY:(int)y
{
    if (![self connect]) return NO;
    Display *dpy = (Display *)_display;

    XRRScreenResources *res = XRRGetScreenResourcesCurrent(dpy, _root);
    if (!res) return NO;

    // Parse the target resolution from the mode string (e.g. "1920x1080")
    int targetW = 0, targetH = 0;
    NSScanner *scanner = [NSScanner scannerWithString:modeId];
    [scanner scanInt:&targetW];
    if ([scanner scanString:@"x" intoString:NULL] || [scanner scanString:@"X" intoString:NULL]) {
        [scanner scanInt:&targetH];
    }
    if (targetW <= 0 || targetH <= 0) {
        NSDebugLog(@"X11DisplayManager: invalid mode string: %@", modeId);
        XRRFreeScreenResources(res);
        return NO;
    }

    BOOL ok = NO;
    for (int i = 0; i < res->noutput; i++) {
        XRROutputInfo *oi = XRRGetOutputInfo(dpy, res, res->outputs[i]);
        if (!oi) continue;
        NSString *nm = [[[NSString alloc] initWithBytes:oi->name
                                                 length:oi->nameLen
                                               encoding:NSUTF8StringEncoding] autorelease];
        if (![nm isEqualToString:output] || !oi->crtc) {
            XRRFreeOutputInfo(oi);
            continue;
        }

        XRRCrtcInfo *ci = XRRGetCrtcInfo(dpy, res, oi->crtc);
        if (!ci) { XRRFreeOutputInfo(oi); continue; }

        // Find the RRMode matching targetW x targetH
        RRMode targetRRMode = None;
        for (int j = 0; j < res->nmode; j++) {
            if ((int)res->modes[j].width == targetW && (int)res->modes[j].height == targetH) {
                targetRRMode = res->modes[j].id;
                break;
            }
        }

        if (targetRRMode) {
            Status st = XRRSetCrtcConfig(dpy, res, oi->crtc, CurrentTime,
                                          x, y, targetRRMode, ci->rotation,
                                          ci->outputs, ci->noutput);
            NSDebugLog(@"X11DisplayManager: setMode %@ -> %s pos %d,%d (st=%d)",
                  output, [modeId UTF8String], x, y, (int)st);
            ok = (st == Success);
        } else {
            NSDebugLog(@"X11DisplayManager: mode %dx%d not found for %@", targetW, targetH, output);
        }

        XRRFreeCrtcInfo(ci);
        XRRFreeOutputInfo(oi);
        break;
    }

    XSync(dpy, False);

    /* XRRSetCrtcConfig only changes the output's mode; the root window (and
     * therefore the X screen size that the Menu bar, Workspace etc. size to)
     * is not resized unless XRRSetScreenSize is called - which the xrandr
     * CLI does automatically.  Compute the bounding box of all configured
     * CRTCs and resize the screen to it, keeping the physical size (mm) so
     * the DPI follows the new resolution like xrandr does.
     *
     * Always call XRRSetScreenSize: the client's cached DisplayWidth/Height on
     * this raw connection is NOT refreshed when other clients (or a previous
     * call) change the screen size, so comparing against it would skip the
     * resize whenever the cache is stale.  Setting the same size is a no-op. */
    if (ok) {
        int bw = 0, bh = 0;
        for (int i = 0; i < res->noutput; i++) {
            XRROutputInfo *oi = XRRGetOutputInfo(dpy, res, res->outputs[i]);
            if (oi) {
                if (oi->crtc) {
                    XRRCrtcInfo *ci = XRRGetCrtcInfo(dpy, res, oi->crtc);
                    if (ci) {
                        int right = ci->x + ci->width;
                        int bottom = ci->y + ci->height;
                        if (right > bw) bw = right;
                        if (bottom > bh) bh = bottom;
                        XRRFreeCrtcInfo(ci);
                    }
                }
                XRRFreeOutputInfo(oi);
            }
        }
        if (bw > 0 && bh > 0) {
            /* Same 96 DPI assumption the other screen-size calls in this file
             * use, so the physical size stays consistent across resolutions. */
            int mmW = (int)(bw * 25.4 / 96.0);
            int mmH = (int)(bh * 25.4 / 96.0);
            XRRSetScreenSize(dpy, _root, bw, bh, mmW, mmH);
        }
    }

    XRRFreeScreenResources(res);
    return ok;
}

- (BOOL)setPosition:(NSString *)output x:(int)x y:(int)y
{
    if (![self connect]) return NO;
    Display *dpy = (Display *)_display;

    XRRScreenResources *res = XRRGetScreenResourcesCurrent(dpy, _root);
    if (!res) return NO;

    BOOL ok = NO;
    for (int i = 0; i < res->noutput; i++) {
        XRROutputInfo *oi = XRRGetOutputInfo(dpy, res, res->outputs[i]);
        if (!oi) continue;
        NSString *nm = [[[NSString alloc] initWithBytes:oi->name
                                                 length:oi->nameLen
                                               encoding:NSUTF8StringEncoding] autorelease];
        if (![nm isEqualToString:output] || !oi->crtc) {
            XRRFreeOutputInfo(oi);
            continue;
        }

        XRRCrtcInfo *ci = XRRGetCrtcInfo(dpy, res, oi->crtc);
        if (!ci) { XRRFreeOutputInfo(oi); continue; }

        Status st = XRRSetCrtcConfig(dpy, res, oi->crtc, CurrentTime,
                                      x, y, ci->mode, ci->rotation,
                                      ci->outputs, ci->noutput);
        NSDebugLog(@"X11DisplayManager: setPosition %@ %d,%d (st=%d)", output, x, y, (int)st);
        ok = (st == Success);
        XRRFreeCrtcInfo(ci);
        XRRFreeOutputInfo(oi);
        break;
    }

    XSync(dpy, False);
    XRRFreeScreenResources(res);
    return ok;
}

#pragma mark - Batch operations

- (BOOL)applyPositions:(NSDictionary<NSString *, NSValue *> *)placements
{
    if (![self connect]) return NO;
    Display *dpy = (Display *)_display;

    XRRScreenResources *res = XRRGetScreenResourcesCurrent(dpy, _root);
    if (!res) return NO;

    // Build output-name -> desired position lookup
    NSMutableDictionary *posMap = [NSMutableDictionary dictionary];
    for (NSString *key in placements) {
        NSPoint pt = [placements[key] pointValue];
        posMap[key] = [NSValue valueWithPoint:pt];
    }

    // Calculate bounding box of the new layout
    int newW = 0, newH = 0;
    for (int i = 0; i < res->noutput; i++) {
        XRROutputInfo *oi = XRRGetOutputInfo(dpy, res, res->outputs[i]);
        if (!oi) continue;
        NSString *nm = [[[NSString alloc] initWithBytes:oi->name
                                                 length:oi->nameLen
                                               encoding:NSUTF8StringEncoding] autorelease];
        if (oi->crtc) {
            XRRCrtcInfo *ci = XRRGetCrtcInfo(dpy, res, oi->crtc);
            if (ci) {
                int x = ci->x, y = ci->y;
                NSValue *val = posMap[nm];
                if (val) { NSPoint p = [val pointValue]; x = p.x; y = p.y; }
                // Find the mode dimensions for this CRTC
                unsigned int modeW = 0, modeH = 0;
                for (int j = 0; j < res->nmode; j++) {
                    if (res->modes[j].id == ci->mode) {
                        modeW = res->modes[j].width;
                        modeH = res->modes[j].height;
                        break;
                    }
                }
                int right = x + (int)modeW;
                int bottom = y + (int)modeH;
                if (right  > newW) newW = right;
                if (bottom > newH) newH = bottom;
                XRRFreeCrtcInfo(ci);
            }
        }
        XRRFreeOutputInfo(oi);
    }

    // Expand screen to cover the new layout BEFORE moving CRTCs
    int curW = DisplayWidth(dpy, _screen);
    int curH = DisplayHeight(dpy, _screen);
    if (newW > curW || newH > curH) {
        int w = (newW > curW) ? newW : curW;
        int h = (newH > curH) ? newH : curH;
        NSDebugLog(@"X11DisplayManager: expanding screen to %dx%d", w, h);

        // XRRSetScreenSize needs mm dimensions; estimate from dpi
        int mmW = (int)(w * 25.4 / 96.0);
        int mmH = (int)(h * 25.4 / 96.0);
        XRRSetScreenSize(dpy, _root, w, h, mmW, mmH);
        XSync(dpy, False);

        XRRFreeScreenResources(res);
        res = XRRGetScreenResourcesCurrent(dpy, _root);
        if (!res) return NO;
    }

    // Move each CRTC that has a new position
    BOOL allOk = YES;
    for (int i = 0; i < res->noutput; i++) {
        XRROutputInfo *oi = XRRGetOutputInfo(dpy, res, res->outputs[i]);
        if (!oi) continue;
        NSString *nm = [[[NSString alloc] initWithBytes:oi->name
                                                 length:oi->nameLen
                                               encoding:NSUTF8StringEncoding] autorelease];
        NSValue *val = posMap[nm];
        if (oi->crtc && val) {
            XRRCrtcInfo *ci = XRRGetCrtcInfo(dpy, res, oi->crtc);
            if (ci) {
                NSPoint p = [val pointValue];
                Status st = XRRSetCrtcConfig(dpy, res, oi->crtc, CurrentTime,
                                              (int)p.x, (int)p.y, ci->mode, ci->rotation,
                                              ci->outputs, ci->noutput);
                NSDebugLog(@"X11DisplayManager: moved %@ to %.0f,%.0f (st=%d)", nm, p.x, p.y, (int)st);
                if (st != Success) allOk = NO;
                XRRFreeCrtcInfo(ci);
            }
        }
        XRRFreeOutputInfo(oi);
    }

    // Shrink screen if layout got smaller
    if (newW < curW || newH < curH) {
        int w = (newW > 0) ? newW : curW;
        int h = (newH > 0) ? newH : curH;
        NSDebugLog(@"X11DisplayManager: shrinking screen to %dx%d", w, h);
        int mmW = (int)(w * 25.4 / 96.0);
        int mmH = (int)(h * 25.4 / 96.0);
        XRRSetScreenSize(dpy, _root, w, h, mmW, mmH);
    }

    XSync(dpy, False);
    XRRFreeScreenResources(res);
    return allOk;
}

- (BOOL)setScreenSize:(int)width height:(int)height
{
    if (![self connect]) return NO;
    Display *dpy = (Display *)_display;

    int mmW = (int)(width  * 25.4 / 96.0);
    int mmH = (int)(height * 25.4 / 96.0);
    XRRSetScreenSize(dpy, _root, width, height, mmW, mmH);
    XSync(dpy, False);
    return YES;
}

- (BOOL)setPrimaryOutput:(NSString *)output
{
    if (![self connect]) return NO;
    Display *dpy = (Display *)_display;

    XRRScreenResources *res = XRRGetScreenResourcesCurrent(dpy, _root);
    if (!res) return NO;

    BOOL ok = NO;
    for (int i = 0; i < res->noutput; i++) {
        XRROutputInfo *oi = XRRGetOutputInfo(dpy, res, res->outputs[i]);
        if (!oi) continue;
        NSString *nm = [[[NSString alloc] initWithBytes:oi->name
                                                 length:oi->nameLen
                                               encoding:NSUTF8StringEncoding] autorelease];
        if ([nm isEqualToString:output]) {
            XRRSetOutputPrimary(dpy, _root, res->outputs[i]);
            XSync(dpy, False);
            ok = YES;
            XRRFreeOutputInfo(oi);
            break;
        }
        XRRFreeOutputInfo(oi);
    }

    XRRFreeScreenResources(res);
    return ok;
}

@end
