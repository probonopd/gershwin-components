/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "ProfileApplier.h"

#include <X11/Xlib.h>
#include <X11/extensions/Xrandr.h>

@implementation ProfileApplier
{
    Display *_dpy;
    NSMutableDictionary *_activeProfiles;
}

- (id)init
{
    self = [super init];
    if (self) {
        _dpy = XOpenDisplay(NULL);
        _activeProfiles = [[NSMutableDictionary alloc] init];

        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        NSDictionary *saved = [defaults dictionaryForKey:@"ColorActiveProfiles"];
        if (saved) {
            [_activeProfiles addEntriesFromDictionary:saved];
        }
    }
    return self;
}

- (void)dealloc
{
    if (_dpy) XCloseDisplay(_dpy);
    [_activeProfiles release];
    [super dealloc];
}

- (BOOL)isAvailable
{
    if (!_dpy) return NO;
    int eventBase, errorBase;
    return XRRQueryExtension(_dpy, &eventBase, &errorBase);
}

- (BOOL)xcalibAvailable
{
    return [[NSFileManager defaultManager] isExecutableFileAtPath:@"/usr/bin/xcalib"];
}

- (BOOL)applyProfile:(NSString *)profilePath forDisplay:(NSString *)displayName
{
    if (!profilePath || !displayName) return NO;

    if ([self xcalibAvailable]) {
        return [self applyViaXcalib:profilePath display:displayName];
    }

    return [self applyViaXrandrGamma:profilePath display:displayName];
}

- (BOOL)applyViaXcalib:(NSString *)profilePath display:(NSString *)displayName
{
    NSTask *task = [[NSTask alloc] init];
    NSPipe *errPipe = [NSPipe pipe];
    [task setLaunchPath:@"/usr/bin/xcalib"];
    [task setArguments:@[@"-output", displayName, @"-load", profilePath]];
    [task setStandardError:errPipe];

    @try {
        [task launch];
        [task waitUntilExit];
        if ([task terminationStatus] == 0) {
            [_activeProfiles setObject:profilePath forKey:displayName];
            [self saveActiveProfiles];
            [task release];
            return YES;
        }
    } @catch (NSException *e) {
        [task release];
        return NO;
    }

    [task release];
    return NO;
}

- (BOOL)applyViaXrandrGamma:(NSString *)profilePath display:(NSString *)displayName
{
    return NO;
}

- (BOOL)revertForDisplay:(NSString *)displayName
{
    if (!displayName) return NO;

    if ([self xcalibAvailable] && displayName) {
        NSTask *task = [[NSTask alloc] init];
        [task setLaunchPath:@"/usr/bin/xcalib"];
        [task setArguments:@[@"-output", displayName, @"-clear"]];
        @try {
            [task launch];
            [task waitUntilExit];
        } @catch (NSException *e) {
            [task release];
            return NO;
        }
        [task release];
    }

    [_activeProfiles removeObjectForKey:displayName];
    [self saveActiveProfiles];
    return YES;
}

- (NSString *)activeProfileForDisplay:(NSString *)displayName
{
    return [_activeProfiles objectForKey:displayName];
}

- (void)saveActiveProfiles
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:_activeProfiles forKey:@"ColorActiveProfiles"];
    [defaults synchronize];
}

@end
