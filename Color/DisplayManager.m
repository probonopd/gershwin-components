/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DisplayManager.h"
#import <X11/Xlib.h>
#import <X11/extensions/Xrandr.h>

@implementation DisplayManager

- (id)init
{
    self = [super init];
    if (self) {
        _display = XOpenDisplay(NULL);
        if (_display) {
            _screen = DefaultScreen((Display *)_display);
            _root = RootWindow((Display *)_display, _screen);
        }
    }
    return self;
}

- (void)dealloc
{
    if (_display) {
        XCloseDisplay((Display *)_display);
    }
    [super dealloc];
}

- (BOOL)isAvailable
{
    return _display != NULL;
}

- (NSArray<NSString *> *)listDisplays
{
    if (!_display) return [NSArray array];

    Display *dpy = (Display *)_display;
    XRRScreenResources *res = XRRGetScreenResources(dpy, _root);
    if (!res) return [NSArray array];

    NSMutableArray *displays = [NSMutableArray array];
    for (int i = 0; i < res->noutput; i++) {
        XRROutputInfo *info = XRRGetOutputInfo(dpy, res, res->outputs[i]);
        if (info && info->connection == RR_Connected && info->crtc) {
            NSString *name = [NSString stringWithUTF8String:info->name];
            if (name) [displays addObject:name];
        }
        if (info) XRRFreeOutputInfo(info);
    }
    XRRFreeScreenResources(res);
    return displays;
}

- (NSString *)outputIdentifierForDisplay:(NSString *)displayName
{
    if (!_display || !displayName) return nil;

    Display *dpy = (Display *)_display;
    XRRScreenResources *res = XRRGetScreenResources(dpy, _root);
    if (!res) return nil;

    const char *targetName = [displayName UTF8String];
    NSString *outputName = nil;

    for (int i = 0; i < res->noutput; i++) {
        XRROutputInfo *info = XRRGetOutputInfo(dpy, res, res->outputs[i]);
        if (info && strcmp(info->name, targetName) == 0) {
            outputName = [NSString stringWithUTF8String:info->name];
            XRRFreeOutputInfo(info);
            break;
        }
        if (info) XRRFreeOutputInfo(info);
    }
    XRRFreeScreenResources(res);
    return outputName;
}

- (unsigned long)crtcForDisplay:(NSString *)displayName
{
    if (!_display || !displayName) return 0;

    Display *dpy = (Display *)_display;
    XRRScreenResources *res = XRRGetScreenResources(dpy, _root);
    if (!res) return 0;

    const char *targetName = [displayName UTF8String];
    unsigned long crtc = 0;

    for (int i = 0; i < res->noutput; i++) {
        XRROutputInfo *info = XRRGetOutputInfo(dpy, res, res->outputs[i]);
        if (info && strcmp(info->name, targetName) == 0) {
            crtc = info->crtc;
            XRRFreeOutputInfo(info);
            break;
        }
        if (info) XRRFreeOutputInfo(info);
    }
    XRRFreeScreenResources(res);
    return crtc;
}

- (NSString *)savedProfileForDisplay:(NSString *)displayName
{
    if (!displayName) return nil;

    NSString *key = [NSString stringWithFormat:@"ColorProfile_%@", displayName];
    return [[NSUserDefaults standardUserDefaults] stringForKey:key];
}

- (void)saveProfile:(NSString *)profilePath forDisplay:(NSString *)displayName
{
    if (!displayName) return;

    NSString *key = [NSString stringWithFormat:@"ColorProfile_%@", displayName];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (profilePath) {
        [defaults setObject:profilePath forKey:key];
    } else {
        [defaults removeObjectForKey:key];
    }
    [defaults synchronize];
}

@end
