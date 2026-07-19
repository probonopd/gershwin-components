/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "EnergyPane.h"
#import "EnergyController.h"
#include <stdlib.h>

@implementation EnergyPane

+ (BOOL)isCompatible {
  NSString *pathEnv = [NSString stringWithUTF8String: getenv("PATH")];
  NSArray *paths = [pathEnv componentsSeparatedByString: @":"];
  for (NSString *dir in paths) {
    if ([[NSFileManager defaultManager] isExecutableFileAtPath:
          [dir stringByAppendingPathComponent: @"xset"]])
      return YES;
  }
  return NO;
}

+ (NSString *)compatibilityReason {
  return @"xset not found — power management requires X11";
}

- (id)initWithBundle:(NSBundle *)bundle
{
    self = [super initWithBundle:bundle];
    if (self) {
        controller = [[EnergyController alloc] init];
    }
    return self;
}

- (void)dealloc
{
    [pollTimer invalidate];
    [pollTimer release];
    [controller release];
    [super dealloc];
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
    return nil;
}

- (void)mainViewDidLoad
{
    [controller refreshFromSystem];
}

- (void)didSelect
{
    [super didSelect];
    [controller refreshFromSystem];
    // Poll battery/power status every second while visible
    [self startPolling];
}

- (void)didUnselect
{
    [self stopPolling];
    [super didUnselect];
}

- (BOOL)autoSaveTextFields
{
    return YES;
}

#pragma mark - Polling

- (void)startPolling
{
    if (pollTimer) return;
    pollTimer = [[NSTimer scheduledTimerWithTimeInterval:1.0
                                                  target:self
                                                selector:@selector(pollTick:)
                                                userInfo:nil
                                                 repeats:YES] retain];
}

- (void)stopPolling
{
    if (!pollTimer) return;
    [pollTimer invalidate];
    [pollTimer release];
    pollTimer = nil;
}

- (void)pollTick:(NSTimer *)timer
{
    (void)timer;
    [controller pollBattery];
}

@end
