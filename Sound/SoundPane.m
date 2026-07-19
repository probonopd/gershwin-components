/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Sound Preference Pane Implementation
 */

#import "SoundPane.h"
#import "SoundController.h"
#import <dispatch/dispatch.h>
#include <stdlib.h>

@implementation SoundPane

+ (BOOL)isCompatible {
  NSString *pathEnv = [NSString stringWithUTF8String: getenv("PATH")];
  NSArray *paths = [pathEnv componentsSeparatedByString: @":"];
  for (NSString *dir in paths) {
    if ([[NSFileManager defaultManager] isExecutableFileAtPath:
          [dir stringByAppendingPathComponent: @"amixer"]])
      return YES;
  }
  return NO;
}

+ (NSString *)compatibilityReason {
  return @"amixer not found — sound configuration requires ALSA";
}

- (id)initWithBundle:(NSBundle *)bundle
{
    self = [super initWithBundle:bundle];
    if (self) {
        controller = [[SoundController alloc] init];
    }
    return self;
}

- (void)dealloc
{
    [self stopRefreshTimer];
    [controller release];
    [super dealloc];
}

- (void)startRefreshTimer
{
    if (!refreshTimer) {
        NSDebugLLog(@"gwcomp", @"SoundPane: Starting device refresh timer (2 second interval)");
        refreshTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                              dispatch_get_main_queue());
        dispatch_source_set_timer(refreshTimer,
                                 dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                                 2 * NSEC_PER_SEC, 0);
        dispatch_source_set_event_handler(refreshTimer, ^{
            [controller refreshDevices];
        });
        dispatch_resume(refreshTimer);
        NSDebugLLog(@"gwcomp", @"SoundPane: Device refresh timer started");
    } else {
        NSDebugLLog(@"gwcomp", @"SoundPane: Refresh timer already running");
    }
}

- (void)stopRefreshTimer
{
    if (refreshTimer) {
        NSDebugLLog(@"gwcomp", @"SoundPane: Stopping device refresh timer");
        dispatch_source_cancel(refreshTimer);
        dispatch_release(refreshTimer);
        refreshTimer = nil;
        NSDebugLLog(@"gwcomp", @"SoundPane: Device refresh timer stopped");
    }
}

- (NSView *)loadMainView
{
    if (_mainView == nil) {
        _mainView = [[controller createMainView] retain];
    }
    return _mainView;
}

- (NSString *)mainNibName
{
    return nil; // We create the view programmatically
}

- (void)mainViewDidLoad
{
    // Initial data refresh
    [controller refreshDevices];
    [self setInitialKeyView:nil];
}

- (void)didSelect
{
    [super didSelect];
    NSDebugLLog(@"gwcomp", @"SoundPane: didSelect called, starting device refresh timer");
    // Refresh data when the pane is selected
    [controller refreshDevices];
    [controller startInputLevelMonitoring];
    // Start periodic device refresh (every 2 seconds)
    [self startRefreshTimer];
    [self setInitialKeyView:nil];
}

- (void)willUnselect
{
    NSDebugLLog(@"gwcomp", @"SoundPane: willUnselect called");
    [controller stopInputLevelMonitoring];
}

- (void)didUnselect
{
    [super didUnselect];
    [self stopRefreshTimer];
    NSDebugLLog(@"gwcomp", @"SoundPane: didUnselect called");
}

- (NSPreferencePaneUnselectReply)shouldUnselect
{
    NSDebugLLog(@"gwcomp", @"SoundPane: shouldUnselect called, allowing unselect");
    return NSUnselectNow;
}

@end
