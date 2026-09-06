/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import "GSAssistantFramework.h"
#import "ColorAssistantPages.h"
#import "ProfileGenerator.h"
#import "ColorAssistantDelegate.h"

#include <X11/Xlib.h>
#include <X11/extensions/Xrandr.h>

static int X11ErrorHandler(Display *dpy, XErrorEvent *ev)
{
    char buf[256];
    XGetErrorText(dpy, ev->error_code, buf, sizeof(buf));
    NSLog(@"X11 error: request=%d code=%d %s", ev->request_code, ev->error_code, buf);
    return 0;
}

@interface GammaController : NSObject
{
    Display *_dpy;
    RRCrtc _crtc;
    int _rampSize;
    XRRCrtcGamma *_savedGamma;
}

- (BOOL)selectDisplay:(NSString *)outputName;
- (BOOL)canCalibrate;
- (void)applyGamma:(double)gamma whitePoint:(double)wp;
- (void)applyToneWithShadows:(double)s midtones:(double)m highlights:(double)h;
- (void)reset;
@end

@implementation GammaController

- (id)init
{
    self = [super init];
    if (self) {
        _dpy = XOpenDisplay(NULL);
        if (_dpy) {
            XSetErrorHandler(X11ErrorHandler);
        }
        _crtc = None;
        _rampSize = 0;
        _savedGamma = NULL;
    }
    return self;
}

- (void)dealloc
{
    if (_savedGamma) XRRFreeGamma(_savedGamma);
    if (_dpy) XCloseDisplay(_dpy);
}

- (BOOL)selectDisplay:(NSString *)outputName
{
    if (!_dpy || !outputName) return NO;

    Window root = RootWindow(_dpy, DefaultScreen(_dpy));
    XRRScreenResources *res = XRRGetScreenResources(_dpy, root);
    if (!res) return NO;

    for (int i = 0; i < res->noutput; i++) {
        XRROutputInfo *info = XRRGetOutputInfo(_dpy, res, res->outputs[i]);
        if (info) {
            NSString *name = [NSString stringWithUTF8String:info->name];
            if ([name isEqualToString:outputName]) {
                _crtc = info->crtc;
                XRRFreeOutputInfo(info);
                break;
            }
            XRRFreeOutputInfo(info);
        }
    }
    XRRFreeScreenResources(res);

    if (_crtc == None) return NO;

    XRRCrtcGamma *current = XRRGetCrtcGamma(_dpy, _crtc);
    if (current) {
        _rampSize = current->size;
        if (_savedGamma) XRRFreeGamma(_savedGamma);
        _savedGamma = current;
    }
    return (_rampSize > 0);
}

/* Whether ANY output on this display has a usable gamma ramp.  On headless
 * or virtual systems (Xvfb, containers) there is none, so calibration is
 * impossible and the app shows an error page instead of a broken wizard. */
- (BOOL)canCalibrate
{
    if (!_dpy) return NO;
    Window root = RootWindow(_dpy, DefaultScreen(_dpy));
    XRRScreenResources *res = XRRGetScreenResources(_dpy, root);
    if (!res) return NO;
    BOOL ok = NO;
    for (int i = 0; i < res->noutput; i++) {
        XRROutputInfo *info = XRRGetOutputInfo(_dpy, res, res->outputs[i]);
        if (info) {
            if (info->crtc != None) {
                XRRCrtcGamma *gamma = XRRGetCrtcGamma(_dpy, info->crtc);
                if (gamma) {
                    ok = (gamma->size > 0);
                    XRRFreeGamma(gamma);
                }
            }
            XRRFreeOutputInfo(info);
        }
        if (ok) break;
    }
    XRRFreeScreenResources(res);
    return ok;
}

- (void)applyGamma:(double)gamma whitePoint:(double)wp
{
    if (!_dpy || _crtc == None || _rampSize == 0) return;

    XRRCrtcGamma *gammaRamp = XRRAllocGamma(_rampSize);
    double g = (gamma < 0.1) ? 1.0 : (1.0 / gamma);

    double rMult = 1.0, gMult = 1.0, bMult = 1.0;
    if (wp < 6499) {
        double t = (6500.0 - wp) / 1500.0;
        rMult = 1.0 + t * 0.12;
        gMult = 1.0 + t * 0.04;
        bMult = 1.0 - t * 0.20;
    } else if (wp > 6501) {
        double t = (wp - 6500.0) / 1000.0;
        rMult = 1.0 - t * 0.15;
        gMult = 1.0 - t * 0.03;
        bMult = 1.0 + t * 0.12;
    }
    double avg = (rMult + gMult + bMult) / 3.0;
    rMult /= avg; gMult /= avg; bMult /= avg;

    for (int i = 0; i < _rampSize; i++) {
        double v = (double)i / (_rampSize - 1);
        double corrected = pow(v, g);
        gammaRamp->red[i] = (unsigned short)MIN(corrected * rMult * 65535.0, 65535.0);
        gammaRamp->green[i] = (unsigned short)MIN(corrected * gMult * 65535.0, 65535.0);
        gammaRamp->blue[i] = (unsigned short)MIN(corrected * bMult * 65535.0, 65535.0);
    }

    XRRSetCrtcGamma(_dpy, _crtc, gammaRamp);
    XRRFreeGamma(gammaRamp);
}

- (void)applyToneWithShadows:(double)s midtones:(double)m highlights:(double)h
{
    if (!_dpy || _crtc == None || _rampSize == 0) return;

    XRRCrtcGamma *gammaRamp = XRRAllocGamma(_rampSize);

    for (int i = 0; i < _rampSize; i++) {
        double v = (double)i / (_rampSize - 1);
        if (v < 0.25) {
            v = pow(v, 1.0 / (s * 0.5 + 0.5));
        } else if (v < 0.75) {
            v = pow(v, 1.0 / (m * 0.5 + 0.5));
        } else {
            v = pow(v, 1.0 / (h * 0.5 + 0.5));
        }
        unsigned short val = (unsigned short)(v * 65535.0);
        gammaRamp->red[i] = val;
        gammaRamp->green[i] = val;
        gammaRamp->blue[i] = val;
    }

    XRRSetCrtcGamma(_dpy, _crtc, gammaRamp);
    XRRFreeGamma(gammaRamp);
}

- (void)reset
{
    if (!_dpy || _crtc == None || !_savedGamma) return;
    XRRSetCrtcGamma(_dpy, _crtc, _savedGamma);
}

@end

@implementation ColorAssistantDelegate

- (void)updateSelectedDisplay:(NSString *)v
{
    _selectedDisplay = [v copy];
}

- (NSString *)selectedDisplay
{
    return _selectedDisplay;
}

- (void)setWhitePoint:(double)v { _whitePoint = v; }
- (double)whitePoint { return _whitePoint; }
- (void)setGammaValue:(double)v { _gammaValue = v; }
- (double)gammaValue { return _gammaValue; }
- (void)setShadows:(double)v { _shadows = v; }
- (double)shadows { return _shadows; }
- (void)setMidtones:(double)v { _midtones = v; }
- (double)midtones { return _midtones; }
- (void)setHighlights:(double)v { _highlights = v; }
- (double)highlights { return _highlights; }
- (void)setAdvancedEnabled:(BOOL)v { _advancedEnabled = v; }
- (BOOL)advancedEnabled { return _advancedEnabled; }
- (GammaController *)gammaCtrl { return _gammaCtrl; }

- (id)init
{
    self = [super init];
    if (self) {
        _whitePoint = 6500.0;
        _gammaValue = 2.2;
        _shadows = 1.0;
        _midtones = 1.0;
        _highlights = 1.0;
        _advancedEnabled = NO;
        _gammaCtrl = [[GammaController alloc] init];
    }
    return self;
}

- (void)dealloc
{
    [_gammaCtrl reset];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender
{
    return YES;
}

- (void)assistantWindowDidFinish:(GSAssistantWindow *)window
{
    CASavePage *savePage = nil;
    NSArray *steps = [window steps];
    for (id<GSAssistantStepProtocol> step in steps) {
        if ([step isKindOfClass:[CASavePage class]]) {
            savePage = (CASavePage *)step;
            break;
        }
    }

    if (!savePage) return;

    NSString *profileName = [savePage profileName];
    BOOL allUsers = [savePage forAllUsers];

    if ([_selectedDisplay length] > 0 && [profileName length] > 0) {
        NSString *dir = [ProfileGenerator profilesDirectoryForAllUsers:allUsers];
        NSString *path = [dir stringByAppendingPathComponent:
            [profileName stringByAppendingPathExtension:@"icc"]];

        BOOL ok = [ProfileGenerator generateProfileAtPath:path
                                                     name:profileName
                                               whitePoint:_whitePoint
                                                    gamma:_gammaValue
                                               forAllUsers:allUsers];
        if (ok) {
            [[NSDistributedNotificationCenter defaultCenter]
                postNotificationName:@"ColorProfileDidChangeNotification"
                              object:nil
                            userInfo:nil
                  deliverImmediately:YES];
        } else {
            NSRunAlertPanel(@"ColorAssistant",
                @"Failed to save profile.", @"OK", nil, nil);
            return;
        }
    }
    [_gammaCtrl reset];
    [NSApp terminate:nil];
}

- (void)assistantWindowDidCancel:(GSAssistantWindow *)window
{
    [_gammaCtrl reset];
}

@end

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        [NSApplication sharedApplication];

        ColorAssistantDelegate *delegate = [[ColorAssistantDelegate alloc] init];
        [NSApp setDelegate:delegate];

        CADisplayPage *display = [[CADisplayPage alloc] init];
        CAWhitePointPage *whitePoint = [[CAWhitePointPage alloc] init];
        CAGammaPage *gamma = [[CAGammaPage alloc] init];
        CAResponsePage *response = [[CAResponsePage alloc] init];
        CASavePage *save = [[CASavePage alloc] init];

        GSAssistantBuilder *builder = [GSAssistantBuilder builder];
        [builder withTitle:@"Display Calibrator Assistant"];
        [builder withIcon:[NSImage imageNamed:@"NSApplicationIcon"]];
        [builder allowingCancel:YES];
        [builder withDelegate:delegate];
        [builder addStep:display];
        [builder addStep:gamma];
        [builder addStep:whitePoint];
        [builder addStep:response];
        [builder addStep:save];

        GSAssistantWindow *assistant = [builder build];
        [assistant setDelegate:delegate];
        [[assistant window] makeKeyAndOrderFront:nil];

        /* On systems without a calibratable display (headless, Xvfb,
         * containers) the wizard would be useless and the gamma sliders
         * would silently do nothing.  Show an explicit error page instead
         * of pretending calibration works. */
        if (![[delegate gammaCtrl] canCalibrate]) {
            [assistant showErrorPageWithTitle:@"Display Calibrator Assistant"
                message:@"Display calibration is not available on this system.\n"
                       "There is no display whose color output can be adjusted."];
        }

        [NSApp run];
    }
    return 0;
}
